use std::hash::Hasher;

use base64::Engine;
use ed25519_dalek::{Signature, VerifyingKey};
use hkdf::Hkdf;
use sha2::Sha512;
use siphasher::sip::SipHasher;

use crate::IdeviceError;

use super::{errors::RemotePairingError, opack, tlv};

#[derive(Clone, Eq, PartialEq)]
pub struct PeerDevice {
    /// peer identifier, same as the identifier returned in the `verifyManualPairing` response
    pub account_id: String,
    /// altIRK: 16-byte
    pub alt_irk: Vec<u8>,
    /// Device's model identifier, e.g. "iPhone14,4"
    pub model: String,
    /// Device's name
    pub name: String,
    /// Device's Unique Device Identifier
    pub remotepairing_udid: String,
}

impl std::fmt::Debug for PeerDevice {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("PeerDevice")
            .field("model", &self.model)
            .field("name", &self.name)
            .field("pairing_material", &"<redacted>")
            .finish()
    }
}

/// A peer identity whose Pair Setup signature has been verified.
///
/// Persist the identifier and long-term public key with the peer's device info.
/// They are required to authenticate every later Pair Verify exchange.
#[derive(Clone, Eq, PartialEq)]
pub struct VerifiedPeerIdentity {
    pub peer: PeerDevice,
    pub pairing_identifier: String,
    pub long_term_public_key: [u8; 32],
}

impl std::fmt::Debug for VerifiedPeerIdentity {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("VerifiedPeerIdentity")
            .field("peer", &self.peer)
            .field("pairing_material", &"<redacted>")
            .finish()
    }
}

impl PeerDevice {
    /// Validates a `_remotepairing._tcp` mDNS `authTag`.
    ///
    /// - `alt_irk`: 16-byte mDNS identity key (`alt_irk`) stored in the pairing file
    /// - `service_identifier`: the service identifier from the mDNS TXT record
    /// - `auth_tag`: 6-byte auth tag from the mDNS TXT record
    ///
    /// Computes `SipHash-2-4(key=alt_irk, msg=service_identifier)` and compares the
    /// first 6 bytes of the 8-byte LE output (reversed) against `auth_tag`.
    pub fn validate_auth_tag(alt_irk: &[u8], service_identifier: &str, auth_tag: &str) -> bool {
        let bytes = match base64::engine::general_purpose::STANDARD.decode(auth_tag) {
            Ok(b) => b,
            Err(_) => return false,
        };
        if bytes.len() != 6 {
            return false;
        }
        let Ok(alt_irk) = <&[u8; 16]>::try_from(alt_irk) else {
            return false;
        };
        compute_auth_tag(alt_irk, service_identifier) == bytes.as_slice()
    }

    pub fn try_from_info_dictionary(dict: &plist::Dictionary) -> Result<Self, IdeviceError> {
        let alt_irk = required_data_field(dict, "altIRK")?;
        if alt_irk.len() != 16 {
            return Err(IdeviceError::UnexpectedResponse(format!(
                "invalid altIRK length in peer device info: expected 16 bytes, got {}",
                alt_irk.len()
            )));
        }

        Ok(Self {
            account_id: required_string_field(dict, "accountID")?,
            alt_irk,
            model: required_string_field(dict, "model")?,
            name: required_string_field(dict, "name")?,
            remotepairing_udid: required_string_field(dict, "remotepairing_udid")?,
        })
    }
}

fn required_string_field(dict: &plist::Dictionary, key: &str) -> Result<String, IdeviceError> {
    dict.get(key)
        .and_then(|value| value.as_string())
        .map(str::to_string)
        .ok_or(IdeviceError::UnexpectedResponse(format!(
            "missing string field `{key}` in peer device info"
        )))
}

fn required_data_field(dict: &plist::Dictionary, key: &str) -> Result<Vec<u8>, IdeviceError> {
    dict.get(key)
        .and_then(|value| value.as_data())
        .map(|value| value.to_vec())
        .ok_or(IdeviceError::UnexpectedResponse(format!(
            "missing data field `{key}` in peer device info"
        )))
}

