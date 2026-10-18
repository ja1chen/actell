// Jackson Coxson
//! TLS-PSK tunnel connect helpers for remote pairing.
//!
//! These functions combine TLS-PSK handshake + CDTunnel handshake into a single call.
//! The CDTunnel protocol itself lives in [`crate::tunnel`].

use tokio::io::{AsyncRead, AsyncReadExt};
use tracing::debug;

use crate::{CdTunnelError, IdeviceError, ReadWrite, tunnel::parse_tunnel_info};

// Re-export for backwards compatibility
pub use crate::tunnel::{CdTunnel, TunnelInfo};

const CDTUNNEL_MAGIC: &[u8] = b"CDTunnel";
const DEFAULT_MTU: u16 = 16000;

/// Wraps a `tokio::net::TcpStream` with TLS-PSK using a pure-Rust implementation
/// and performs the CDTunnel handshake, returning a ready-to-use tunnel.
///
/// `encryption_key` is the key from `RemotePairingClient::encryption_key()`.
///
/// This uses a built-in TLS 1.2 PSK-AES256-CBC-SHA384 implementation with no
/// external TLS library dependency.
pub async fn connect_tls_psk_tunnel_native<S: ReadWrite>(
    stream: S,
    encryption_key: &[u8],
) -> Result<CdTunnel<super::tls_psk::TlsPskStream<S>>, IdeviceError> {
    let mut tls_stream = super::tls_psk::tls_psk_handshake(stream, encryption_key).await?;
    debug!("Native TLS-PSK handshake complete");

    // CDTunnel handshake over TLS using the record-level API
    let request = serde_json::json!({
        "type": "clientHandshakeRequest",
        "mtu": DEFAULT_MTU
    });
    let body = serde_json::to_vec(&request)?;

    let mut pkt = Vec::new();
    pkt.extend_from_slice(CDTUNNEL_MAGIC);
    pkt.extend_from_slice(&(body.len() as u16).to_be_bytes());
    pkt.extend_from_slice(&body);
    tls_stream.write_app_data(&pkt).await?;

    debug!("Sent CDTunnel handshake request via TLS");

    let response_body = read_cdtunnel_response(&mut tls_stream).await?;

    let response: serde_json::Value = serde_json::from_slice(&response_body)
        .map_err(|e| IdeviceError::InternalError(e.to_string()))?;

    debug!("Received CDTunnel handshake response");

    let info = parse_tunnel_info(&response)?;

    debug!("CDTunnel established");

    Ok(CdTunnel {
        inner: tls_stream,
        info,
    })
}

/// Reads exactly one length-delimited CDTunnel response from a plaintext TLS
/// stream. `AsyncRead` buffering preserves any following tunnel bytes.
async fn read_cdtunnel_response<R: AsyncRead + Unpin>(
    stream: &mut R,
) -> Result<Vec<u8>, IdeviceError> {
    let mut header = [0; CDTUNNEL_MAGIC.len() + 2];
    stream.read_exact(&mut header).await?;
    if header[..CDTUNNEL_MAGIC.len()] != *CDTUNNEL_MAGIC {
        return Err(CdTunnelError::InvalidMagic.into());
    }
    let declared_length = u16::from_be_bytes([
        header[CDTUNNEL_MAGIC.len()],
        header[CDTUNNEL_MAGIC.len() + 1],
    ]) as usize;
    let mut body = vec![0; declared_length];
    stream.read_exact(&mut body).await?;
    Ok(body)
}

#[cfg(test)]
fn parse_cdtunnel_response_body(packet: &[u8]) -> Result<&[u8], IdeviceError> {
    let body_start = CDTUNNEL_MAGIC.len() + 2;
    if packet.len() < body_start {
        return Err(CdTunnelError::PacketTooShort.into());
    }
    if packet.get(..CDTUNNEL_MAGIC.len()) != Some(CDTUNNEL_MAGIC) {
        return Err(CdTunnelError::InvalidMagic.into());
    }
    let declared_length = u16::from_be_bytes([
        packet[CDTUNNEL_MAGIC.len()],
        packet[CDTUNNEL_MAGIC.len() + 1],
    ]) as usize;
    let body_end = body_start
        .checked_add(declared_length)
        .ok_or(CdTunnelError::SizeMismatch)?;
    if body_end != packet.len() {
        return Err(CdTunnelError::SizeMismatch.into());
    }
    packet
        .get(body_start..body_end)
        .ok_or_else(|| CdTunnelError::SizeMismatch.into())
}

