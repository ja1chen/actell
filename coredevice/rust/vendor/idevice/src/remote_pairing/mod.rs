//! Remote Pairing

use crate::IdeviceError;
use base64::Engine as _;
use errors::RemotePairingError;

use chacha20poly1305::{
    ChaCha20Poly1305, Key, KeyInit, Nonce,
    aead::{Aead, Payload},
};
use ed25519_dalek::{Signature, VerifyingKey};
use hkdf::Hkdf;
use idevice_srp::{client::SrpClient, groups::G_3072};
use plist_macro::plist;
use plist_macro::{PlistConvertible, PlistExt};
use rand::Rng as _;
use rsa::{rand_core::OsRng, signature::SignerMut};
use serde::Serialize;
use sha2::Sha512;
use tracing::{debug, warn};
use x25519_dalek::{EphemeralSecret, PublicKey as X25519PublicKey};
use zeroize::Zeroizing;

pub mod errors;
mod opack;
mod peer_device;
mod responder;
mod rp_pairing_file;
mod socket;
pub mod tls_psk;
mod tlv;
pub mod tunnel;

// export
pub use peer_device::{PeerDevice, VerifiedPeerIdentity, compute_auth_tag};
pub use responder::{PAIRABLE_HOST_SERVICE_TYPE, PairRecordState, PairableHost, PairableHostInfo};
pub use rp_pairing_file::RpPairingFile;
pub use socket::{RpPairingSocket, RpPairingSocketProvider};
#[cfg(feature = "openssl")]
pub use tunnel::connect_tls_psk_tunnel;
pub use tunnel::{CdTunnel, TunnelInfo, connect_tls_psk_tunnel_native};

const RPPAIRING_MAGIC: &[u8] = b"RPPairing";
const WIRE_PROTOCOL_VERSION: u8 = 19;

pub struct RemotePairingClient<R: RpPairingSocketProvider> {
    inner: R,
    sequence_number: usize,
    encrypted_sequence_number: u64,
    sending_host: String,

    /// The shared secret from X25519 (pair-verify) or SRP (initial pairing).
    /// Used as PSK for the TLS tunnel and to derive per-message encryption keys.
    encryption_key: Zeroizing<Vec<u8>>,

    client_cipher: ChaCha20Poly1305,
    server_cipher: ChaCha20Poly1305,

    paired_peer_device: Option<VerifiedPeerIdentity>,
}

impl<R: RpPairingSocketProvider> RemotePairingClient<R> {
    pub fn new(inner: R, sending_host: &str) -> Self {
        // Initial ciphers are placeholders; they will be re-derived from
        // the actual encryption_key once pair-verify or pairing completes.
        let initial_key = vec![0u8; 32];
        let (client_cipher, server_cipher) = Self::derive_main_ciphers(&initial_key);

        Self {
            inner,
            sequence_number: 0,
            encrypted_sequence_number: 0,
            sending_host: sending_host.to_string(),
            encryption_key: Zeroizing::new(initial_key),
            client_cipher,
            server_cipher,
            paired_peer_device: None,
        }
    }

    fn derive_main_ciphers(key: &[u8]) -> (ChaCha20Poly1305, ChaCha20Poly1305) {
        let hk = Hkdf::<sha2::Sha512>::new(None, key);
        let mut okm = Zeroizing::new([0u8; 32]);
        hk.expand(b"ClientEncrypt-main", &mut okm[..]).unwrap();
        let client_cipher = ChaCha20Poly1305::new(chacha20poly1305::Key::from_slice(&okm[..]));

        let hk = Hkdf::<sha2::Sha512>::new(None, key);
        let mut okm = Zeroizing::new([0u8; 32]);
        hk.expand(b"ServerEncrypt-main", &mut okm[..]).unwrap();
        let server_cipher = ChaCha20Poly1305::new(chacha20poly1305::Key::from_slice(&okm[..]));

        (client_cipher, server_cipher)
    }

    /// Returns the encryption key established during pairing.
    /// This is used as TLS-PSK for tunnel connections.
    pub fn encryption_key(&self) -> &[u8] {
        &self.encryption_key
    }

    /// Connects an already-paired peer and authenticates it before sending M3.
    ///
    /// New pairing is intentionally a separate explicit operation. Any
    /// authentication or transport failure is returned to the caller and can
    /// never trigger an implicit Pair Setup fallback.
    pub async fn connect_paired(
        &mut self,
        pairing_file: &mut RpPairingFile,
        peer_identity: &VerifiedPeerIdentity,
    ) -> Result<(), IdeviceError> {
        self.attempt_pair_verify().await?;
        self.validate_pairing(pairing_file, peer_identity).await
    }

    /// Returns authenticated peer identity captured during explicit Pair Setup.
    pub fn paired_peer_device(&self) -> Result<&VerifiedPeerIdentity, IdeviceError> {
        self.paired_peer_device
            .as_ref()
            .ok_or(IdeviceError::UnexpectedResponse(
                "paired peer device info is only available after a successful pair() call".into(),
            ))
    }

