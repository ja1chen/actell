//! Programmatic device rotation via the `com.apple.coredevice.devicecontrol`
//! RemoteXPC service.

use std::borrow::Cow;

use crate::{
    IdeviceError, ReadWrite, RemoteXpcClient, obf, xpc,
    xpc::{Dictionary, XPCObject},
};

use super::CoreDeviceError;

/// Which way to rotate the device by 90 degrees.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum RotationDirection {
    /// Counter-clockwise.
    Left,
    /// Clockwise.
    Right,
}

impl RotationDirection {
    /// The `rotate` wire value.
    pub fn as_str(self) -> &'static str {
        match self {
            RotationDirection::Left => "left",
            RotationDirection::Right => "right",
        }
    }
}

/// A device orientation as reported by `devicecontrol`
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Orientation {
    Portrait,
    PortraitUpsideDown,
    LandscapeLeft,
    LandscapeRight,
    FaceUp,
    FaceDown,
    /// A value the device reported that this crate doesn't have a variant for.
    Unknown(String),
}

impl Orientation {
    fn from_wire(s: &str) -> Self {
        match s {
            "portrait" => Orientation::Portrait,
            "portraitUpsideDown" => Orientation::PortraitUpsideDown,
            "landscapeLeft" => Orientation::LandscapeLeft,
            "landscapeRight" => Orientation::LandscapeRight,
            "faceUp" => Orientation::FaceUp,
            "faceDown" => Orientation::FaceDown,
            other => Orientation::Unknown(other.to_string()),
        }
    }
}

/// The device's orientation after a rotation request.
#[derive(Debug, Clone)]
pub struct OrientationState {
    pub orientation: Orientation,
    pub non_flat_orientation: Orientation,
    /// whether rotation lock is engaged.
    pub locked: bool,
}

#[derive(Debug)]
pub struct OrientationServiceClient<R: ReadWrite> {
    inner: RemoteXpcClient<R>,
}

#[cfg(feature = "rsd")]
impl crate::RsdService for OrientationServiceClient<Box<dyn ReadWrite>> {
    fn rsd_service_name() -> Cow<'static, str> {
        obf!("com.apple.coredevice.devicecontrol")
    }

    async fn from_stream(stream: Box<dyn ReadWrite>) -> Result<Self, IdeviceError> {
        let mut inner = RemoteXpcClient::new(stream).await?;
        inner.do_handshake().await?;
        Ok(Self { inner })
    }
}

impl<R: ReadWrite> OrientationServiceClient<R> {
    pub fn new(inner: RemoteXpcClient<R>) -> Self {
        Self { inner }
    }

    /// Query the current device and last non-flat orientations without
    /// rotating the target.
    pub async fn current_orientation(&mut self) -> Result<OrientationState, IdeviceError> {
        self.request_orientation(None).await
    }

    /// Rotate the device 90 degrees in `direction`, returning the device's
    /// resulting [`OrientationState`].
    pub async fn rotate(
        &mut self,
        direction: RotationDirection,
    ) -> Result<OrientationState, IdeviceError> {
        self.request_orientation(Some(direction)).await
    }

    async fn request_orientation(
        &mut self,
        direction: Option<RotationDirection>,
    ) -> Result<OrientationState, IdeviceError> {
        let msg = build_orientation_request(direction);
        self.inner.send_object(msg, true).await?;
        let response = self.inner.recv().await?;
        parse_orientation_state(&response)
    }
}

fn build_orientation_request(direction: Option<RotationDirection>) -> XPCObject {
    let id: Cow<str> = obf!("com.apple.coredevice.feature.remote.devicecontrol.orientation");
    let payload = match direction {
        Some(direction) => xpc!({
            "rotate": {
                "_0": direction.as_str()
            }
        }),
        None => XPCObject::Dictionary(Dictionary::from_iter([(
            "currentOrientation".into(),
            XPCObject::Dictionary(Dictionary::new()),
        )])),
    };
    xpc!({
        "featureIdentifier": id.to_string(),
        "messageType": "OrientationRequest",
        "payload": payload
    })
}