#[cfg(test)]
mod tests {
    use tokio::io::{AsyncReadExt, AsyncWriteExt};

    use super::*;

    fn packet(declared_length: u16, body: &[u8]) -> Vec<u8> {
        let mut packet = CDTUNNEL_MAGIC.to_vec();
        packet.extend_from_slice(&declared_length.to_be_bytes());
        packet.extend_from_slice(body);
        packet
    }

    #[test]
    fn response_parser_accepts_only_an_exact_declared_body() {
        let packet = packet(4, b"test");

        assert_eq!(parse_cdtunnel_response_body(&packet).unwrap(), b"test");
    }

    #[test]
    fn response_parser_rejects_truncated_oversized_and_trailing_bodies() {
        for packet in [packet(4, b"ab"), packet(u16::MAX, b"ab"), packet(1, b"ab")] {
            let error = parse_cdtunnel_response_body(&packet).unwrap_err();
            assert!(matches!(
                error,
                IdeviceError::CdTunnel(CdTunnelError::SizeMismatch)
            ));
        }
    }

    #[test]
    fn hostile_declared_lengths_never_panic() {
        for declared in [0, 1, 2, 255, 256, 16_383, 16_384, u16::MAX] {
            for actual in [0, 1, 2, 255, 256, 4_096] {
                let body = vec![0xAA; actual];
                let packet = packet(declared, &body);

                let result = std::panic::catch_unwind(|| parse_cdtunnel_response_body(&packet));

                assert!(result.is_ok(), "declared={declared} actual={actual}");
                assert_eq!(result.unwrap().is_ok(), usize::from(declared) == actual);
            }
        }
    }

    #[test]
    fn response_parser_classifies_short_and_bad_magic_packets() {
        assert!(matches!(
            parse_cdtunnel_response_body(b"short").unwrap_err(),
            IdeviceError::CdTunnel(CdTunnelError::PacketTooShort)
        ));
        let mut bad_magic = packet(0, b"");
        bad_magic[0] ^= 1;
        assert!(matches!(
            parse_cdtunnel_response_body(&bad_magic).unwrap_err(),
            IdeviceError::CdTunnel(CdTunnelError::InvalidMagic)
        ));
    }

    #[tokio::test]
    async fn response_reader_reassembles_fragmented_tls_plaintext_without_losing_following_bytes() {
        let body = br#"{"clientParameters":{"address":"fd00::2","mtu":1500},"serverAddress":"fd00::1","serverRSDPort":58783}"#;
        let response = packet(body.len() as u16, body);
        let (mut writer, mut reader) = tokio::io::duplex(3);
        let writer_task = tokio::spawn(async move {
            for byte in response {
                writer.write_all(&[byte]).await.unwrap();
            }
            writer.write_all(b"next").await.unwrap();
        });

        assert_eq!(read_cdtunnel_response(&mut reader).await.unwrap(), body);
        let mut following = [0; 4];
        reader.read_exact(&mut following).await.unwrap();
        assert_eq!(&following, b"next");
        writer_task.await.unwrap();
    }

