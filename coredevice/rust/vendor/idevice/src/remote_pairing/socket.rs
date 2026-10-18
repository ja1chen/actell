// Jackson Coxson

use base64::{Engine as _, engine::general_purpose::STANDARD as B64};
use plist_macro::plist;
use serde::Serialize;
use serde_json::json;
use std::{fmt::Debug, pin::Pin};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tracing::{debug, warn};

use crate::{
    IdeviceError, ReadWrite, RemoteXpcClient,
    remote_pairing::{RPPAIRING_MAGIC, errors::RemotePairingError},
    xpc::XPCObject,
};

pub trait RpPairingSocketProvider: Debug {
    fn send_plain(
        &mut self,
        value: impl Serialize,
        seq: usize,
    ) -> Pin<Box<dyn Future<Output = Result<(), IdeviceError>> + Send + '_>>;

    fn send_encrypted(
        &mut self,
        ciphertext: Vec<u8>,
        seq: usize,
    ) -> Pin<Box<dyn Future<Output = Result<(), IdeviceError>> + Send + '_>>;

    fn recv_plain<'a>(
        &'a mut self,
    ) -> Pin<Box<dyn Future<Output = Result<plist::Value, IdeviceError>> + Send + 'a>>;

    /// rppairing uses b64, while RemoteXPC uses raw bytes just fine
    fn serialize_bytes(b: &[u8]) -> plist::Value;
    fn deserialize_bytes(v: plist::Value) -> Option<Vec<u8>>;
}

#[derive(Debug)]
pub struct RpPairingSocket<R: ReadWrite> {
    pub inner: R,
    /// The value placed in the `originatedBy` field of every envelope we send.
    ///
    /// The host (the side that connects to a device and initiates pairing) sends
    /// `"host"`. The responder side - a "pairable host" that a device connects to
    /// and pairs *into* (see [`crate::remote_pairing::PairableHost`]) - sends
    /// `"device"`, because in rppairing terms it plays the accessory/responder role.
    originated_by: &'static str,
    /// The next peer-owned sequence number accepted on this connection.
    next_incoming_sequence_number: u64,
}

impl<R: ReadWrite> RpPairingSocket<R> {
    fn expected_peer_role(&self) -> &'static str {
        if self.originated_by == "host" {
            "device"
        } else {
            "host"
        }
    }

    /// Creates a socket for the initiating host (sends `originatedBy: "host"`).
    pub fn new(socket: R) -> Self {
        Self {
            inner: socket,
            originated_by: "host",
            next_incoming_sequence_number: 0,
        }
    }

    /// Creates a socket for the responder side (sends `originatedBy: "device"`).
    ///
    /// Use this when accepting a device-initiated pairing with
    /// [`crate::remote_pairing::PairableHost`].
    pub fn new_device(socket: R) -> Self {
        Self {
            inner: socket,
            originated_by: "device",
            next_incoming_sequence_number: 0,
        }
    }

    async fn send_rppairing(&mut self, value: impl Serialize) -> Result<(), IdeviceError> {
        let value = serde_json::to_string(&value)?;
        let x = value.as_bytes();
        let frame_length = u16::try_from(x.len()).map_err(|_| IdeviceError::IntegerOverflow)?;

        let mut frame = Vec::with_capacity(RPPAIRING_MAGIC.len() + 2 + x.len());
        frame.extend_from_slice(RPPAIRING_MAGIC);
        frame.extend_from_slice(&frame_length.to_be_bytes());
        frame.extend_from_slice(x);
        self.inner.write_all(&frame).await?;
        self.inner.flush().await?;
        Ok(())
    }
}

impl<R: ReadWrite> RpPairingSocketProvider for RpPairingSocket<R> {
    fn send_plain(
        &mut self,
        value: impl Serialize,
        seq: usize,
    ) -> Pin<Box<dyn Future<Output = Result<(), IdeviceError>> + Send + '_>> {
        let v = json!({
            "message": {"plain": {"_0": value}},
            "originatedBy": self.originated_by,
            "sequenceNumber": seq
        });

