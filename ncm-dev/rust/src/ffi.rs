// SPDX-License-Identifier: GPL-3.0-only
//! Polling C ABI with integer handles, no callbacks or persistent keys.
//! Explicit start owns a worker/runtime; linking/ABI queries do no network I/O.
use crate::{
    Cause, Error, ExistingIdentity, NcmConnector, RelayConnector, RpPairingFile, Session, Stage,
    VerifiedPeerIdentity,
};
use std::{
    collections::HashMap,
    slice,
    sync::{
        Arc, Mutex, OnceLock,
        atomic::{AtomicBool, AtomicU64, AtomicUsize, Ordering},
    },
};
use tokio::sync::{OwnedSemaphorePermit, Semaphore, mpsc, watch};
use zeroize::{Zeroize, Zeroizing};
#[path = "pairing.rs"]
mod pairing;
const INVALID: i32 = 1;
const BUSY: i32 = 2;
const CLOSED: i32 = 3;
const EMPTY: i32 = 4;
const SMALL: i32 = 5;
const NOT_READY: i32 = 6;
const SCREEN: u32 = 1;
const MEDIA: u32 = 2;
const INPUT: u32 = 4;
const VERIFY: u32 = 8;
#[repr(C)]
pub struct Bytes {
    data: *const u8,
    size: usize,
}
#[repr(C)]
pub struct Identity {
    seed: Bytes,
    controller_id: Bytes,
    peer_id: Bytes,
    peer_public_key: Bytes,
    alt_irk: Bytes,
    peer_udid: Bytes,
    peer_model: Bytes,
}
#[repr(C)]
pub struct Config {
    abi: u32,
    interface_index: u32,
    generation: u32,
    endpoint_index: u32,
    permissions: u32,
}
#[repr(C)]
#[derive(Default, Clone, Copy)]
pub struct EventHeader {
    request_id: u64,
    kind: u32,
    stage: u32,
    cause: u32,
    reserved: u32,
    size: usize,
}
struct Event {
    header: EventHeader,
    data: Vec<u8>,
    credit: Option<OwnedSemaphorePermit>,
}
impl Drop for Event {
    fn drop(&mut self) {
        self.data.zeroize();
    }
}
impl Event {
    fn ok(id: u64, kind: u32, data: Vec<u8>) -> Self {
        Self {
            header: EventHeader {
                request_id: id,
                kind,
                size: data.len(),
                ..Default::default()
            },
            data,
            credit: None,
        }
    }
    fn failed(id: u64, e: Error) -> Self {
        Self {
            header: EventHeader {
                request_id: id,
                kind: 3,
                stage: e.stage as u32 + 1,
                cause: e.cause as u32 + 1,
                ..Default::default()
            },
            data: Vec::new(),
            credit: None,
        }
    }
}
#[derive(Clone)]
struct Request {
    id: u64,
    action: u32,
    x: u16,
    y: u16,
    end_x: u16,
    end_y: u16,
    duration: u16,
    payload: Zeroizing<Vec<u8>>,
    expected_geometry: Option<u64>,
}
struct Receiver {
    pending: Option<Event>,
    queue: mpsc::Receiver<Event>,
}
struct Entry {
    pairing: bool,
    pairing_state: AtomicUsize,
    submit: Mutex<(u64, mpsc::Sender<Request>)>,
    receive: Mutex<Receiver>,
    cancel: watch::Sender<bool>,
    ready: AtomicBool,
    done: AtomicBool,
    video: Arc<crate::video::VideoMailbox>,
    screen_allowed: bool,
}
static ENTRIES: OnceLock<Mutex<HashMap<u64, Arc<Entry>>>> = OnceLock::new();
static NEXT: AtomicU64 = AtomicU64::new(1);
static WORKERS: AtomicUsize = AtomicUsize::new(0);
fn registry() -> &'static Mutex<HashMap<u64, Arc<Entry>>> {
    ENTRIES.get_or_init(|| Mutex::new(HashMap::new()))
}
fn get(id: u64) -> Option<Arc<Entry>> {
    registry().lock().ok()?.get(&id).cloned()
}
fn protect(f: impl FnOnce() -> i32) -> i32 {
    std::panic::catch_unwind(std::panic::AssertUnwindSafe(f)).unwrap_or(INVALID)
}
unsafe fn bytes<'a>(b: &Bytes, limit: usize) -> Result<&'a [u8], i32> {
    if b.data.is_null() || b.size == 0 || b.size > limit {
        return Err(INVALID);
    }
    Ok(unsafe { slice::from_raw_parts(b.data, b.size) })
}
unsafe fn text(b: &Bytes) -> Result<String, i32> {
    let b = unsafe { bytes(b, 256) }?;
    if b.contains(&0) {
        return Err(INVALID);
    }
    std::str::from_utf8(b)
        .map(str::to_owned)
        .map_err(|_| INVALID)
}
unsafe fn identity(raw: &Identity) -> Result<ExistingIdentity, i32> {
    let seed = Zeroizing::new(
        <[u8; 32]>::try_from(unsafe { bytes(&raw.seed, 32) }?).map_err(|_| INVALID)?,
    );
    let key = ed25519_dalek::SigningKey::from_bytes(&seed);
    let alt = unsafe { bytes(&raw.alt_irk, 16) }?.to_vec();
    if alt.len() != 16 {
        return Err(INVALID);
    }
    let peer_id = unsafe { text(&raw.peer_id) }?;
    let id = ExistingIdentity {
        controller: RpPairingFile {
            identifier: unsafe { text(&raw.controller_id) }?,
            e_public_key: key.verifying_key(),
            e_private_key: key,
            alt_irk: Some(alt.clone()),
        },
        peer: VerifiedPeerIdentity {
            pairing_identifier: peer_id.clone(),
            long_term_public_key: unsafe { bytes(&raw.peer_public_key, 32) }?
                .try_into()
                .map_err(|_| INVALID)?,
            peer: idevice::remote_pairing::PeerDevice {
                account_id: peer_id,
                alt_irk: alt,
                name: String::new(),
                remotepairing_udid: unsafe { text(&raw.peer_udid) }?,
                model: unsafe { text(&raw.peer_model) }?,
            },
        },
    };
    id.validate().map_err(|_| INVALID)?;
    Ok(id)
}
fn launch(
    connector: impl NcmConnector + 'static,
    mut identity: ExistingIdentity,
    permissions: u32,
) -> Result<u64, i32> {
    WORKERS
        .fetch_update(Ordering::SeqCst, Ordering::SeqCst, |n| {
            (n < 2).then_some(n + 1)
        })
        .map_err(|_| BUSY)?;
    let (tx, mut rx) = mpsc::channel::<Request>(1);
    let (events, queue) = mpsc::channel(1);
    let (cancel, mut cancelled) = watch::channel(false);
    let entry = Arc::new(Entry {
        pairing: false,
        pairing_state: AtomicUsize::new(0),
        submit: Mutex::new((0, tx)),
        receive: Mutex::new(Receiver {
            pending: None,
            queue,
        }),
        cancel,
        ready: AtomicBool::new(false),
        done: AtomicBool::new(false),
        video: Arc::new(crate::video::VideoMailbox::default()),
        screen_allowed: permissions & SCREEN != 0,
    });
    let id = NEXT.fetch_add(1, Ordering::SeqCst);
    if id == 0 {
        WORKERS.fetch_sub(1, Ordering::SeqCst);
        return Err(BUSY);
    }
    {
        let mut entries = registry().lock().map_err(|_| INVALID)?;
        if entries.len() >= 2 {
            WORKERS.fetch_sub(1, Ordering::SeqCst);
            return Err(BUSY);
        }
        entries.insert(id, entry.clone());
    }
    let worker_entry = entry.clone();
    let spawn = std::thread::Builder::new()
        .name("ncm-backend".into())
        .spawn(move || {
            struct Finished(Arc<Entry>);
            impl Drop for Finished {
                fn drop(&mut self) {
                    self.0.done.store(true, Ordering::SeqCst);
                    self.0.ready.store(false, Ordering::SeqCst);
                    WORKERS.fetch_sub(1, Ordering::SeqCst);
                }
            }
            let _finished = Finished(worker_entry.clone());
            let Ok(runtime) = tokio::runtime::Builder::new_current_thread()
                .enable_all()
                .build()
            else {
                return;
            };
            runtime.block_on(async {
                let work = async {
                    let connection = Session::connect(&connector, &mut identity).await;
                    drop(identity); // long-term signing seed no longer needed after PairVerify.
                    let mut session = match connection {
                        Ok(s) => s,
                        Err(e) => {
                            let _ = events.send(Event::failed(0, e)).await;
                            return;
                        }
                    };
                    session.video = worker_entry.video.clone();
                    let credit = Arc::new(Semaphore::new(1));
                    let names = session
                        .services()
                        .unwrap_or_default()
                        .into_iter()
                        .map(|s| s.name)
                        .collect::<Vec<_>>();
                    worker_entry.ready.store(true, Ordering::SeqCst);
                    let mut ready = Event::ok(0, 1, serde_json::to_vec(&names).unwrap_or_default());
                    ready.credit = credit.clone().acquire_owned().await.ok();
                    if events.send(ready).await.is_err() {
                        return;
                    }
                    while let Some(request) = rx.recv().await {
                        let permit = credit.clone().acquire_owned().await.ok();
                        let mut response = execute(&mut session, request, permissions).await;
                        response.credit = permit;
                        if events.send(response).await.is_err() {
                            break;
                        }
                    }
                };
                tokio::select! {biased;_ = cancelled.changed()=>{},_ = work=>{}}
            });
            // Dropping this owned runtime cancels every spawned adapter/media task;
            // all native sockets are owned by those tasks, never leaked to a global runtime.
        });
    if spawn.is_err() {
        registry().lock().map_err(|_| INVALID)?.remove(&id);
        WORKERS.fetch_sub(1, Ordering::SeqCst);
        return Err(INVALID);
    }
    Ok(id)
}
// Independent ordinary Lockdown worker: no RP identity, discovery or control actions.
fn launch_lockdown(
    connector: impl NcmConnector + 'static,
    identity: crate::lockdown::ExistingIdentity,
) -> Result<u64, i32> {
    WORKERS
        .fetch_update(Ordering::SeqCst, Ordering::SeqCst, |n| {
            (n < 2).then_some(n + 1)
        })
        .map_err(|_| BUSY)?;
    let (tx, mut rx) = mpsc::channel::<Request>(1);
    let (events, queue) = mpsc::channel(1);
    let (cancel, mut cancelled) = watch::channel(false);
    let entry = Arc::new(Entry {
        pairing: false,
        pairing_state: AtomicUsize::new(0),
        submit: Mutex::new((0, tx)),
        receive: Mutex::new(Receiver {
            pending: None,
            queue,
        }),
        cancel,
        ready: AtomicBool::new(false),
        done: AtomicBool::new(false),
        video: Arc::new(crate::video::VideoMailbox::default()),
        screen_allowed: false,
    });
    let id = NEXT.fetch_add(1, Ordering::SeqCst);
    {
        let mut entries = registry().lock().map_err(|_| INVALID)?;
        if id == 0 || entries.len() >= 2 {
            WORKERS.fetch_sub(1, Ordering::SeqCst);
            return Err(BUSY);
        }
        entries.insert(id, entry.clone());
    }
    let spawn = std::thread::Builder::new()
        .name("ncm-lockdown".into())
        .spawn(move || {
            struct Finished(Arc<Entry>);
            impl Drop for Finished {
                fn drop(&mut self) {
                    self.0.done.store(true, Ordering::SeqCst);
                    self.0.ready.store(false, Ordering::SeqCst);
                    WORKERS.fetch_sub(1, Ordering::SeqCst);
                }
            }
            let _finished = Finished(entry.clone());
            let Ok(runtime) = tokio::runtime::Builder::new_current_thread()
                .enable_all()
                .build()
            else {
                return;
            };
            runtime.block_on(async {
                let work = async {
                    let connected = crate::lockdown::Session::connect(&connector, &identity).await;
                    drop(identity);
                    let mut session = match connected {
                        Ok(s) => s,
                        Err(e) => {
                            let _ = events.send(lockdown_failure(0, e)).await;
                            return;
                        }
                    };
                    let credit = Arc::new(Semaphore::new(1));
                    entry.ready.store(true, Ordering::SeqCst);
                    let mut ready = Event::ok(0, 2, Vec::new());
                    ready.credit = credit.clone().acquire_owned().await.ok();
                    if events.send(ready).await.is_err() {
                        return;
                    }
                    while let Some(request) = rx.recv().await {
                        let permit = credit.clone().acquire_owned().await.ok();
                        let mut reply = if request.action == 5 {
                            session
                                .stop()
                                .await
                                .map(|_| Event::ok(request.id, 2, Vec::new()))
                                .unwrap_or_else(|e| lockdown_failure(request.id, e))
                        } else {
                            lockdown_failure(request.id, crate::lockdown::Failure::Closed)
                        };
                        reply.credit = permit;
                        if events.send(reply).await.is_err() || request.action == 5 {
                            return;
                        }
                    }
                };
                tokio::select! {biased;_=cancelled.changed()=>{},_=work=>{}}
            });
        });
    if spawn.is_err() {
        registry().lock().map_err(|_| INVALID)?.remove(&id);
        WORKERS.fetch_sub(1, Ordering::SeqCst);
        return Err(INVALID);
    }
    Ok(id)
}
fn lockdown_failure(id: u64, e: crate::lockdown::Failure) -> Event {
    Event {
        header: EventHeader {
            request_id: id,
            kind: 3,
            stage: e as u32 + 101,
            cause: 1,
            ..Default::default()
        },
        data: Vec::new(),
        credit: None,
    }
}
/// # Safety
/// Byte slices must be valid for this call; handle must be writable. Input is copied
/// synchronously. No file lookup, new pairing, screenshots, media or RP fallback.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn ncm_lockdown_start(
    interface_index: u32,
    permissions: u32,
    record: Bytes,
    udid: Bytes,
    handle: *mut u64,
) -> i32 {
    protect(|| {
        if handle.is_null() {
            return INVALID;
        }
        unsafe {
            *handle = 0;
        }
        if interface_index == 0 || permissions != VERIFY {
            return INVALID;
        }
        let input = match unsafe { bytes(&record, 1024 * 1024) } {
            Ok(b) => b,
            Err(e) => return e,
        };
        let udid = match unsafe { text(&udid) } {
            Ok(t) => t,
            Err(e) => return e,
        };
        let identity = match crate::lockdown::ExistingIdentity::from_plist(input, &udid) {
            Ok(i) => i,
            Err(_) => return INVALID,
        };
        let connector = match RelayConnector::new_lockdown(interface_index) {
            Ok(c) => c,
            Err(_) => return INVALID,
        };
        match launch_lockdown(connector, identity) {
            Ok(id) => {
                unsafe {
                    *handle = id;
                }
                0
            }
            Err(e) => e,
        }
    })
}
fn request_geometry_valid(r: &Request, video: &crate::video::VideoMailbox) -> bool {
    r.expected_geometry.is_none_or(|g| video.matches_geometry(g))
}
async fn execute(session: &mut Session, r: Request, permissions: u32) -> Event {
    let required = match r.action {
        1 | 11 => 0,
        2 => SCREEN,
        3 => MEDIA,
        4 | 6 | 7 | 9 | 10 => INPUT,
        8 => VERIFY,
        _ => u32::MAX,
    };
    if permissions & required != required {
        return Event::failed(
            r.id,
            Error {
                stage: match r.action {
                    2 => Stage::Screenshot,
                    3 => Stage::Media,
                    _ => Stage::Input,
                },
                cause: Cause::Unprepared,
            },
        );
    }
    if !request_geometry_valid(&r, &session.video) {
        return Event::failed(r.id, Error { stage: Stage::Input, cause: Cause::InvalidParameters });
    }
    let result = match r.action {
        1 => session
            .check_developer_readiness()
            .await
            .map(|_| Event::ok(r.id, 2, Vec::new())),
        11 => session
            .stop_touch_media()
            .await
            .map(|_| Event::ok(r.id, 2, Vec::new())),
        2 => session
            .screenshot()
            .await
            .map(|s| Event::ok(r.id, 4, s.png)),
        3 => session
            .start_touch_media()
            .await
            .map(|_| Event::ok(r.id, 2, Vec::new())),
        4 => session
            .tap_guarded(r.x, r.y, r.expected_geometry)
            .await
            .map(|_| Event::ok(r.id, 2, Vec::new())),
        6 => session
            .drag_guarded(r.x, r.y, r.end_x, r.end_y, r.duration, r.expected_geometry)
            .await
            .map(|_| Event::ok(r.id, 2, Vec::new())),
        7 => session.home().await.map(|_| Event::ok(r.id, 2, Vec::new())),
        8 => session
            .list_apps()
            .await
            .map(|apps| Event::ok(r.id, 11, apps)),
        9 | 10 => {
            let p: serde_json::Value =
                serde_json::from_slice(&r.payload).expect("validated payload");
            if r.action == 9 {
                let args: Vec<String> = p["arguments"]
                    .as_array()
                    .expect("validated arguments")
                    .iter()
                    .map(|v| v.as_str().unwrap().to_owned())
                    .collect();
                session
                    .launch_app(p["bundle_id"].as_str().unwrap(), &args)
                    .await
                    .map(|_| Event::ok(r.id, 2, Vec::new()))
            } else {
                session
                    .type_text(p["text"].as_str().unwrap())
                    .await
                    .map(|_| Event::ok(r.id, 2, Vec::new()))
            }
        }
        _ => Err(Error {
            stage: Stage::Closed,
            cause: Cause::InvalidParameters,
        }),
    };
    result.unwrap_or_else(|e| {
        let mut event = Event::failed(r.id, e);
        // Failed preparation has emitted no HID reports and retains the session.
        if r.action == 3 {
            event.header.kind = 10;
        } else if r.action == 8 {
            event.header.kind = 12;
        }
        event
    })
}
/// # Safety
/// `status` must be writable. Counters only, never packet bytes or credentials.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn ncm_backend_video_get_status(
    handle: u64,
    status: *mut crate::video::VideoStatus,
) -> i32 {
    protect(|| {
        if status.is_null() {
            return INVALID;
        }
        let Some(entry) = get(handle) else {
            return CLOSED;
        };
        if !entry.screen_allowed {
            return NOT_READY;
        }
        if entry.done.load(Ordering::SeqCst) {
            return CLOSED;
        }
        unsafe {
            *status = entry.video.status();
        }
        0
    })
}
/// # Safety
/// `status` must be writable. Counters only, never packet bytes or credentials.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn ncm_backend_video_get_snapshot(
    handle: u64,
    status: *mut crate::video::VideoSnapshot,
) -> i32 {
    protect(|| {
        if status.is_null() {
            return INVALID;
        }
        let Some(entry) = get(handle) else {
            return CLOSED;
        };
        if !entry.screen_allowed {
            return NOT_READY;
        }
        if entry.done.load(Ordering::SeqCst) {
            return CLOSED;
        }
        unsafe {
            *status = entry.video.snapshot();
        }
        0
    })
}
/// Additive ABI: nonzero per-handle credential; no struct layout changes.
#[unsafe(no_mangle)]
pub extern "C" fn ncm_backend_video_geometry_generation(handle: u64) -> u64 {
    get(handle).filter(|e| e.screen_allowed && !e.done.load(Ordering::SeqCst))
        .map(|e| e.video.geometry_generation()).unwrap_or(0)
}
/// Swift publishes a changed decoded crop using this in-memory invalidation only.
#[unsafe(no_mangle)]
pub extern "C" fn ncm_backend_video_invalidate_geometry(handle: u64) -> u64 {
    get(handle).filter(|e| e.screen_allowed && !e.done.load(Ordering::SeqCst))
        .map(|e| e.video.invalidate_geometry()).unwrap_or(0)
}
/// Bind a decoder observation to the exact sample emitted by video_poll.
#[unsafe(no_mangle)]
pub extern "C" fn ncm_backend_video_sample_geometry(handle: u64, serial: u64, epoch: u64) -> u64 {
    get(handle).filter(|e| e.screen_allowed && !e.done.load(Ordering::SeqCst))
        .map(|e| e.video.sample_geometry(serial, epoch)).unwrap_or(0)
}
#[unsafe(no_mangle)]
pub extern "C" fn ncm_backend_video_publish_geometry(handle: u64, expected: u64) -> u64 {
    get(handle).filter(|e| e.screen_allowed && !e.done.load(Ordering::SeqCst))
        .map(|e| e.video.publish_decoded_geometry(expected)).unwrap_or(0)
}
/// Request one fresh keyframe on the already authorized video channel.
#[unsafe(no_mangle)]
pub extern "C" fn ncm_backend_video_refresh(handle: u64) -> i32 {
    let Some(entry) = get(handle) else {
        return CLOSED;
    };
    if !entry.screen_allowed {
        return NOT_READY;
    }
    if entry.done.load(Ordering::SeqCst) {
        return CLOSED;
    }
    entry.video.request_refresh();
    0
}
/// # Safety
/// The output header and optional byte buffer must be writable for capacity bytes.
/// Independent bounded video channel; never consumes command receipts.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn ncm_backend_video_poll(
    handle: u64,
    event: *mut EventHeader,
    buffer: *mut u8,
    capacity: usize,
) -> i32 {
    protect(|| {
        if event.is_null() {
            return INVALID;
        }
        let Some(entry) = get(handle) else {
            return CLOSED;
        };
        if !entry.screen_allowed {
            return NOT_READY;
        }
        if entry.done.load(Ordering::SeqCst) {
            return CLOSED;
        }
        let (kind, size, data) = entry
            .video
            .poll(if buffer.is_null() { 0 } else { capacity });
        unsafe {
            *event = EventHeader {
                kind,
                size,
                ..Default::default()
            };
        }
        if kind == 0 {
            return EMPTY;
        }
        let Some(data) = data else {
            return SMALL;
        };
        if !data.is_empty() {
            unsafe {
                std::ptr::copy_nonoverlapping(data.as_ptr(), buffer, data.len());
            }
        }
        0
    })
}
#[unsafe(no_mangle)]
pub extern "C" fn ncm_backend_abi() -> u32 {
    1
}
/// # Safety
/// Non-null pointers must reference valid, readable C structs/byte buffers for
/// this call; handle must be writable. Bytes are copied synchronously.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn ncm_backend_start(
    config: *const Config,
    raw: *const Identity,
    handle: *mut u64,
) -> i32 {
    protect(|| {
        if config.is_null() || raw.is_null() || handle.is_null() {
            return INVALID;
        }
        unsafe { *handle = 0 };
        let config = unsafe { &*config };
        if config.abi != 1
            || config.endpoint_index >= 16
            || config.permissions & VERIFY == 0
            || config.permissions & !15 != 0
        {
            return INVALID;
        }
        let id = match unsafe { identity(&*raw) } {
            Ok(id) => id,
            Err(e) => return e,
        };
        let connector = match RelayConnector::new(
            config.interface_index,
            config.generation,
            config.endpoint_index as u8,
        ) {
            Ok(c) => c,
            Err(_) => return INVALID,
        };
        match launch(connector, id, config.permissions) {
            Ok(id) => {
                unsafe { *handle = id };
                0
            }
            Err(e) => e,
        }
    })
}
/// Start through the default VPN loopback interface; authorization and identity
/// validation are identical to the S3 path. Port comes from local Bonjour only.
/// # Safety
/// raw and handle must reference readable/writable C values for this call.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn ncm_local_vpn_start(
    interface_index: u32,
    pairing_port: u16,
    permissions: u32,
    raw: *const Identity,
    handle: *mut u64,
) -> i32 {
    unsafe { ncm_local_vpn_start_configured(interface_index, pairing_port, permissions,
        0x0a070101, 0x0a070001, raw, handle) }
}
/// # Safety
/// Same pointer contract as ncm_local_vpn_start; addresses are host integers in address order.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn ncm_local_vpn_start_configured(
    interface_index: u32, pairing_port: u16, permissions: u32,
    local_ipv4: u32, peer_ipv4: u32, raw: *const Identity, handle: *mut u64,
) -> i32 {
    protect(|| {
        if raw.is_null() || handle.is_null() {
            return INVALID;
        }
        unsafe { *handle = 0 };
        if permissions & VERIFY == 0 || permissions & !15 != 0 {
            return INVALID;
        }
        let id = match unsafe { identity(&*raw) } {
            Ok(id) => id,
            Err(e) => return e,
        };
        let connector =
            match crate::local_vpn::LocalVPNConnector::configured(interface_index, pairing_port,
                std::net::Ipv4Addr::from(local_ipv4), std::net::Ipv4Addr::from(peer_ipv4)) {
                Ok(c) => c,
                Err(_) => return INVALID,
            };
        match launch(connector, id, permissions) {
            Ok(id) => {
                unsafe { *handle = id };
                0
            }
            Err(e) => e,
        }
    })
}
#[unsafe(no_mangle)]
pub extern "C" fn ncm_backend_submit(handle: u64, id: u64, action: u32, x: u16, y: u16) -> i32 {
    if !(1..=5).contains(&action) && action != 7 && action != 8 && action != 11 {
        return INVALID;
    }
    submit_request(
        handle,
        Request {
            id,
            action,
            x,
            y,
            end_x: 0,
            end_y: 0,
            duration: 0,
            expected_geometry: None,
            payload: Zeroizing::new(Vec::new()),
        },
    )
}
#[unsafe(no_mangle)]
pub extern "C" fn ncm_backend_drag(
    handle: u64,
    id: u64,
    x: u16,
    y: u16,
    end_x: u16,
    end_y: u16,
    duration: u16,
) -> i32 {
    if !(100..=2000).contains(&duration) {
        return INVALID;
    }
    submit_request(
        handle,
        Request {
            id,
            action: 6,
            x,
            y,
            end_x,
            end_y,
            duration,
            expected_geometry: None,
            payload: Zeroizing::new(Vec::new()),
        },
    )
}
/// V2 coordinate input carries its capture credential through the native queue.
#[unsafe(no_mangle)]
pub extern "C" fn ncm_backend_input_guarded(handle: u64, id: u64, action: u32,
    x: u16, y: u16, end_x: u16, end_y: u16, duration: u16, expected_geometry: u64) -> i32 {
    if expected_geometry == 0 || ![4, 6].contains(&action)
        || (action == 6 && !(100..=2000).contains(&duration)) { return INVALID; }
    submit_request(handle, Request { id, action, x, y, end_x, end_y, duration,
        expected_geometry: Some(expected_geometry), payload: Zeroizing::new(Vec::new()) })
}
fn valid_command(action: u32, bytes: &[u8]) -> bool {
    if bytes.len() > 16 * 1024 {
        return false;
    }
    let Ok(p) = serde_json::from_slice::<serde_json::Value>(bytes) else {
        return false;
    };
    let valid_text = |s: &str| !s.is_empty() && !s.contains('\0');
    match action {
        9 => {
            p["bundle_id"].as_str().is_some_and(|s| {
                valid_text(s)
                    && s.len() <= 256
                    && s.bytes()
                        .all(|c| c.is_ascii_alphanumeric() || b".-_".contains(&c))
            }) && p["arguments"].as_array().is_some_and(|a| {
                a.len() <= 32
                    && a.iter().all(|v| {
                        v.as_str()
                            .is_some_and(|s| s.len() <= 1024 && !s.contains('\0'))
                    })
            })
        }
        10 => p["text"]
            .as_str()
            .is_some_and(|s| crate::valid_input_text(s)),
        _ => false,
    }
}
/// # Safety
/// Payload is a readable UTF-8 JSON buffer, copied synchronously and cleared on drop.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn ncm_backend_command(
    handle: u64,
    id: u64,
    action: u32,
    payload: Bytes,
) -> i32 {
    protect(|| {
        let Ok(data) = (unsafe { bytes(&payload, 16 * 1024) }) else {
            return INVALID;
        };
        if !valid_command(action, data) {
            return INVALID;
        }
        submit_request(
            handle,
            Request {
                id,
                action,
                x: 0,
                y: 0,
                end_x: 0,
                end_y: 0,
                duration: 0,
                expected_geometry: None,
                payload: Zeroizing::new(data.to_vec()),
            },
        )
    })
}
fn submit_request(handle: u64, request: Request) -> i32 {
    let id = request.id;
    protect(|| {
        if id == 0 {
            return INVALID;
        }
        let Some(entry) = get(handle) else {
            return CLOSED;
        };
        if entry.pairing {
            return INVALID;
        }
        if entry.done.load(Ordering::SeqCst) {
            return CLOSED;
        }
        if !entry.ready.load(Ordering::SeqCst) {
            return NOT_READY;
        }
        let Ok(mut submit) = entry.submit.lock() else {
            return INVALID;
        };
        if id <= submit.0 {
            return INVALID;
        }
        match submit.1.try_send(request) {
            Ok(()) => {
                submit.0 = id;
                0
            }
            Err(mpsc::error::TrySendError::Full(_)) => BUSY,
            Err(_) => CLOSED,
        }
    })
}
/// # Safety
/// header must be writable; non-null buffer must be writable for capacity bytes.
/// Passing null/zero is a size query. A SMALL result retains the event.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn ncm_backend_poll(
    handle: u64,
    header: *mut EventHeader,
    buffer: *mut u8,
    capacity: usize,
) -> i32 {
    protect(|| {
        if header.is_null() || capacity > 64 * 1024 * 1024 {
            return INVALID;
        }
        unsafe { *header = EventHeader::default() };
        let Some(entry) = get(handle) else {
            return CLOSED;
        };
        let Ok(mut receive) = entry.receive.lock() else {
            return INVALID;
        };
        if receive.pending.is_none() {
            match receive.queue.try_recv() {
                Ok(e) => receive.pending = Some(e),
                Err(mpsc::error::TryRecvError::Empty) => {
                    return if entry.done.load(Ordering::SeqCst) {
                        CLOSED
                    } else {
                        EMPTY
                    };
                }
                Err(_) => return CLOSED,
            }
        }
        let e = receive.pending.as_ref().unwrap();
        unsafe { *header = e.header };
        if e.data.len() > capacity || (!e.data.is_empty() && buffer.is_null()) {
            return SMALL;
        }
        if !e.data.is_empty() {
            unsafe { std::ptr::copy_nonoverlapping(e.data.as_ptr(), buffer, e.data.len()) };
        }
        receive.pending.take();
        0
    })
}
#[unsafe(no_mangle)]
pub extern "C" fn ncm_backend_close(handle: u64) {
    let _ = protect(|| {
        if let Some(entry) = registry().lock().ok().and_then(|mut r| r.remove(&handle)) {
            let _ = entry.cancel.send(true);
        }
        0
    });
}
#[cfg(any(test, feature = "offline-fixtures"))]
fn fixture_identity() -> ExistingIdentity {
    let key = ed25519_dalek::SigningKey::from_bytes(&[0x42; 32]);
    ExistingIdentity {
        controller: RpPairingFile {
            identifier: "SYNTHETIC-CONTROLLER".into(),
            e_public_key: key.verifying_key(),
            e_private_key: key,
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
                name: String::new(),
                remotepairing_udid: "SYNTHETIC-UDID".into(),
            },
        },
    }
}
// Public synthetic sample only; this export never exists in device archives.
#[cfg(feature = "offline-fixtures")]
#[unsafe(no_mangle)]
pub unsafe extern "C" fn ncm_test_start_video_burst(
    sample: Bytes,
    continuous: u32,
    handle: *mut u64,
) -> i32 {
    protect(|| {
        let Ok(data) = (unsafe { bytes(&sample, 4096) }) else {
            return INVALID;
        };
        if data.len() < 64 {
            return INVALID;
        }
        let n = |offset: usize| u32::from_le_bytes(data[offset..offset + 4].try_into().unwrap());
        let (width, height) = (n(40), n(44));
        let lengths = [
            n(48) as usize,
            n(52) as usize,
            n(56) as usize,
            n(60) as usize,
        ];
        if n(36) != 1
            || width == 0
            || height == 0
            || width > 256
            || height > 256
            || lengths.iter().any(|n| *n == 0)
            || lengths.iter().sum::<usize>() + 64 != data.len()
        {
            return INVALID;
        }
        let mut offset = 64;
        let mut fields = Vec::new();
        for len in lengths {
            fields.push(data[offset..offset + len].to_vec());
            offset += len;
        }
        let params = idevice::core_device::display_stream::HevcParameterSets {
            revision: 1,
            pixel_width: width,
            pixel_height: height,
            video_parameter_set: fields[0].clone(),
            sequence_parameter_set: fields[1].clone(),
            picture_parameter_set: fields[2].clone(),
        };
        let unit = idevice::core_device::display_stream::HevcAccessUnit {
            ssrc: 7,
            rtp_timestamp: n(32),
            first_sequence_number: 1,
            last_sequence_number: 1,
            parameter_set_revision: 1,
            is_sync: true,
            bytes: fields[3].clone(),
        };
        unsafe { start_media_fixture(handle, Some((unit, params)), continuous != 0) }
    })
}