    #[test]
    fn tunnel_info_rejects_missing_zero_fractional_and_out_of_range_numbers() {
        let valid = serde_json::json!({
            "clientParameters": {"address": "fd00::2", "mtu": 1500},
            "serverAddress": "fd00::1",
            "serverRSDPort": 58783
        });
        assert_eq!(parse_tunnel_info(&valid).unwrap().mtu, 1500);

        for invalid in [
            serde_json::json!({
                "clientParameters": {"address": "fd00::2"},
                "serverAddress": "fd00::1",
                "serverRSDPort": 58783
            }),
            serde_json::json!({
                "clientParameters": {"address": "fd00::2", "mtu": 0},
                "serverAddress": "fd00::1",
                "serverRSDPort": 58783
            }),
            serde_json::json!({
                "clientParameters": {"address": "fd00::2", "mtu": 65536},
                "serverAddress": "fd00::1",
                "serverRSDPort": 58783
            }),
            serde_json::json!({
                "clientParameters": {"address": "fd00::2", "mtu": 1500.5},
                "serverAddress": "fd00::1",
                "serverRSDPort": 58783
            }),
            serde_json::json!({
                "clientParameters": {"address": "fd00::2", "mtu": 1500},
                "serverAddress": "fd00::1"
            }),
            serde_json::json!({
                "clientParameters": {"address": "fd00::2", "mtu": 1500},
                "serverAddress": "fd00::1",
                "serverRSDPort": 0
            }),
            serde_json::json!({
                "clientParameters": {"address": "fd00::2", "mtu": 1500},
                "serverAddress": "fd00::1",
                "serverRSDPort": 65536
            }),
        ] {
            assert!(parse_tunnel_info(&invalid).is_err(), "{invalid}");
        }
    }
}

/// Wraps a `tokio::net::TcpStream` with TLS-PSK using OpenSSL and performs
/// the CDTunnel handshake, returning a ready-to-use tunnel.
///
/// `encryption_key` is the key from `RemotePairingClient::encryption_key()`.
///
/// Requires the `openssl` feature. Consider using [`connect_tls_psk_tunnel_native`]
/// instead, which has no external dependency.
#[cfg(feature = "openssl")]
pub async fn connect_tls_psk_tunnel<S: ReadWrite>(
    stream: S,
    encryption_key: &[u8],
) -> Result<CdTunnel<tokio_openssl::SslStream<S>>, IdeviceError> {
    use openssl::ssl::{SslConnector, SslMethod, SslVerifyMode};

    let psk = encryption_key.to_vec();

    let mut builder = SslConnector::builder(SslMethod::tls_client())
        .map_err(|e| IdeviceError::InternalError(format!("SslConnector::builder: {e}")))?;

    builder.set_verify(SslVerifyMode::NONE);
    builder
        .set_cipher_list(
            "PSK-AES128-CBC-SHA:PSK-AES256-CBC-SHA:PSK-AES128-CBC-SHA256:PSK-AES256-CBC-SHA384",
        )
        .map_err(|e| IdeviceError::InternalError(format!("set_cipher_list: {e}")))?;
    builder.set_psk_client_callback(move |_ssl, _hint, identity, psk_out| {
        if !identity.is_empty() {
            identity[0] = 0;
        }
        let len = psk.len().min(psk_out.len());
        psk_out[..len].copy_from_slice(&psk[..len]);
        Ok(len)
    });

    builder
        .set_min_proto_version(Some(openssl::ssl::SslVersion::TLS1_2))
        .map_err(|e| IdeviceError::InternalError(e.to_string()))?;
    builder
        .set_max_proto_version(Some(openssl::ssl::SslVersion::TLS1_2))
        .map_err(|e| IdeviceError::InternalError(e.to_string()))?;

    let ssl_connector = builder.build();
    let mut conf = ssl_connector
        .configure()
        .map_err(|e| IdeviceError::InternalError(e.to_string()))?;
    conf.set_verify_hostname(false);
    conf.set_use_server_name_indication(false);
    let ssl = conf
        .into_ssl("localhost")
        .map_err(|e| IdeviceError::InternalError(e.to_string()))?;

    let mut tls_stream = tokio_openssl::SslStream::new(ssl, stream)
        .map_err(|e| IdeviceError::InternalError(e.to_string()))?;

    if let Err(e) = std::pin::Pin::new(&mut tls_stream).connect().await {
        let ssl_errors = openssl::error::ErrorStack::get();
        let msg = format!("TLS-PSK handshake failed: {e} (SSL errors: {ssl_errors:?})");
        tracing::error!("{msg}");
        return Err(IdeviceError::InternalError(msg));
    }

    debug!("TLS-PSK handshake complete");

    CdTunnel::handshake(tls_stream).await
}