    pub async fn validate_pairing(
        &mut self,
        pairing_file: &mut RpPairingFile,
        peer_identity: &VerifiedPeerIdentity,
    ) -> Result<(), IdeviceError> {
        let x_private_key = EphemeralSecret::random_from_rng(OsRng);
        let x_public_key = X25519PublicKey::from(&x_private_key);

        let pairing_data = tlv::serialize_tlv8(&[
            tlv::TLV8Entry {
                tlv_type: tlv::PairingDataComponentType::State,
                data: vec![0x01],
            },
            tlv::TLV8Entry {
                tlv_type: tlv::PairingDataComponentType::PublicKey,
                data: x_public_key.to_bytes().to_vec(),
            },
        ]);
        let pairing_data = R::serialize_bytes(&pairing_data);
        self.send_pairing_data(plist!({
            "data": pairing_data,
            "kind": "verifyManualPairing",
            "startNewSession": true
        }))
        .await?;
        debug!("Waiting for response from verifyManualPairing");

        let pairing_data = self.receive_pairing_data().await?;

        let data = match R::deserialize_bytes(pairing_data) {
            Some(d) => d,
            None => {
                return Err(IdeviceError::UnexpectedResponse(
                    "failed to deserialize pair-verify response bytes".into(),
                ));
            }
        };

        let data = tlv::deserialize_tlv8(&data)?;

        if data
            .iter()
            .any(|x| x.tlv_type == tlv::PairingDataComponentType::ErrorResponse)
        {
            self.send_pair_verified_failed().await?;
            return Err(RemotePairingError::PairVerifyFailed.into());
        }

        let device_public_key = match data
            .iter()
            .find(|x| x.tlv_type == tlv::PairingDataComponentType::PublicKey)
        {
            Some(d) => d,
            None => {
                warn!("No public key in TLV data");
                return Err(IdeviceError::UnexpectedResponse(
                    "missing public key in pair-verify TLV data".into(),
                ));
            }
        };
        let peer_pub_bytes: [u8; 32] = match device_public_key.data.as_slice().try_into() {
            Ok(d) => d,
            Err(_) => {
                warn!("Device public key isn't the expected size");
                return Err(IdeviceError::NotEnoughBytes(
                    32,
                    device_public_key.data.len(),
                ));
            }
        };
        let device_public_key = x25519_dalek::PublicKey::from(peer_pub_bytes);
        let shared_secret = x_private_key.diffie_hellman(&device_public_key);

        // Derive encryption key with HKDF-SHA512
        let hk =
            Hkdf::<sha2::Sha512>::new(Some(b"Pair-Verify-Encrypt-Salt"), shared_secret.as_bytes());

        let mut okm = Zeroizing::new([0u8; 32]);
        hk.expand(b"Pair-Verify-Encrypt-Info", &mut okm[..])
            .unwrap();

        // ChaCha20Poly1305 AEAD cipher
        let cipher = ChaCha20Poly1305::new(chacha20poly1305::Key::from_slice(&okm[..]));

        authenticate_pair_verify_m2(
            &data,
            &cipher,
            &device_public_key,
            &x_public_key,
            peer_identity,
        )?;

        let ed25519_signing_key = &mut pairing_file.e_private_key;

        let mut signbuf = Vec::with_capacity(32 + pairing_file.identifier.len() + 32);
        signbuf.extend_from_slice(x_public_key.as_bytes()); // 32 bytes
        signbuf.extend_from_slice(pairing_file.identifier.as_bytes()); // variable
        signbuf.extend_from_slice(device_public_key.as_bytes()); // 32 bytes

        let signature: Signature = ed25519_signing_key.sign(&signbuf);

        let plaintext = vec![
            tlv::TLV8Entry {
                tlv_type: tlv::PairingDataComponentType::Identifier,
                data: pairing_file.identifier.as_bytes().to_vec(),
            },
            tlv::TLV8Entry {
                tlv_type: tlv::PairingDataComponentType::Signature,
                data: signature.to_vec(),
            },
        ];
        let plaintext = tlv::serialize_tlv8(&plaintext);
        let nonce = Nonce::from_slice(b"\x00\x00\x00\x00PV-Msg03"); // 12-byte nonce
        let ciphertext = cipher
            .encrypt(
                nonce,
                Payload {
                    msg: &plaintext,
                    aad: &[],
                },
            )
            .expect("encryption should not fail");

        let msg = vec![
            tlv::TLV8Entry {
                tlv_type: tlv::PairingDataComponentType::State,
                data: [0x03].to_vec(),
            },
            tlv::TLV8Entry {
                tlv_type: tlv::PairingDataComponentType::EncryptedData,
                data: ciphertext,
            },
        ];

        debug!("Waiting for signbuf response");
        self.send_pairing_data(plist! ({
            "data": R::serialize_bytes(&tlv::serialize_tlv8(&msg)),
            "kind": "verifyManualPairing",
            "startNewSession": false
        }))
        .await?;
        let res = self.receive_pairing_data().await?;

        let data = match R::deserialize_bytes(res) {
            Some(d) => d,
            None => {
                return Err(IdeviceError::UnexpectedResponse(
                    "failed to deserialize pair-verify signature response bytes".into(),
                ));
            }
        };
        if let Err(error) = validate_pair_verify_m4(&data) {
            debug!("Pair Verify did not complete");
            self.send_pair_verified_failed().await?;
            return Err(error);
        }

        // Install the authenticated shared secret only after the peer has
        // accepted M3 and completed Pair Verify.
        self.encryption_key = Zeroizing::new(shared_secret.as_bytes().to_vec());
        let (cc, sc) = Self::derive_main_ciphers(shared_secret.as_bytes());
        self.client_cipher = cc;
        self.server_cipher = sc;

        Ok(())
    }

    pub async fn send_pair_verified_failed(&mut self) -> Result<(), IdeviceError> {
        self.inner
            .send_plain(
                plist!({
                    "event": {
                        "_0": {
                            "pairVerifyFailed": {}
                        }
                    }
                }),
                self.sequence_number,
            )
            .await?;
        self.sequence_number += 1;
        Ok(())
    }

    pub async fn attempt_pair_verify(&mut self) -> Result<plist::Value, IdeviceError> {
        debug!("Sending attemptPairVerify");
        self.inner
            .send_plain(
                plist!({
                    "request": {
                        "_0": {
                            "handshake": {
                                "_0": {
                                    "hostOptions": {
                                        "attemptPairVerify": true
                                    },
                                    "wireProtocolVersion": plist::Value::Integer(WIRE_PROTOCOL_VERSION.into()),
                                }
                            }
                        }
                    }
                }),
                self.sequence_number,
            )
            .await?;
        self.sequence_number += 1;

        debug!("Waiting for attemptPairVerify response");
        let response = self.inner.recv_plain().await?;

        let response = response
            .as_dictionary()
            .and_then(|x| x.get("response"))
            .and_then(|x| x.as_dictionary())
            .and_then(|x| x.get("_1"))
            .and_then(|x| x.as_dictionary())
            .and_then(|x| x.get("handshake"))
            .and_then(|x| x.as_dictionary())
            .and_then(|x| x.get("_0"));

        match response {
            Some(v) => Ok(v.to_owned()),
            None => Err(IdeviceError::UnexpectedResponse(
                "missing handshake response in attemptPairVerify".into(),
            )),
        }
    }