// Synthetic ABI ownership fixture, compiled out of every device archive.
#[cfg(feature = "offline-fixtures")]
/// # Safety
/// handle must be writable; no network or credentials are accessed.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn ncm_test_start_media_failure(handle: *mut u64) -> i32 {
    unsafe { start_media_fixture(handle, None, false) }
}
#[cfg(feature = "offline-fixtures")]
unsafe fn start_media_fixture(
    handle: *mut u64,
    burst: Option<(
        idevice::core_device::display_stream::HevcAccessUnit,
        idevice::core_device::display_stream::HevcParameterSets,
    )>,
    continuous: bool,
) -> i32 {
    protect(|| {
        if handle.is_null() {
            return INVALID;
        }
        unsafe {
            *handle = 0;
        }
        let (tx, mut rx) = mpsc::channel::<Request>(1);
        let (events, queue) = mpsc::channel(1);
        let (cancel, mut cancelled) = watch::channel(false);
        let entry = Arc::new(Entry {
            pairing: false,
            pairing_state: AtomicUsize::new(0),
            submit: Mutex::new((0, tx)),
            receive: Mutex::new(Receiver {
                pending: None,
                queue,
            }),
            cancel,
            ready: AtomicBool::new(true),
            done: AtomicBool::new(false),
            video: Arc::new(crate::video::VideoMailbox::default()),
            screen_allowed: burst.is_some(),
        });
        let id = NEXT.fetch_add(1, Ordering::SeqCst);
        registry().lock().unwrap().insert(id, entry.clone());
        let spawn = std::thread::Builder::new().spawn(move || {
            let runtime = tokio::runtime::Builder::new_current_thread()
                .enable_all()
                .build()
                .unwrap();
            runtime.block_on(async {
                let work = async {
                    if events.send(Event::ok(0, 1, b"[]".to_vec())).await.is_err() {
                        return;
                    }
                    let mut fixture_media: Option<tokio::task::JoinHandle<()>> = None;
                    while let Some(request) = rx.recv().await {
                        let event = match request.action {
                            2 => Event::failed(
                                request.id,
                                Error {
                                    stage: Stage::ScreenshotConnection,
                                    cause: Cause::Protocol,
                                },
                            ),
                            3 if burst.is_some() => {
                                if let Some(task) = fixture_media.take() {
                                    task.abort();
                                }
                                let (unit, params) = burst.as_ref().unwrap();
                                entry.video.begin_stream();
                                for _ in 0..1000 {
                                    entry.video.push(unit.clone(), params.clone());
                                    let mut inter = unit.clone();
                                    inter.is_sync = false;
                                    entry.video.push(inter, params.clone());
                                }
                                let (mut inter, params) = (unit.clone(), params.clone());
                                inter.is_sync = false;
                                let media_entry = entry.clone();
                                fixture_media = Some(tokio::spawn(async move {
                                    let began = tokio::time::Instant::now();
                                    loop {
                                        tokio::time::sleep(std::time::Duration::from_millis(40))
                                            .await;
                                        if continuous {
                                            media_entry.video.push(inter.clone(), params.clone());
                                        } else if began.elapsed() < std::time::Duration::from_secs(3) {
                                            // Healthy idle peer: progress reports, no new pictures.
                                            media_entry.video.sender_report(true);
                                        }
                                    }
                                }));
                                Event::ok(request.id, 2, Vec::new())
                            }
                            11 => {
                                if let Some(task) = fixture_media.take() {
                                    task.abort();
                                }
                                entry.video.reset();
                                Event::ok(request.id, 2, Vec::new())
                            }
                            3 => {
                                let mut e = Event::failed(
                                    request.id,
                                    Error {
                                        stage: Stage::VideoNegotiation,
                                        cause: Cause::Timeout,
                                    },
                                );
                                e.header.kind = 10;
                                e
                            }
                            4 | 6 => Event::failed(
                                request.id,
                                Error {
                                    stage: Stage::Input,
                                    cause: Cause::DeliveryUncertain,
                                },
                            ),
                            _ => Event::ok(request.id, 2, Vec::new()),
                        };
                        if events.send(event).await.is_err() {
                            return;
                        }
                    }
                };
                tokio::select! { biased; _=cancelled.changed()=>{}, _=work=>{} }
            });
            entry.done.store(true, Ordering::SeqCst);
        });
        if spawn.is_err() {
            registry().lock().unwrap().remove(&id);
            return INVALID;
        }
        unsafe {
            *handle = id;
        }
        0
    })
}

