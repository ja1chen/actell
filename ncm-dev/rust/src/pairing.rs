// SPDX-License-Identifier: GPL-3.0-only
//! Explicit responder pairing, with durable Swift acknowledgement before M6.
use super::*;
use idevice::remote_pairing::{PairRecordState, PairableHost, PairableHostInfo, RpPairingSocket};
use tokio::sync::Mutex as AsyncMutex;

fn failed() -> Event {
    Event {
        header: EventHeader {
            kind: 3,
            stage: 201,
            cause: 1,
            ..Default::default()
        },
        data: Vec::new(),
        credit: None,
    }
}
fn protocol_error() -> idevice::IdeviceError {
    idevice::remote_pairing::errors::RemotePairingError::PairRecordPersistenceFailed.into()
}
fn record(seed: &[u8], id: &str, peer: &VerifiedPeerIdentity, committed: bool) -> Vec<u8> {
    serde_json::to_vec(&serde_json::json!({
        "version":1, "seed":seed, "controllerID":id, "peerID":peer.pairing_identifier,
        "peerPublicKey":peer.long_term_public_key.as_slice(), "alternateIRK":peer.peer.alt_irk,
        "peerUDID":peer.peer.remotepairing_udid, "peerModel":peer.peer.model, "committed":committed
    }))
    .expect("serializable record")
}
async fn run(
    events: mpsc::Sender<Event>,
    rx: mpsc::Receiver<Request>,
    entry: Arc<Entry>,
) -> Result<(), idevice::IdeviceError> {
    let listener = tokio::net::TcpListener::bind((std::net::Ipv4Addr::UNSPECIFIED, 0)).await?;
    let mut controller = RpPairingFile::generate("执言");
    let mut info = PairableHostInfo::generate("执言", "Mac17,7");
    info.identifier = controller.identifier.clone();
    info.udid = uuid::Uuid::new_v4().to_string();
    let txt: HashMap<_, _> = info
        .mdns_txt_records(&controller.identifier)
        .into_iter()
        .collect();
    let advertisement = serde_json::to_vec(&serde_json::json!({
        "port":listener.local_addr()?.port(), "identifier":controller.identifier, "txt":txt
    }))
    .map_err(|_| protocol_error())?;
    events
        .send(Event::ok(0, 5, advertisement))
        .await
        .map_err(|_| protocol_error())?;
    let (stream, _) = listener.accept().await?;
    drop(listener); // one user-selected connection; no retry/accept loop
    let seed = Arc::new(Zeroizing::new(controller.e_private_key.to_bytes()));
    let controller_id = controller.identifier.clone();
    let receiver = Arc::new(AsyncMutex::new(rx));
    let pin_events = events.clone();
    let persistence_events = events.clone();
    let mut host = PairableHost::new(RpPairingSocket::new_device(stream), info);
    host.accept_fallible(
        &mut controller,
        move |pin| async move {
            pin_events
                .send(Event::ok(0, 6, pin.into_bytes()))
                .await
                .map_err(|_| protocol_error())
        },
        move |state, peer| {
            let events = persistence_events.clone();
            let rx = receiver.clone();
            let entry = entry.clone();
            let seed = seed.clone();
            let id = controller_id.clone();
            async move {
                let committed = state == PairRecordState::Committed;
                let expected = if committed { 2 } else { 1 };
                entry
                    .pairing_state
                    .store(expected as usize, Ordering::SeqCst);
                entry.ready.store(true, Ordering::SeqCst);
                events
                    .send(Event::ok(
                        0,
                        if committed { 8 } else { 7 },
                        record(seed.as_slice(), &id, &peer, committed),
                    ))
                    .await
                    .map_err(|_| protocol_error())?;
                let ack = tokio::time::timeout(std::time::Duration::from_secs(10), async {
                    rx.lock().await.recv().await
                })
                .await
                .map_err(|_| protocol_error())?
                .ok_or_else(protocol_error)?;
                entry.ready.store(false, Ordering::SeqCst);
                if ack.action != 6 || ack.id != expected {
                    return Err(protocol_error());
                }
                Ok(())
            }
        },
    )
    .await?;
    events
        .send(Event::ok(0, 9, Vec::new()))
        .await
        .map_err(|_| protocol_error())?;
    Ok(())
}
/// # Safety
/// handle must point to writable u64; explicit consent 1 required.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn ncm_pairing_start(consent: u32, handle: *mut u64) -> i32 {
    protect(|| {
        if handle.is_null() {
            return INVALID;
        }
        unsafe {
            *handle = 0;
        }
        if consent != 1 {
            return INVALID;
        }
        if WORKERS
            .fetch_update(Ordering::SeqCst, Ordering::SeqCst, |n| {
                (n < 2).then_some(n + 1)
            })
            .is_err()
        {
            return BUSY;
        }
        let (tx, rx) = mpsc::channel(1);
        let (events, queue) = mpsc::channel(1);
        let (cancel, mut cancelled) = watch::channel(false);
        let entry = Arc::new(Entry {
            pairing: true,
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
        let Ok(mut entries) = registry().lock() else {
            WORKERS.fetch_sub(1, Ordering::SeqCst);
            return INVALID;
        };
        if id == 0 || entries.len() >= 2 {
            WORKERS.fetch_sub(1, Ordering::SeqCst);
            return BUSY;
        }
        entries.insert(id, entry.clone());
        drop(entries);
        let spawn = std::thread::Builder::new().name("ncm-pairing".into()).spawn(move || {
            struct Finished(Arc<Entry>);
            impl Drop for Finished { fn drop(&mut self) { self.0.ready.store(false, Ordering::SeqCst); self.0.done.store(true, Ordering::SeqCst); WORKERS.fetch_sub(1, Ordering::SeqCst); } }
            let _finished = Finished(entry.clone());
            let Ok(runtime) = tokio::runtime::Builder::new_current_thread().enable_all().build() else { return; };
            runtime.block_on(async {
                tokio::select! { biased;
                    _ = cancelled.changed() => {},
                    result = tokio::time::timeout(std::time::Duration::from_secs(180), run(events.clone(), rx, entry)) => {
                        if !matches!(result, Ok(Ok(()))) { let _ = events.send(failed()).await; }
                    }
                }
            });
        });
        if spawn.is_err() {
            if let Ok(mut entries) = registry().lock() {
                entries.remove(&id);
            }
            WORKERS.fetch_sub(1, Ordering::SeqCst);
            return INVALID;
        }
        unsafe {
            *handle = id;
        }
        0
    })
}
#[unsafe(no_mangle)]
pub extern "C" fn ncm_pairing_ack(handle: u64, state: u32) -> i32 {
    protect(|| {
        if !(1..=2).contains(&state) {
            return INVALID;
        }
        let Some(entry) = get(handle) else {
            return CLOSED;
        };
        if !entry.pairing {
            return INVALID;
        }
        if !entry.ready.load(Ordering::SeqCst)
            || entry.pairing_state.load(Ordering::SeqCst) != state as usize
        {
            return NOT_READY;
        }
        let Ok(mut submit) = entry.submit.lock() else {
            return INVALID;
        };
        if u64::from(state) != submit.0 + 1 {
            return INVALID;
        }
        match submit.1.try_send(Request {
            expected_geometry: None,
            id: u64::from(state),
            action: 6,
            x: 0,
            y: 0,
            end_x: 0,
            end_y: 0,
            duration: 0,
            payload: Zeroizing::new(Vec::new()),
        }) {
            Ok(()) => {
                submit.0 = u64::from(state);
                entry.pairing_state.store(0, Ordering::SeqCst);
                0
            }
            Err(mpsc::error::TrySendError::Full(_)) => BUSY,
            Err(_) => CLOSED,
        }
    })
}