    pub async fn pair<Fut>(
        &mut self,
        pairing_file: &mut RpPairingFile,
        pin_callback: impl Fn() -> Fut,
    ) -> Result<(), IdeviceError>
    where
        Fut: std::future::Future<Output = String>,
    {
        let (salt, public_key, pin) = self.request_pair_consent(pin_callback).await?;
        let key = self.init_srp_context(&salt, &public_key, &pin).await?;
        let tlv = self.save_pair_record_on_peer(pairing_file, &key).await?;
        let peer_device = peer_device::parse_verified_accessory_identity(&tlv, &key)?;

        pairing_file.alt_irk = Some(peer_device.peer.alt_irk.clone());
        self.paired_peer_device = Some(peer_device);

        Ok(())
    }

    /// Returns salt and public key and pin
    async fn request_pair_consent<Fut>(
        &mut self,
        pin_callback: impl Fn() -> Fut,
    ) -> Result<(Vec<u8>, Vec<u8>, String), IdeviceError>
    where
        Fut: std::future::Future<Output = String>,
    {
        let tlv = tlv::serialize_tlv8(&[
            tlv::TLV8Entry {
                tlv_type: tlv::PairingDataComponentType::Method,
                data: vec![0x00],
            },
            tlv::TLV8Entry {
                tlv_type: tlv::PairingDataComponentType::State,
                data: vec![0x01],
            },
        ]);
        let tlv = R::serialize_bytes(&tlv);
        self.send_pairing_data(plist!({
            "data": tlv,
            "kind": "setupManualPairing",
            "sendingHost": &self.sending_host,
            "startNewSession": true
        }))
        .await?;

        let response = self.inner.recv_plain().await?;
        let response = match response
            .get_by("event")
            .and_then(|x| x.get_by("_0"))
            .and_then(|x| x.as_dictionary())
        {
            Some(r) => r,
            None => {
                return Err(IdeviceError::UnexpectedResponse(
                    "missing event._0 in pair consent response".into(),
                ));
            }
        };

        let mut pin = None;

        let pairing_data = match if let Some(err) = response.get("pairingRejectedWithError") {
            let context = err
                .get_by("wrappedError")
                .and_then(|x| x.get_by("userInfo"))
                .and_then(|x| x.get_by("NSLocalizedDescription"))
                .and_then(|x| x.as_string())
                .map(|x| x.to_string());
            return Err(RemotePairingError::PairingRejected(context.unwrap_or_default()).into());
        } else if response.get("awaitingUserConsent").is_some() {
            pin = Some("000000".to_string());
            Some(self.receive_pairing_data().await?)
        } else {
            // On Apple TV, we can get the pin now
            response
                .get_by("pairingData")
                .and_then(|x| x.get_by("_0"))
                .and_then(|x| x.get_by("data"))
                .map(|x| x.to_owned())
        } {
            Some(p) => p,
            None => {
                return Err(IdeviceError::UnexpectedResponse(
                    "missing pairing data in pair consent response".into(),
                ));
            }
        };

        let tlv = tlv::deserialize_tlv8(&match R::deserialize_bytes(pairing_data) {
            Some(t) => t,
            None => {
                return Err(IdeviceError::UnexpectedResponse(
                    "failed to deserialize pairing data bytes in pair consent".into(),
                ));
            }
        })?;
        let mut salt = Vec::new();
        let mut public_key = Vec::new();
        for t in tlv {
            match t.tlv_type {
                tlv::PairingDataComponentType::Salt => {
                    salt = t.data;
                }
                tlv::PairingDataComponentType::PublicKey => {
                    public_key.extend(t.data);
                }
                tlv::PairingDataComponentType::ErrorResponse => {
                    warn!("Pairing data contained error response");
                    return Err(IdeviceError::UnexpectedResponse(
                        "pairing data contained error response during pair consent".into(),
                    ));
                }
                _ => {
                    continue;
                }
            }
        }

        let pin = match pin {
            Some(p) => p,
            None => pin_callback().await,
        };

        if salt.is_empty() || public_key.is_empty() {
            warn!("Pairing data did not contain salt or public key");
            return Err(IdeviceError::UnexpectedResponse(
                "pairing data missing salt or public key".into(),
            ));
        }

        Ok((salt, public_key, pin))
    }

    /// Returns the encryption key
    async fn init_srp_context(
        &mut self,
        salt: &[u8],
        public_key: &[u8],
        pin: &str,
    ) -> Result<Vec<u8>, IdeviceError> {
        let client = SrpClient::<Sha512>::new(
            &G_3072, // PRIME_3072 + generator
        );

        let mut a_private = [0u8; 32];
        rand::rng().fill_bytes(&mut a_private);

        let a_public = client.compute_public_ephemeral(&a_private);

        let verifier = match client.process_reply(
            &a_private,
            "Pair-Setup".as_bytes(),
            &pin.as_bytes()[..6],
            salt,
            public_key,
            false,
        ) {
            Ok(v) => v,
            Err(e) => {
                warn!("SRP verifier creation failed: {e:?}");
                return Err(RemotePairingError::SrpAuthFailed.into());
            }
        };

        let client_proof = verifier.proof();

        let tlv = tlv::serialize_tlv8(&[
            tlv::TLV8Entry {
                tlv_type: tlv::PairingDataComponentType::State,
                data: vec![0x03],
            },
            tlv::TLV8Entry {
                tlv_type: tlv::PairingDataComponentType::PublicKey,
                data: a_public[..254].to_vec(),
            },
            tlv::TLV8Entry {
                tlv_type: tlv::PairingDataComponentType::PublicKey,
                data: a_public[254..].to_vec(),
            },
            tlv::TLV8Entry {
                tlv_type: tlv::PairingDataComponentType::Proof,
                data: client_proof.to_vec(),
            },
        ]);
        let tlv = R::serialize_bytes(&tlv);

        self.send_pairing_data(plist!({
            "data": tlv,
            "kind": "setupManualPairing",
            "sendingHost": &self.sending_host,
            "startNewSession": false,

        }))
        .await?;

        let response = self.receive_pairing_data().await?;
        let response = tlv::deserialize_tlv8(&match R::deserialize_bytes(response.to_owned()) {
            Some(r) => r,
            None => {
                return Err(IdeviceError::UnexpectedResponse(
                    "failed to deserialize SRP proof response bytes".into(),
                ));
            }
        })?;

        let proof = match response
            .iter()
            .find(|x| x.tlv_type == tlv::PairingDataComponentType::Proof)
        {
            Some(p) => &p.data,
            None => {
                warn!("Proof response did not contain server proof");
                return Err(IdeviceError::UnexpectedResponse(
                    "missing server proof in SRP response".into(),
                ));
            }
        };

        match verifier.verify_server(proof) {
            Ok(_) => Ok(verifier.key().to_vec()),
            Err(e) => {
                warn!("Server auth failed: {e:?}");
                Err(RemotePairingError::SrpAuthFailed.into())
            }
        }
    }