#[cfg(feature = "offline-fixtures")]
/// # Safety
/// handle must be writable. Target is restricted to IPv4 loopback.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn ncm_test_start_loopback(port: u16, handle: *mut u64) -> i32 {
    protect(|| {
        if handle.is_null() || port == 0 {
            return INVALID;
        }
        unsafe { *handle = 0 };
        match launch(RelayConnector::loopback(port), fixture_identity(), VERIFY) {
            Ok(id) => {
                unsafe { *handle = id };
                0
            }
            Err(e) => e,
        }
    })
}
#[cfg(test)]
mod tests {
    #[test]
    fn command_payload_is_bounded_typed_and_accepts_unicode() {
        // ASCII, whitespace, and mixed Unicode all use the same paste command.
        for text in ["ASCII 123!", "你好 ESP32 🌟", "\n\t ", "a"]
            .iter()
            .copied()
        {
            let payload = serde_json::to_vec(&serde_json::json!({"text": text})).unwrap();
            assert!(super::valid_command(10, &payload));
        }
        for count in [8192, 8193] {
            let payload =
                serde_json::to_vec(&serde_json::json!({"text": "x".repeat(count)})).unwrap();
            assert_eq!(super::valid_command(10, &payload), count == 8192);
        }
        assert!(super::valid_command(10, br#"{"text":"hello"}"#));
        assert!(super::valid_command(
            10,
            "{\"text\":\"你好 🌟\"}".as_bytes()
        ));
        assert!(super::valid_command(
            9,
            br#"{"bundle_id":"example.fixture","arguments":["--resume","token"]}"#
        ));
        for invalid in [
            br#"{"bundle_id":"example.fixture","arguments":"wrong"}"#.as_slice(),
            br#"{"bundle_id":"bad/path","arguments":[]}"#,
            br#"{"bundle_id":"example.fixture","arguments":[4]}"#,
        ] {
            assert!(!super::valid_command(9, invalid));
        }
        assert!(!super::valid_command(10, br#"{"text":"a\u0000b"}"#));
        assert!(!super::valid_command(10, br#"{"text":""}"#));
        assert!(!super::valid_command(10, &vec![b'x'; 16 * 1024 + 1]));
        assert!(!super::valid_command(7, br#"{"text":"hello"}"#));
    }

    static TEST_LOCK: tokio::sync::Mutex<()> = tokio::sync::Mutex::const_new(());
    #[tokio::test]
    async fn pairing_persistence_ack_requires_exact_pending_state_and_rejects_replay() {
        let _test = TEST_LOCK.lock().await;
        let (tx, mut rx) = mpsc::channel(1);
        let (_, queue) = mpsc::channel(1);
        let (cancel, _) = watch::channel(false);
        let entry = Arc::new(Entry {
            pairing: true,
            pairing_state: AtomicUsize::new(1),
            submit: Mutex::new((0, tx)),
            receive: Mutex::new(Receiver {
                pending: None,
                queue,
            }),
            cancel,
            ready: AtomicBool::new(true),
            done: AtomicBool::new(false),
            video: Arc::new(crate::video::VideoMailbox::default()),
            screen_allowed: false,
        });
        let id = NEXT.fetch_add(1, Ordering::SeqCst);
        registry().lock().unwrap().insert(id, entry.clone());
        let mut header = EventHeader::default();
        assert_eq!(
            unsafe { ncm_backend_video_poll(id, &mut header, std::ptr::null_mut(), 0) },
            NOT_READY
        );
        assert_eq!(ncm_backend_video_refresh(id), NOT_READY);
        let mut snapshot = crate::video::VideoSnapshot::default();
        assert_eq!(unsafe { ncm_backend_video_get_snapshot(id, &mut snapshot) }, NOT_READY);
        let mut status = crate::video::VideoStatus::default();
        assert_eq!(
            unsafe { ncm_backend_video_get_status(id, &mut status) },
            NOT_READY
        );
        assert_eq!(pairing::ncm_pairing_ack(id, 2), NOT_READY);
        assert_eq!(pairing::ncm_pairing_ack(id, 1), 0);
        assert_eq!(pairing::ncm_pairing_ack(id, 1), NOT_READY);
        assert_eq!(pairing::ncm_pairing_ack(id, 2), NOT_READY);
        let request = rx.try_recv().unwrap();
        assert_eq!(request.id, 1);
        assert_eq!(request.action, 6);
        entry.pairing_state.store(2, Ordering::SeqCst);
        assert_eq!(pairing::ncm_pairing_ack(id, 1), NOT_READY);
        assert_eq!(pairing::ncm_pairing_ack(id, 2), 0);
        assert_eq!(rx.try_recv().unwrap().id, 2);
        ncm_backend_close(id);
        assert_eq!(pairing::ncm_pairing_ack(id, 2), CLOSED);
    }

    #[tokio::test]
    async fn explicit_pairing_listener_requires_consent_and_close_releases_port() {
        let _test = TEST_LOCK.lock().await;
        let mut id = 99;
        assert_eq!(unsafe { pairing::ncm_pairing_start(0, &mut id) }, INVALID);
        assert_eq!(id, 0);
        assert_eq!(unsafe { pairing::ncm_pairing_start(1, &mut id) }, 0);
        let mut header = EventHeader::default();
        let deadline = tokio::time::Instant::now() + std::time::Duration::from_secs(3);
        loop {
            let code = unsafe { ncm_backend_poll(id, &mut header, std::ptr::null_mut(), 0) };
            if code == SMALL {
                break;
            }
            assert_eq!(code, EMPTY);
            assert!(tokio::time::Instant::now() < deadline);
            tokio::time::sleep(std::time::Duration::from_millis(5)).await;
        }
        assert_eq!(header.kind, 5);
        let mut payload = vec![0; header.size];
        assert_eq!(
            unsafe { ncm_backend_poll(id, &mut header, payload.as_mut_ptr(), payload.len()) },
            0
        );
        let value: serde_json::Value = serde_json::from_slice(&payload).unwrap();
        assert!(value.get("seed").is_none());
        assert_eq!(value["txt"]["identifier"], value["identifier"]);
        assert_eq!(pairing::ncm_pairing_ack(id, 1), NOT_READY);
        assert_eq!(ncm_backend_submit(id, 1, 1, 0, 0), INVALID);
        let port = value["port"].as_u64().unwrap() as u16;
        ncm_backend_close(id);
        ncm_backend_close(id);
        loop {
            if tokio::net::TcpStream::connect((std::net::Ipv4Addr::LOCALHOST, port))
                .await
                .is_err()
            {
                break;
            }
            assert!(tokio::time::Instant::now() < deadline);
            tokio::time::sleep(std::time::Duration::from_millis(5)).await;
        }
        while WORKERS.load(Ordering::SeqCst) != 0 {
            assert!(tokio::time::Instant::now() < deadline);
            tokio::time::sleep(std::time::Duration::from_millis(5)).await;
        }
    }

    use super::*;
    use tokio::io::{AsyncReadExt, AsyncWriteExt};
    #[tokio::test]
    async fn polling_keeps_payload_until_sufficient_buffer_and_close_revokes_handle() {
        let _test = TEST_LOCK.lock().await;
        let (send, queue) = mpsc::channel(1);
        let (tx, _) = mpsc::channel(1);
        let (cancel, _) = watch::channel(false);
        let entry = Arc::new(Entry {
            pairing: false,
            pairing_state: AtomicUsize::new(0),
            submit: Mutex::new((0, tx)),
            receive: Mutex::new(Receiver {
                pending: None,
                queue,
            }),
            cancel,
            ready: AtomicBool::new(true),
            done: AtomicBool::new(false),
            video: Arc::new(crate::video::VideoMailbox::default()),
            screen_allowed: true,
        });
        let id = NEXT.fetch_add(1, Ordering::SeqCst);
        registry().lock().unwrap().insert(id, entry);
        send.try_send(Event::ok(9, 4, vec![1, 2, 3]))
            .unwrap_or_else(|_| panic!("queue"));
        let mut h = EventHeader::default();
        assert_eq!(
            unsafe { ncm_backend_video_poll(id, &mut h, std::ptr::null_mut(), 0) },
            EMPTY
        );
        assert_eq!(ncm_backend_video_refresh(id), 0);
        let mut status = crate::video::VideoStatus::default();
        assert_eq!(unsafe { ncm_backend_video_get_status(id, &mut status) }, 0);
        assert_eq!(status.datagrams, 0);
        let mut snapshot = crate::video::VideoSnapshot::default();
        assert_eq!(unsafe { ncm_backend_video_get_snapshot(id, &mut snapshot) }, 0);
        assert_eq!(snapshot.serial, 0);
        assert_eq!(unsafe { ncm_backend_video_get_snapshot(id, std::ptr::null_mut()) }, INVALID);
        assert_eq!(unsafe { ncm_backend_video_get_snapshot(u64::MAX, &mut snapshot) }, CLOSED);
        assert_eq!(
            unsafe { ncm_backend_video_get_status(id, std::ptr::null_mut()) },
            INVALID
        );

        assert_eq!(
            unsafe { ncm_backend_poll(id, &mut h, std::ptr::null_mut(), 0) },
            SMALL
        );
        assert_eq!((h.request_id, h.size), (9, 3));
        let mut output = [0; 3];
        assert_eq!(
            unsafe { ncm_backend_poll(id, &mut h, output.as_mut_ptr(), 3) },
            0
        );
        assert_eq!(output, [1, 2, 3]);
        ncm_backend_close(id);
        assert_eq!(
            unsafe { ncm_backend_poll(id, &mut h, std::ptr::null_mut(), 0) },
            CLOSED
        );
        ncm_backend_close(id);
    }
    #[tokio::test]
    async fn queued_geometry_fence_rejects_changed_capture_before_dispatch() {
        let _test = TEST_LOCK.lock().await;
        let (tx, mut rx) = mpsc::channel(4);
        let (_send, queue) = mpsc::channel(1);
        let (cancel, _) = watch::channel(false);
        let video = Arc::new(crate::video::VideoMailbox::default());
        video.begin_stream();
        let entry = Arc::new(Entry {
            pairing: false, pairing_state: AtomicUsize::new(0),
            submit: Mutex::new((0, tx)), receive: Mutex::new(Receiver { pending: None, queue }),
            cancel, ready: AtomicBool::new(true), done: AtomicBool::new(false),
            video: video.clone(), screen_allowed: true,
        });
        let handle = NEXT.fetch_add(1, Ordering::SeqCst);
        registry().lock().unwrap().insert(handle, entry);
        let capture = ncm_backend_video_geometry_generation(handle);
        assert_ne!(capture, 0);
        assert_eq!(ncm_backend_input_guarded(handle, 1, 4, 10, 20, 0, 0, 0, 0), INVALID);
        assert_eq!(ncm_backend_input_guarded(handle, 1, 4, 10, 20, 0, 0, 0, capture), 0);
        // Simulate blocked dequeue while the independent video receiver resets.
        video.reset();
        let queued = rx.recv().await.unwrap();
        assert!(!request_geometry_valid(&queued, &video), "Production execute gate must reject before calling Session.tap");
        let renewed = ncm_backend_video_geometry_generation(handle);
        assert_eq!(ncm_backend_input_guarded(handle, 2, 6, 1, 2, 3, 4, 100, renewed), 0);
        video.set_visible_size(Some((1179, 2556)));
        let queued = rx.recv().await.unwrap();
        assert!(!request_geometry_valid(&queued, &video), "Size changes while drag is queued must reject both endpoints");
        let renewed = ncm_backend_video_geometry_generation(handle);
        assert_eq!(ncm_backend_input_guarded(handle, 3, 4, 1, 2, 0, 0, 0, renewed), 0);
        assert!(request_geometry_valid(&rx.recv().await.unwrap(), &video));
        assert_eq!(ncm_backend_submit(handle, 4, 4, 1, 2), 0);
        video.reset();
        assert!(request_geometry_valid(&rx.recv().await.unwrap(), &video), "Legacy local input has no v2 geometry contract");
        assert_eq!(ncm_backend_video_invalidate_geometry(handle), video.geometry_generation());
        ncm_backend_close(handle);
        assert_eq!(ncm_backend_video_geometry_generation(handle), 0);
        assert_eq!(ncm_backend_input_guarded(handle, 5, 4, 1, 2, 0, 0, 0, renewed), CLOSED);
    }
    #[tokio::test]
    async fn command_queue_is_bounded_and_duplicate_ids_are_rejected() {
        let _test = TEST_LOCK.lock().await;
        let (tx, mut rx) = mpsc::channel(1);
        let (_send, queue) = mpsc::channel(1);
        let (cancel, _) = watch::channel(false);
        let entry = Arc::new(Entry {
            pairing: false,
            pairing_state: AtomicUsize::new(0),
            submit: Mutex::new((0, tx)),
            receive: Mutex::new(Receiver {
                pending: None,
                queue,
            }),
            cancel,
            ready: AtomicBool::new(true),
            done: AtomicBool::new(false),
            video: Arc::new(crate::video::VideoMailbox::default()),
            screen_allowed: false,
        });
        let id = NEXT.fetch_add(1, Ordering::SeqCst);
        registry().lock().unwrap().insert(id, entry);
        // Invalid drag must not consume the monotonic request ID or queue slot.
        assert_eq!(ncm_backend_drag(id, 1, 0, 0, 65535, 65535, 99), INVALID);
        assert_eq!(ncm_backend_drag(id, 1, 0, 0, 65535, 65535, 2001), INVALID);
        assert_eq!(ncm_backend_drag(id, 1, 0, 0, 65535, 65535, 100), 0);
        let drag = rx.try_recv().unwrap();
        assert_eq!(
            (drag.action, drag.end_x, drag.end_y, drag.duration),
            (6, 65535, 65535, 100)
        );
        assert_eq!(ncm_backend_submit(id, 2, 2, 0, 0), 0);
        assert_eq!(ncm_backend_drag(id, 2, 0, 0, 1, 1, 100), INVALID);
        assert_eq!(ncm_backend_submit(id, 2, 2, 0, 0), INVALID);
        assert_eq!(ncm_backend_submit(id, 3, 2, 0, 0), BUSY);
        assert_eq!(rx.try_recv().unwrap().id, 2);
        assert_eq!(ncm_backend_submit(id, 3, 2, 0, 0), 0);
        ncm_backend_close(id);
    }
    #[tokio::test]
    async fn closing_one_handle_preserves_another_sessions_reply() {
        let _test = TEST_LOCK.lock().await;
        let mut ids = Vec::new();
        for value in [11, 22] {
            let (tx, _) = mpsc::channel(1);
            let (events, queue) = mpsc::channel(1);
            let (cancel, _) = watch::channel(false);
            let entry = Arc::new(Entry {
                pairing: false,
                pairing_state: AtomicUsize::new(0),
                submit: Mutex::new((0, tx)),
                receive: Mutex::new(Receiver {
                    pending: None,
                    queue,
                }),
                cancel,
                ready: AtomicBool::new(true),
                done: AtomicBool::new(false),
                video: Arc::new(crate::video::VideoMailbox::default()),
                screen_allowed: false,
            });
            let id = NEXT.fetch_add(1, Ordering::SeqCst);
            registry().lock().unwrap().insert(id, entry);
            events
                .try_send(Event::ok(1, 4, vec![value]))
                .unwrap_or_else(|_| panic!("fixture queue"));
            ids.push(id);
        }
        ncm_backend_close(ids[0]);
        let mut h = EventHeader::default();
        let mut byte = [0];
        assert_eq!(
            unsafe { ncm_backend_poll(ids[0], &mut h, byte.as_mut_ptr(), 1) },
            CLOSED
        );
        assert_eq!(
            unsafe { ncm_backend_poll(ids[1], &mut h, byte.as_mut_ptr(), 1) },
            0
        );
        assert_eq!(byte, [22]);
        ncm_backend_close(ids[1]);
    }
    #[tokio::test]
    async fn ffi_worker_reports_real_handshake_failure_and_cancels_pending_read() {
        let _test = TEST_LOCK.lock().await;
        struct Connector(Mutex<Option<tokio::io::DuplexStream>>);
        impl NcmConnector for Connector {
            fn connect(&self, _: crate::Purpose) -> crate::DialFuture<'_> {
                Box::pin(async move {
                    Ok(Box::new(self.0.lock().unwrap().take().unwrap()) as crate::Stream)
                })
            }
        }
        let (stream, mut peer) = tokio::io::duplex(4096);
        let id = launch(
            Connector(Mutex::new(Some(stream))),
            fixture_identity(),
            VERIFY,
        )
        .unwrap();
        let mut magic = [0; 9];
        peer.read_exact(&mut magic).await.unwrap();
        assert_eq!(&magic, b"RPPairing");
        peer.write_all(b"bad").await.unwrap();
        peer.shutdown().await.unwrap();
        let mut h = EventHeader::default();
        for _ in 0..100 {
            let r = unsafe { ncm_backend_poll(id, &mut h, std::ptr::null_mut(), 0) };
            if r == 0 {
                break;
            }
            assert_eq!(r, EMPTY);
            tokio::time::sleep(std::time::Duration::from_millis(2)).await;
        }
        assert_eq!(h.kind, 3);
        assert_eq!(h.stage, Stage::PairVerify as u32 + 1);
        ncm_backend_close(id);
        let (stream, mut peer) = tokio::io::duplex(4096);
        let id = launch(
            Connector(Mutex::new(Some(stream))),
            fixture_identity(),
            VERIFY,
        )
        .unwrap();
        peer.read_exact(&mut magic).await.unwrap();
        ncm_backend_close(id);
        let mut drain = Vec::new();
        tokio::time::timeout(
            std::time::Duration::from_secs(1),
            peer.read_to_end(&mut drain),
        )
        .await
        .unwrap()
        .unwrap();
        assert_eq!(ncm_backend_submit(id, 1, 2, 0, 0), CLOSED);
    }
    #[tokio::test]
    async fn ordinary_lockdown_worker_ready_only_after_tls_and_stops_cleanly() {
        let _test = TEST_LOCK.lock().await;
        use crate::lockdown::tests as peer;
        struct Connector(Mutex<Option<tokio::io::DuplexStream>>);
        impl NcmConnector for Connector {
            fn connect(&self, purpose: crate::Purpose) -> crate::DialFuture<'_> {
                assert_eq!(purpose, crate::Purpose::LockdownSession);
                Box::pin(async move {
                    Ok(Box::new(self.0.lock().unwrap().take().unwrap()) as crate::Stream)
                })
            }
        }
        let (stream, mut device) = tokio::io::duplex(4096);
        let id = launch_lockdown(Connector(Mutex::new(Some(stream))), peer::identity()).unwrap();
        let request = peer::read(&mut device).await;
        assert_eq!(
            request.get("Request").and_then(plist::Value::as_string),
            Some("StartSession")
        );
        let mut event = EventHeader::default();
        assert_eq!(
            unsafe { ncm_backend_poll(id, &mut event, std::ptr::null_mut(), 0) },
            EMPTY
        );
        peer::write(&mut device, peer::start_reply()).await;
        let mut tls = peer::acceptor(false).accept(device).await.unwrap();
        async fn poll(id: u64) -> EventHeader {
            tokio::time::timeout(std::time::Duration::from_secs(2), async {
                loop {
                    let mut e = EventHeader::default();
                    let status = unsafe { ncm_backend_poll(id, &mut e, std::ptr::null_mut(), 0) };
                    if status == 0 {
                        return e;
                    }
                    assert_eq!(status, EMPTY);
                    tokio::time::sleep(std::time::Duration::from_millis(2)).await;
                }
            })
            .await
            .unwrap()
        }
        let ready = poll(id).await;
        assert_eq!(ready.kind, 2);
        assert_eq!(ready.request_id, 0);
        assert_eq!(ncm_backend_submit(id, 1, 5, 0, 0), 0);
        let stop = peer::read(&mut tls).await;
        assert_eq!(
            stop.get("Request").and_then(plist::Value::as_string),
            Some("StopSession")
        );
        let mut response = plist::Dictionary::new();
        response.insert("Request".into(), "StopSession".into());
        peer::write(&mut tls, response).await;
        let stopped = poll(id).await;
        assert_eq!(stopped.kind, 2);
        assert_eq!(stopped.request_id, 1);
        ncm_backend_close(id);
    }
}
