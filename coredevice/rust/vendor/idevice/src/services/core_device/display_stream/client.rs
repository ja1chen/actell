//! com.apple.coredevice.displayservice - the service Xcode's DeviceHub uses to
//! stream a device's display.
//!
//! Control plane (support info / server status / start / stop) is plain
//! RemoteXPC. The media is negotiated as an AVConference session: we send a
//! `negotiatorOffer`, the device answers, and then streams
//! plaintext RTP/HEVC to the receiver address we provide.

use crate::{
    IdeviceError, ReadWrite, obf,
    xpc::{Dictionary as XpcDictionary, XPCObject},
};

#[cfg(feature = "rsd")]
impl crate::RsdService for DisplayServiceClient<Box<dyn ReadWrite>> {
    fn rsd_service_name() -> std::borrow::Cow<'static, str> {
        obf!("com.apple.coredevice.displayservice")
    }

    async fn from_stream(stream: Box<dyn ReadWrite>) -> Result<Self, IdeviceError> {
        Ok(Self {
            inner: super::super::CoreDeviceServiceClient::new(stream).await?,
        })
    }
}

#[derive(Debug)]
pub struct DisplayServiceClient<R: ReadWrite> {
    inner: super::super::CoreDeviceServiceClient<R>,
}

impl<R: ReadWrite> DisplayServiceClient<R> {
    pub fn new(inner: super::super::CoreDeviceServiceClient<R>) -> Self {
        Self { inner }
    }

    /// Query what media-stream features the device supports (codecs, screen
    /// sharing, system audio, display info, screenshot capture, etc).
    pub async fn get_media_support_info(&mut self) -> Result<plist::Value, IdeviceError> {
        self.inner
            .invoke_with_plist(
                obf!("com.apple.coredevice.feature.getmediasupportinfo"),
                plist::Dictionary::new(),
            )
            .await
    }

    /// Query the current media-stream server status on the device. When a
    /// session is active this returns the full negotiated `streamConfig`.
    pub async fn get_media_stream_server_status(&mut self) -> Result<plist::Value, IdeviceError> {
        self.inner
            .invoke_with_plist(
                obf!("com.apple.coredevice.feature.getmediastreamserverstatus"),
                plist::Dictionary::new(),
            )
            .await
    }

    /// Stop the active media stream.
    pub async fn stop_media_stream(&mut self) -> Result<plist::Value, IdeviceError> {
        let mut input = plist::Dictionary::new();
        input.insert("stopAll".into(), plist::Value::Boolean(true));
        self.inner
            .invoke_with_plist_action(
                obf!("com.apple.coredevice.feature.stopmediastream"),
                input,
                obf!("com.apple.coredevice.action.mediastreamstop"),
            )
            .await
    }

    /// Stop only the named receiver stream tokens. Use a fresh service
    /// connection: the stop must be its sole reply-bearing request.
    pub async fn stop_media_stream_identifiers(&mut self, identifiers: &[u32]) -> Result<plist::Value, IdeviceError> {
        let input = scoped_stop_input(identifiers)?;
        self.inner.invoke_inner(
            obf!("com.apple.coredevice.feature.stopmediastream"), Some(input),
            Some(obf!("com.apple.coredevice.action.mediastreamstop").into()),
        ).await
    }

    /// Invoke `startvideooutput` with a built `MediaStreamStartParameters` XPC
    /// dictionary (see [`build_start_video_parameters`]).
    pub async fn start_video_output(
        &mut self,
        params: XpcDictionary,
    ) -> Result<plist::Value, IdeviceError> {
        self.inner
            .invoke(
                obf!("com.apple.coredevice.feature.startvideooutput"),
                Some(params),
            )
            .await
    }

    /// Invoke `startmediastream` with a built `MediaStreamStartParameters` XPC
    /// dictionary. This is the feature DeviceHub actually uses for video. The
    /// complete response is returned so callers can preserve its
    /// `negotiatorAnswer` for either an AVConference relay or the userspace
    /// fallback parser.
    pub async fn start_media_stream(
        &mut self,
        params: XpcDictionary,
    ) -> Result<plist::Value, IdeviceError> {
        self.inner
            .invoke(
                obf!("com.apple.coredevice.feature.startmediastream"),
                Some(params),
            )
            .await
    }
}

fn scoped_stop_input(identifiers: &[u32]) -> Result<XpcDictionary, IdeviceError> {
    if identifiers.is_empty() {
        return Err(crate::core_device::CoreDeviceError::MalformedField("stop identifiers").into());
    }
    let mut input = XpcDictionary::new();
    input.insert("stopAll".into(), XPCObject::Bool(false));
    input.insert("identifiers".into(), XPCObject::Array(identifiers.iter().map(|id| XPCObject::UInt64(u64::from(*id))).collect()));
    Ok(input)
}

#[cfg(test)]
mod scoped_stop_tests {
    use super::*;
    #[test]
    fn stop_request_names_only_owned_tokens_without_signed_conversion() {
        let input = scoped_stop_input(&[7, u32::MAX]).unwrap();
        assert!(matches!(input.get("stopAll"), Some(XPCObject::Bool(false))));
        let Some(XPCObject::Array(ids)) = input.get("identifiers") else { panic!("missing identifiers") };
        assert!(matches!(ids.as_slice(), [XPCObject::UInt64(7), XPCObject::UInt64(4_294_967_295)]));
        assert!(scoped_stop_input(&[]).is_err());
    }
}