    async fn save_pair_record_on_peer(
        &mut self,
        pairing_file: &mut RpPairingFile,
        encryption_key: &[u8],
    ) -> Result<Vec<tlv::TLV8Entry>, IdeviceError> {
        let salt = b"Pair-Setup-Encrypt-Salt";
        let info = b"Pair-Setup-Encrypt-Info";

        let hk = Hkdf::<Sha512>::new(Some(salt), encryption_key);
        let mut setup_encryption_key = Zeroizing::new([0u8; 32]);
        hk.expand(info, &mut setup_encryption_key[..])
            .expect("HKDF expand failed");

        // Save the SRP session key as the encryption key
        self.encryption_key = Zeroizing::new(encryption_key.to_vec());

        {
            // Re-derive main ciphers from the SRP session key
            let (cc, sc) = Self::derive_main_ciphers(encryption_key);
            self.client_cipher = cc;
            self.server_cipher = sc;
        }

        let hk = Hkdf::<Sha512>::new(Some(b"Pair-Setup-Controller-Sign-Salt"), encryption_key);

        let mut signbuf = Vec::with_capacity(32 + pairing_file.identifier.len() + 32);

        let mut hkdf_out = Zeroizing::new([0u8; 32]);
        hk.expand(b"Pair-Setup-Controller-Sign-Info", &mut hkdf_out[..])
            .expect("HKDF expand failed");

        signbuf.extend_from_slice(&hkdf_out[..]);

        signbuf.extend_from_slice(pairing_file.identifier.as_bytes());
        signbuf.extend_from_slice(pairing_file.e_public_key.as_bytes());

        let signature = pairing_file.e_private_key.sign(&signbuf);

        let device_info = crate::plist!({
            "altIRK": b"\xe9\xe8-\xc0jIykVoT\x00\x19\xb1\xc7{".to_vec(),
            "btAddr": "11:22:33:44:55:66",
            "mac": b"\x11\x22\x33\x44\x55\x66".to_vec(),
            "remotepairing_serial_number": "AAAAAAAAAAAA",
            "accountID": pairing_file.identifier.as_str(),
            "model": "computer-model",
            "name": self.sending_host.as_str()
        });
        let device_info = opack::plist_to_opack(&device_info);

        let tlv = tlv::serialize_tlv8(&[
            tlv::TLV8Entry {
                tlv_type: tlv::PairingDataComponentType::Identifier,
                data: pairing_file.identifier.as_bytes().to_vec(),
            },
            tlv::TLV8Entry {
                tlv_type: tlv::PairingDataComponentType::PublicKey,
                data: pairing_file.e_public_key.to_bytes().to_vec(),
            },
            tlv::TLV8Entry {
                tlv_type: tlv::PairingDataComponentType::Signature,
                data: signature.to_vec(),
            },
            tlv::TLV8Entry {
                tlv_type: tlv::PairingDataComponentType::Info,
                data: device_info,
            },
        ]);

        let key = Key::from_slice(&setup_encryption_key[..]); // 32 bytes
        let cipher = ChaCha20Poly1305::new(key);

        let nonce = Nonce::from_slice(b"\x00\x00\x00\x00PS-Msg05"); // 12 bytes

        let plaintext = &tlv;

        let ciphertext = match cipher.encrypt(
            nonce,
            Payload {
                msg: plaintext,
                aad: b"",
            },
        ) {
            Ok(c) => c,
            Err(e) => {
                warn!("Chacha encryption failed: {e:?}");
                return Err(RemotePairingError::ChachaEncryption(e).into());
            }
        };
        debug!("ciphertext len: {}", ciphertext.len());

        let tlv = tlv::serialize_tlv8(&[
            tlv::TLV8Entry {
                tlv_type: tlv::PairingDataComponentType::EncryptedData,
                data: ciphertext[..254].to_vec(),
            },
            tlv::TLV8Entry {
                tlv_type: tlv::PairingDataComponentType::EncryptedData,
                data: ciphertext[254..].to_vec(),
            },
            tlv::TLV8Entry {
                tlv_type: tlv::PairingDataComponentType::State,
                data: vec![0x05],
            },
        ]);
        let tlv = R::serialize_bytes(&tlv);

        debug!("Sending encrypted data");
        self.send_pairing_data(plist!({
            "data": tlv,
            "kind": "setupManualPairing",
            "sendingHost": &self.sending_host,
            "startNewSession": false,
        }))
        .await?;

        debug!("Waiting for encrypted data");
        let response = match R::deserialize_bytes(self.receive_pairing_data().await?) {
            Some(r) => r,
            None => {
                warn!("Pairing data response was not deserializable");
                return Err(IdeviceError::UnexpectedResponse(
                    "failed to deserialize pair record response bytes".into(),
                ));
            }
        };

        let tlv = tlv::deserialize_tlv8(&response)?;

        let mut encrypted_data = Vec::new();
        for t in tlv {
            match t.tlv_type {
                tlv::PairingDataComponentType::EncryptedData => encrypted_data.extend(t.data),
                tlv::PairingDataComponentType::ErrorResponse => {
                    warn!("TLV contained error response");
                    return Err(IdeviceError::UnexpectedResponse(
                        "TLV error response in pair record save".into(),
                    ));
                }
                _ => {}
            }
        }

        let nonce = Nonce::from_slice(b"\x00\x00\x00\x00PS-Msg06");

        let plaintext = cipher
            .decrypt(
                nonce,
                Payload {
                    msg: &encrypted_data,
                    aad: b"",
                },
            )
            .map_err(RemotePairingError::ChachaEncryption)?;

        let tlv = tlv::deserialize_tlv8(&plaintext)?;

        Ok(tlv)
    }