fn parse_info_dictionary_from_tlv(
    entries: &[tlv::TLV8Entry],
) -> Result<plist::Dictionary, IdeviceError> {
    if tlv::contains_component(entries, tlv::PairingDataComponentType::ErrorResponse) {
        return Err(IdeviceError::UnexpectedResponse(
            "TLV error response in pair record save".into(),
        ));
    }

    let info = tlv::collect_component_data(entries, tlv::PairingDataComponentType::Info);
    if info.is_empty() {
        return Err(IdeviceError::UnexpectedResponse(
            "missing info payload in pair record response".into(),
        ));
    }

    let info_plist = opack::opack_to_plist(&info).map_err(|e| {
        IdeviceError::UnexpectedResponse(format!(
            "failed to parse OPACK info payload from pair record response: {e}"
        ))
    })?;

    let info_dict = info_plist
        .as_dictionary()
        .ok_or(IdeviceError::UnexpectedResponse(
            "info OPACK payload is not a dictionary".into(),
        ))?;

    Ok(info_dict.to_owned())
}

pub(super) fn parse_peer_device_from_tlv(
    entries: &[tlv::TLV8Entry],
) -> Result<PeerDevice, IdeviceError> {
    let info = parse_info_dictionary_from_tlv(entries)?;
    PeerDevice::try_from_info_dictionary(&info)
}

/// Parses and authenticates the controller identity in Pair Setup M5.
pub(super) fn parse_verified_peer_identity(
    entries: &[tlv::TLV8Entry],
    session_key: &[u8],
) -> Result<VerifiedPeerIdentity, IdeviceError> {
    parse_verified_identity(
        entries,
        session_key,
        b"Pair-Setup-Controller-Sign-Salt",
        b"Pair-Setup-Controller-Sign-Info",
    )
}

/// Parses and authenticates the accessory identity in Pair Setup M6.
pub(super) fn parse_verified_accessory_identity(
    entries: &[tlv::TLV8Entry],
    session_key: &[u8],
) -> Result<VerifiedPeerIdentity, IdeviceError> {
    parse_verified_identity(
        entries,
        session_key,
        b"Pair-Setup-Accessory-Sign-Salt",
        b"Pair-Setup-Accessory-Sign-Info",
    )
}

fn parse_verified_identity(
    entries: &[tlv::TLV8Entry],
    session_key: &[u8],
    derivation_salt: &[u8],
    derivation_info: &[u8],
) -> Result<VerifiedPeerIdentity, IdeviceError> {
    use tlv::PairingDataComponentType as Component;

    let peer = parse_peer_device_from_tlv(entries)?;
    let identifier_bytes = tlv::collect_component_data(entries, Component::Identifier);
    if identifier_bytes.is_empty() {
        return Err(RemotePairingError::PeerIdentityMalformed("missing identifier").into());
    }
    let pairing_identifier = String::from_utf8(identifier_bytes)?;
    let long_term_public_key: [u8; 32] = tlv::collect_component_data(entries, Component::PublicKey)
        .try_into()
        .map_err(|_| RemotePairingError::PeerIdentityMalformed("invalid public key length"))?;
    let signature =
        Signature::from_slice(&tlv::collect_component_data(entries, Component::Signature))
            .map_err(|_| RemotePairingError::PeerIdentityMalformed("invalid signature length"))?;
    let verifying_key = VerifyingKey::from_bytes(&long_term_public_key)
        .map_err(|_| RemotePairingError::PeerIdentityMalformed("invalid public key"))?;

    let mut controller_x = [0_u8; 32];
    Hkdf::<Sha512>::new(Some(derivation_salt), session_key)
        .expand(derivation_info, &mut controller_x)
        .map_err(|_| RemotePairingError::PeerAuthenticationFailed)?;
    let mut signed_data = Vec::with_capacity(controller_x.len() + pairing_identifier.len() + 32);
    signed_data.extend_from_slice(&controller_x);
    signed_data.extend_from_slice(pairing_identifier.as_bytes());
    signed_data.extend_from_slice(&long_term_public_key);
    verifying_key
        .verify_strict(&signed_data, &signature)
        .map_err(|_| RemotePairingError::PeerAuthenticationFailed)?;
    // `Info` is outside the signature. Bind its account identity to the
    // identifier that the peer actually signed before exposing either value.
    if peer.account_id != pairing_identifier {
        return Err(RemotePairingError::PeerAuthenticationFailed.into());
    }

    Ok(VerifiedPeerIdentity {
        peer,
        pairing_identifier,
        long_term_public_key,
    })
}

/// Computes the 6-byte mDNS `authTag` for the given `alt_irk` and `service_identifier`.
///
/// Algorithm: `SipHash-2-4(key=alt_irk, msg=service_identifier)` → take 8-byte LE output,
/// return the first 6 bytes in **reverse** order.
///
/// Use this to populate the `authTag` TXT record when advertising a
/// `_remotepairing-pairable-host._tcp` service (base64-encode the result).
pub fn compute_auth_tag(alt_irk: &[u8; 16], service_identifier: &str) -> [u8; 6] {
    let k0 = u64::from_le_bytes(alt_irk[..8].try_into().unwrap());
    let k1 = u64::from_le_bytes(alt_irk[8..16].try_into().unwrap());
    let mut sip = SipHasher::new_with_keys(k0, k1);
    sip.write(service_identifier.as_bytes());
    let output = sip.finish().to_le_bytes();
    let mut tag = [0u8; 6];
    for i in 0..6 {
        tag[i] = output[5 - i];
    }
    tag
}

