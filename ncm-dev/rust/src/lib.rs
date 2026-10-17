// SPDX-License-Identifier: GPL-3.0-only
//! Real protocol backend for an iOS-hosted controller. All device I/O must be
//! provided by an NCM/S3 or VPN loopback connector; this backend does not discover a Mac tunnel or
//! read/write a pairing file. Nothing runs just by linking this static library.
mod ffi;
mod media;
mod relay;
mod local_vpn;
mod video;
pub use relay::RelayConnector;
pub mod lockdown;
mod png;
mod transport;
pub use idevice::remote_pairing::{RpPairingFile, VerifiedPeerIdentity};
use idevice::{
    RemoteXpcClient, RsdService,
    core_device::{
        AppServiceClient, ButtonState, HardwareButton, HidError, ImageFormat, IndigoHidClient,
        KeyboardServiceConfiguration, KeyboardUsage, PasteboardServiceClient,
        ScreenCaptureServiceClient, UniversalHidServiceClient,
    },
    remote_pairing::{RemotePairingClient, RpPairingSocket, connect_tls_psk_tunnel_native},
    rsd::RsdHandshake,
    services::mobile_image_mounter::ImageMounter,
    tcp::{
        adapter::Adapter,
        handle::{AdapterHandle, StreamHandle},
    },
};
use std::{future::Future, net::Ipv6Addr, time::Duration};
pub use transport::{DialFuture, NcmConnector, Purpose, Stream};
use transport::{Gated, OperationGuard, Owner};

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
#[repr(u32)]
pub enum Stage {
    Identity,
    NcmConnect,
    PairVerify,
    TunnelListener,
    TlsTunnel,
    Rsd,
    DeveloperMode,
    DeveloperImage,
    Screenshot,
    Media,
    Input,
    Closed,
    VideoReceiver,
    VideoService,
    VideoNegotiation,
    VideoAnswer,
    VideoPackets,
    TouchService,
    ScreenshotConnection,
    ScreenshotResponse,
    Applications,
}
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
#[repr(u32)]
pub enum Cause {
    Protocol,
    Timeout,
    InvalidParameters,
    MissingService,
    Unprepared,
    MediaInactive,
    DeliveryUncertain,
}
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct Error {
    pub stage: Stage,
    pub cause: Cause,
}
impl std::fmt::Display for Error {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{:?}/{:?}", self.stage, self.cause)
    }
}
impl std::error::Error for Error {}
pub(crate) fn valid_input_text(text: &str) -> bool {
    !text.is_empty() && text.len() <= 8192 && !text.contains('\0')
}
fn error(stage: Stage, cause: Cause) -> Error {
    Error { stage, cause }
}
async fn bounded<T, E>(stage: Stage, f: impl Future<Output = Result<T, E>>) -> Result<T, Error> {
    bounded_for(stage, Duration::from_secs(15), f).await
}
async fn bounded_for<T, E>(
    stage: Stage,
    deadline: Duration,
    f: impl Future<Output = Result<T, E>>,
) -> Result<T, Error> {
    tokio::time::timeout(deadline, f)
        .await
        .map_err(|_| error(stage, Cause::Timeout))?
        .map_err(|_| error(stage, Cause::Protocol))
}
/// Only already-authorized, in-memory RemotePairing identities. Caller retains
/// original identifier/keys/peer binding. There is no Pair Setup or persistence.
pub struct ExistingIdentity {
    pub controller: RpPairingFile,
    pub peer: VerifiedPeerIdentity,
}
impl ExistingIdentity {
    fn validate(&self) -> Result<(), Error> {
        if self.controller.identifier.is_empty()
            || self.controller.identifier.len() > 256
            || self.controller.e_private_key.verifying_key() != self.controller.e_public_key
            || self.peer.pairing_identifier.is_empty()
            || self.peer.peer.remotepairing_udid.is_empty()
            || self.peer.peer.model.is_empty()
            || self.peer.peer.alt_irk.len() != 16
            || self.controller.alt_irk.as_deref() != Some(self.peer.peer.alt_irk.as_slice())
        {
            return Err(error(Stage::Identity, Cause::InvalidParameters));
        }
        Ok(())
    }
}
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct Service {
    pub name: String,
    pub port: u16,
    pub remote_xpc: bool,
}
pub struct Screenshot {
    pub png: Vec<u8>,
    pub width: u32,
    pub height: u32,
}
/// Transport evidence, explicitly not evidence of visible UIKit effects.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum TouchDelivery {
    ReportsWrittenVisualEffectUnverified,
}
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum CloseReport {
    OwnedTransportRevokedRemoteMediaStopUnconfirmed,
}