        Box::pin(async move {
            self.send_rppairing(v).await?;
            Ok(())
        })
    }

    fn send_encrypted(
        &mut self,
        ciphertext: Vec<u8>,
        seq: usize,
    ) -> Pin<Box<dyn Future<Output = Result<(), IdeviceError>> + Send + '_>> {
        let v = json!({
            "message": {"streamEncrypted": {"_0": B64.encode(&ciphertext)}},
            "originatedBy": self.originated_by,
            "sequenceNumber": seq
        });

        Box::pin(async move {
            self.send_rppairing(v).await?;
            Ok(())
        })
    }

    fn recv_plain<'a>(
        &'a mut self,
    ) -> Pin<Box<dyn Future<Output = Result<plist::Value, IdeviceError>> + Send + 'a>> {
        Box::pin(async move {
            let mut magic = vec![0u8; RPPAIRING_MAGIC.len()];
            self.inner.read_exact(&mut magic).await?;
            if magic != RPPAIRING_MAGIC {
                return Err(IdeviceError::UnexpectedResponse(
                    "invalid RPPairing frame magic".into(),
                ));
            }

            let mut packet_len_bytes = [0u8; 2];
            self.inner.read_exact(&mut packet_len_bytes).await?;
            let packet_len = u16::from_be_bytes(packet_len_bytes);

            let mut value = vec![0u8; packet_len as usize];
            self.inner.read_exact(&mut value).await?;

            debug!("recv_rppairing: {packet_len} json bytes");

            let value: serde_json::Value = serde_json::from_slice(&value)?;
            if value.get("originatedBy").and_then(|role| role.as_str())
                != Some(self.expected_peer_role())
            {
                return Err(IdeviceError::UnexpectedResponse(
                    "invalid RPPairing envelope origin".into(),
                ));
            }
            if value
                .get("sequenceNumber")
                .and_then(|sequence| sequence.as_u64())
                != Some(self.next_incoming_sequence_number)
            {
                return Err(IdeviceError::UnexpectedResponse(
                    "invalid RPPairing envelope sequence".into(),
                ));
            }

            let message = value
                .get("message")
                .and_then(|message| message.as_object())
                .ok_or_else(|| {
                    IdeviceError::UnexpectedResponse("missing RPPairing envelope message".into())
                })?;
            let plain = message.get("plain").and_then(|plain| plain.get("_0"));
            let encrypted = message
                .get("streamEncrypted")
                .and_then(|encrypted| encrypted.get("_0"))
                .and_then(|encoded| encoded.as_str());
            let received = match (plain, encrypted) {
                (Some(value), None) if value.is_object() => plist::to_value(value)?,
                (Some(_), None) => {
                    return Err(IdeviceError::UnexpectedResponse(
                        "invalid RPPairing plain message".into(),
                    ));
                }
                (None, Some(encoded)) => {
                    B64.decode(encoded).map_err(RemotePairingError::from)?;
                    plist::to_value(&value)?
                }
                (None, None) => {
                    return Err(IdeviceError::UnexpectedResponse(
                        "missing RPPairing envelope message".into(),
                    ));
                }
                (Some(_), Some(_)) => {
                    return Err(IdeviceError::UnexpectedResponse(
                        "ambiguous RPPairing envelope message".into(),
                    ));
                }
            };
            self.next_incoming_sequence_number = self
                .next_incoming_sequence_number
                .checked_add(1)
                .ok_or(IdeviceError::IntegerOverflow)?;
            Ok(received)
        })
    }

    fn serialize_bytes(b: &[u8]) -> plist::Value {
        plist!(B64.encode(b))
    }

    fn deserialize_bytes(v: plist::Value) -> Option<Vec<u8>> {
        if let plist::Value::String(v) = v {
            B64.decode(v).ok()
        } else {
            None
        }
    }
}

impl<R: ReadWrite> RpPairingSocketProvider for RemoteXpcClient<R> {
    fn send_plain(
        &mut self,
        value: impl Serialize,
        seq: usize,
    ) -> Pin<Box<dyn Future<Output = Result<(), IdeviceError>> + Send + '_>> {
        let value: plist::Value = plist::to_value(&value).expect("plist assert failed");
        let value: XPCObject = value.into();

        let v = crate::xpc!({
            "mangledTypeName": "RemotePairing.ControlChannelMessageEnvelope",
            "value": {
                "message": {"plain": {"_0": value}},
                "originatedBy": "host",
                "sequenceNumber": seq as u64
            }
        });
        debug!("Sending RemoteXPC pairing envelope sequence={seq}");