#[cfg(test)]
mod tests {
    use ed25519_dalek::{Signer as _, SigningKey};

    use super::*;

    fn sample_peer_device_dictionary(account_id: &str) -> plist::Dictionary {
        let mut dict = plist::Dictionary::new();
        dict.insert("accountID".into(), plist::Value::String(account_id.into()));
        dict.insert("altIRK".into(), plist::Value::Data(vec![0xAB; 16]));
        dict.insert("model".into(), plist::Value::String("AppleTV11,1".into()));
        dict.insert("name".into(), plist::Value::String("Living Room".into()));
        dict.insert(
            "remotepairing_udid".into(),
            plist::Value::String("00008110-001A2B3C00000000".into()),
        );
        dict
    }

    fn decode_hex(value: &str) -> Vec<u8> {
        value
            .as_bytes()
            .chunks_exact(2)
            .map(|pair| {
                let text = std::str::from_utf8(pair).unwrap();
                u8::from_str_radix(text, 16).unwrap()
            })
            .collect()
    }

    #[test]
    fn peer_device_requires_all_fields() {
        let mut dict = sample_peer_device_dictionary("test-account");
        dict.remove("model");

        let err = PeerDevice::try_from_info_dictionary(&dict).unwrap_err();

        assert!(
            matches!(err, IdeviceError::UnexpectedResponse(message) if message.contains("model"))
        );
    }

    #[test]
    fn peer_device_parses_required_fields() {
        let dict = sample_peer_device_dictionary("test-account");

        let peer_device = PeerDevice::try_from_info_dictionary(&dict).unwrap();

        assert_eq!(peer_device.account_id, "test-account");
        assert_eq!(peer_device.alt_irk, vec![0xAB; 16]);
        assert_eq!(peer_device.model, "AppleTV11,1");
        assert_eq!(peer_device.name, "Living Room");
        assert_eq!(peer_device.remotepairing_udid, "00008110-001A2B3C00000000");
    }

    #[test]
    fn parse_peer_device_from_tlv_reads_info_payload() {
        let info = plist::Value::Dictionary(sample_peer_device_dictionary("test-account"));
        let entries = vec![tlv::TLV8Entry {
            tlv_type: tlv::PairingDataComponentType::Info,
            data: opack::plist_to_opack(&info),
        }];

        let peer_device = parse_peer_device_from_tlv(&entries).unwrap();

        assert_eq!(peer_device.name, "Living Room");
        assert_eq!(peer_device.alt_irk.len(), 16);
    }

    fn signed_identity_entries_with_account_id(
        session_key: &[u8],
        signing_key: &SigningKey,
        account_id: &str,
    ) -> Vec<tlv::TLV8Entry> {
        let identifier = "verified-device";
        let public_key = signing_key.verifying_key().to_bytes();
        let mut controller_x = [0_u8; 32];
        Hkdf::<Sha512>::new(Some(b"Pair-Setup-Controller-Sign-Salt"), session_key)
            .expand(b"Pair-Setup-Controller-Sign-Info", &mut controller_x)
            .unwrap();
        let mut signed_data = Vec::new();
        signed_data.extend_from_slice(&controller_x);
        signed_data.extend_from_slice(identifier.as_bytes());
        signed_data.extend_from_slice(&public_key);
        let signature = signing_key.sign(&signed_data);

        vec![
            tlv::TLV8Entry {
                tlv_type: tlv::PairingDataComponentType::Identifier,
                data: identifier.as_bytes().to_vec(),
            },
            tlv::TLV8Entry {
                tlv_type: tlv::PairingDataComponentType::PublicKey,
                data: public_key.to_vec(),
            },
            tlv::TLV8Entry {
                tlv_type: tlv::PairingDataComponentType::Signature,
                data: signature.to_bytes().to_vec(),
            },
            tlv::TLV8Entry {
                tlv_type: tlv::PairingDataComponentType::Info,
                data: opack::plist_to_opack(&plist::Value::Dictionary(
                    sample_peer_device_dictionary(account_id),
                )),
            },
        ]
    }