pub struct Session {
    owner: Owner,
    _control: Option<RemotePairingClient<RpPairingSocket<Gated>>>,
    adapter: AdapterHandle,
    handshake: RsdHandshake,
    _rsd_control: Option<RemoteXpcClient<StreamHandle>>,
    prepared: bool,
    media: Option<media::Media>,
    indigo: Option<IndigoHidClient<Box<dyn idevice::ReadWrite>>>,
    video: std::sync::Arc<video::VideoMailbox>,
    valid: bool,
}
/// Fixed recovery stages; durations are measured in the worker's monotonic
/// clock. Bounded to the eight connection steps, with no protocol payloads.
pub(crate) struct ConnectTiming {
    pub stage: u32,
    pub elapsed_ns: u64,
    pub failed: bool,
}
// Expand around the existing await instead of nesting another Future: native
// worker stacks must not grow just to measure the large protocol state machine.
macro_rules! timed_connect {
    ($timings:expr, $stage:expr, $work:expr) => {{
        let began = std::time::Instant::now();
        let result = $work.await;
        $timings.push(ConnectTiming { stage: $stage, elapsed_ns: began.elapsed().as_nanos().min(u64::MAX as u128) as u64, failed: result.is_err() });
        result
    }};
}

impl Session {
    /// No fallback: a rejected verify never triggers Pair Setup, lockdown record
    /// lookup, native TCP, QUIC, VPN configuration or any Mac service.
    pub async fn connect(
        connector: &impl NcmConnector,
        identity: &mut ExistingIdentity,
    ) -> Result<Self, Error> {
        Self::connect_timed(connector, identity, &mut Vec::new()).await
    }
    pub(crate) async fn connect_timed(
        connector: &impl NcmConnector,
        identity: &mut ExistingIdentity,
        timings: &mut Vec<ConnectTiming>,
    ) -> Result<Self, Error> {
        identity.validate()?;
        let owner = Owner::default();
        let stream = timed_connect!(timings, 1, bounded(Stage::NcmConnect, connector.connect(Purpose::PairVerify)))?;
        let mut control = RemotePairingClient::new(
            RpPairingSocket::new(Gated::new(stream, owner.0.clone())),
            &identity.controller.identifier,
        );
        timed_connect!(timings, 2, bounded(Stage::PairVerify, control.attempt_pair_verify()))?;
        timed_connect!(timings, 3, bounded(
            Stage::PairVerify,
            control.validate_pairing(&mut identity.controller, &identity.peer),
        ))?;
        let port = timed_connect!(timings, 4, bounded(Stage::TunnelListener, control.create_tcp_listener()))?;
        if port == 0 {
            return Err(error(Stage::TunnelListener, Cause::InvalidParameters));
        }
        let stream = timed_connect!(timings, 5, bounded(
            Stage::NcmConnect,
            connector.connect(Purpose::NegotiatedTunnel { port }),
        ))?;
        let tunnel = timed_connect!(timings, 6, bounded(
            Stage::TlsTunnel,
            connect_tls_psk_tunnel_native(
                Gated::new(stream, owner.0.clone()),
                control.encryption_key(),
            ),
        ))?;
        let (client, server, rsd_port, mss) = tunnel_parameters(&tunnel.info)?;
        let mut raw = Adapter::new(Box::new(tunnel.into_inner()), client.into(), server.into());
        raw.set_mss(mss);
        let mut adapter = raw.to_async_handle();
        let rsd_stream = timed_connect!(timings, 7, bounded(Stage::Rsd, adapter.connect(rsd_port)))?;
        let (handshake, rsd_control) =
            timed_connect!(timings, 8, bounded(Stage::Rsd, RsdHandshake::new_retained(rsd_stream)))?;
        verify_rsd_identity(&handshake, &identity.peer)?;
        Ok(Self {
            owner,
            _control: Some(control),
            adapter,
            handshake,
            _rsd_control: Some(rsd_control),
            prepared: false,
            media: None,
            indigo: None,
            video: std::sync::Arc::new(video::VideoMailbox::default()),
            valid: true,
        })
    }
    fn check(&self) -> Result<(), Error> {
        if self.valid && !self.owner.0.is_closed() {
            Ok(())
        } else {
            Err(error(Stage::Closed, Cause::Unprepared))
        }
    }
    pub fn services(&self) -> Result<Vec<Service>, Error> {
        self.check()?;
        let mut services: Vec<_> = self
            .handshake
            .services
            .iter()
            .map(|(n, s)| Service {
                name: n.clone(),
                port: s.port,
                remote_xpc: s.uses_remote_xpc,
            })
            .collect();
        services.sort_by(|a, b| a.name.cmp(&b.name));
        Ok(services)
    }
    /// Read-only checks, never download/personalize/mount a DDI or toggle mode.
    pub async fn check_developer_readiness(&mut self) -> Result<(), Error> {
        self.check()?;
        self.prepared = false;
        let mut mounter = bounded(
            Stage::DeveloperImage,
            ImageMounter::connect_rsd(&mut self.adapter, &mut self.handshake),
        )
        .await?;
        if !bounded(Stage::DeveloperMode, mounter.query_developer_mode_status()).await? {
            return Err(error(Stage::DeveloperMode, Cause::Unprepared));
        }
        if !bounded(
            Stage::DeveloperImage,
            mounter.image_is_present("Personalized"),
        )
        .await?
        {
            return Err(error(Stage::DeveloperImage, Cause::Unprepared));
        }
        self.prepared = true;
        Ok(())
    }
    fn require(&self, name: &str, stage: Stage) -> Result<(), Error> {
        self.check()?;
        if !self.prepared {
            return Err(error(stage, Cause::Unprepared));
        }
        if self
            .handshake
            .services
            .get(name)
            .is_none_or(|s| s.port == 0 || !s.uses_remote_xpc)
        {
            return Err(error(stage, Cause::MissingService));
        }
        Ok(())
    }
    /// Actual CoreDevice request. Nothing is logged/saved/uploaded; bytes belong
    /// solely to caller. Caller must obtain screen-access consent before calling.
    pub async fn screenshot(&mut self) -> Result<Screenshot, Error> {
        self.require(
            "com.apple.coredevice.screencaptureservice",
            Stage::Screenshot,
        )?;
        let mut client = bounded(
            Stage::ScreenshotConnection,
            ScreenCaptureServiceClient::connect_rsd(&mut self.adapter, &mut self.handshake),
        )
        .await?;
        // A full-screen PNG can be several MiB. The ESP32 relay and background
        // TCP scheduling need a transfer budget distinct from small handshakes.
        // This remains one read-only request, never a retry of an input action.
        let png = bounded_for(
            Stage::ScreenshotResponse,
            Duration::from_secs(90),
            client.take_screenshot(None, ImageFormat::Png),
        )
        .await?;
        let dimensions =
            png::validate_png(&png).map_err(|_| error(Stage::Screenshot, Cause::Protocol))?;
        Ok(Screenshot {
            png,
            width: dimensions.width,
            height: dimensions.height,
        })
    }
    pub async fn input_display_geometry(&mut self) -> Result<Vec<u8>, Error> {
        self.check()?;
        let size = media::query_display_geometry(&mut self.adapter, &mut self.handshake).await;
        self.video.set_visible_size(size.as_ref().ok().copied());
        // A failed read-only query can retain this session, but a transport
        // closure during that query must still be reported as Closed.
        self.check()?;
        let (width, height) = size?;
        serde_json::to_vec(&serde_json::json!({"width": width, "height": height}))
            .map_err(|_| error(Stage::Input, Cause::Protocol))
    }
    /// Starts real DisplayService video negotiation and drains packets in
    /// the owned tunnel. No HEVC decode. Explicit media consent is a caller duty.
    /// Preparation sends no touch reports. Its scoped streams/drains are dropped
    /// on error/cancellation; the authenticated tunnel and screenshot path survive.
    pub async fn start_touch_media(&mut self) -> Result<(), Error> {
        self.require("com.apple.coredevice.displayservice", Stage::Media)?;
        self.require("com.apple.coredevice.hid.universalhidservice", Stage::Input)?;
        if self.media.is_some() {
            return Err(error(Stage::Media, Cause::InvalidParameters));
        }
        self.media = Some(
            media::Media::start(&mut self.adapter, &mut self.handshake, self.video.clone()).await?,
        );
        Ok(())
    }
    /// Release only this controller's media/HID streams and decoder bytes.
    /// No global stopAll; retained authentication can serve the next task.
    pub async fn stop_touch_media(&mut self) -> Result<(), Error> {
        self.check()?;
        let result = if let Some(media) = self.media.take() {
            media.stop(&mut self.adapter, &mut self.handshake).await
        } else { Ok(()) };
        self.indigo.take();
        self.video.reset();
        result
    }
    /// No replay on timeout/uncertain release. A negotiated screen session must belong to
    /// this same authenticated generation; result never claims a visible tap.
    pub async fn tap(&mut self, x: u16, y: u16) -> Result<TouchDelivery, Error> {
        self.tap_guarded(x, y, None).await
    }
    async fn tap_guarded(&mut self, x: u16, y: u16, geometry: Option<u64>) -> Result<TouchDelivery, Error> {
        self.check()?;
        let media = self
            .media
            .as_mut()
            .ok_or(error(Stage::Input, Cause::MediaInactive))?;
        let mut guard = OperationGuard(Some(self.owner.0.clone()));
        match media.tap(x, y, geometry.map(|g| (&*self.video, g))).await {
            Ok(()) => {
                guard.0 = None;
                Ok(TouchDelivery::ReportsWrittenVisualEffectUnverified)
            }
            Err(e) => {
                self.invalidate();
                Err(e)
            }
        }
    }
    pub async fn drag(
        &mut self,
        x: u16,
        y: u16,
        end_x: u16,
        end_y: u16,
        duration: u16,
    ) -> Result<TouchDelivery, Error> {
        self.drag_guarded(x, y, end_x, end_y, duration, None).await
    }
    async fn drag_guarded(&mut self, x: u16, y: u16, end_x: u16, end_y: u16,
        duration: u16, geometry: Option<u64>) -> Result<TouchDelivery, Error> {
        self.check()?;
        if !(100..=2000).contains(&duration) {
            return Err(error(Stage::Input, Cause::InvalidParameters));
        }
        let media = self
            .media
            .as_mut()
            .ok_or(error(Stage::Input, Cause::MediaInactive))?;
        let mut guard = OperationGuard(Some(self.owner.0.clone()));
        match media.drag(x, y, end_x, end_y, duration, geometry.map(|g| (&*self.video, g))).await {
            Ok(()) => {
                guard.0 = None;
                Ok(TouchDelivery::ReportsWrittenVisualEffectUnverified)
            }
            Err(e) => {
                self.invalidate();
                Err(e)
            }
        }
    }
    pub async fn list_apps(&mut self) -> Result<Vec<u8>, Error> {
        self.require("com.apple.coredevice.appservice", Stage::Applications)?;
        let mut client = bounded(
            Stage::Applications,
            AppServiceClient::connect_rsd(&mut self.adapter, &mut self.handshake),
        )
        .await?;
        let streaming = self
            .handshake
            .services
            .get("com.apple.coredevice.appservice")
            .and_then(|s| s.features.as_ref())
            .is_some_and(|f| {
                f.iter()
                    .any(|name| name == "com.apple.coredevice.feature.streamapplist")
            });
        let apps = bounded(
            Stage::Applications,
            client.list_apps_mode(false, true, false, false, true, streaming),
        )
        .await?;
        let rows: Vec<_> = apps.into_iter().map(|a| serde_json::json!({"name": a.name, "bundle_id": a.bundle_identifier, "version": a.version})).collect();
        serde_json::to_vec(&rows).map_err(|_| error(Stage::Applications, Cause::Protocol))
    }
    pub async fn launch_app(&mut self, bundle: &str, arguments: &[String]) -> Result<(), Error> {
        self.require("com.apple.coredevice.appservice", Stage::Applications)?;
        let mut client = bounded(
            Stage::Applications,
            AppServiceClient::connect_rsd(&mut self.adapter, &mut self.handshake),
        )
        .await?;
        let args: Vec<&str> = arguments.iter().map(String::as_str).collect();
        let mut guard = OperationGuard(Some(self.owner.0.clone()));
        // Never terminate an existing app just to apply launch arguments.
        bounded(
            Stage::Applications,
            client.launch_application(bundle, &args, false, false, None, None, None),
        )
        .await
        .map_err(|_| error(Stage::Applications, Cause::DeliveryUncertain))?;
        guard.0 = None;
        Ok(())
    }
    pub async fn home(&mut self) -> Result<(), Error> {
        self.require("com.apple.coredevice.hid.indigo", Stage::Input)?;
        if self.media.is_none() {
            return Err(error(Stage::Input, Cause::MediaInactive));
        }
        if self.indigo.is_none() {
            self.indigo = Some(
                bounded(
                    Stage::Input,
                    IndigoHidClient::connect_rsd(&mut self.adapter, &mut self.handshake),
                )
                .await?,
            );
        }
        let client = self.indigo.as_mut().unwrap();
        let mut guard = OperationGuard(Some(self.owner.0.clone()));
        bounded(Stage::Input, async {
            client
                .send_hardware_button(HardwareButton::Home, ButtonState::Down)
                .await?;
            tokio::time::sleep(Duration::from_millis(100)).await;
            client
                .send_hardware_button(HardwareButton::Home, ButtonState::Up)
                .await
        })
        .await
        .map_err(|_| error(Stage::Input, Cause::DeliveryUncertain))?;
        guard.0 = None;
        Ok(())
    }
    pub async fn type_text(&mut self, text: &str) -> Result<(), Error> {
        // Paste the complete Unicode string through a registered keyboard so iOS
        // can attach key-command authentication to the receiving app's read.
        if !valid_input_text(text) {
            return Err(error(Stage::Input, Cause::InvalidParameters));
        }
        if self.media.is_none() {
            return Err(error(Stage::Input, Cause::MediaInactive));
        }
        self.require("com.apple.coredevice.pasteboardservice", Stage::Input)?;
        self.require("com.apple.coredevice.hid.universalhidservice", Stage::Input)?;
        let mut pasteboard = bounded(
            Stage::Input,
            PasteboardServiceClient::connect_rsd(&mut self.adapter, &mut self.handshake),
        )
        .await?;
        // Keep the keyboard connection local: retaining it in Session would keep
        // the software keyboard suppressed after this operation finishes.
        let mut keyboard = bounded(
            Stage::Input,
            UniversalHidServiceClient::connect_rsd(&mut self.adapter, &mut self.handshake),
        )
        .await?;
        let config = KeyboardServiceConfiguration {
            service_id: (1u64 << 32) | u64::from(uuid::Uuid::new_v4().as_u128() as u32),
            product: "Actell keyboard".into(),
            manufacturer: "Actell".into(),
            ..Default::default()
        };
        // Cancellation or an uncertain result still revokes this transport
        // generation. Never read the previous clipboard or replay the paste.
        let mut guard = OperationGuard(Some(self.owner.0.clone()));
        let result = bounded(Stage::Input, async {
            let command = KeyboardUsage::new(0xe3)?;
            let v = KeyboardUsage::new(0x19)?;
            let service_id = keyboard.create_keyboard_service(&config).await?;
            // Preserve the delays from the successful independent-device probe
            // until the normal app path has been accepted on hardware.
            tokio::time::sleep(Duration::from_millis(400)).await;
            pasteboard.set_text(text, "general").await?;
            for held in [vec![command], vec![command, v], vec![command], vec![]] {
                keyboard
                    .set_keyboard_usages(service_id, held.into_iter().collect(), None)
                    .await?;
                tokio::time::sleep(Duration::from_millis(80)).await;
            }
            tokio::time::sleep(Duration::from_millis(1200)).await;
            Ok::<(), HidError>(())
        })
        .await;
        // StreamHandle::drop requests closure of just this HID connection.
        // A cancelled future also drops it; no global stopAll is sent.
        drop(keyboard);
        result.map_err(|_| error(Stage::Input, Cause::DeliveryUncertain))?;
        guard.0 = None;
        Ok(())
    }
    fn invalidate(&mut self) {
        self.valid = false;
        self.prepared = false;
        self.media.take();
        self.indigo.take();
        self.owner.0.close();
        self._rsd_control.take();
        self._control.take();
    }
    /// No stopAll: that could affect another controller. Remote media teardown
    /// after owned-tunnel close is UNVERIFIED and must be checked on hardware.
    pub async fn close(mut self) -> CloseReport {
        self.invalidate();
        let _ = self.adapter.close().await;
        CloseReport::OwnedTransportRevokedRemoteMediaStopUnconfirmed
    }
}
impl Drop for Session {
    fn drop(&mut self) {
        self.invalidate();
    }
}
fn tunnel_parameters(
    info: &idevice::tunnel::TunnelInfo,
) -> Result<(Ipv6Addr, Ipv6Addr, u16, usize), Error> {
    let fail = || error(Stage::TlsTunnel, Cause::InvalidParameters);
    let client: Ipv6Addr = info.client_address.parse().map_err(|_| fail())?;
    let server: Ipv6Addr = info.server_address.parse().map_err(|_| fail())?;
    if [client, server].iter().any(|a| {
        a.is_unspecified() || a.is_loopback() || a.is_multicast() || a.to_ipv4_mapped().is_some()
    }) || client == server
        || info.mtu < 1280
        || info.server_rsd_port == 0
    {
        return Err(fail());
    }
    Ok((
        client,
        server,
        info.server_rsd_port,
        usize::from(info.mtu) - 60,
    ))
}
fn verify_rsd_identity(h: &RsdHandshake, peer: &VerifiedPeerIdentity) -> Result<(), Error> {
    if h.protocol_version == 0
        || h.properties
            .get("UniqueDeviceID")
            .and_then(plist::Value::as_string)
            != Some(peer.peer.remotepairing_udid.as_str())
        || h.properties
            .get("ProductType")
            .and_then(plist::Value::as_string)
            != Some(peer.peer.model.as_str())
    {
        return Err(error(Stage::Rsd, Cause::InvalidParameters));
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::{
        Mutex,
        atomic::{AtomicUsize, Ordering},
    };
    use tokio::io::{AsyncReadExt, AsyncWriteExt, DuplexStream};
    fn fixture_identity() -> ExistingIdentity {
        // Public deterministic test-only seeds. Never persisted or used with a device.
        let key = ed25519_dalek::SigningKey::from_bytes(&[0x42; 32]);
        ExistingIdentity {
            controller: RpPairingFile {
                e_public_key: key.verifying_key(),
                e_private_key: key,
                identifier: "SYNTHETIC-CONTROLLER".into(),
                alt_irk: Some(vec![0x33; 16]),
            },
            peer: VerifiedPeerIdentity {
                pairing_identifier: "SYNTHETIC-PEER".into(),
                long_term_public_key: ed25519_dalek::SigningKey::from_bytes(&[0x44; 32])
                    .verifying_key()
                    .to_bytes(),
                peer: idevice::remote_pairing::PeerDevice {
                    account_id: "SYNTHETIC-PEER".into(),
                    alt_irk: vec![0x33; 16],
                    model: "iPhone-SYNTHETIC".into(),
                    name: "test".into(),
                    remotepairing_udid: "SYNTHETIC-UDID".into(),
                },
            },
        }
    }
    struct Connector {
        stream: Mutex<Option<DuplexStream>>,
        calls: AtomicUsize,
    }
    impl NcmConnector for Connector {
        fn connect(&self, purpose: Purpose) -> DialFuture<'_> {
            self.calls.fetch_add(1, Ordering::SeqCst);
            assert_eq!(
                purpose,
                Purpose::PairVerify,
                "failure must not dial a tunnel/fallback"
            );
            Box::pin(async move {
                Ok(Box::new(self.stream.lock().unwrap().take().expect("no retry")) as Stream)
            })
        }
    }
    async fn read_frame(peer: &mut DuplexStream) -> String {
        let mut magic = [0; 9];
        peer.read_exact(&mut magic).await.unwrap();
        assert_eq!(&magic, b"RPPairing");
        let size = peer.read_u16().await.unwrap();
        let mut b = vec![0; size as usize];
        peer.read_exact(&mut b).await.unwrap();
        String::from_utf8(b).unwrap()
    }
    #[tokio::test]
    async fn real_verify_m1_rejection_closes_without_pair_setup_or_tunnel() {
        let (stream, mut peer) = tokio::io::duplex(8192);
        let connector = Connector {
            stream: Mutex::new(Some(stream)),
            calls: AtomicUsize::new(0),
        };
        let mock = tokio::spawn(async move {
            let greeting = read_frame(&mut peer).await;
            assert!(greeting.contains("attemptPairVerify"));
            assert!(!greeting.contains("pairingData"));
            let body=br#"{"originatedBy":"device","sequenceNumber":0,"message":{"plain":{"_0":{"response":{"_1":{"handshake":{"_0":{"wireProtocolVersion":19}}}}}}}}"#;
            peer.write_all(b"RPPairing").await.unwrap();
            peer.write_u16(body.len() as u16).await.unwrap();
            peer.write_all(body).await.unwrap();
            let m1 = read_frame(&mut peer).await;
            assert!(m1.contains("verifyManualPairing"));
            assert!(m1.contains("startNewSession"));
            assert!(!m1.contains("setupManualPairing"));
            // Adversarial peer sends a truncated second envelope, not fake success.
            peer.write_all(b"BAD").await.unwrap();
            peer.shutdown().await.unwrap();
            let mut rest = Vec::new();
            peer.read_to_end(&mut rest).await.unwrap();
            assert!(rest.is_empty());
        });
        let mut timings = Vec::new();
        let result = Session::connect_timed(&connector, &mut fixture_identity(), &mut timings).await;
        assert_eq!(timings.iter().map(|t| t.stage).collect::<Vec<_>>(), vec![1, 2, 3]);
        assert!(!timings[0].failed);
        assert!(timings.last().unwrap().failed);
        assert!(matches!(
            result,
            Err(Error {
                stage: Stage::PairVerify,
                ..
            })
        ));
        mock.await.unwrap();
        assert_eq!(connector.calls.load(Ordering::SeqCst), 1);
    }
    #[tokio::test]
    async fn invalid_identity_never_dials() {
        let connector = Connector {
            stream: Mutex::new(None),
            calls: AtomicUsize::new(0),
        };
        let mut id = fixture_identity();
        id.controller.alt_irk = None;
        assert!(matches!(
            Session::connect(&connector, &mut id).await,
            Err(Error {
                stage: Stage::Identity,
                ..
            })
        ));
        assert_eq!(connector.calls.load(Ordering::SeqCst), 0);
    }
    #[tokio::test]
    async fn failed_video_preparation_does_not_revoke_screenshot_generation() {
        let (stream, peer) = tokio::io::duplex(1024);
        drop(peer); // synthetic broken video transport, no device connection
        let adapter = Adapter::new(
            Box::new(stream),
            "fdab::1".parse().unwrap(),
            "fdab::2".parse().unwrap(),
        )
        .to_async_handle();
        let services = [
            "com.apple.coredevice.displayservice",
            "com.apple.coredevice.hid.universalhidservice",
            "com.apple.coredevice.screencaptureservice",
        ]
        .into_iter()
        .map(|name| {
            (
                name.to_owned(),
                idevice::rsd::RsdService {
                    entitlement: String::new(),
                    port: 1234,
                    uses_remote_xpc: true,
                    features: None,
                    service_version: None,
                },
            )
        })
        .collect();
        let mut session = Session {
            owner: Owner::default(),
            _control: None,
            adapter,
            handshake: RsdHandshake {
                services,
                protocol_version: 1,
                properties: Default::default(),
                uuid: String::new(),
            },
            _rsd_control: None,
            prepared: true,
            media: None,
            indigo: None,
            video: std::sync::Arc::new(video::VideoMailbox::default()),
            valid: true,
        };
        let result =
            tokio::time::timeout(Duration::from_secs(2), session.start_touch_media()).await;
        assert!(!matches!(result, Ok(Ok(()))));
        assert!(session.stop_touch_media().await.is_ok());
        assert!(
            session.stop_touch_media().await.is_ok(),
            "owned media release is idempotent"
        );
        assert!(session.media.is_none());
        assert!(session.prepared);
        assert!(
            session.check().is_ok(),
            "preparation must not close the owned generation"
        );
        assert!(
            session
                .require(
                    "com.apple.coredevice.screencaptureservice",
                    Stage::Screenshot
                )
                .is_ok()
        );
    }

    #[test]
    fn tunnel_uses_negotiated_ipv6_and_port_only() {
        let mut info = idevice::tunnel::TunnelInfo {
            client_address: "fdab::9".into(),
            server_address: "fdab::8".into(),
            netmask: String::new(),
            mtu: 1280,
            server_rsd_port: 43210,
        };
        let (_, _, port, mss) = tunnel_parameters(&info).unwrap();
        assert_eq!((port, mss), (43210, 1220));
        info.server_rsd_port = 0;
        assert!(tunnel_parameters(&info).is_err());
        info.server_rsd_port = 43210;
        for ip in [
            "192.168.7.2",
            "::ffff:192.168.7.2",
            "::1",
            "::",
            "ff02::fb",
            "fdab::9",
        ] {
            info.server_address = ip.into();
            assert!(tunnel_parameters(&info).is_err());
        }
    }
    #[test]
    fn rsd_metadata_must_match_verified_peer() {
        let id = fixture_identity();
        let mut h = RsdHandshake {
            services: Default::default(),
            properties: Default::default(),
            protocol_version: 1,
            uuid: String::new(),
        };
        assert!(verify_rsd_identity(&h, &id.peer).is_err());
        h.properties.insert(
            "UniqueDeviceID".into(),
            plist::Value::String(id.peer.peer.remotepairing_udid.clone()),
        );
        h.properties.insert(
            "ProductType".into(),
            plist::Value::String(id.peer.peer.model.clone()),
        );
        assert!(verify_rsd_identity(&h, &id.peer).is_ok());
        h.protocol_version = 0;
        assert!(verify_rsd_identity(&h, &id.peer).is_err());
    }
    #[test]
    fn canceled_operation_invalidates_transport_generation() {
        let owner = Owner::default();
        drop(OperationGuard(Some(owner.0.clone())));
        assert!(owner.0.is_closed());
    }
}
