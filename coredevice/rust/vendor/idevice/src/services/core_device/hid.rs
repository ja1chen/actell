//! HID back-channel for CoreDevice remote control. Served by the DDI daemon `dtuhidd`.
//!
//! **Authentication gate (applies to EVERY event kind here):** the device drops
//! the synthetic HID events `dtuhidd` posts unless a displayservice media stream
//! is active. This is true for buttons and keyboard just as much as touch.
//! Without the stream the event decodes and dispatches cleanly (the daemon even
//! logs `received peer event`) but nothing happens. Starting a
//! displayservice media stream (see `display_stream`) authenticates the HID
//! surfaces so the events route through to the system as real input.
//! The stream only needs to exist for the duration of the events;
//! its RTP payload can be discarded.

use serde::Deserialize;
use std::{
    borrow::Cow,
    collections::{BTreeMap, BTreeSet},
    sync::{
        OnceLock,
        atomic::{AtomicU64, Ordering},
    },
};
use thiserror::Error;
use web_time::Instant;

use crate::{
    IdeviceError, ReadWrite, RemoteXpcClient, obf,
    services::core_device::CoreDeviceError,
    xpc::{Dictionary, XPCObject},
};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ButtonState {
    Down,
    Up,
    Canceled,
}

impl ButtonState {
    pub fn raw(self) -> u64 {
        match self {
            ButtonState::Down => 1,
            ButtonState::Up => 2,
            ButtonState::Canceled => 3,
        }
    }
}

/// Hardware buttons whose Consumer-page usages are confirmed against the OSS
/// implementation's captured iOS 27 control path.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub enum HardwareButton {
    Home,
    Lock,
    VolumeUp,
    VolumeDown,
    Mute,
    Siri,
}

impl HardwareButton {
    /// Return the HID usage page and usage code sent in an
    /// `IndigoButtonEvent`.
    pub const fn usage(self) -> (u16, u16) {
        match self {
            Self::Home => (0x0C, 0x40),
            Self::Lock => (0x0C, 0x30),
            Self::VolumeUp => (0x0C, 0xE9),
            Self::VolumeDown => (0x0C, 0xEA),
            Self::Mute => (0x0C, 0xE2),
            Self::Siri => (0x0C, 0xCF),
        }
    }
}

#[derive(Debug, Clone, Default, PartialEq, Eq)]
struct ButtonTracker {
    pressed: BTreeSet<HardwareButton>,
}

impl ButtonTracker {
    fn transition(
        &mut self,
        button: HardwareButton,
        state: ButtonState,
    ) -> Result<(), HidInputError> {
        match state {
            ButtonState::Down if self.pressed.insert(button) => Ok(()),
            ButtonState::Down => Err(HidInputError::InvalidStateTransition(
                "hardware button is already down",
            )),
            ButtonState::Up | ButtonState::Canceled if self.pressed.remove(&button) => Ok(()),
            ButtonState::Up | ButtonState::Canceled => Err(HidInputError::InvalidStateTransition(
                "hardware button is not down",
            )),
        }
    }

