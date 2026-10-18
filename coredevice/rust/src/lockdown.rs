// SPDX-License-Identifier: GPL-3.0-only
//! Ordinary network Lockdown. No RemotePairing, Pair, key lookup or TLS fallback.
use crate::{CoreDeviceConnector, Purpose, Stream};
use plist::{Dictionary, Value};
use rustls::{
    ClientConfig, DigitallySignedStruct, SignatureScheme,
    client::danger::{HandshakeSignatureValid, ServerCertVerified, ServerCertVerifier},
    crypto::{ring, verify_tls12_signature, verify_tls13_signature},
    pki_types::{CertificateDer, PrivateKeyDer, ServerName, UnixTime, pem::PemObject},
};
use std::{io::Cursor, sync::Arc, time::Duration};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use zeroize::Zeroizing;
const LIMIT: usize = 64 * 1024;
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum Failure {
    Identity,
    Connect,
    StartSession,
    PeerRejected,
    SessionTls,
    StopSession,
    Closed,
}
/// Only the client identity and pinned DeviceCertificate are retained. A plist
/// containing RemotePairing keys cannot satisfy these ordinary Lockdown fields.
pub struct ExistingIdentity {
    host_id: String,
    system_buid: String,
    device_certificate: CertificateDer<'static>,
    host_certificate: CertificateDer<'static>,
    host_key: Zeroizing<Vec<u8>>,
}
fn identifier(s: &str) -> bool {
    !s.is_empty() && s.len() <= 256 && s.bytes().all(|b| (33..=126).contains(&b))
}
impl ExistingIdentity {
    /// Caller selects/authorizes the record; no filesystem or keychain lookup.
    pub fn from_plist(data: &[u8], expected_udid: &str) -> Result<Self, Failure> {
        if data.len() > 1024 * 1024 || !identifier(expected_udid) {
            return Err(Failure::Identity);
        }
        let value = Value::from_reader(Cursor::new(data)).map_err(|_| Failure::Identity)?;
        let d = value.as_dictionary().ok_or(Failure::Identity)?;
        if d.get("UDID")
            .is_some_and(|v| v.as_string() != Some(expected_udid))
        {
            return Err(Failure::Identity);
        }
        let text = |name: &str| -> Result<String, Failure> {
            let s = d
                .get(name)
                .and_then(Value::as_string)
                .ok_or(Failure::Identity)?;
            if !identifier(s) {
                return Err(Failure::Identity);
            }
            Ok(s.to_owned())
        };
        let data = |name: &str| -> Result<Vec<u8>, Failure> {
            let s = d
                .get(name)
                .and_then(Value::as_data)
                .ok_or(Failure::Identity)?;
            if s.is_empty() || s.len() > LIMIT {
                return Err(Failure::Identity);
            }
            Ok(s.to_vec())
        };
        let cert = |name: &str| -> Result<CertificateDer<'static>, Failure> {
            CertificateDer::from_pem_slice(&data(name)?).map_err(|_| Failure::Identity)
        };
        let id = Self {
            host_id: text("HostID")?,
            system_buid: text("SystemBUID")?,
            device_certificate: cert("DeviceCertificate")?,
            host_certificate: cert("HostCertificate")?,
            host_key: Zeroizing::new(data("HostPrivateKey")?),
        };
        id.tls_config()?; // Reject key/certificate mismatch before any socket opens.
        Ok(id)
    }
    fn tls_config(&self) -> Result<ClientConfig, Failure> {
        let provider = Arc::new(ring::default_provider());
        let mut config = ClientConfig::builder_with_provider(provider)
            .with_protocol_versions(&[&rustls::version::TLS12])
            .map_err(|_| Failure::Identity)?
            .dangerous()
            .with_custom_certificate_verifier(Arc::new(PinnedDevice(
                self.device_certificate.clone(),
            )))
            .with_client_auth_cert(
                vec![self.host_certificate.clone()],
                PrivateKeyDer::from_pem_slice(&self.host_key).map_err(|_| Failure::Identity)?,
            )
            .map_err(|_| Failure::Identity)?;
        config.enable_sni = false;
        Ok(config)
    }
}
/// Match the already trusted pairing certificate and verify proof of possession.
/// No hostname/CA assumptions about Apple's locally generated pairing identity.
#[derive(Debug)]
struct PinnedDevice(CertificateDer<'static>);
impl ServerCertVerifier for PinnedDevice {
    fn verify_server_cert(
        &self,
        cert: &CertificateDer<'_>,
        _: &[CertificateDer<'_>],
        _: &ServerName<'_>,
        _: &[u8],
        _: UnixTime,
    ) -> Result<ServerCertVerified, rustls::Error> {
        if cert.as_ref() != self.0.as_ref() {
            return Err(rustls::Error::InvalidCertificate(
                rustls::CertificateError::ApplicationVerificationFailure,
            ));
        }
        Ok(ServerCertVerified::assertion())
    }
    fn verify_tls12_signature(
        &self,
        message: &[u8],
        cert: &CertificateDer<'_>,
        signature: &DigitallySignedStruct,
    ) -> Result<HandshakeSignatureValid, rustls::Error> {
        verify_tls12_signature(
            message,
            cert,
            signature,
            &ring::default_provider().signature_verification_algorithms,
        )
    }
    fn verify_tls13_signature(
        &self,
        message: &[u8],
        cert: &CertificateDer<'_>,
        signature: &DigitallySignedStruct,
    ) -> Result<HandshakeSignatureValid, rustls::Error> {
        verify_tls13_signature(
            message,
            cert,
            signature,
            &ring::default_provider().signature_verification_algorithms,
        )
    }
    fn supported_verify_schemes(&self) -> Vec<SignatureScheme> {
        ring::default_provider()
            .signature_verification_algorithms
            .supported_schemes()
    }
}
async fn exchange(stream: &mut Stream, request: Dictionary) -> Result<Dictionary, ()> {
    let mut bytes = Vec::new();
    Value::Dictionary(request)
        .to_writer_xml(&mut bytes)
        .map_err(|_| ())?;
    if bytes.len() > LIMIT {
        return Err(());
    }
    stream.write_u32(bytes.len() as u32).await.map_err(|_| ())?;
    stream.write_all(&bytes).await.map_err(|_| ())?;
    stream.flush().await.map_err(|_| ())?;
    let len = stream.read_u32().await.map_err(|_| ())? as usize;
    if len == 0 || len > LIMIT {
        return Err(());
    }
    let mut reply = vec![0; len];
    stream.read_exact(&mut reply).await.map_err(|_| ())?;
    Value::from_reader(Cursor::new(reply))
        .map_err(|_| ())?
        .into_dictionary()
        .ok_or(())
}
fn request(name: &str) -> Dictionary {
    let mut d = Dictionary::new();
    d.insert("Request".into(), name.into());
    d.insert("Label".into(), "CoreDeviceBackend".into());
    d
}
fn session_id(d: &Dictionary) -> Result<String, Failure> {
    if d.contains_key("Error") {
        return Err(Failure::PeerRejected);
    }
    if d.get("Request").and_then(Value::as_string) != Some("StartSession")
        || d.get("EnableSessionSSL").and_then(Value::as_boolean) != Some(true)
    {
        return Err(Failure::StartSession);
    }
    let id = d
        .get("SessionID")
        .and_then(Value::as_string)
        .ok_or(Failure::StartSession)?;
    if !identifier(id) {
        return Err(Failure::StartSession);
    }
    Ok(id.into())
}
pub struct Session {
    stream: Option<Stream>,
    session_id: String,
}
impl Session {
    /// Fixed Lockdown purpose only. The session is ready only after mutual TLS
    /// finishes. A response or TCP ACK alone is never an authentication result.
    pub async fn connect(
        connector: &impl CoreDeviceConnector,
        identity: &ExistingIdentity,
    ) -> Result<Self, Failure> {
        let config = identity.tls_config()?;
        let mut stream = tokio::time::timeout(
            Duration::from_secs(4),
            connector.connect(Purpose::LockdownSession),
        )
        .await
        .map_err(|_| Failure::Connect)?
        .map_err(|_| Failure::Connect)?;
        let mut start = request("StartSession");
        start.insert("HostID".into(), identity.host_id.clone().into());
        start.insert("SystemBUID".into(), identity.system_buid.clone().into());
        let reply = tokio::time::timeout(Duration::from_secs(15), exchange(&mut stream, start))
            .await
            .map_err(|_| Failure::StartSession)?
            .map_err(|_| Failure::StartSession)?;
        let id = session_id(&reply)?;
        let tls = tokio::time::timeout(
            Duration::from_secs(15),
            tokio_rustls::TlsConnector::from(Arc::new(config)).connect(
                ServerName::try_from("Device").map_err(|_| Failure::Identity)?,
                stream,
            ),
        )
        .await
        .map_err(|_| Failure::SessionTls)?
        .map_err(|_| Failure::SessionTls)?;
        Ok(Self {
            stream: Some(Box::new(tls)),
            session_id: id,
        })
    }
    pub fn tls_ready(&self) -> bool {
        self.stream.is_some()
    }
    pub async fn stop(&mut self) -> Result<(), Failure> {
        // Taking ownership makes timeout/error terminal; no plaintext downgrade.
        let mut stream = self.stream.take().ok_or(Failure::Closed)?;
        let mut stop = request("StopSession");
        stop.insert("SessionID".into(), self.session_id.clone().into());
        let result = tokio::time::timeout(Duration::from_secs(5), exchange(&mut stream, stop))
            .await
            .map_err(|_| Failure::StopSession)?
            .map_err(|_| Failure::StopSession)?;
        if result.contains_key("Error")
            || result.get("Request").and_then(Value::as_string) != Some("StopSession")
        {
            return Err(Failure::StopSession);
        }
        Ok(())
    }
}

#[cfg(test)]
pub(crate) mod tests {
    use super::*;
    use crate::DialFuture;
    use std::sync::{
        Mutex,
        atomic::{AtomicUsize, Ordering},
    };
    use tokio::io::DuplexStream;
    const HOST: &[u8] = include_bytes!("../tests/fixtures/lockdown/test-host.pem");
    const HOST_KEY: &[u8] = include_bytes!("../tests/fixtures/lockdown/test-host-key.pem");
    const DEVICE: &[u8] = include_bytes!("../tests/fixtures/lockdown/test-device.pem");
    const DEVICE_KEY: &[u8] = include_bytes!("../tests/fixtures/lockdown/test-device-key.pem");
    const ROOT: &[u8] = include_bytes!("../tests/fixtures/lockdown/test-root.pem");
    struct Connector {
        socket: Mutex<Option<DuplexStream>>,
        calls: AtomicUsize,
    }
    impl CoreDeviceConnector for Connector {
        fn connect(&self, purpose: Purpose) -> DialFuture<'_> {
            assert_eq!(purpose, Purpose::LockdownSession);
            self.calls.fetch_add(1, Ordering::SeqCst);
            let stream = self.socket.lock().unwrap().take().unwrap();
            Box::pin(async move { Ok(Box::new(stream) as Stream) })
        }
    }
    fn pair_bytes() -> Vec<u8> {
        let mut d = Dictionary::new();
        for (k, v) in [
            ("HostID", "PUBLIC-TEST-HOST"),
            ("SystemBUID", "PUBLIC-TEST-BUID"),
            ("UDID", "PUBLIC-TEST-UDID"),
        ] {
            d.insert(k.into(), v.into());
        }
        for (k, v) in [
            ("DeviceCertificate", DEVICE),
            ("HostCertificate", HOST),
            ("HostPrivateKey", HOST_KEY),
        ] {
            d.insert(k.into(), Value::Data(v.into()));
        }
        let mut bytes = Vec::new();
        Value::Dictionary(d).to_writer_binary(&mut bytes).unwrap();
        bytes
    }
    pub(crate) fn identity() -> ExistingIdentity {
        ExistingIdentity::from_plist(&pair_bytes(), "PUBLIC-TEST-UDID").unwrap()
    }
    pub(crate) async fn read<S: tokio::io::AsyncRead + Unpin>(s: &mut S) -> Dictionary {
        let len = s.read_u32().await.unwrap() as usize;
        assert!(len <= LIMIT);
        let mut data = vec![0; len];
        s.read_exact(&mut data).await.unwrap();
        Value::from_reader(Cursor::new(data))
            .unwrap()
            .into_dictionary()
            .unwrap()
    }
    pub(crate) async fn write<S: tokio::io::AsyncWrite + Unpin>(s: &mut S, d: Dictionary) {
        let mut data = Vec::new();
        Value::Dictionary(d).to_writer_binary(&mut data).unwrap();
        s.write_u32(data.len() as u32).await.unwrap();
        s.write_all(&data).await.unwrap();
        s.flush().await.unwrap();
    }
    pub(crate) fn start_reply() -> Dictionary {
        let mut d = request("StartSession");
        d.insert("EnableSessionSSL".into(), true.into());
        d.insert("SessionID".into(), "PUBLIC-TEST-SESSION".into());
        d
    }
    pub(crate) fn acceptor(wrong_cert: bool) -> tokio_rustls::TlsAcceptor {
        let mut roots = rustls::RootCertStore::empty();
        roots
            .add(CertificateDer::from_pem_slice(ROOT).unwrap())
            .unwrap();
        let provider = Arc::new(ring::default_provider());
        let verifier = rustls::server::WebPkiClientVerifier::builder_with_provider(
            Arc::new(roots),
            provider.clone(),
        )
        .build()
        .unwrap();
        let config = rustls::ServerConfig::builder_with_provider(provider)
            .with_protocol_versions(&[&rustls::version::TLS12])
            .unwrap()
            .with_client_cert_verifier(verifier)
            .with_single_cert(
                vec![
                    CertificateDer::from_pem_slice(if wrong_cert { HOST } else { DEVICE }).unwrap(),
                ],
                PrivateKeyDer::from_pem_slice(if wrong_cert { HOST_KEY } else { DEVICE_KEY })
                    .unwrap(),
            )
            .unwrap();
        tokio_rustls::TlsAcceptor::from(Arc::new(config))
    }
    #[test]
    fn ordinary_record_rejects_peer_mismatch_and_rp_record() {
        assert!(ExistingIdentity::from_plist(&pair_bytes(), "ANOTHER-UDID").is_err());
        assert!(
            ExistingIdentity::from_plist(br#"{"identifier":"rp-only"}"#, "PUBLIC-TEST-UDID")
                .is_err()
        );
        assert!(
            ExistingIdentity::from_plist(&vec![0; 1024 * 1024 + 1], "PUBLIC-TEST-UDID").is_err()
        );
    }
    #[test]
    fn strict_start_session_response() {
        let good = start_reply();
        assert!(session_id(&good).is_ok());
        for key in ["SessionID", "EnableSessionSSL", "Request"] {
            let mut d = good.clone();
            d.remove(key);
            assert_eq!(session_id(&d), Err(Failure::StartSession));
        }
        let mut d = good.clone();
        d.insert("EnableSessionSSL".into(), false.into());
        assert_eq!(session_id(&d), Err(Failure::StartSession));
        d.insert("Error".into(), "InvalidHostID".into());
        assert_eq!(session_id(&d), Err(Failure::PeerRejected));
    }
    #[tokio::test]
    async fn mutual_tls_and_stop_session_on_same_stream() {
        let (a, mut b) = tokio::io::duplex(4096);
        let c = Connector {
            socket: Mutex::new(Some(a)),
            calls: AtomicUsize::new(0),
        };
        let server = tokio::spawn(async move {
            let start = read(&mut b).await;
            assert_eq!(
                start.get("Request").and_then(Value::as_string),
                Some("StartSession")
            );
            assert_eq!(
                start.get("HostID").and_then(Value::as_string),
                Some("PUBLIC-TEST-HOST")
            );
            assert_eq!(
                start.get("SystemBUID").and_then(Value::as_string),
                Some("PUBLIC-TEST-BUID")
            );
            assert!(!start.contains_key("PairRecord"));
            write(&mut b, start_reply()).await;
            let mut tls = acceptor(false).accept(b).await.unwrap();
            assert_eq!(tls.get_ref().1.peer_certificates().unwrap().len(), 1);
            let stop = read(&mut tls).await;
            assert_eq!(
                stop.get("Request").and_then(Value::as_string),
                Some("StopSession")
            );
            assert_eq!(
                stop.get("SessionID").and_then(Value::as_string),
                Some("PUBLIC-TEST-SESSION")
            );
            write(&mut tls, request("StopSession")).await;
        });
        let mut session = Session::connect(&c, &identity()).await.unwrap();
        assert!(session.tls_ready());
        session.stop().await.unwrap();
        assert!(!session.tls_ready());
        assert_eq!(session.stop().await, Err(Failure::Closed));
        assert_eq!(c.calls.load(Ordering::SeqCst), 1);
        server.await.unwrap();
    }
    #[tokio::test]
    async fn mismatched_device_certificate_is_terminal() {
        let (a, mut b) = tokio::io::duplex(4096);
        let c = Connector {
            socket: Mutex::new(Some(a)),
            calls: AtomicUsize::new(0),
        };
        let server = tokio::spawn(async move {
            read(&mut b).await;
            write(&mut b, start_reply()).await;
            assert!(acceptor(true).accept(b).await.is_err());
        });
        assert!(matches!(
            Session::connect(&c, &identity()).await,
            Err(Failure::SessionTls)
        ));
        assert_eq!(c.calls.load(Ordering::SeqCst), 1);
        server.await.unwrap();
    }
    #[tokio::test]
    async fn rejected_session_never_sends_tls_or_pair() {
        let (a, mut b) = tokio::io::duplex(4096);
        let c = Connector {
            socket: Mutex::new(Some(a)),
            calls: AtomicUsize::new(0),
        };
        let server = tokio::spawn(async move {
            read(&mut b).await;
            let mut d = request("StartSession");
            d.insert("Error".into(), "InvalidHostID".into());
            write(&mut b, d).await;
            assert_eq!(
                b.read_u8().await.unwrap_err().kind(),
                std::io::ErrorKind::UnexpectedEof
            );
        });
        assert!(matches!(
            Session::connect(&c, &identity()).await,
            Err(Failure::PeerRejected)
        ));
        assert_eq!(c.calls.load(Ordering::SeqCst), 1);
        server.await.unwrap();
    }
}