    /// Send an encrypted request and receive an encrypted response.
    /// Used for post-pairing RPCs like creating tunnel listeners.
    pub async fn send_receive_encrypted_request(
        &mut self,
        request: plist::Value,
    ) -> Result<plist::Value, IdeviceError> {
        let plaintext = serde_json::to_vec(
            &plist::to_value(&request).map_err(|e| IdeviceError::InternalError(e.to_string()))?,
        )
        .map_err(|e| IdeviceError::InternalError(e.to_string()))?;

        // Build nonce: 8-byte LE sequence number + 4 zero bytes
        let mut nonce_bytes = [0u8; 12];
        nonce_bytes[..8].copy_from_slice(&self.encrypted_sequence_number.to_le_bytes());
        let nonce = Nonce::from_slice(&nonce_bytes);

        let ciphertext = self
            .client_cipher
            .encrypt(
                nonce,
                Payload {
                    msg: &plaintext,
                    aad: b"",
                },
            )
            .map_err(|e| IdeviceError::RemotePairing(RemotePairingError::ChachaEncryption(e)))?;

        self.inner
            .send_encrypted(ciphertext, self.sequence_number)
            .await?;
        self.sequence_number += 1;

        // Receive encrypted response
        let response = self.inner.recv_plain().await?;
        let encrypted_data = response
            .get_by("message")
            .and_then(|m| m.get_by("streamEncrypted"))
            .and_then(|s| s.get_by("_0"))
            .and_then(|d| {
                // Could be bytes directly or base64
                R::deserialize_bytes(d.to_owned())
            })
            .ok_or(IdeviceError::UnexpectedResponse(
                "missing encrypted data in streamEncrypted response".into(),
            ))?;

        let decrypted = self
            .server_cipher
            .decrypt(
                nonce,
                Payload {
                    msg: &encrypted_data,
                    aad: b"",
                },
            )
            .map_err(|e| IdeviceError::RemotePairing(RemotePairingError::ChachaEncryption(e)))?;

        self.encrypted_sequence_number += 1;

        let value: plist::Value = serde_json::from_slice(&decrypted)
            .map_err(|e| IdeviceError::InternalError(e.to_string()))?;

        // Extract response._1
        let result = value
            .get_by("response")
            .and_then(|r| r.get_by("_1"))
            .cloned()
            .ok_or(IdeviceError::UnexpectedResponse(
                "missing response._1 in encrypted response".into(),
            ))?;

        Ok(result)
    }

    /// Send a request to create a TCP tunnel listener on the device.
    /// Returns the port the device is listening on.
    pub async fn create_tcp_listener(&mut self) -> Result<u16, IdeviceError> {
        let request = plist!({
            "request": {
                "_0": {
                    "createListener": {
                        "key": base64::engine::general_purpose::STANDARD.encode(&self.encryption_key),
                        "transportProtocolType": "tcp"
                    }
                }
            }
        });

        let response = self.send_receive_encrypted_request(request).await?;
        debug!("Received createListener response");

        parse_tcp_listener_port(&response)
    }

    async fn send_pairing_data(
        &mut self,
        pairing_data: impl Serialize + PlistConvertible,
    ) -> Result<(), IdeviceError> {
        self.inner
            .send_plain(
                plist!({
                    "event": {
                        "_0": {
                            "pairingData": {
                                "_0": pairing_data
                            }
                        }
                    }
                }),
                self.sequence_number,
            )
            .await?;

        self.sequence_number += 1;
        Ok(())
    }

    async fn receive_pairing_data(&mut self) -> Result<plist::Value, IdeviceError> {
        let response = self.inner.recv_plain().await?;

        let response = match response.get_by("event").and_then(|x| x.get_by("_0")) {
            Some(r) => r,
            None => {
                return Err(IdeviceError::UnexpectedResponse(
                    "missing event._0 in pairing data response".into(),
                ));
            }
        };

        if let Some(data) = response
            .get_by("pairingData")
            .and_then(|x| x.get_by("_0"))
            .and_then(|x| x.get_by("data"))
        {
            Ok(data.to_owned())
        } else if let Some(err) = response.get_by("pairingRejectedWithError") {
            let context = err
                .get_by("wrappedError")
                .and_then(|x| x.get_by("userInfo"))
                .and_then(|x| x.get_by("NSLocalizedDescription"))
                .and_then(|x| x.as_string())
                .map(|x| x.to_string());
            Err(RemotePairingError::PairingRejected(context.unwrap_or_default()).into())
        } else {
            Err(IdeviceError::UnexpectedResponse(
                "pairing data response contained neither data nor rejection".into(),
            ))
        }
    }
}

impl<R: RpPairingSocketProvider> std::fmt::Debug for RemotePairingClient<R> {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("RemotePairingClient")
            .field("inner", &self.inner)
            .field("sequence_number", &self.sequence_number)
            .field("sending_host", &self.sending_host)
            .finish()
    }
}

fn authenticate_pair_verify_m2(
    entries: &[tlv::TLV8Entry],
    cipher: &ChaCha20Poly1305,
    peer_ephemeral_key: &X25519PublicKey,
    controller_ephemeral_key: &X25519PublicKey,
    stored_peer: &VerifiedPeerIdentity,
) -> Result<(), IdeviceError> {
    let encrypted_identity =
        tlv::collect_component_data(entries, tlv::PairingDataComponentType::EncryptedData);
    if encrypted_identity.is_empty() {
        return Err(RemotePairingError::PairVerifyM2Malformed.into());
    }
    let plaintext = cipher
        .decrypt(
            Nonce::from_slice(b"\x00\x00\x00\x00PV-Msg02"),
            Payload {
                msg: &encrypted_identity,
                aad: &[],
            },
        )
        .map_err(|_| RemotePairingError::PairVerifyM2DecryptionFailed)?;
    let identity =
        tlv::deserialize_tlv8(&plaintext).map_err(|_| RemotePairingError::PairVerifyM2Malformed)?;
    let identifier =
        tlv::collect_component_data(&identity, tlv::PairingDataComponentType::Identifier);
    let signature = Signature::from_slice(&tlv::collect_component_data(
        &identity,
        tlv::PairingDataComponentType::Signature,
    ))
    .map_err(|_| RemotePairingError::PairVerifyM2Malformed)?;
    let verifying_key = VerifyingKey::from_bytes(&stored_peer.long_term_public_key)
        .map_err(|_| RemotePairingError::PairVerifyM2Malformed)?;
    let mut signed_data = Vec::with_capacity(32 + identifier.len() + 32);
    signed_data.extend_from_slice(peer_ephemeral_key.as_bytes());
    signed_data.extend_from_slice(&identifier);
    signed_data.extend_from_slice(controller_ephemeral_key.as_bytes());
    verifying_key
        .verify_strict(&signed_data, &signature)
        .map_err(|_| RemotePairingError::PairVerifyM2SignatureFailed)?;
    if identifier.as_slice() != stored_peer.pairing_identifier.as_bytes() {
        return Err(RemotePairingError::PairVerifyM2IdentifierMismatch.into());
    }
    Ok(())
}