    fn signed_identity_entries(
        session_key: &[u8],
        signing_key: &SigningKey,
    ) -> Vec<tlv::TLV8Entry> {
        signed_identity_entries_with_account_id(session_key, signing_key, "verified-device")
    }

    #[test]
    fn pair_setup_identity_requires_a_valid_m5_signature() {
        let session_key = b"pair-setup-session-key";
        let signing_key = SigningKey::from_bytes(&[0x42; 32]);
        let entries = signed_identity_entries(session_key, &signing_key);

        let identity = parse_verified_peer_identity(&entries, session_key).unwrap();

        assert_eq!(identity.pairing_identifier, "verified-device");
        assert_eq!(
            identity.long_term_public_key,
            signing_key.verifying_key().to_bytes()
        );
        assert_eq!(identity.peer.name, "Living Room");
    }

    #[test]
    fn pair_setup_identity_accepts_an_independent_m5_vector() {
        let session_key: Vec<u8> = (0..64).collect();
        let identifier = "00008130-TEST-DEVICE";
        let public_key =
            decode_hex("03a107bff3ce10be1d70dd18e74bc09967e4d6309ba50d5f1ddc8664125531b8");
        let signature = decode_hex(
            "208c57145c67d47b9ead670e5b1c1d59cec9911b36ca0ed83ef58bbb716f918e1\
             405dd6324707ef3ed8ed2fbaba9e01f3c63375dee6005a220ccefb90a6b8105",
        );
        let entries = vec![
            tlv::TLV8Entry {
                tlv_type: tlv::PairingDataComponentType::Identifier,
                data: identifier.as_bytes().to_vec(),
            },
            tlv::TLV8Entry {
                tlv_type: tlv::PairingDataComponentType::PublicKey,
                data: public_key.clone(),
            },
            tlv::TLV8Entry {
                tlv_type: tlv::PairingDataComponentType::Signature,
                data: signature,
            },
            tlv::TLV8Entry {
                tlv_type: tlv::PairingDataComponentType::Info,
                data: opack::plist_to_opack(&plist::Value::Dictionary(
                    sample_peer_device_dictionary(identifier),
                )),
            },
        ];
        let mut controller_x = [0_u8; 32];
        Hkdf::<Sha512>::new(Some(b"Pair-Setup-Controller-Sign-Salt"), &session_key)
            .expand(b"Pair-Setup-Controller-Sign-Info", &mut controller_x)
            .unwrap();

        let identity = parse_verified_peer_identity(&entries, &session_key).unwrap();

        assert_eq!(
            controller_x.to_vec(),
            decode_hex("0466a0bf8ce2baaa4dcf7797775db7f1c3040e75f035338e97de03eb2033fcc4")
        );
        assert_eq!(identity.pairing_identifier, identifier);
        assert_eq!(identity.long_term_public_key.as_slice(), public_key);
    }

    #[test]
    fn pair_setup_identity_rejects_a_tampered_m5_signature() {
        let session_key = b"pair-setup-session-key";
        let signing_key = SigningKey::from_bytes(&[0x42; 32]);
        let mut entries = signed_identity_entries(session_key, &signing_key);
        let signature = entries
            .iter_mut()
            .find(|entry| entry.tlv_type == tlv::PairingDataComponentType::Signature)
            .unwrap();
        signature.data[0] ^= 1;

        let error = parse_verified_peer_identity(&entries, session_key).unwrap_err();

        assert!(matches!(
            error,
            IdeviceError::RemotePairing(RemotePairingError::PeerAuthenticationFailed)
        ));
    }

    #[test]
    fn pair_setup_identity_rejects_an_opack_account_id_mismatch() {
        let session_key = b"pair-setup-session-key";
        let signing_key = SigningKey::from_bytes(&[0x42; 32]);
        let entries =
            signed_identity_entries_with_account_id(session_key, &signing_key, "other-device");

        let error = parse_verified_peer_identity(&entries, session_key).unwrap_err();

        assert!(matches!(
            error,
            IdeviceError::RemotePairing(RemotePairingError::PeerAuthenticationFailed)
        ));
    }

    #[test]
    fn validate_auth_tag_returns_true_for_correct_tag() {
        let alt_irk = base64::engine::general_purpose::STANDARD
            .decode("Mgp6ZGPzXM2ku9br46vsiw==")
            .unwrap();
        let service_identifier = "2BE6E510-0325-4365-923E-B14C6F57DB3A";
        let auth_tag = "kXjlTr2l";
        assert!(PeerDevice::validate_auth_tag(
            &alt_irk,
            service_identifier,
            auth_tag
        ));
    }
}