fn parse_orientation_state(response: &plist::Value) -> Result<OrientationState, IdeviceError> {
    let payload = response
        .as_dictionary()
        .ok_or(CoreDeviceError::MalformedField("(root)"))?;
    let orientation = payload
        .get("currentDeviceOrientation")
        .and_then(plist::Value::as_string)
        .ok_or(CoreDeviceError::MissingField("currentDeviceOrientation"))?;
    let non_flat = payload
        .get("currentDeviceNonFlatOrientation")
        .and_then(plist::Value::as_string)
        .ok_or(CoreDeviceError::MissingField(
            "currentDeviceNonFlatOrientation",
        ))?;
    let locked = payload
        .get("currentDeviceOrientationLocked")
        .and_then(plist::Value::as_boolean)
        .ok_or(CoreDeviceError::MissingField(
            "currentDeviceOrientationLocked",
        ))?;

    Ok(OrientationState {
        orientation: Orientation::from_wire(orientation),
        non_flat_orientation: Orientation::from_wire(non_flat),
        locked,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn query_is_non_mutating_and_rotation_has_one_exact_direction() {
        let query = build_orientation_request(None);
        let query_payload = query
            .as_dictionary()
            .unwrap()
            .get("payload")
            .and_then(XPCObject::as_dictionary)
            .unwrap();
        assert_eq!(
            query_payload
                .get("currentOrientation")
                .and_then(XPCObject::as_dictionary),
            Some(&Dictionary::new())
        );

        let rotate = build_orientation_request(Some(RotationDirection::Left));
        let rotate_payload = rotate
            .as_dictionary()
            .unwrap()
            .get("payload")
            .and_then(XPCObject::as_dictionary)
            .unwrap();
        let direction = rotate_payload
            .get("rotate")
            .and_then(XPCObject::as_dictionary)
            .and_then(|value| value.get("_0"));
        assert_eq!(direction, Some(&XPCObject::String("left".into())));
    }

    #[test]
    fn orientation_state_requires_all_authoritative_fields() {
        let payload = plist::Dictionary::from_iter([
            (
                String::from("currentDeviceOrientation"),
                plist::Value::String("faceUp".into()),
            ),
            (
                String::from("currentDeviceNonFlatOrientation"),
                plist::Value::String("landscapeRight".into()),
            ),
            (
                String::from("currentDeviceOrientationLocked"),
                plist::Value::Boolean(false),
            ),
        ]);
        let valid = plist::Value::Dictionary(payload.clone());
        let state = parse_orientation_state(&valid).unwrap();
        assert_eq!(state.orientation, Orientation::FaceUp);
        assert_eq!(state.non_flat_orientation, Orientation::LandscapeRight);
        assert!(!state.locked);

        for missing in [
            "currentDeviceOrientation",
            "currentDeviceNonFlatOrientation",
            "currentDeviceOrientationLocked",
        ] {
            let mut incomplete = payload.clone();
            incomplete.remove(missing);
            let response = plist::Value::Dictionary(incomplete);
            assert!(parse_orientation_state(&response).is_err());
        }
    }

    #[test]
    fn orientation_state_comes_from_the_response_root() {
        let response = plist::Value::Dictionary(plist::Dictionary::from_iter([
            (
                String::from("currentDeviceOrientation"),
                plist::Value::String("portrait".into()),
            ),
            (
                String::from("currentDeviceNonFlatOrientation"),
                plist::Value::String("landscapeRight".into()),
            ),
            (
                String::from("currentDeviceOrientationLocked"),
                plist::Value::Boolean(false),
            ),
        ]));

        let state = parse_orientation_state(&response).unwrap();
        assert_eq!(state.orientation, Orientation::Portrait);
        assert_eq!(state.non_flat_orientation, Orientation::LandscapeRight);
        assert!(!state.locked);
    }
}