/// Accepts Apple's canonical Pair Verify completion state and optional proof
/// extensions while rejecting malformed, duplicate-state, and error messages.
fn validate_pair_verify_m4(response: &[u8]) -> Result<(), IdeviceError> {
    let entries = tlv::deserialize_tlv8(response)?;
    if tlv::serialize_tlv8(&entries) != response {
        return Err(RemotePairingError::PairVerifyCompletionFailed.into());
    }
    if tlv::contains_component(&entries, tlv::PairingDataComponentType::ErrorResponse) {
        return Err(RemotePairingError::PairVerifyCompletionFailed.into());
    }
    let mut states = entries
        .iter()
        .filter(|entry| entry.tlv_type == tlv::PairingDataComponentType::State);
    match (states.next(), states.next()) {
        (Some(state), None) if state.data.as_slice() == [4] => Ok(()),
        _ => Err(RemotePairingError::PairVerifyCompletionFailed.into()),
    }
}

/// Extracts a nonzero TCP port without truncating an untrusted plist integer.
fn parse_tcp_listener_port(response: &plist::Value) -> Result<u16, IdeviceError> {
    let port = response
        .get_by("createListener")
        .and_then(|listener| listener.get_by("port"))
        .and_then(plist::Value::as_unsigned_integer)
        .ok_or(IdeviceError::UnexpectedResponse(
            "invalid port in createListener response".into(),
        ))?;
    let port = u16::try_from(port).map_err(|_| {
        IdeviceError::UnexpectedResponse("invalid port in createListener response".into())
    })?;
    if port == 0 {
        return Err(IdeviceError::UnexpectedResponse(
            "invalid port in createListener response".into(),
        ));
    }
    Ok(port)
}

#[cfg(test)]
mod tests {
    use ed25519_dalek::{Signer as _, SigningKey};

    use super::*;

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

    fn verified_peer(signing_key: &SigningKey) -> VerifiedPeerIdentity {
        VerifiedPeerIdentity {
            peer: PeerDevice {
                account_id: "account".into(),
                alt_irk: vec![0x11; 16],
                model: "iPhone19,1".into(),
                name: "Test iPhone".into(),
                remotepairing_udid: "00008140-test".into(),
            },
            pairing_identifier: "peer-identifier".into(),
            long_term_public_key: signing_key.verifying_key().to_bytes(),
        }
    }

    fn tcp_listener_response(port: plist::Value) -> plist::Value {
        let mut listener = plist::Dictionary::new();
        listener.insert("port".into(), port);
        let mut response = plist::Dictionary::new();
        response.insert("createListener".into(), plist::Value::Dictionary(listener));
        plist::Value::Dictionary(response)
    }

    fn pair_verify_cipher(shared_secret: &[u8; 32]) -> ChaCha20Poly1305 {
        let hk = Hkdf::<Sha512>::new(Some(b"Pair-Verify-Encrypt-Salt"), shared_secret);
        let mut key = [0_u8; 32];
        hk.expand(b"Pair-Verify-Encrypt-Info", &mut key).unwrap();
        ChaCha20Poly1305::new(Key::from_slice(&key))
    }

    fn authenticated_m2(
        cipher: &ChaCha20Poly1305,
        peer_ephemeral_key: &X25519PublicKey,
        controller_ephemeral_key: &X25519PublicKey,
        signing_key: &SigningKey,
        identifier: &str,
    ) -> Vec<tlv::TLV8Entry> {
        let mut signed_data = Vec::new();
        signed_data.extend_from_slice(peer_ephemeral_key.as_bytes());
        signed_data.extend_from_slice(identifier.as_bytes());
        signed_data.extend_from_slice(controller_ephemeral_key.as_bytes());
        let signature = signing_key.sign(&signed_data);
        let plaintext = tlv::serialize_tlv8(&[
            tlv::TLV8Entry {
                tlv_type: tlv::PairingDataComponentType::Identifier,
                data: identifier.as_bytes().to_vec(),
            },
            tlv::TLV8Entry {
                tlv_type: tlv::PairingDataComponentType::Signature,
                data: signature.to_bytes().to_vec(),
            },
        ]);
        let ciphertext = cipher
            .encrypt(
                Nonce::from_slice(b"\x00\x00\x00\x00PV-Msg02"),
                Payload {
                    msg: &plaintext,
                    aad: &[],
                },
            )
            .unwrap();
        vec![tlv::TLV8Entry {
            tlv_type: tlv::PairingDataComponentType::EncryptedData,
            data: ciphertext,
        }]
    }

    #[test]
    fn pair_verify_authenticates_m2_before_m3() {
        let signing_key = SigningKey::from_bytes(&[0x41; 32]);
        let stored_peer = verified_peer(&signing_key);
        let peer_ephemeral_key = X25519PublicKey::from([0x21; 32]);
        let controller_ephemeral_key = X25519PublicKey::from([0x31; 32]);
        let cipher = pair_verify_cipher(&[0x51; 32]);
        let m2 = authenticated_m2(
            &cipher,
            &peer_ephemeral_key,
            &controller_ephemeral_key,
            &signing_key,
            &stored_peer.pairing_identifier,
        );

        authenticate_pair_verify_m2(
            &m2,
            &cipher,
            &peer_ephemeral_key,
            &controller_ephemeral_key,
            &stored_peer,
        )
        .unwrap();
    }