    #[cfg(test)]
    fn is_empty(&self) -> bool {
        self.pressed.is_empty()
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum DigitizerEventType {
    Start,
    Position,
    End,
}

impl DigitizerEventType {
    pub fn raw(self) -> u64 {
        match self {
            DigitizerEventType::Start => 0,
            DigitizerEventType::Position => 1,
            DigitizerEventType::End => 2,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum DigitizerEdge {
    None,
    Top,
    Left,
    Bottom,
    Right,
}

impl DigitizerEdge {
    pub fn raw(self) -> u64 {
        match self {
            DigitizerEdge::None => 0,
            DigitizerEdge::Top => 1,
            DigitizerEdge::Left => 2,
            DigitizerEdge::Bottom => 3,
            DigitizerEdge::Right => 4,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum DigitizerTarget {
    MainScreen,
    Display(u64),
}

impl DigitizerTarget {
    pub fn raw(self) -> u64 {
        match self {
            DigitizerTarget::MainScreen => 0,
            DigitizerTarget::Display(n) => n,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ScrollTarget {
    DigitalCrown,
    Dial,
}

impl ScrollTarget {
    pub fn raw(self) -> u64 {
        match self {
            ScrollTarget::DigitalCrown => 0,
            ScrollTarget::Dial => 1,
        }
    }
}

pub mod scroll_phase {
    pub const UNDEFINED: u64 = 0x0;
    pub const BEGAN: u64 = 0x1;
    pub const CHANGED: u64 = 0x2;
    pub const ENDED: u64 = 0x4;
    pub const CANCELLED: u64 = 0x8;
    pub const MAY_BEGIN: u64 = 0x80;
}

pub mod scroll_momentum {
    pub const UNDEFINED: u64 = 0x0;
    pub const CONTINUE: u64 = 0x1;
    pub const START: u64 = 0x2;
    pub const END: u64 = 0x4;
    pub const WILL_BEGIN: u64 = 0x8;
    pub const INTERRUPTED: u64 = 0x10;
}

pub const DIGITIZER_REPORT_ID: u8 = 0x13;
pub const TOUCHSCREEN_REPORT_ID: u8 = 0x09;
pub const KEYBOARD_REPORT_ID: u8 = 0x01;
pub const TOUCHSCREEN_STATE_CONTACT: u8 = 0xC2;
pub const TOUCHSCREEN_STATE_RELEASE: u8 = 0x02;

pub const DIGITIZER_SURFACE_MAIN_TOUCHSCREEN: u64 = 257;
pub const DIGITIZER_SURFACE_TOUCHSCREEN_GESTURE: u64 = 1281;
pub const KEYBOARD_SURFACE_DEFAULT_SERVICE_ID: u64 = 0x1_0000_2001;

const KEYBOARD_USAGE_BITMAP_BYTES: usize = 30;
const MAX_KEYBOARD_USAGE: u16 = (KEYBOARD_USAGE_BITMAP_BYTES * 8 - 1) as u16;
const KEYBOARD_REPORT_DESCRIPTOR: [u8; 68] = [
    0x05, 0x01, 0x09, 0x06, 0xA1, 0x01, 0x05, 0x07, 0x19, 0xE0, 0x29, 0xE7, 0x15, 0x00, 0x25, 0x01,
    0x95, 0x08, 0x75, 0x01, 0x81, 0x02, 0x95, 0x01, 0x75, 0x08, 0x81, 0x01, 0x05, 0x07, 0x19, 0x00,
    0x29, 0xFF, 0x15, 0x00, 0x26, 0xFF, 0x00, 0x95, 0x06, 0x75, 0x08, 0x81, 0x00, 0x05, 0x08, 0x19,
    0x01, 0x29, 0x05, 0x15, 0x00, 0x25, 0x01, 0x95, 0x05, 0x75, 0x01, 0x91, 0x02, 0x95, 0x01, 0x75,
    0x03, 0x91, 0x01, 0xC0,
];

/// Invalid local HID input. These errors are produced before any bytes are
/// written to the device and never contain report contents or typed text.
#[derive(Debug, Error, Clone, Copy, PartialEq, Eq)]
pub enum HidInputError {
    #[error("keyboard usage {0} cannot be encoded in the virtual keyboard report")]
    InvalidKeyboardUsage(u16),
    #[error("HID usage {value} does not fit the {field} wire field")]
    InvalidUsage { field: &'static str, value: u64 },
    #[error("HID service identifier must not be zero")]
    InvalidServiceIdentifier,
    #[error("HID report must contain at least one byte")]
    EmptyReport,
    #[error("HID report exceeds the 65535-byte protocol limit")]
    ReportTooLarge,
    #[error("invalid virtual keyboard metadata field: {0}")]
    InvalidKeyboardMetadata(&'static str),
    #[error("virtual keyboard service is not registered in this session")]
    KeyboardNotRegistered,
    #[error("drag step count must be between 1 and 1024")]
    InvalidDragStepCount,
    #[error("drag sample delay must not exceed 1000 milliseconds")]
    InvalidDragDelay,
    #[error("the Indigo {0} event envelope is not supported")]
    UnsupportedIndigoEvent(&'static str),
    #[error("invalid HID state transition: {0}")]
    InvalidStateTransition(&'static str),
}

/// A local validation/state failure or an error writing the validated HID
/// operation to the authenticated RemoteXPC channel.
#[derive(Debug, Error)]
pub enum HidError {
    #[error(transparent)]
    Input(#[from] HidInputError),
    #[error(transparent)]
    Device(#[from] IdeviceError),
}

/// A usage on the HID Keyboard/Keypad page that fits the registered virtual
/// keyboard's one-byte usage fields.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub struct KeyboardUsage(u8);

impl KeyboardUsage {
    /// Validate a HID Keyboard/Keypad usage before it reaches the report
    /// encoder.
    pub fn new(raw: u16) -> Result<Self, HidInputError> {
        if raw > MAX_KEYBOARD_USAGE {
            return Err(HidInputError::InvalidKeyboardUsage(raw));
        }
        Ok(Self(raw as u8))
    }

    pub fn raw(self) -> u8 {
        self.0
    }
}

/// A normalized point on the device's main touchscreen. Both axes span the
/// complete `u16` range (`0` through `65535`) independent of pixel dimensions.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct TouchPoint {
    pub x: u16,
    pub y: u16,
}

impl TouchPoint {
    pub const fn new(x: u16, y: u16) -> Self {
        Self { x, y }
    }
}

/// A stateful single-contact touchscreen intent.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum TouchEvent {
    Down(TouchPoint),
    Move(TouchPoint),
    Up(TouchPoint),
    /// Release the active contact at its last successfully sent position.
    Cancel,
}

/// Contact state encoded by the confirmed 58-byte `mainTouchscreen` report.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum TouchContactState {
    Contact,
    Release,
}

impl TouchContactState {
    pub const fn raw(self) -> u8 {
        match self {
            Self::Contact => TOUCHSCREEN_STATE_CONTACT,
            Self::Release => TOUCHSCREEN_STATE_RELEASE,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
struct TouchSample {
    state: TouchContactState,
    point: TouchPoint,
}

impl TouchSample {
    const fn contact(point: TouchPoint) -> Self {
        Self {
            state: TouchContactState::Contact,
            point,
        }
    }

    const fn release(point: TouchPoint) -> Self {
        Self {
            state: TouchContactState::Release,
            point,
        }
    }
}

#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
struct TouchState {
    active_point: Option<TouchPoint>,
}

impl TouchState {
    fn transition(&mut self, event: TouchEvent) -> Result<TouchSample, HidInputError> {
        match (self.active_point, event) {
            (None, TouchEvent::Down(point)) => {
                self.active_point = Some(point);
                Ok(TouchSample::contact(point))
            }
            (Some(_), TouchEvent::Move(point)) => {
                self.active_point = Some(point);
                Ok(TouchSample::contact(point))
            }
            (Some(_), TouchEvent::Up(point)) => {
                self.active_point = None;
                Ok(TouchSample::release(point))
            }
            (Some(point), TouchEvent::Cancel) => {
                self.active_point = None;
                Ok(TouchSample::release(point))
            }
            (Some(_), TouchEvent::Down(_)) => Err(HidInputError::InvalidStateTransition(
                "touch contact is already down",
            )),
            (None, TouchEvent::Move(_)) => Err(HidInputError::InvalidStateTransition(
                "touch contact must be down before it moves",
            )),
            (None, TouchEvent::Up(_)) => Err(HidInputError::InvalidStateTransition(
                "touch contact is not down",
            )),
            (None, TouchEvent::Cancel) => Err(HidInputError::InvalidStateTransition(
                "touch contact is not down",
            )),
        }
    }

    #[cfg(test)]
    const fn is_active(self) -> bool {
        self.active_point.is_some()
    }
}

#[derive(Debug, Clone, Default, PartialEq, Eq)]
struct KeyboardState {
    pressed: BTreeSet<KeyboardUsage>,
}

impl KeyboardState {
    fn press(&mut self, usage: KeyboardUsage) -> Result<BTreeSet<KeyboardUsage>, HidInputError> {
        if !self.pressed.insert(usage) {
            return Err(HidInputError::InvalidStateTransition(
                "keyboard key is already down",
            ));
        }
        Ok(self.pressed.clone())
    }

    fn release(&mut self, usage: KeyboardUsage) -> Result<BTreeSet<KeyboardUsage>, HidInputError> {
        if !self.pressed.remove(&usage) {
            return Err(HidInputError::InvalidStateTransition(
                "keyboard key is not down",
            ));
        }
        Ok(self.pressed.clone())
    }

    fn cancel(&mut self) -> BTreeSet<KeyboardUsage> {
        self.pressed.clear();
        self.pressed.clone()
    }

    fn replace(&mut self, pressed: BTreeSet<KeyboardUsage>) -> BTreeSet<KeyboardUsage> {
        self.pressed = pressed;
        self.pressed.clone()
    }

    #[cfg(test)]
    fn is_empty(&self) -> bool {
        self.pressed.is_empty()
    }
}

/// Properties for the virtual keyboard surface registered with
/// `universalhidservice`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct KeyboardServiceConfiguration {
    pub service_id: u64,
    pub product: String,
    pub manufacturer: String,
    pub vendor_id: u16,
    pub product_id: u16,
}

impl Default for KeyboardServiceConfiguration {
    fn default() -> Self {
        Self {
            service_id: KEYBOARD_SURFACE_DEFAULT_SERVICE_ID,
            product: "Device Hub virtual keyboard".into(),
            manufacturer: "Device Hub".into(),
            vendor_id: 0x05AC,
            product_id: 0x0250,
        }
    }
}

impl KeyboardServiceConfiguration {
    fn validate(&self) -> Result<(), HidInputError> {
        fn validate_text(value: &str, field: &'static str) -> Result<(), HidInputError> {
            if value.is_empty()
                || value.len() > 128
                || value.chars().any(|character| character.is_control())
            {
                return Err(HidInputError::InvalidKeyboardMetadata(field));
            }
            Ok(())
        }

        if self.service_id == 0 {
            return Err(HidInputError::InvalidServiceIdentifier);
        }
        validate_text(&self.product, "product")?;
        validate_text(&self.manufacturer, "manufacturer")
    }
}

/// A 48-bit monotonic timestamp for HID reports. The gesture recognizer only
/// cares about monotonicity and inter-frame deltas. A process-relative
/// [`Instant`] avoids wall-clock adjustments; an atomic tie-breaker keeps
/// back-to-back reports strictly ordered at coarse clock resolutions.
fn default_timestamp() -> u64 {
    const MASK: u64 = (1u64 << 48) - 1;
    static ORIGIN: OnceLock<Instant> = OnceLock::new();
    static LAST: AtomicU64 = AtomicU64::new(0);

    let elapsed = ORIGIN.get_or_init(Instant::now).elapsed().as_nanos();
    let candidate = u64::try_from(elapsed).unwrap_or(u64::MAX) & MASK;
    let mut previous = LAST.load(Ordering::Relaxed);
    loop {
        let next = if candidate > previous {
            candidate
        } else if previous < MASK {
            previous + 1
        } else {
            candidate
        };
        match LAST.compare_exchange_weak(previous, next, Ordering::Relaxed, Ordering::Relaxed) {
            Ok(_) => return next,
            Err(actual) => previous = actual,
        }
    }
}

/// Build a 19-byte gesture/pointer HID report
///
/// `x`/`y` are signed 32-bit. `timestamp` is a 48-bit monotonic value; pass
/// `None` to use the process's monotonic HID clock.
///
/// Layout: `[0x13][x:i32 LE][y:i32 LE][00 00][ts:6 LE][00 00]`.
pub fn build_digitizer_report(x: i32, y: i32, timestamp: Option<u64>) -> Vec<u8> {
    let ts = timestamp.unwrap_or_else(default_timestamp) & ((1u64 << 48) - 1);
    let mut r = Vec::with_capacity(19);
    r.push(DIGITIZER_REPORT_ID);
    r.extend_from_slice(&x.to_le_bytes());
    r.extend_from_slice(&y.to_le_bytes());
    r.extend_from_slice(&[0, 0]);
    r.extend_from_slice(&ts.to_le_bytes()[..6]);
    r.extend_from_slice(&[0, 0]);
    r
}

/// Build the captured 39-byte UniversalHID keyboard event.
///
/// Every report replaces the device's prior pressed-key set. An empty
/// iterator therefore releases every key. The event contains a report ID,
/// 240-bit HID Keyboard/Keypad usage bitmap, 48-bit monotonic timestamp, and
/// two trailing zero bytes. This is the `send` payload consumed by
/// UniversalHID; it is not the boot report described by the virtual service's
/// registration descriptor.
pub fn build_keyboard_report(usage_codes: impl IntoIterator<Item = KeyboardUsage>) -> Vec<u8> {
    build_keyboard_report_at(usage_codes, None)
}

fn build_keyboard_report_at(
    usage_codes: impl IntoIterator<Item = KeyboardUsage>,
    timestamp: Option<u64>,
) -> Vec<u8> {
    let timestamp = timestamp.unwrap_or_else(default_timestamp) & ((1u64 << 48) - 1);
    let mut bitmap = [0u8; KEYBOARD_USAGE_BITMAP_BYTES];
    for usage in usage_codes {
        let usage = usize::from(usage.raw());
        bitmap[usage / 8] |= 1 << (usage % 8);
    }

    let mut report = Vec::with_capacity(39);
    report.push(KEYBOARD_REPORT_ID);
    report.extend_from_slice(&bitmap);
    report.extend_from_slice(&timestamp.to_le_bytes()[..6]);
    report.extend_from_slice(&[0, 0]);
    report
}

fn codable_value(tag: &str, value: XPCObject) -> XPCObject {
    let mut wrapper = Dictionary::new();
    wrapper.insert(tag.into(), value);
    XPCObject::Dictionary(wrapper)
}

fn universal_hid_request(payload: Dictionary) -> Dictionary {
    let mut request = Dictionary::new();
    let feature_identifier: Cow<'static, str> =
        obf!("com.apple.coredevice.feature.remote.universalhidservice");
    request.insert(
        "featureIdentifier".into(),
        XPCObject::String(feature_identifier.into()),
    );
    request.insert("messageType".into(), XPCObject::String("Request".into()));
    request.insert("payload".into(), XPCObject::Dictionary(payload));
    request
}

fn build_create_keyboard_service_request(config: &KeyboardServiceConfiguration) -> Dictionary {
    let usage = XPCObject::Int64(6);
    let usage_page = XPCObject::Int64(1);
    let vendor_id = XPCObject::Int64(i64::from(config.vendor_id));
    let product_id = XPCObject::Int64(i64::from(config.product_id));
    let service_id = XPCObject::UInt64(config.service_id);

    let mut usage_pair = Dictionary::new();
    usage_pair.insert("DeviceUsage".into(), usage.clone());
    usage_pair.insert("DeviceUsagePage".into(), usage_page.clone());

    let mut codable_usage_pair = Dictionary::new();
    codable_usage_pair.insert("DeviceUsage".into(), codable_value("int", usage.clone()));
    codable_usage_pair.insert(
        "DeviceUsagePage".into(),
        codable_value("int", usage_page.clone()),
    );

    let mut storage = Dictionary::new();
    storage.insert(
        "Manufacturer".into(),
        codable_value("string", XPCObject::String(config.manufacturer.clone())),
    );
    storage.insert(
        "Product".into(),
        codable_value("string", XPCObject::String(config.product.clone())),
    );
    storage.insert("ProductID".into(), codable_value("int", product_id.clone()));
    storage.insert("VendorID".into(), codable_value("int", vendor_id.clone()));
    storage.insert("PrimaryUsage".into(), codable_value("int", usage.clone()));
    storage.insert(
        "PrimaryUsagePage".into(),
        codable_value("int", usage_page.clone()),
    );
    storage.insert(
        "DeviceUsagePairs".into(),
        codable_value(
            "array",
            XPCObject::Array(vec![codable_value(
                "dictionary",
                XPCObject::Dictionary(codable_usage_pair),
            )]),
        ),
    );
    storage.insert(
        "Transport".into(),
        codable_value("string", XPCObject::String("USB".into())),
    );
    storage.insert(
        "ReportDescriptor".into(),
        codable_value("data", XPCObject::Data(KEYBOARD_REPORT_DESCRIPTOR.to_vec())),
    );
    storage.insert(
        "UniversalControlVirtualService".into(),
        codable_value("bool", XPCObject::Bool(true)),
    );
    storage.insert(
        "_ServiceID".into(),
        codable_value("uint", service_id.clone()),
    );

    let mut properties = Dictionary::new();
    properties.insert(
        "DeviceUsagePairs".into(),
        XPCObject::Array(vec![XPCObject::Dictionary(usage_pair)]),
    );
    properties.insert("PrimaryUsage".into(), XPCObject::UInt64(6));
    properties.insert("PrimaryUsagePage".into(), XPCObject::UInt64(1));
    properties.insert("Product".into(), XPCObject::String(config.product.clone()));
    properties.insert("ProductID".into(), product_id);
    properties.insert("VendorID".into(), vendor_id);
    properties.insert(
        "_CoreDevice_codablePropertyStorage".into(),
        XPCObject::Dictionary(storage),
    );
    properties.insert("_ServiceID".into(), service_id);

    let mut create_service = Dictionary::new();
    create_service.insert("_0".into(), XPCObject::Dictionary(properties));

    let mut payload = Dictionary::new();
    payload.insert(
        "createService".into(),
        XPCObject::Dictionary(create_service),
    );
    universal_hid_request(payload)
}

fn parse_created_keyboard_service_id(response: &plist::Value) -> Result<u64, IdeviceError> {
    let response = response
        .as_dictionary()
        .ok_or(CoreDeviceError::MalformedField("keyboard create response"))?;
    let service_id = response
        .get("serviceID")
        .ok_or(CoreDeviceError::MissingField("serviceID"))?
        .as_unsigned_integer()
        .filter(|service_id| *service_id != 0)
        .ok_or(CoreDeviceError::MalformedField("serviceID"))?;
    Ok(service_id)
}

fn build_send_report_request(service_id: u64, report: Vec<u8>) -> Dictionary {
    let mut tuple = Dictionary::new();
    tuple.insert("_0".into(), XPCObject::Data(report));
    tuple.insert("_1".into(), XPCObject::UInt64(service_id));
    let mut payload = Dictionary::new();
    payload.insert("send".into(), XPCObject::Dictionary(tuple));
    universal_hid_request(payload)
}

fn validate_report(service_id: u64, report: &[u8]) -> Result<(), HidInputError> {
    if service_id == 0 {
        return Err(HidInputError::InvalidServiceIdentifier);
    }
    if report.is_empty() {
        return Err(HidInputError::EmptyReport);
    }
    if report.len() > u16::MAX as usize {
        return Err(HidInputError::ReportTooLarge);
    }
    Ok(())
}

fn narrow_usage(field: &'static str, value: u64) -> Result<u16, HidInputError> {
    u16::try_from(value).map_err(|_| HidInputError::InvalidUsage { field, value })
}

fn validate_drag(steps: u32, delay_ms: u64) -> Result<(), HidInputError> {
    if !(1..=1024).contains(&steps) {
        return Err(HidInputError::InvalidDragStepCount);
    }
    if delay_ms > 1000 {
        return Err(HidInputError::InvalidDragDelay);
    }
    Ok(())
}

/// Build a 58-byte `mainTouchscreen` HID report (report ID `0x09`).
///
/// `state` is a contact sample or release at the normalized `point`. Pass
/// `timestamp = None` to use the process's monotonic HID clock.
///
/// Layout: `[0x09 0x01 0x05 state][x:u16 LE][y:u16 LE][32×00][02 00 00 00][ts:6 LE][8×00]`.
pub fn build_touchscreen_report(
    state: TouchContactState,
    point: TouchPoint,
    timestamp: Option<u64>,
) -> Vec<u8> {
    let ts = timestamp.unwrap_or_else(default_timestamp) & ((1u64 << 48) - 1);
    let mut r = Vec::with_capacity(58);
    r.extend_from_slice(&[TOUCHSCREEN_REPORT_ID, 0x01, 0x05, state.raw()]);
    r.extend_from_slice(&point.x.to_le_bytes());
    r.extend_from_slice(&point.y.to_le_bytes());
    r.extend_from_slice(&[0u8; 32]);
    r.extend_from_slice(&[0x02, 0x00, 0x00, 0x00]);
    r.extend_from_slice(&ts.to_le_bytes()[..6]);
    r.extend_from_slice(&[0u8; 8]);
    r
}

fn build_indigo_button_request(usage_page: u16, usage_code: u16, state: ButtonState) -> Dictionary {
    let mut payload = Dictionary::new();
    payload.insert("state".into(), XPCObject::UInt64(state.raw()));
    payload.insert("usagePage".into(), XPCObject::UInt64(u64::from(usage_page)));
    payload.insert("usageCode".into(), XPCObject::UInt64(u64::from(usage_code)));

    let mut request = Dictionary::new();
    request.insert(
        "messageType".into(),
        XPCObject::String("IndigoButtonEvent".into()),
    );
    request.insert("payload".into(), XPCObject::Dictionary(payload));
    let feature_identifier: Cow<'static, str> =
        obf!("com.apple.coredevice.feature.remote.hid.button");
    request.insert(
        "featureIdentifier".into(),
        XPCObject::String(feature_identifier.into()),
    );
    request
}

fn build_indigo_keyboard_request(usage_code: u16, state: ButtonState) -> Dictionary {
    let mut payload = Dictionary::new();
    payload.insert("usageCode".into(), XPCObject::UInt64(u64::from(usage_code)));
    payload.insert("state".into(), XPCObject::UInt64(state.raw()));

    let mut request = Dictionary::new();
    request.insert(
        "messageType".into(),
        XPCObject::String("IndigoKeyboardButtonEvent".into()),
    );
    request.insert("payload".into(), XPCObject::Dictionary(payload));
    let feature_identifier: Cow<'static, str> =
        obf!("com.apple.coredevice.feature.remote.hid.keyboard");
    request.insert(
        "featureIdentifier".into(),
        XPCObject::String(feature_identifier.into()),
    );
    request
}

/// Generic Indigo HID events.
///
/// `com.apple.coredevice.hid.indigo`.
#[derive(Debug)]
pub struct IndigoHidClient<R: ReadWrite> {
    inner: RemoteXpcClient<R>,
    buttons: ButtonTracker,
}

#[cfg(feature = "rsd")]
impl crate::RsdService for IndigoHidClient<Box<dyn ReadWrite>> {
    fn rsd_service_name() -> Cow<'static, str> {
        obf!("com.apple.coredevice.hid.indigo")
    }

    async fn from_stream(stream: Box<dyn ReadWrite>) -> Result<Self, IdeviceError> {
        let mut inner = RemoteXpcClient::new(stream).await?;
        inner.do_handshake().await?;
        Ok(Self {
            inner,
            buttons: ButtonTracker::default(),
        })
    }
}

impl<R: ReadWrite> IndigoHidClient<R> {
    pub fn new(inner: RemoteXpcClient<R>) -> Self {
        Self {
            inner,
            buttons: ButtonTracker::default(),
        }
    }

    /// Send an `IndigoButtonEvent`: a single hardware-button state change.
    ///
    /// * `usage_page` - HID usage page (e.g. `0x0C` Consumer for media keys,
    ///   `0x01` Generic Desktop for power/sleep).
    /// * `usage_code` - HID usage within that page.
    /// * `state` - [`ButtonState::Down`], [`ButtonState::Up`], or
    ///   [`ButtonState::Canceled`].
    ///
    /// This low-level operation does not track button state. Controller code
    /// should use [`send_hardware_button`](Self::send_hardware_button) for the
    /// confirmed iOS hardware usages and balanced state transitions.
    pub async fn send_button(
        &mut self,
        usage_page: u64,
        usage_code: u64,
        state: ButtonState,
    ) -> Result<(), HidError> {
        let usage_page = narrow_usage("usagePage", usage_page)?;
        let usage_code = narrow_usage("usageCode", usage_code)?;
        let request = build_indigo_button_request(usage_page, usage_code, state);
        self.inner.send_object(request, false).await?;
        Ok(())
    }

    /// Send a confirmed iOS hardware-button transition, rejecting duplicate
    /// downs and unmatched ups/cancellations before writing to the device.
    ///
    /// State is committed only after the one-way RemoteXPC write succeeds. If
    /// a write is cancelled or fails, callers can retry the transition.
    pub async fn send_hardware_button(
        &mut self,
        button: HardwareButton,
        state: ButtonState,
    ) -> Result<(), HidError> {
        let mut next = self.buttons.clone();
        next.transition(button, state)?;
        let (usage_page, usage_code) = button.usage();
        self.send_button(u64::from(usage_page), u64::from(usage_code), state)
            .await?;
        self.buttons = next;
        Ok(())
    }

    /// Send one keyboard edge through the confirmed Indigo keyboard feature.
    pub async fn send_keyboard(
        &mut self,
        usage_code: u64,
        state: ButtonState,
    ) -> Result<(), HidError> {
        let usage_code = narrow_usage("usageCode", usage_code)?;
        KeyboardUsage::new(usage_code)?;
        let request = build_indigo_keyboard_request(usage_code, state);
        self.inner.send_object(request, false).await?;
        Ok(())
    }

    /// Indigo's digitizer envelope is not wire-compatible with the captured
    /// iOS path. Use [`UniversalHidServiceClient::send_touch`] instead.
    pub async fn send_digitizer(
        &mut self,
        _point_one: (f64, f64),
        _point_two: Option<(f64, f64)>,
        _event_type: DigitizerEventType,
        _edge: DigitizerEdge,
        _target: DigitizerTarget,
    ) -> Result<(), HidError> {
        Err(HidInputError::UnsupportedIndigoEvent("digitizer").into())
    }

    /// Indigo's scroll envelope is not wire-compatible with the captured iOS
    /// path and is deliberately rejected rather than emitting a no-op packet.
    pub async fn send_scroll(
        &mut self,
        _point: (f64, f64, f64),
        _phase: u64,
        _momentum: u64,
        _target: ScrollTarget,
    ) -> Result<(), HidError> {
        Err(HidInputError::UnsupportedIndigoEvent("scroll").into())
    }

    /// Indigo's vendor-defined envelope is not wire-compatible with the
    /// captured iOS path and is deliberately rejected.
    pub async fn send_vendor_defined(
        &mut self,
        _usage_page: u64,
        _usage: u64,
        _version: u64,
        _data: Vec<u8>,
    ) -> Result<(), HidError> {
        Err(HidInputError::UnsupportedIndigoEvent("vendor-defined").into())
    }
}

/// A HID surface the device has registered, as returned by
/// [`UniversalHidServiceClient::list_connected_services`]. The device also
/// reports a verbose `_CoreDevice_codablePropertyStorage` mirror of these
/// fields, which this skips.
#[derive(Debug, Clone, Deserialize, PartialEq, Eq)]
pub struct HidSurface {
    /// The surface's identifier — the `service_id` to pass to
    /// [`UniversalHidServiceClient::send_report`].
    #[serde(rename = "_ServiceID")]
    pub service_id: u64,
    /// Human-readable product string, e.g. `"CoreDevice touchscreen(nil)"`.
    #[serde(rename = "Product")]
    pub product: Option<String>,
    /// The surface's primary HID usage.
    #[serde(rename = "PrimaryUsage")]
    pub primary_usage: Option<u64>,
    /// The surface's primary HID usage page.
    #[serde(rename = "PrimaryUsagePage")]
    pub primary_usage_page: Option<u64>,
}

fn parse_hid_surfaces(response: &plist::Value) -> Result<Vec<HidSurface>, IdeviceError> {
    let response = response
        .as_dictionary()
        .ok_or(CoreDeviceError::MalformedField(
            "connectedServices response",
        ))?;
    let encoded = response
        .get("connectedServices")
        .ok_or(CoreDeviceError::MissingField("connectedServices"))?;
    let surfaces: Vec<HidSurface> = plist::from_value(encoded)
        .map_err(|_| CoreDeviceError::MalformedField("connectedServices"))?;
    if surfaces.len() > 256 {
        return Err(CoreDeviceError::MalformedField("connectedServices").into());
    }

    let mut identifiers = BTreeSet::new();
    for surface in &surfaces {
        if surface.service_id == 0 || !identifiers.insert(surface.service_id) {
            return Err(CoreDeviceError::MalformedField("connectedServices").into());
        }
        if let Some(product) = &surface.product
            && (product.is_empty()
                || product.len() > 256
                || product.chars().any(|character| character.is_control()))
        {
            return Err(CoreDeviceError::MalformedField("connectedServices").into());
        }
        if surface
            .primary_usage_page
            .is_some_and(|page| page > u64::from(u16::MAX))
            || surface
                .primary_usage
                .is_some_and(|usage| usage > u64::from(u16::MAX))
        {
            return Err(CoreDeviceError::MalformedField("connectedServices").into());
        }
    }
    Ok(surfaces)
}

/// Inspect and drive the device's registered HID surfaces.
#[derive(Debug)]
pub struct UniversalHidServiceClient<R: ReadWrite> {
    inner: RemoteXpcClient<R>,
    touch: TouchState,
    keyboards: BTreeMap<u64, KeyboardState>,
}

#[cfg(feature = "rsd")]
impl crate::RsdService for UniversalHidServiceClient<Box<dyn ReadWrite>> {
    fn rsd_service_name() -> Cow<'static, str> {
        obf!("com.apple.coredevice.hid.universalhidservice")
    }

    async fn from_stream(stream: Box<dyn ReadWrite>) -> Result<Self, IdeviceError> {
        let mut inner = RemoteXpcClient::new(stream).await?;
        inner.do_handshake().await?;
        Ok(Self {
            inner,
            touch: TouchState::default(),
            keyboards: BTreeMap::new(),
        })
    }
}

impl<R: ReadWrite> UniversalHidServiceClient<R> {
    pub fn new(inner: RemoteXpcClient<R>) -> Self {
        Self {
            inner,
            touch: TouchState::default(),
            keyboards: BTreeMap::new(),
        }
    }

    /// Build the `{featureIdentifier, messageType: "Request", payload}` envelope
    /// these requests share.
    fn request(payload: Dictionary) -> Dictionary {
        universal_hid_request(payload)
    }

    /// Enumerate the device's currently-registered HID surfaces.
    pub async fn list_connected_services(&mut self) -> Result<Vec<HidSurface>, IdeviceError> {
        let mut payload = Dictionary::new();
        payload.insert(
            "connectedServices".into(),
            XPCObject::Dictionary(Dictionary::new()),
        );
        let msg = Self::request(payload);
        self.inner.send_object(msg, true).await?;
        let res = self.inner.recv().await?;

        parse_hid_surfaces(&res)
    }

    /// Deliver a non-empty, bounded raw HID report to one of the device's HID
    /// surfaces.
    pub async fn send_report(&mut self, service_id: u64, report: Vec<u8>) -> Result<(), HidError> {
        validate_report(service_id, &report)?;

        // `send` is a Swift tuple `(_0: report, _1: serviceID)`.
        let msg = build_send_report_request(service_id, report);
        self.inner.send_object(msg, false).await?;
        Ok(())
    }

    /// Send a single 19-byte gesture/pointer report at (`x`, `y`).
    /// For an actual on-screen touch use
    /// [`send_touch`](Self::send_touch).
    pub async fn send_digitizer(
        &mut self,
        x: i32,
        y: i32,
        service_id: u64,
        timestamp: Option<u64>,
    ) -> Result<(), HidError> {
        self.send_report(service_id, build_digitizer_report(x, y, timestamp))
            .await
    }

    /// Send a checked down, move, up, or cancellation event to the confirmed
    /// `mainTouchscreen` surface.
    ///
    /// The touchscreen wire format has no distinct cancel opcode, so
    /// [`TouchEvent::Cancel`] emits a release at the last successfully sent
    /// point. State changes are committed only after the RemoteXPC write
    /// succeeds.
    pub async fn send_touch(
        &mut self,
        event: TouchEvent,
        timestamp: Option<u64>,
    ) -> Result<(), HidError> {
        let mut next = self.touch;
        let sample = next.transition(event)?;
        self.send_report(
            DIGITIZER_SURFACE_MAIN_TOUCHSCREEN,
            build_touchscreen_report(sample.state, sample.point, timestamp),
        )
        .await?;
        self.touch = next;
        Ok(())
    }

    /// Register the captured Universal Control virtual-keyboard surface and
    /// return the service identifier assigned by the device.
    pub async fn create_keyboard_service(
        &mut self,
        configuration: &KeyboardServiceConfiguration,
    ) -> Result<u64, HidError> {
        configuration.validate()?;
        let request = build_create_keyboard_service_request(configuration);
        self.inner.send_object(request, true).await?;
        let response = self.inner.recv().await?;
        let service_id = parse_created_keyboard_service_id(&response)?;
        self.keyboards.insert(service_id, KeyboardState::default());
        Ok(service_id)
    }

    async fn send_keyboard_state(
        &mut self,
        service_id: u64,
        pressed: &BTreeSet<KeyboardUsage>,
        timestamp: Option<u64>,
    ) -> Result<(), HidError> {
        let report = build_keyboard_report_at(pressed.iter().copied(), timestamp);
        self.send_report(service_id, report).await
    }

    /// Atomically replace the complete pressed-key bitmap with one HID report.
    ///
    /// This is the primitive for semantic chord edges: callers calculate the
    /// full key plus modifier set, and the device never observes partially
    /// applied modifiers. State commits only after the RemoteXPC write
    /// succeeds.
    pub async fn set_keyboard_usages(
        &mut self,
        service_id: u64,
        pressed: BTreeSet<KeyboardUsage>,
        timestamp: Option<u64>,
    ) -> Result<(), HidError> {
        let mut next = self
            .keyboards
            .get(&service_id)
            .cloned()
            .ok_or(HidInputError::KeyboardNotRegistered)?;
        let pressed = next.replace(pressed);
        self.send_keyboard_state(service_id, &pressed, timestamp)
            .await?;
        self.keyboards.insert(service_id, next);
        Ok(())
    }

    /// Press one key on a virtual keyboard surface. The full pressed-key bitmap
    /// is sent, so modifiers and chords remain held until explicitly released.
    pub async fn key_down(
        &mut self,
        service_id: u64,
        usage: KeyboardUsage,
        timestamp: Option<u64>,
    ) -> Result<(), HidError> {
        let mut next = self
            .keyboards
            .get(&service_id)
            .cloned()
            .ok_or(HidInputError::KeyboardNotRegistered)?;
        let pressed = next.press(usage)?;
        self.send_keyboard_state(service_id, &pressed, timestamp)
            .await?;
        self.keyboards.insert(service_id, next);
        Ok(())
    }

    /// Release one currently-pressed key on a virtual keyboard surface.
    pub async fn key_up(
        &mut self,
        service_id: u64,
        usage: KeyboardUsage,
        timestamp: Option<u64>,
    ) -> Result<(), HidError> {
        let mut next = self
            .keyboards
            .get(&service_id)
            .cloned()
            .ok_or(HidInputError::KeyboardNotRegistered)?;
        let pressed = next.release(usage)?;
        self.send_keyboard_state(service_id, &pressed, timestamp)
            .await?;
        self.keyboards.insert(service_id, next);
        Ok(())
    }

    /// Release every key on a registered virtual keyboard. This is the
    /// cancellation primitive to call when a controller gesture is interrupted.
    pub async fn cancel_keyboard(
        &mut self,
        service_id: u64,
        timestamp: Option<u64>,
    ) -> Result<(), HidError> {
        let mut next = self
            .keyboards
            .get(&service_id)
            .cloned()
            .ok_or(HidInputError::KeyboardNotRegistered)?;
        let pressed = next.cancel();
        self.send_keyboard_state(service_id, &pressed, timestamp)
            .await?;
        self.keyboards.insert(service_id, next);
        Ok(())
    }

    /// A tap on the touchscreen: one contact sample, a short hold, then a
    /// release at the same point.
    pub async fn tap(&mut self, x: u16, y: u16) -> Result<(), HidError> {
        let point = TouchPoint::new(x, y);
        self.send_touch(TouchEvent::Down(point), None).await?;
        crate::time::sleep(std::time::Duration::from_millis(50)).await;
        self.send_touch(TouchEvent::Up(point), None).await
    }

    /// A drag on the touchscreen from (`x1`, `y1`) to (`x2`, `y2`): a stream of
    /// `steps` contact samples advancing linearly, a final contact at the end
    /// point, then a release. `delay_ms` is slept between samples so the gesture
    /// recognizer sees a velocity (a too-fast drag reads as a tap). This is the
    /// real touch-drag used for scrolling/swiping content. `steps` must be
    /// between 1 and 1024, and `delay_ms` must not exceed 1000.
    pub async fn drag(
        &mut self,
        x1: u16,
        y1: u16,
        x2: u16,
        y2: u16,
        steps: u32,
        delay_ms: u64,
    ) -> Result<(), HidError> {
        validate_drag(steps, delay_ms)?;

        let start = TouchPoint::new(x1, y1);
        let end = TouchPoint::new(x2, y2);
        self.send_touch(TouchEvent::Down(start), None).await?;
        for i in 1..=steps {
            let t = i as f64 / steps as f64;
            let x = (x1 as f64 + (x2 as f64 - x1 as f64) * t).round() as u16;
            let y = (y1 as f64 + (y2 as f64 - y1 as f64) * t).round() as u16;
            self.send_touch(TouchEvent::Move(TouchPoint::new(x, y)), None)
                .await?;
            if delay_ms > 0 && i < steps {
                crate::time::sleep(std::time::Duration::from_millis(delay_ms)).await;
            }
        }
        self.send_touch(TouchEvent::Up(end), None).await
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn plist_dictionary(
        entries: impl IntoIterator<Item = (&'static str, plist::Value)>,
    ) -> plist::Value {
        plist::Value::Dictionary(plist::Dictionary::from_iter(
            entries
                .into_iter()
                .map(|(key, value)| (String::from(key), value)),
        ))
    }

    fn surface(
        service_id: u64,
        product: Option<&str>,
        primary_usage_page: Option<u64>,
        primary_usage: Option<u64>,
    ) -> plist::Value {
        let mut entries = vec![("_ServiceID", plist::Value::Integer(service_id.into()))];
        if let Some(product) = product {
            entries.push(("Product", plist::Value::String(product.into())));
        }
        if let Some(primary_usage_page) = primary_usage_page {
            entries.push((
                "PrimaryUsagePage",
                plist::Value::Integer(primary_usage_page.into()),
            ));
        }
        if let Some(primary_usage) = primary_usage {
            entries.push(("PrimaryUsage", plist::Value::Integer(primary_usage.into())));
        }
        plist_dictionary(entries)
    }

    fn connected_services(surfaces: Vec<plist::Value>) -> plist::Value {
        plist_dictionary([("connectedServices", plist::Value::Array(surfaces))])
    }

    #[test]
    fn digitizer_report_layout() {
        let r = build_digitizer_report(100, -50, Some(0x0102030405));
        assert_eq!(r.len(), 19);
        assert_eq!(r[0], DIGITIZER_REPORT_ID);
        assert_eq!(&r[1..5], &100i32.to_le_bytes());
        assert_eq!(&r[5..9], &(-50i32).to_le_bytes());
        assert_eq!(&r[9..11], &[0, 0]);
        assert_eq!(&r[11..17], &0x0102030405u64.to_le_bytes()[..6]);
        assert_eq!(&r[17..19], &[0, 0]);
    }

    #[test]
    fn touchscreen_report_layout() {
        let r = build_touchscreen_report(
            TouchContactState::Contact,
            TouchPoint::new(375, 812),
            Some(0xAABBCCDD),
        );
        assert_eq!(r.len(), 58);
        assert_eq!(&r[0..4], &[0x09, 0x01, 0x05, 0xC2]);
        assert_eq!(&r[4..6], &375u16.to_le_bytes());
        assert_eq!(&r[6..8], &812u16.to_le_bytes());
        assert_eq!(&r[8..40], &[0u8; 32]);
        assert_eq!(&r[40..44], &[0x02, 0x00, 0x00, 0x00]);
        assert_eq!(&r[44..50], &0xAABBCCDDu64.to_le_bytes()[..6]);
        assert_eq!(&r[50..58], &[0u8; 8]);
    }

    #[test]
    fn timestamp_is_truncated_to_48_bits() {
        // A timestamp above 48 bits must be masked, not overflow the 6-byte field.
        let r = build_digitizer_report(0, 0, Some(u64::MAX));
        assert_eq!(&r[11..17], &[0xFF; 6]);
    }

    #[test]
    fn generated_timestamps_are_strictly_ordered() {
        let first = default_timestamp();
        let second = default_timestamp();

        assert!(second > first || (first == (1u64 << 48) - 1 && second < first));
        assert!(second < 1u64 << 48);
    }

    #[test]
    fn keyboard_report_matches_the_captured_universal_hid_event_shape() {
        let usages = [
            KeyboardUsage::new(0x04).unwrap(),
            KeyboardUsage::new(0xE1).unwrap(),
        ];

        let report = build_keyboard_report_at(usages, Some(0x0605_0403_0201));

        assert_eq!(report.len(), 39);
        assert_eq!(report[0], 0x01);
        assert_eq!(report[1], 0b0001_0000);
        assert_eq!(report[29], 0b0000_0010);
        assert_eq!(&report[31..37], &[1, 2, 3, 4, 5, 6]);
        assert_eq!(&report[37..39], &[0, 0]);
    }

    #[test]
    fn keyboard_usage_validation_matches_the_report_field_boundary() {
        assert_eq!(KeyboardUsage::new(239).unwrap().raw(), 239);
        assert_eq!(
            KeyboardUsage::new(240),
            Err(HidInputError::InvalidKeyboardUsage(240))
        );
        assert_eq!(
            KeyboardUsage::new(u16::MAX),
            Err(HidInputError::InvalidKeyboardUsage(u16::MAX))
        );
    }

    #[test]
    fn empty_keyboard_report_releases_every_usage() {
        let report = build_keyboard_report_at([], Some(0));

        assert_eq!(report[0], KEYBOARD_REPORT_ID);
        assert_eq!(&report[1..], &[0; 38]);
    }

    #[test]
    fn keyboard_report_encodes_more_than_six_non_modifier_keys() {
        let usages = (0x04..=0x0A).map(|usage| KeyboardUsage::new(usage).unwrap());
        let report = build_keyboard_report_at(usages, Some(0));

        assert_eq!(report[1], 0b1111_0000);
        assert_eq!(report[2], 0b0000_0111);
    }

    #[test]
    fn keyboard_service_request_matches_the_captured_codable_shape() {
        let config = KeyboardServiceConfiguration::default();

        let request = build_create_keyboard_service_request(&config);
        let payload = request
            .get("payload")
            .and_then(XPCObject::as_dictionary)
            .unwrap();
        let properties = payload
            .get("createService")
            .and_then(XPCObject::as_dictionary)
            .and_then(|tuple| tuple.get("_0"))
            .and_then(XPCObject::as_dictionary)
            .unwrap();
        let storage = properties
            .get("_CoreDevice_codablePropertyStorage")
            .and_then(XPCObject::as_dictionary)
            .unwrap();

        assert_eq!(
            request.get("featureIdentifier"),
            Some(&XPCObject::String(
                "com.apple.coredevice.feature.remote.universalhidservice".into()
            ))
        );
        assert_eq!(
            request.get("messageType"),
            Some(&XPCObject::String("Request".into()))
        );
        assert_eq!(
            properties.get("PrimaryUsagePage"),
            Some(&XPCObject::UInt64(1))
        );
        assert_eq!(properties.get("PrimaryUsage"), Some(&XPCObject::UInt64(6)));
        assert_eq!(
            storage
                .get("UniversalControlVirtualService")
                .and_then(XPCObject::as_dictionary)
                .and_then(|value| value.get("bool")),
            Some(&XPCObject::Bool(true))
        );
        assert_eq!(
            storage
                .get("ReportDescriptor")
                .and_then(XPCObject::as_dictionary)
                .and_then(|value| value.get("data")),
            Some(&XPCObject::Data(KEYBOARD_REPORT_DESCRIPTOR.to_vec()))
        );
        assert_eq!(
            storage
                .get("_ServiceID")
                .and_then(XPCObject::as_dictionary)
                .and_then(|value| value.get("uint")),
            Some(&XPCObject::UInt64(KEYBOARD_SURFACE_DEFAULT_SERVICE_ID))
        );
    }

    #[test]
    fn keyboard_service_response_uses_the_device_assigned_identifier() {
        let response = plist::Value::Dictionary(plist::Dictionary::from_iter([(
            String::from("serviceID"),
            plist::Value::Integer(0x1_0000_3001u64.into()),
        )]));

        assert_eq!(
            parse_created_keyboard_service_id(&response).unwrap(),
            0x1_0000_3001
        );
    }

    #[test]
    fn keyboard_service_response_rejects_missing_zero_or_mistyped_identifiers() {
        let responses = [
            plist_dictionary([]),
            plist_dictionary([("serviceID", plist::Value::Integer(0u64.into()))]),
            plist_dictionary([("serviceID", plist::Value::String("4097".into()))]),
            plist::Value::String("not a dictionary".into()),
        ];

        for response in responses {
            assert!(parse_created_keyboard_service_id(&response).is_err());
        }
    }

    #[test]
    fn keyboard_service_configuration_rejects_unsafe_metadata() {
        let configuration = KeyboardServiceConfiguration {
            service_id: 0,
            ..KeyboardServiceConfiguration::default()
        };
        assert_eq!(
            configuration.validate(),
            Err(HidInputError::InvalidServiceIdentifier)
        );

        let configuration = KeyboardServiceConfiguration {
            product: String::new(),
            ..KeyboardServiceConfiguration::default()
        };
        assert_eq!(
            configuration.validate(),
            Err(HidInputError::InvalidKeyboardMetadata("product"))
        );

        let configuration = KeyboardServiceConfiguration {
            product: "x".repeat(129),
            ..KeyboardServiceConfiguration::default()
        };
        assert_eq!(
            configuration.validate(),
            Err(HidInputError::InvalidKeyboardMetadata("product"))
        );

        let configuration = KeyboardServiceConfiguration {
            manufacturer: "line\nbreak".into(),
            ..KeyboardServiceConfiguration::default()
        };
        assert_eq!(
            configuration.validate(),
            Err(HidInputError::InvalidKeyboardMetadata("manufacturer"))
        );

        let configuration = KeyboardServiceConfiguration {
            product: "x".repeat(128),
            ..KeyboardServiceConfiguration::default()
        };
        assert!(configuration.validate().is_ok());
    }

    #[test]
    fn keyboard_state_requires_balanced_key_transitions_and_can_cancel() {
        let key = KeyboardUsage::new(0x04).unwrap();
        let mut state = KeyboardState::default();

        assert_eq!(state.press(key).unwrap(), [key].into_iter().collect());
        assert!(state.press(key).is_err());
        assert_eq!(state.release(key).unwrap(), [].into_iter().collect());
        assert!(state.release(key).is_err());

        state.press(key).unwrap();
        assert_eq!(state.cancel(), [].into_iter().collect());
        assert!(state.is_empty());

        let modifier = KeyboardUsage::new(0xE1).unwrap();
        assert_eq!(
            state.replace([key, modifier].into_iter().collect()),
            [key, modifier].into_iter().collect()
        );
        assert_eq!(
            state.replace([key].into_iter().collect()),
            [key].into_iter().collect()
        );
    }

    #[test]
    fn touch_state_enforces_down_move_up_and_cancel_sequences() {
        let start = TouchPoint::new(1, 2);
        let moved = TouchPoint::new(3, 4);
        let mut state = TouchState::default();

        assert!(state.transition(TouchEvent::Move(moved)).is_err());
        assert_eq!(
            state.transition(TouchEvent::Down(start)).unwrap(),
            TouchSample::contact(start)
        );
        assert!(state.transition(TouchEvent::Down(start)).is_err());
        assert_eq!(
            state.transition(TouchEvent::Move(moved)).unwrap(),
            TouchSample::contact(moved)
        );
        assert_eq!(
            state.transition(TouchEvent::Cancel).unwrap(),
            TouchSample::release(moved)
        );
        assert!(state.transition(TouchEvent::Up(moved)).is_err());
        assert!(!state.is_active());
    }

    #[test]
    fn touch_up_releases_at_the_reported_terminal_point() {
        let start = TouchPoint::new(0, u16::MAX);
        let end = TouchPoint::new(u16::MAX, 0);
        let mut state = TouchState::default();

        state.transition(TouchEvent::Down(start)).unwrap();
        assert_eq!(
            state.transition(TouchEvent::Up(end)).unwrap(),
            TouchSample::release(end)
        );
        assert!(!state.is_active());

        let report = build_touchscreen_report(TouchContactState::Release, end, Some(1));
        assert_eq!(&report[3..8], &[0x02, 0xFF, 0xFF, 0x00, 0x00]);
    }

    #[test]
    fn button_state_tracks_independent_buttons_and_cancellation() {
        let mut state = ButtonTracker::default();

        state
            .transition(HardwareButton::Home, ButtonState::Down)
            .unwrap();
        state
            .transition(HardwareButton::VolumeUp, ButtonState::Down)
            .unwrap();
        assert!(
            state
                .transition(HardwareButton::Home, ButtonState::Down)
                .is_err()
        );
        state
            .transition(HardwareButton::Home, ButtonState::Up)
            .unwrap();
        state
            .transition(HardwareButton::VolumeUp, ButtonState::Canceled)
            .unwrap();
        assert!(state.is_empty());
    }

    #[test]
    fn confirmed_hardware_button_uses_the_indigo_button_envelope() {
        let (page, usage) = HardwareButton::VolumeDown.usage();
        let request = build_indigo_button_request(page, usage, ButtonState::Canceled);
        let payload = request
            .get("payload")
            .and_then(XPCObject::as_dictionary)
            .unwrap();

        assert_eq!(
            request.get("messageType"),
            Some(&XPCObject::String("IndigoButtonEvent".into()))
        );
        assert_eq!(
            request.get("featureIdentifier"),
            Some(&XPCObject::String(
                "com.apple.coredevice.feature.remote.hid.button".into()
            ))
        );
        assert_eq!(payload.get("state"), Some(&XPCObject::UInt64(3)));
        assert_eq!(payload.get("usagePage"), Some(&XPCObject::UInt64(0x0C)));
        assert_eq!(payload.get("usageCode"), Some(&XPCObject::UInt64(0xEA)));
    }

    #[test]
    fn keyboard_edges_use_the_confirmed_indigo_keyboard_envelope() {
        let request = build_indigo_keyboard_request(0x27, ButtonState::Down);
        let payload = request
            .get("payload")
            .and_then(XPCObject::as_dictionary)
            .unwrap();

        assert_eq!(
            request.get("messageType"),
            Some(&XPCObject::String("IndigoKeyboardButtonEvent".into()))
        );
        assert_eq!(
            request.get("featureIdentifier"),
            Some(&XPCObject::String(
                "com.apple.coredevice.feature.remote.hid.keyboard".into()
            ))
        );
        assert_eq!(payload.get("state"), Some(&XPCObject::UInt64(1)));
        assert_eq!(payload.get("usageCode"), Some(&XPCObject::UInt64(0x27)));
    }

    #[test]
    fn named_hardware_button_usages_are_exact() {
        assert_eq!(
            [
                HardwareButton::Home.usage(),
                HardwareButton::Lock.usage(),
                HardwareButton::VolumeUp.usage(),
                HardwareButton::VolumeDown.usage(),
                HardwareButton::Mute.usage(),
                HardwareButton::Siri.usage(),
            ],
            [
                (0x0C, 0x40),
                (0x0C, 0x30),
                (0x0C, 0xE9),
                (0x0C, 0xEA),
                (0x0C, 0xE2),
                (0x0C, 0xCF),
            ]
        );
    }

    #[test]
    fn raw_button_usage_fields_are_bounded_to_uint16() {
        assert_eq!(narrow_usage("usageCode", 0).unwrap(), 0);
        assert_eq!(
            narrow_usage("usageCode", u64::from(u16::MAX)).unwrap(),
            u16::MAX
        );
        assert_eq!(
            narrow_usage("usageCode", u64::from(u16::MAX) + 1),
            Err(HidInputError::InvalidUsage {
                field: "usageCode",
                value: u64::from(u16::MAX) + 1,
            })
        );
    }

    #[test]
    fn universal_hid_report_uses_the_captured_swift_tuple_shape() {
        let request = build_send_report_request(257, vec![0x09, 0x01]);
        let send = request
            .get("payload")
            .and_then(XPCObject::as_dictionary)
            .and_then(|payload| payload.get("send"))
            .and_then(XPCObject::as_dictionary)
            .unwrap();

        assert_eq!(send.get("_0"), Some(&XPCObject::Data(vec![0x09, 0x01])));
        assert_eq!(send.get("_1"), Some(&XPCObject::UInt64(257)));
    }

    #[test]
    fn raw_report_validation_rejects_ambiguous_or_oversized_frames() {
        assert_eq!(
            validate_report(0, &[1]),
            Err(HidInputError::InvalidServiceIdentifier)
        );
        assert_eq!(validate_report(1, &[]), Err(HidInputError::EmptyReport));
        assert!(validate_report(1, &vec![0; u16::MAX as usize]).is_ok());
        assert_eq!(
            validate_report(1, &vec![0; u16::MAX as usize + 1]),
            Err(HidInputError::ReportTooLarge)
        );
    }

    #[test]
    fn connected_service_response_is_validated_before_exposure() {
        let response = connected_services(vec![
            surface(257, Some("mainTouchscreen"), Some(1), Some(2)),
            surface(1281, None, Some(1), None),
        ]);

        let parsed = parse_hid_surfaces(&response).unwrap();
        assert_eq!(parsed.len(), 2);
        assert_eq!(parsed[0].service_id, 257);
        assert_eq!(parsed[1].primary_usage_page, Some(1));
        assert_eq!(parsed[1].primary_usage, None);
    }

    #[test]
    fn connected_service_response_rejects_malformed_and_ambiguous_surfaces() {
        let malformed = [
            plist::Value::String("not a dictionary".into()),
            plist_dictionary([]),
            plist_dictionary([(
                "connectedServices",
                plist::Value::String("not an array".into()),
            )]),
            connected_services(vec![surface(0, None, None, None)]),
            connected_services(vec![
                surface(257, None, None, None),
                surface(257, None, None, None),
            ]),
            connected_services(vec![surface(257, Some("control\ncharacter"), None, None)]),
            connected_services(vec![surface(
                257,
                None,
                Some(u64::from(u16::MAX) + 1),
                None,
            )]),
            connected_services(
                (1..=257)
                    .map(|service_id| surface(service_id, None, None, None))
                    .collect(),
            ),
        ];

        for response in malformed {
            let error = parse_hid_surfaces(&response).unwrap_err();
            assert!(!error.to_string().contains("control\ncharacter"));
        }
    }

    #[test]
    fn drag_validation_bounds_sample_count_and_delay() {
        assert_eq!(
            validate_drag(0, 0),
            Err(HidInputError::InvalidDragStepCount)
        );
        assert!(validate_drag(1, 0).is_ok());
        assert!(validate_drag(1024, 1000).is_ok());
        assert_eq!(
            validate_drag(1025, 0),
            Err(HidInputError::InvalidDragStepCount)
        );
        assert_eq!(validate_drag(1, 1001), Err(HidInputError::InvalidDragDelay));
    }
}