        Box::pin(async move {
            self.send_object(v, true).await?;
            Ok(())
        })
    }

    fn send_encrypted(
        &mut self,
        ciphertext: Vec<u8>,
        seq: usize,
    ) -> Pin<Box<dyn Future<Output = Result<(), IdeviceError>> + Send + '_>> {
        let v = crate::xpc!({
            "mangledTypeName": "RemotePairing.ControlChannelMessageEnvelope",
            "value": {
                "message": {"streamEncrypted": {"_0": ciphertext}},
                "originatedBy": "host",
                "sequenceNumber": seq as u64
            }
        });

        Box::pin(async move {
            self.send_object(v, true).await?;
            Ok(())
        })
    }

    fn recv_plain<'a>(
        &'a mut self,
    ) -> Pin<Box<dyn Future<Output = Result<plist::Value, IdeviceError>> + Send + 'a>> {
        Box::pin(async move {
            let msg = self.recv_root().await?;
            debug!("Received RemoteXPC pairing envelope");
            let msg = msg.into_dictionary().and_then(|mut x| x.remove("value"));

            let msg = match msg {
                Some(v) => v,
                None => {
                    return Err(IdeviceError::UnexpectedResponse(
                        "missing value field in RemoteXPC message".into(),
                    ));
                }
            };

            // Try plain first
            if let Some(plain) = msg
                .as_dictionary()
                .and_then(|x| x.get("message"))
                .and_then(|x| x.as_dictionary())
                .and_then(|x| x.get("plain"))
                .and_then(|x| x.as_dictionary())
                .and_then(|x| x.get("_0"))
                .cloned()
            {
                return Ok(plain);
            }

            // Return the whole value dict for encrypted handling
            Ok(msg)
        })
    }

    fn serialize_bytes(b: &[u8]) -> plist::Value {
        plist::Value::Data(b.to_owned())
    }

    fn deserialize_bytes(v: plist::Value) -> Option<Vec<u8>> {
        if let plist::Value::Data(v) = v {
            Some(v)
        } else {
            warn!("Non-data passed to rppairingsocket::deserialize_bytes for RemoteXPC provider");
            None
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn frame(magic: &[u8], body: &[u8]) -> Vec<u8> {
        let mut frame = Vec::with_capacity(magic.len() + 2 + body.len());
        frame.extend_from_slice(magic);
        frame.extend_from_slice(&(body.len() as u16).to_be_bytes());
        frame.extend_from_slice(body);
        frame
    }

    async fn receive_frame(bytes: &[u8]) -> Result<plist::Value, IdeviceError> {
        let capacity = bytes.len().max(1);
        let (mut writer, reader) = tokio::io::duplex(capacity);
        writer.write_all(bytes).await.unwrap();
        drop(writer);

        RpPairingSocket::new(reader).recv_plain().await
    }

    #[tokio::test]
    async fn send_plain_rejects_json_larger_than_the_u16_frame_contract() {
        let (stream, _peer) = tokio::io::duplex(1);
        let mut socket = RpPairingSocket::new(stream);
        let oversized = serde_json::json!({"data": "x".repeat(usize::from(u16::MAX))});

        let error = socket.send_plain(oversized, 0).await.unwrap_err();

        assert!(matches!(error, IdeviceError::IntegerOverflow));
    }

    #[tokio::test]
    async fn recv_plain_rejects_incorrect_magic() {
        let body = br#"{"message":{"plain":{"_0":{}}},"originatedBy":"device","sequenceNumber":0}"#;

        let error = receive_frame(&frame(b"not_magic", body)).await.unwrap_err();

        assert!(
            matches!(error, IdeviceError::UnexpectedResponse(message) if message == "invalid RPPairing frame magic")
        );
    }

    #[tokio::test]
    async fn recv_plain_rejects_json_null_instead_of_coercing_it() {
        let body =
            br#"{"message":{"plain":{"_0":null}},"originatedBy":"device","sequenceNumber":0}"#;

        let error = receive_frame(&frame(RPPAIRING_MAGIC, body))
            .await
            .unwrap_err();

        assert!(
            matches!(error, IdeviceError::UnexpectedResponse(message) if message == "invalid RPPairing plain message")
        );
    }

    #[tokio::test]
    async fn recv_plain_rejects_an_envelope_from_the_local_role() {
        let body = br#"{"message":{"plain":{"_0":{}}},"originatedBy":"host","sequenceNumber":0}"#;

        let error = receive_frame(&frame(RPPAIRING_MAGIC, body))
            .await
            .unwrap_err();

        assert!(
            matches!(error, IdeviceError::UnexpectedResponse(message) if message == "invalid RPPairing envelope origin")
        );
    }

    #[tokio::test]
    async fn recv_plain_rejects_an_unexpected_sequence_number() {
        let body = br#"{"message":{"plain":{"_0":{}}},"originatedBy":"device","sequenceNumber":7}"#;

        let error = receive_frame(&frame(RPPAIRING_MAGIC, body))
            .await
            .unwrap_err();

        assert!(
            matches!(error, IdeviceError::UnexpectedResponse(message) if message == "invalid RPPairing envelope sequence")
        );
    }

    #[tokio::test]
    async fn recv_plain_rejects_a_missing_message_payload() {
        let body = br#"{"originatedBy":"device","sequenceNumber":0}"#;

        let error = receive_frame(&frame(RPPAIRING_MAGIC, body))
            .await
            .unwrap_err();

        assert!(
            matches!(error, IdeviceError::UnexpectedResponse(message) if message == "missing RPPairing envelope message")
        );
    }

    #[tokio::test]
    async fn recv_plain_rejects_malformed_json() {
        let error = receive_frame(&frame(RPPAIRING_MAGIC, b"{"))
            .await
            .unwrap_err();

        assert!(matches!(error, IdeviceError::Json(_)));
    }

    #[tokio::test]
    async fn recv_plain_rejects_malformed_base64() {
        let body = br#"{"message":{"streamEncrypted":{"_0":"not-base64!!"}},"originatedBy":"device","sequenceNumber":0}"#;

        let error = receive_frame(&frame(RPPAIRING_MAGIC, body))
            .await
            .unwrap_err();

        assert!(matches!(
            error,
            IdeviceError::RemotePairing(RemotePairingError::Base64DecodeError(_))
        ));
    }

    #[tokio::test]
    async fn recv_plain_rejects_every_truncated_frame_prefix_without_panicking() {
        let body = br#"{"message":{"plain":{"_0":{}}},"originatedBy":"device","sequenceNumber":0}"#;
        let complete = frame(RPPAIRING_MAGIC, body);

        for length in 0..complete.len() {
            assert!(
                receive_frame(&complete[..length]).await.is_err(),
                "accepted truncated frame prefix of length {length}"
            );
        }
    }

    #[tokio::test]
    async fn recv_plain_requires_a_well_formed_sequence_number() {
        let bodies: [&[u8]; 3] = [
            br#"{"message":{"plain":{"_0":{}}},"originatedBy":"device"}"#,
            br#"{"message":{"plain":{"_0":{}}},"originatedBy":"device","sequenceNumber":-1}"#,
            br#"{"message":{"plain":{"_0":{}}},"originatedBy":"device","sequenceNumber":"0"}"#,
        ];

        for body in bodies {
            let error = receive_frame(&frame(RPPAIRING_MAGIC, body))
                .await
                .unwrap_err();
            assert!(
                matches!(error, IdeviceError::UnexpectedResponse(message) if message == "invalid RPPairing envelope sequence")
            );
        }
    }

    #[tokio::test]
    async fn recv_plain_accepts_strictly_ordered_peer_sequences() {
        let first =
            br#"{"message":{"plain":{"_0":{"index":0}}},"originatedBy":"device","sequenceNumber":0}"#;
        let second =
            br#"{"message":{"plain":{"_0":{"index":1}}},"originatedBy":"device","sequenceNumber":1}"#;
        let mut bytes = frame(RPPAIRING_MAGIC, first);
        bytes.extend(frame(RPPAIRING_MAGIC, second));
        let (mut writer, reader) = tokio::io::duplex(bytes.len());
        writer.write_all(&bytes).await.unwrap();
        drop(writer);
        let mut socket = RpPairingSocket::new(reader);

        let first = socket.recv_plain().await.unwrap();
        let second = socket.recv_plain().await.unwrap();

        assert_eq!(
            first
                .as_dictionary()
                .and_then(|value| value.get("index"))
                .and_then(plist::Value::as_signed_integer),
            Some(0)
        );
        assert_eq!(
            second
                .as_dictionary()
                .and_then(|value| value.get("index"))
                .and_then(plist::Value::as_signed_integer),
            Some(1)
        );
    }

    #[tokio::test]
    async fn recv_plain_accepts_the_host_role_for_a_responder_socket() {
        let body = br#"{"message":{"plain":{"_0":{}}},"originatedBy":"host","sequenceNumber":0}"#;
        let bytes = frame(RPPAIRING_MAGIC, body);
        let (mut writer, reader) = tokio::io::duplex(bytes.len());
        writer.write_all(&bytes).await.unwrap();
        drop(writer);

        let value = RpPairingSocket::new_device(reader)
            .recv_plain()
            .await
            .unwrap();

        assert_eq!(value, plist::Value::Dictionary(plist::Dictionary::new()));
    }
}