    #[test]
    fn pair_verify_accepts_an_independent_m2_vector() {
        let controller_ephemeral_key = X25519PublicKey::from(
            <[u8; 32]>::try_from(
                decode_hex("79a631eede1bf9c98f12032cdeadd0e7a079398fc786b88cc846ec89af85a51a")
                    .as_slice(),
            )
            .unwrap(),
        );
        let peer_ephemeral_key = X25519PublicKey::from(
            <[u8; 32]>::try_from(
                decode_hex("358072d6365880d1aeea329adf9121383851ed21a28e3b75e965d0d2cd166254")
                    .as_slice(),
            )
            .unwrap(),
        );
        let shared_secret = <[u8; 32]>::try_from(
            decode_hex("04c304fb1ca83cee75e206344231f33797e07d9929db670994b7c6fbeb1dc255")
                .as_slice(),
        )
        .unwrap();
        let long_term_public_key = <[u8; 32]>::try_from(
            decode_hex("cd14b37f956e953194ff7fb73b3d81dcc561d61a7538094b7c3e1a643ee5f3aa")
                .as_slice(),
        )
        .unwrap();
        let stored_peer = VerifiedPeerIdentity {
            peer: PeerDevice {
                account_id: "account".into(),
                alt_irk: vec![0x11; 16],
                model: "iPhone19,1".into(),
                name: "Test iPhone".into(),
                remotepairing_udid: "00008140-test".into(),
            },
            pairing_identifier: "00008130-TEST-DEVICE".into(),
            long_term_public_key,
        };
        let cipher = pair_verify_cipher(&shared_secret);
        let m2 = vec![tlv::TLV8Entry {
            tlv_type: tlv::PairingDataComponentType::EncryptedData,
            data: decode_hex(
                "9bbb324a5ca4b4e3c2f6c0d3cc4339f829f463a22784aeceb427130ff7d46d20\
                 fdfae490920824574471e91fb4ca79aed3e98d94d5f6462d7c7be6f1add83088\
                 ec9599b2922ef10b74370a4daa8618e4a36859e92d50ef15aef9cd63e571d519\
                 e5762383a6257194",
            ),
        }];

        authenticate_pair_verify_m2(
            &m2,
            &cipher,
            &peer_ephemeral_key,
            &controller_ephemeral_key,
            &stored_peer,
        )
        .unwrap();
    }

    #[test]
    fn pair_verify_rejects_tampered_m2() {
        let signing_key = SigningKey::from_bytes(&[0x41; 32]);
        let stored_peer = verified_peer(&signing_key);
        let peer_ephemeral_key = X25519PublicKey::from([0x21; 32]);
        let controller_ephemeral_key = X25519PublicKey::from([0x31; 32]);
        let cipher = pair_verify_cipher(&[0x51; 32]);
        let mut m2 = authenticated_m2(
            &cipher,
            &peer_ephemeral_key,
            &controller_ephemeral_key,
            &signing_key,
            &stored_peer.pairing_identifier,
        );
        m2[0].data[0] ^= 1;

        let error = authenticate_pair_verify_m2(
            &m2,
            &cipher,
            &peer_ephemeral_key,
            &controller_ephemeral_key,
            &stored_peer,
        )
        .unwrap_err();

        assert!(matches!(
            error,
            IdeviceError::RemotePairing(RemotePairingError::PairVerifyM2DecryptionFailed)
        ));
    }

    #[test]
    fn pair_verify_rejects_a_stored_identifier_mismatch() {
        let signing_key = SigningKey::from_bytes(&[0x41; 32]);
        let mut stored_peer = verified_peer(&signing_key);
        let peer_ephemeral_key = X25519PublicKey::from([0x21; 32]);
        let controller_ephemeral_key = X25519PublicKey::from([0x31; 32]);
        let cipher = pair_verify_cipher(&[0x51; 32]);
        let m2 = authenticated_m2(
            &cipher,
            &peer_ephemeral_key,
            &controller_ephemeral_key,
            &signing_key,
            &stored_peer.pairing_identifier,
        );
        stored_peer.pairing_identifier = "different-peer".into();

        let error = authenticate_pair_verify_m2(
            &m2,
            &cipher,
            &peer_ephemeral_key,
            &controller_ephemeral_key,
            &stored_peer,
        )
        .unwrap_err();

        assert!(matches!(
            error,
            IdeviceError::RemotePairing(RemotePairingError::PairVerifyM2IdentifierMismatch)
        ));
    }

    #[test]
    fn pair_verify_reports_a_stored_public_key_mismatch() {
        let signing_key = SigningKey::from_bytes(&[0x41; 32]);
        let other_signing_key = SigningKey::from_bytes(&[0x42; 32]);
        let stored_peer = verified_peer(&other_signing_key);
        let peer_ephemeral_key = X25519PublicKey::from([0x21; 32]);
        let controller_ephemeral_key = X25519PublicKey::from([0x31; 32]);
        let cipher = pair_verify_cipher(&[0x51; 32]);
        let m2 = authenticated_m2(
            &cipher,
            &peer_ephemeral_key,
            &controller_ephemeral_key,
            &signing_key,
            &stored_peer.pairing_identifier,
        );

        let error = authenticate_pair_verify_m2(
            &m2,
            &cipher,
            &peer_ephemeral_key,
            &controller_ephemeral_key,
            &stored_peer,
        )
        .unwrap_err();

        assert!(matches!(
            error,
            IdeviceError::RemotePairing(RemotePairingError::PairVerifyM2SignatureFailed)
        ));
    }

    #[test]
    fn pair_verify_authenticates_before_classifying_an_identifier_mismatch() {
        let signing_key = SigningKey::from_bytes(&[0x41; 32]);
        let stored_signing_key = SigningKey::from_bytes(&[0x42; 32]);
        let stored_peer = verified_peer(&stored_signing_key);
        let peer_ephemeral_key = X25519PublicKey::from([0x21; 32]);
        let controller_ephemeral_key = X25519PublicKey::from([0x31; 32]);
        let cipher = pair_verify_cipher(&[0x51; 32]);
        let m2 = authenticated_m2(
            &cipher,
            &peer_ephemeral_key,
            &controller_ephemeral_key,
            &signing_key,
            "untrusted-identifier",
        );

        let error = authenticate_pair_verify_m2(
            &m2,
            &cipher,
            &peer_ephemeral_key,
            &controller_ephemeral_key,
            &stored_peer,
        )
        .unwrap_err();

        assert!(matches!(
            error,
            IdeviceError::RemotePairing(RemotePairingError::PairVerifyM2SignatureFailed)
        ));
    }

    #[test]
    fn pair_verify_rejects_m4_with_the_wrong_state() {
        let m4 = tlv::serialize_tlv8(&[tlv::TLV8Entry {
            tlv_type: tlv::PairingDataComponentType::State,
            data: vec![3],
        }]);

        let error = validate_pair_verify_m4(&m4).unwrap_err();

        assert!(matches!(
            error,
            IdeviceError::RemotePairing(RemotePairingError::PairVerifyCompletionFailed)
        ));
    }