fn codable_int(v: i64) -> XPCObject {
    let mut d = XpcDictionary::new();
    d.insert("int".into(), XPCObject::Int64(v));
    XPCObject::Dictionary(d)
}

fn codable_string(v: &str) -> XPCObject {
    let mut d = XpcDictionary::new();
    d.insert("string".into(), XPCObject::String(v.into()));
    XPCObject::Dictionary(d)
}

fn codable_uuid(v: uuid::Uuid) -> XPCObject {
    let mut d = XpcDictionary::new();
    d.insert("uuid".into(), XPCObject::Uuid(v));
    XPCObject::Dictionary(d)
}

/// Build the `MediaStreamStartParameters` XPC dictionary for `startmediastream`
/// with `type = video`.
///
/// `negotiator_offer` is the caller-owned AVConference mode-5 binary plist.
/// This builder embeds those bytes verbatim; it never parses, regenerates, or
/// reserializes them.
///
/// `receiver_ip`/`receiver_port` are where the device sends RTP.
/// `negotiator_offer` is the zlib+protobuf blob
/// from [`super::negotiation::MediaNegotiationBlob::to_negotiator_offer`].
/// `display_id` selects which device display to mirror (1 = primary?).
#[allow(clippy::too_many_arguments)]
pub fn build_start_video_parameters(
    receiver_ip: &str,
    receiver_port: u16,
    sender_ip: &str,
    sender_port: u16,
    negotiator_offer: Vec<u8>,
    client_supported_features: u64,
    display_id: i64,
    client_session_id: uuid::Uuid,
) -> XpcDictionary {
    build_start_parameters(
        "video",
        receiver_ip,
        receiver_port,
        sender_ip,
        sender_port,
        negotiator_offer,
        client_supported_features,
        client_session_id,
        Some(display_id),
    )
}

/// Build the `MediaStreamStartParameters` for the audio stream. Device Hub
/// starts this before the video stream to establish the screen-sharing session
/// (the video stream otherwise fails because the device negotiator finds no local
/// screen video rules). Use the same `client_session_id` as the video stream.
#[allow(clippy::too_many_arguments)]
pub fn build_start_audio_parameters(
    receiver_ip: &str,
    receiver_port: u16,
    sender_ip: &str,
    sender_port: u16,
    negotiator_offer: Vec<u8>,
    client_supported_features: u64,
    client_session_id: uuid::Uuid,
) -> XpcDictionary {
    build_start_parameters(
        "audio",
        receiver_ip,
        receiver_port,
        sender_ip,
        sender_port,
        negotiator_offer,
        client_supported_features,
        client_session_id,
        None,
    )
}

/// Shared `MediaStreamStartParameters` builder. `display_id` is `Some` only for
/// video streams (adds the `CoreDeviceVideoDisplayMode`/`VideoStreamForDisplayID`
/// options).
///
/// Option keys/values mirror exactly what Device Hub sends (captured from the
/// device's own logs). The callID is taken from the offer, and the clientName
/// ("CoreDeviceScreenSharing") is supplied by the device's mode-6 settings.
#[allow(clippy::too_many_arguments)]
fn build_start_parameters(
    stream_type: &str,
    receiver_ip: &str,
    receiver_port: u16,
    sender_ip: &str,
    sender_port: u16,
    negotiator_offer: Vec<u8>,
    client_supported_features: u64,
    client_session_id: uuid::Uuid,
    display_id: Option<i64>,
) -> XpcDictionary {
    let mut options = XpcDictionary::new();
    // Required for every CoreDevice media stream:
    options.insert(
        "AVCMediaStreamNegotiatorTransportProtocolType".into(),
        codable_int(2),
    );
    options.insert(
        "AVCMediaStreamNegotiatorAccessNetworkType".into(),
        codable_int(1),
    );
    options.insert(
        "avcMediaStreamOptionClientSessionID".into(),
        codable_uuid(client_session_id),
    );
    // Video-specific: which display to mirror.
    if let Some(display_id) = display_id {
        options.insert(
            "CoreDeviceVideoDisplayMode".into(),
            codable_string("DisplayByID"),
        );
        options.insert("VideoStreamForDisplayID".into(), codable_int(display_id));
    }

    let mut params = XpcDictionary::new();
    params.insert("receiverIP".into(), XPCObject::String(receiver_ip.into()));
    params.insert(
        "receiverPort".into(),
        XPCObject::UInt64(receiver_port as u64),
    );
    params.insert("senderIP".into(), XPCObject::String(sender_ip.into()));
    params.insert("senderPort".into(), XPCObject::UInt64(sender_port as u64));
    params.insert("timeout".into(), XPCObject::UInt64(3600));
    params.insert("type".into(), XPCObject::String(stream_type.into()));
    params.insert("direction".into(), XPCObject::String("output".into()));
    params.insert("negotiatorOffer".into(), XPCObject::Data(negotiator_offer));
    params.insert(
        "clientSupportedFeatures".into(),
        XPCObject::UInt64(client_supported_features),
    );
    params.insert("options".into(), XPCObject::Dictionary(options));
    params
}