    #[test]
    fn pair_verify_accepts_an_exact_m4_completion() {
        let m4 = tlv::serialize_tlv8(&[tlv::TLV8Entry {
            tlv_type: tlv::PairingDataComponentType::State,
            data: vec![4],
        }]);

        validate_pair_verify_m4(&m4).unwrap();
    }

    #[test]
    fn pair_verify_accepts_m4_with_optional_encrypted_peer_proof() {
        let m4 = tlv::serialize_tlv8(&[
            tlv::TLV8Entry {
                tlv_type: tlv::PairingDataComponentType::State,
                data: vec![4],
            },
            tlv::TLV8Entry {
                tlv_type: tlv::PairingDataComponentType::EncryptedData,
                data: vec![0xA5; 32],
            },
        ]);

        validate_pair_verify_m4(&m4).unwrap();
    }

    #[test]
    fn pair_verify_rejects_m4_without_a_state() {
        let m4 = tlv::serialize_tlv8(&[tlv::TLV8Entry {
            tlv_type: tlv::PairingDataComponentType::Proof,
            data: vec![4],
        }]);

        let error = validate_pair_verify_m4(&m4).unwrap_err();

        assert!(matches!(
            error,
            IdeviceError::RemotePairing(RemotePairingError::PairVerifyCompletionFailed)
        ));
    }

    #[test]
    fn pair_verify_rejects_m4_with_an_error() {
        let m4 = tlv::serialize_tlv8(&[
            tlv::TLV8Entry {
                tlv_type: tlv::PairingDataComponentType::State,
                data: vec![4],
            },
            tlv::TLV8Entry {
                tlv_type: tlv::PairingDataComponentType::ErrorResponse,
                data: vec![2],
            },
        ]);

        let error = validate_pair_verify_m4(&m4).unwrap_err();

        assert!(matches!(
            error,
            IdeviceError::RemotePairing(RemotePairingError::PairVerifyCompletionFailed)
        ));
    }

    #[test]
    fn pair_verify_rejects_every_other_m4_state() {
        for state in u8::MIN..=u8::MAX {
            if state == 4 {
                continue;
            }
            let m4 = tlv::serialize_tlv8(&[tlv::TLV8Entry {
                tlv_type: tlv::PairingDataComponentType::State,
                data: vec![state],
            }]);

            assert!(
                validate_pair_verify_m4(&m4).is_err(),
                "accepted invalid Pair Verify state {state}"
            );
        }
    }

    #[test]
    fn pair_verify_rejects_malformed_m4_state_shapes() {
        let cases = [
            Vec::new(),
            tlv::serialize_tlv8(&[tlv::TLV8Entry {
                tlv_type: tlv::PairingDataComponentType::State,
                data: Vec::new(),
            }]),
            tlv::serialize_tlv8(&[tlv::TLV8Entry {
                tlv_type: tlv::PairingDataComponentType::State,
                data: vec![4, 4],
            }]),
            tlv::serialize_tlv8(&[
                tlv::TLV8Entry {
                    tlv_type: tlv::PairingDataComponentType::State,
                    data: vec![4],
                },
                tlv::TLV8Entry {
                    tlv_type: tlv::PairingDataComponentType::State,
                    data: vec![4],
                },
            ]),
        ];

        for m4 in cases {
            let error = validate_pair_verify_m4(&m4).unwrap_err();
            assert!(matches!(
                error,
                IdeviceError::RemotePairing(RemotePairingError::PairVerifyCompletionFailed)
            ));
        }
    }

    #[test]
    fn pair_verify_rejects_a_truncated_m4_tlv() {
        let error = validate_pair_verify_m4(&[tlv::PairingDataComponentType::State as u8, 2, 4])
            .unwrap_err();

        assert!(matches!(
            error,
            IdeviceError::RemotePairing(RemotePairingError::MalformedTlv)
        ));
    }

    #[test]
    fn pair_verify_rejects_a_trailing_m4_tlv_byte() {
        let error = validate_pair_verify_m4(&[
            tlv::PairingDataComponentType::State as u8,
            1,
            4,
            tlv::PairingDataComponentType::State as u8,
        ])
        .unwrap_err();

        assert!(matches!(
            error,
            IdeviceError::RemotePairing(RemotePairingError::MalformedTlv)
        ));
    }

    #[test]
    fn tcp_listener_rejects_port_zero() {
        let response = tcp_listener_response(plist::Value::Integer(0_u64.into()));

        let error = parse_tcp_listener_port(&response).unwrap_err();

        assert!(
            matches!(error, IdeviceError::UnexpectedResponse(message) if message == "invalid port in createListener response")
        );
    }

    #[test]
    fn tcp_listener_accepts_the_valid_port_boundaries() {
        for expected in [1_u16, u16::MAX] {
            let response = tcp_listener_response(plist::Value::Integer(u64::from(expected).into()));

            assert_eq!(parse_tcp_listener_port(&response).unwrap(), expected);
        }
    }

    #[test]
    fn tcp_listener_rejects_ports_above_u16_max_without_truncating() {
        for invalid in [u64::from(u16::MAX) + 1, u64::MAX] {
            let response = tcp_listener_response(plist::Value::Integer(invalid.into()));

            let error = parse_tcp_listener_port(&response).unwrap_err();

            assert!(
                matches!(error, IdeviceError::UnexpectedResponse(message) if message == "invalid port in createListener response")
            );
        }
    }

    #[test]
    fn tcp_listener_rejects_missing_and_non_unsigned_ports() {
        let cases = [
            plist::Value::Dictionary(plist::Dictionary::new()),
            {
                let mut response = plist::Dictionary::new();
                response.insert(
                    "createListener".into(),
                    plist::Value::Dictionary(plist::Dictionary::new()),
                );
                plist::Value::Dictionary(response)
            },
            tcp_listener_response(plist::Value::String("62078".into())),
            tcp_listener_response(plist::Value::Integer((-1_i64).into())),
        ];

        for response in cases {
            let error = parse_tcp_listener_port(&response).unwrap_err();
            assert!(
                matches!(error, IdeviceError::UnexpectedResponse(message) if message == "invalid port in createListener response")
            );
        }
    }
}
