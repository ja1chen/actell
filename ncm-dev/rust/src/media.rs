// SPDX-License-Identifier: GPL-3.0-only
//! Authenticated DisplayService video negotiation and discard-only consumer.
//! Complete HEVC units are handed to the owning App decoder; no media is persisted.
use crate::{Cause, Error, Stage, Stream, bounded, error};
use idevice::{
    RsdService,
    core_device::{
        DisplayServiceClient, TouchEvent, TouchPoint, UniversalHidServiceClient,
        display_stream::{
            RtpPacket, ReportBlock, SenderReport, build_frame_ack, build_pli, build_liveness, build_rctl,
            build_start_video_parameters,
            hevc::{HevcAccessUnitAssembler, HevcDepacketizerEvent},
            is_rtcp,
            negotiation::{CallInfoBlob, build_screen_video_offer_with_bitrate, parse_screen_video_answer},
        },
    },
    rsd::RsdHandshake,
    tcp::handle::AdapterHandle,
};
use std::{
    sync::{
        Arc,
        atomic::{AtomicBool, Ordering},
    },
    time::Duration,
};
use tokio::task::JoinHandle;
// Requested sender port is an offer only; feedback uses the returned SourcePort.
const REQUESTED_VIDEO_PORT: u16 = 50001;
// S3 relay budget, not an iOS limit. Live 6 Mbps produced sender ENOBUFS;
// 2 Mbps RCTL feedback made the peer target ~1.7 Mbps without steady-state loss.
const RECEIVER_BANDWIDTH_KBPS: u16 = 2000;
// Display identity and geometry are queried from the authenticated peer.
struct DisplayInfoClient(idevice::core_device::CoreDeviceServiceClient<Stream>);
impl RsdService for DisplayInfoClient {
    fn rsd_service_name() -> std::borrow::Cow<'static, str> {
        "com.apple.coredevice.deviceinfo".into()
    }
    async fn from_stream(stream: Stream) -> Result<Self, idevice::IdeviceError> {
        Ok(Self(
            idevice::core_device::CoreDeviceServiceClient::new(stream).await?,
        ))
    }
}
async fn read_display_geometry(info: &mut DisplayInfoClient, id: i64) -> Option<(u32, u32)> {
    let value = tokio::time::timeout(
        Duration::from_secs(2),
        info.0.invoke_with_plist(
            "com.apple.coredevice.feature.getdisplayinfo",
            plist::Dictionary::new(),
        ),
    )
    .await
    .ok()?
    .ok()?;
    display_geometry(&value, id)
}
fn display_geometry(value: &plist::Value, id: i64) -> Option<(u32, u32)> {
    let root = value.as_dictionary()?;
    if !root.get("current")?.as_boolean()? {
        return None;
    }
    let displays = root.get("displays")?.as_array()?;
    let mut matches = displays
        .iter()
        .filter_map(|v| v.as_dictionary())
        .filter(|d| d.get("displayId").and_then(plist::Value::as_signed_integer) == Some(id));
    let display = matches.next()?;
    if matches.next().is_some() {
        return None;
    }
    let frame = display.get("frame")?.as_array()?;
    if frame.len() != 2 {
        return None;
    }
    let origin = frame[0].as_array()?;
    let size = frame[1].as_array()?;
    if origin.len() != 2 || size.len() != 2 {
        return None;
    }
    fn number(v: &plist::Value) -> Option<f64> {
        v.as_real()
            .or_else(|| v.as_signed_integer().map(|n| n as f64))
    }
    if number(&origin[0])? != 0.0 || number(&origin[1])? != 0.0 {
        return None;
    }
    let w = number(&size[0])?;
    let h = number(&size[1])?;
    if !w.is_finite()
        || !h.is_finite()
        || w.fract() != 0.0
        || h.fract() != 0.0
        || !(1.0..=16384.0).contains(&w)
        || !(1.0..=16384.0).contains(&h)
    {
        return None;
    }
    Some((w as u32, h as u32))
}
#[derive(Default)]
struct Drains(Vec<JoinHandle<()>>);
impl Drop for Drains {
    fn drop(&mut self) {
        for task in &self.0 {
            task.abort();
        }
    }
}
pub(crate) struct Media {
    _video: DisplayServiceClient<Stream>,
    stop_identifier: u32,
    hid: UniversalHidServiceClient<Stream>,
    _drains: Drains,
    healthy: Arc<AtomicBool>,
}
impl Media {
    pub async fn start(
        adapter: &mut AdapterHandle,
        handshake: &mut RsdHandshake,
        mailbox: Arc<crate::video::VideoMailbox>,
    ) -> Result<Self, Error> {
        let fail = || error(Stage::VideoAnswer, Cause::Protocol);
        let mut drains = Drains::default();
        let healthy = Arc::new(AtomicBool::new(true));
        let video_udp = bounded(Stage::VideoReceiver, adapter.bind_udp(0)).await?;
        let receiver = adapter.host_ip().to_string();
        let sender = adapter.peer_ip().to_string();
        // Compatibility profile captured in Device Hub's protocol source, not
        // evidence of iOS27 compatibility or the actual controller model/OS.
        let info = CallInfoBlob {
            call_id: 0,
            client_version: 1,
            device_type: "Mac17,7".into(),
            framework_version: "2205.3.1".into(),
            os_version: "25F71".into(),
            device_name: None,
            audio_device_uid: None,
        };
        let session = uuid::Uuid::new_v4();
        let ssrc =
            u32::from_be_bytes(uuid::Uuid::new_v4().as_bytes()[..4].try_into().unwrap()).max(1);
        let call_id = uuid::Uuid::new_v4().to_string().to_uppercase();
        let offer = build_screen_video_offer_with_bitrate(&call_id, &info, ssrc, u32::from(RECEIVER_BANDWIDTH_KBPS) * 1000).map_err(|_| fail())?;
        // Retain the video session until close; audio is not needed for touch.
        let mut video = bounded(
            Stage::VideoService,
            DisplayServiceClient::connect_rsd(adapter, handshake),
        )
        .await?;
        let geometry_probe = std::env::var_os("NCM_VIDEO_GEOMETRY_PROBE").is_some();
        const DISPLAY_ID: i64 = 1;
        let mut display_info = bounded(
            Stage::VideoService,
            DisplayInfoClient::connect_rsd(adapter, handshake),
        )
        .await
        .ok();
        let initial_geometry = if let Some(info) = &mut display_info {
            read_display_geometry(info, DISPLAY_ID).await
        } else {
            None
        };
        if initial_geometry.is_none() { display_info = None; }
        let answer = bounded(
            Stage::VideoNegotiation,
            video.start_media_stream(build_start_video_parameters(
                &receiver,
                video_udp.local_port(),
                &sender,
                REQUESTED_VIDEO_PORT,
                offer,
                140,
                DISPLAY_ID,
                session,
            )),
        )
        .await?;
        if geometry_probe {
            eprintln!("NCM geometry answer {answer:?}");
            eprintln!(
                "NCM geometry status {:?}",
                video.get_media_stream_server_status().await
            );
        }
        let negotiated = parse_screen_video_answer(extract_answer(&answer)?).map_err(|_| fail())?;
        let config = match feedback_endpoint(&answer) {
            Some(config) => config,
            None => {
                let status = bounded(Stage::VideoAnswer, video.get_media_stream_server_status()).await?;
                feedback_endpoint(&status).ok_or_else(fail)?
            }
        };
        if config.1 != negotiated.ssrc { return Err(fail()); }
        let (feedback_port, _, receiver_ssrc) = config;
        eprintln!("NCM video feedback negotiated port={feedback_port} receiver={receiver_ssrc} sender={}", negotiated.ssrc);
        // Refresh outside the receiver: service latency must not block RTP/ACKs.
        // Each frame carries a snapshot, validated against that frame's SPS.
        mailbox.begin_stream();
        mailbox.set_visible_size(initial_geometry);
        if let Some(mut info) = display_info {
            let geometry_mailbox = mailbox.clone();
            drains.0.push(tokio::spawn(async move {
                loop {
                    tokio::time::sleep(Duration::from_secs(1)).await;
                    let size = read_display_geometry(&mut info, DISPLAY_ID).await;
                    geometry_mailbox.set_visible_size(size);
                    // A timed-out XPC request cannot safely reuse this channel.
                    if size.is_none() { break; }
                }
            }));
        }
        let video_health = healthy.clone();
        drains.0.push(tokio::spawn(async move {
            let mut assembler = HevcAccessUnitAssembler::new(negotiated.payload_type, negotiated.ssrc);
            let mut needs_sync = true;
            let mut probe_extensions = 0;
            let mut probe_rtcp = 0;
            let mut received_payload_octets = 0u64;
            let mut discontinuity_logs = 0;
            let probe_began = std::time::Instant::now();
            let mut probe_packets = 0u64;
            let mut reports = VideoFeedback::new(receiver_ssrc, negotiated.ssrc, call_id);
            let mut control_tick = tokio::time::interval(Duration::from_millis(50));
            control_tick.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Skip);
            let mut feedback = tokio::time::interval(Duration::from_secs(1));
            feedback.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Skip);
            loop {
                tokio::select! {
                    packet=video_udp.recv()=>match packet {
                        Ok(p)=> {
                            mailbox.received_from(p.source_port);
                            // The adapter already binds the authenticated peer IP and local port.
                            // senderPort is our feedback destination, not a constraint on inbound source ports.
                            if is_rtcp(&p.data) {
                                if let Some(sr) = SenderReport::parse_first(&p.data) {
                                    if sr.ssrc == negotiated.ssrc {
                                        reports.sender_report = Some((sr.ntp_middle, tokio::time::Instant::now()));
                                        mailbox.sender_report(sr.packet_count == reports.unique_packets && assembler.is_complete());
                                    }
                                }
                                if geometry_probe && p.data.len() >= 28 && p.data[1] == 200 {
                                    let sent_packets = u32::from_be_bytes(p.data[20..24].try_into().unwrap());
                                    let sent_octets = u32::from_be_bytes(p.data[24..28].try_into().unwrap());
                                    eprintln!("NCM video sender report sentPackets={sent_packets} receivedPackets={} sentOctets={sent_octets} receivedOctets={received_payload_octets}", reports.packets);
                                }
                                if geometry_probe && probe_rtcp < 4 {
                                    eprintln!("NCM geometry RTCP {:02x?}", &p.data[..p.data.len().min(512)]);
                                    probe_rtcp += 1;
                                }
                                continue;
                            }
                            let Some(packet) = parse_video_packet(&p.data, negotiated) else { mailbox.count(2); continue; };
                            if geometry_probe && probe_extensions < 12 && packet.marker {
                                eprintln!("NCM geometry RTP marker padding={} profile={} ext={:02x?} rawtail={:02x?}", packet.padding, packet.ext_profile, packet.ext_data, &p.data[p.data.len().saturating_sub(96)..]);
                                probe_extensions += 1;
                            }
                            if geometry_probe && probe_packets < 30000 {
                                eprintln!("NCM packet us={} seq={} ts={} marker={} size={}", probe_began.elapsed().as_micros(), packet.sequence_number, packet.timestamp, packet.marker, packet.payload.len());
                                probe_packets += 1;
                            }
                            mailbox.packet_pending();
                            mailbox.count(1);
                            received_payload_octets += packet.payload.len() as u64;
                            if let Some(ack) = reports.observe_packet(&packet) {
                                if video_udp.send_to(feedback_port, ack).await.is_err() { video_health.store(false, Ordering::SeqCst); return; }
                            }
                            for event in assembler.push_packet(&packet) {
                                match event {
                                    HevcDepacketizerEvent::AccessUnit(unit) => {
                                        mailbox.count(3);
                                        if let Some(params) = assembler.parameter_sets() {
                                            if mailbox.push(unit, params) { needs_sync = false; }
                                            else { assembler.mark_stream_discontinuity(); needs_sync = true; }
                                        }
                                    },
                                    HevcDepacketizerEvent::Discontinuity(reason) => {
                                        if discontinuity_logs < 8 {
                                            eprintln!("NCM video discontinuity {reason:?} seq={} ts={} marker={}", packet.sequence_number, packet.timestamp, packet.marker);
                                            discontinuity_logs += 1;
                                        }
                                        mailbox.count(4); mailbox.reset(); needs_sync = true;
                                    },
                                    HevcDepacketizerEvent::PacketRejected(_) => { mailbox.count(2); },
                                }
                            }
                        },
                        Err(_)=>break,
                    },
                    _=control_tick.tick()=> {
                        if let Some(report) = reports.control_report() {
                            if video_udp.send_to(feedback_port,report).await.is_err() { break; }
                        }
                    },
                    _=feedback.tick()=> {
                        let refresh = mailbox.take_refresh();
                        // Receiver Reports must continue during recovery; a PLI
                        // does not satisfy the sender's RTCP reception timeout.
                        let mut report = reports.liveness_report();
                        if needs_sync || refresh {
                            mailbox.count(6);
                            let request = reports.keyframe_request();
                            if geometry_probe { eprintln!("NCM refresh us={} port={feedback_port} sync={needs_sync} requested={refresh} bytes={request:02x?}",probe_began.elapsed().as_micros()); }
                            report.extend_from_slice(&request);
                        }
                        if video_udp.send_to(feedback_port,report).await.is_err() { break; }
                    }
                }
            }
            mailbox.reset();
            video_health.store(false, Ordering::SeqCst);
        }));
        // A successful reply-bearing video session, not arrival of RTP frames,
        // is the prerequisite used by the verified touch_session reference.
        // Idle/static screens and receiver filtering must not block HID reports.
        // Reference touch_session allows HID surfaces time to become authenticated.
        tokio::time::sleep(Duration::from_millis(350)).await;
        let hid = bounded(
            Stage::TouchService,
            UniversalHidServiceClient::connect_rsd(adapter, handshake),
        )
        .await?;
        Ok(Self {
            _video: video,
            stop_identifier: receiver_ssrc,
            hid,
            _drains: drains,
            healthy,
        })
    }
    pub async fn stop(self, adapter: &mut AdapterHandle, handshake: &mut RsdHandshake) -> Result<(), Error> {
        // Dropping local sockets does not clear the peer's remote-observation
        // assertion. Never reuse the start connection for this stop request.
        let mut stop = bounded(Stage::Media, DisplayServiceClient::connect_rsd(adapter, handshake)).await?;
        let reply = bounded(Stage::Media, stop.stop_media_stream_identifiers(&[self.stop_identifier])).await?;
        if stop_confirmed(&reply, self.stop_identifier) { Ok(()) }
        else { Err(error(Stage::Media, Cause::Protocol)) }
    }
    pub async fn drag(
        &mut self,
        x: u16,
        y: u16,
        end_x: u16,
        end_y: u16,
        duration: u16,
        geometry: Option<(&crate::video::VideoMailbox, u64)>,
    ) -> Result<(), Error> {
        if !(100..=2000).contains(&duration) {
            return Err(error(Stage::Input, Cause::InvalidParameters));
        }
        if !self.healthy.load(Ordering::SeqCst) {
            return Err(error(Stage::Input, Cause::MediaInactive));
        }
        // Last local check before starting Down. This is not a physical screen
        // lock; changes after Down begins retain uncertain-result semantics.
        check_geometry(geometry)?;
        let uncertain = || error(Stage::Input, Cause::DeliveryUncertain);
        bounded(
            Stage::Input,
            self.hid
                .send_touch(TouchEvent::Down(TouchPoint::new(x, y)), None),
        )
        .await
        .map_err(|_| uncertain())?;
        let start = tokio::time::Instant::now();
        let steps = u32::from(duration).div_ceil(20);
        for i in 1..=steps {
            tokio::time::sleep_until(
                start
                    + Duration::from_millis(u64::from(duration) * u64::from(i) / u64::from(steps)),
            )
            .await;
            let interpolate = |a: u16, b: u16| {
                (i64::from(a) + (i64::from(b) - i64::from(a)) * i64::from(i) / i64::from(steps))
                    as u16
            };
            let point = TouchPoint::new(interpolate(x, end_x), interpolate(y, end_y));
            bounded(
                Stage::Input,
                self.hid.send_touch(TouchEvent::Move(point), None),
            )
            .await
            .map_err(|_| uncertain())?;
        }
        bounded(
            Stage::Input,
            self.hid
                .send_touch(TouchEvent::Up(TouchPoint::new(end_x, end_y)), None),
        )
        .await
        .map_err(|_| uncertain())
    }
    pub async fn tap(&mut self, x: u16, y: u16, geometry: Option<(&crate::video::VideoMailbox, u64)>) -> Result<(), Error> {
        if !self.healthy.load(Ordering::SeqCst) {
            return Err(error(Stage::Input, Cause::MediaInactive));
        }
        check_geometry(geometry)?;
        let point = TouchPoint::new(x, y);
        if bounded(
            Stage::Input,
            self.hid.send_touch(TouchEvent::Down(point), None),
        )
        .await
        .is_err()
        {
            // An incomplete write may still have reached the device. Do not
            // replay Down or claim cancellation succeeded; close the generation.
            return Err(error(Stage::Input, Cause::DeliveryUncertain));
        }
        tokio::time::sleep(Duration::from_millis(50)).await;
        bounded(
            Stage::Input,
            self.hid.send_touch(TouchEvent::Up(point), None),
        )
        .await
        .map_err(|_| error(Stage::Input, Cause::DeliveryUncertain))
    }
}

fn check_geometry(geometry: Option<(&crate::video::VideoMailbox, u64)>) -> Result<(), Error> {
    if geometry.is_some_and(|(video, expected)| !video.matches_geometry(expected)) {
        return Err(error(Stage::Input, Cause::InvalidParameters));
    }
    Ok(())
}

fn stop_confirmed(reply: &plist::Value, identifier: u32) -> bool {
    let Some(sessions) = reply.as_dictionary()
        .and_then(|d| d.get("serverInfo")).and_then(plist::Value::as_dictionary)
        .and_then(|d| d.get("sessions")).and_then(plist::Value::as_array) else { return false };
    sessions.iter().all(|session| {
        session.as_dictionary().and_then(|d| d.get("connection")).and_then(plist::Value::as_dictionary)
            .and_then(|d| d.get("streamConfig")).and_then(plist::Value::as_dictionary)
            .and_then(|d| d.get("RemoteSSRC")).and_then(plist::Value::as_unsigned_integer)
            .and_then(|id| u32::try_from(id).ok()).is_some_and(|id| id != identifier)
    })
}
/// Admission is bound to the authenticated answer, not an assumed UDP source port.
fn parse_video_packet(
    data: &[u8],
    expected: idevice::core_device::display_stream::negotiation::ScreenVideoStream,
) -> Option<RtpPacket<'_>> {
    if is_rtcp(data) {
        return None;
    }
    let p = RtpPacket::parse_checked(data).ok()?;
    (p.ssrc == expected.ssrc && p.payload_type == expected.payload_type && !p.payload.is_empty())
        .then_some(p)
}
struct VideoFeedback {
    our_ssrc: u32,
    media_ssrc: u32,
    cname: String,
    base: Option<u16>,
    highest: u32,
    timestamp: u32,
    packets: u32,
    unique_packets: u32,
    seen: std::collections::HashSet<u32>,
    current_frame_packets: u32,
    last_frame_packets: u32,
    previous_expected: u32,
    previous_received: u32,
    sender_report: Option<(u32,tokio::time::Instant)>,
}
impl VideoFeedback {
    fn new(our_ssrc: u32, media_ssrc: u32, cname: String) -> Self {
        Self {
            our_ssrc,
            media_ssrc,
            cname,
            base: None,
            highest: 0,
            unique_packets: 0, seen: std::collections::HashSet::new(),
            timestamp: 0, packets: 0, current_frame_packets: 0, last_frame_packets: 0,
            previous_expected: 0, previous_received: 0, sender_report: None,
        }
    }
    fn observe_sequence(&mut self, sequence: u16) {
        let Some(base) = self.base else {
            self.base = Some(sequence);
            return;
        };
        let current = base.wrapping_add(self.highest as u16);
        let delta = sequence.wrapping_sub(current);
        if delta != 0 && delta < 0x8000 {
            self.highest = self.highest.wrapping_add(u32::from(delta));
        }
    }
    fn observe_packet(&mut self, packet: &RtpPacket<'_>) -> Option<Vec<u8>> {
        // Receipt counts and the highest sequence serve different purposes.
        // A reordered packet is still received, even if it cannot advance highest.
        self.observe_sequence(packet.sequence_number);
        let highest = u32::from(self.base.unwrap()).wrapping_add(self.highest);
        let behind = (highest as u16).wrapping_sub(packet.sequence_number);
        if behind < 0x8000 && self.seen.insert(highest.wrapping_sub(u32::from(behind))) {
            self.unique_packets = self.unique_packets.wrapping_add(1);
            if self.seen.len() > 0x9000 { self.seen.retain(|seq| highest.wrapping_sub(*seq) < 0x8000); }
        }
        if self.packets == 0 || packet.timestamp.wrapping_sub(self.timestamp) < 0x80000000 {
            self.timestamp = packet.timestamp;
        }
        self.packets = self.packets.wrapping_add(1);
        self.current_frame_packets = self.current_frame_packets.saturating_add(1);
        if !packet.marker { return None; }
        self.last_frame_packets = std::mem::take(&mut self.current_frame_packets);
        // Receipt pacing must continue even if an AU was discarded after loss.
        Some(build_frame_ack(self.our_ssrc, packet.timestamp))
    }
    fn control_report(&self) -> Option<Vec<u8>> {
        self.base?;
        Some(build_rctl(self.our_ssrc, self.timestamp, self.last_frame_packets, self.packets, RECEIVER_BANDWIDTH_KBPS))
    }
    fn liveness_report(&mut self) -> Vec<u8> {
        let expected = self.base.map(|_| self.highest.saturating_add(1)).unwrap_or(0);
        let interval_expected = expected.saturating_sub(self.previous_expected);
        let interval_received = self.packets.saturating_sub(self.previous_received);
        let loss = interval_expected.saturating_sub(interval_received);
        let fraction = if interval_expected == 0 { 0 } else { ((u64::from(loss)*256/u64::from(interval_expected)).min(255)) as u8 };
        self.previous_expected = expected; self.previous_received = self.packets;
        let (lsr,dlsr) = self.sender_report.map(|(lsr,at)| (lsr,(at.elapsed().as_secs_f64()*65536.0).min(u32::MAX as f64) as u32)).unwrap_or((0,0));
        build_liveness(self.our_ssrc, &self.cname, &[ReportBlock {
            source_ssrc: self.media_ssrc, fraction_lost: fraction,
            cumulative_lost: expected.saturating_sub(self.packets).min(0x7fffff),
            highest_seq: self.base.map(|base| u32::from(base).wrapping_add(self.highest)).unwrap_or(0),
            jitter: 0, lsr, dlsr,
        }])
    }
    fn keyframe_request(&mut self) -> Vec<u8> {
        // PLI and FIR reached the same iOS encoder hook; sending both together
        // generated "Request key frame too soon, discard" for the duplicate.
        build_pli(self.our_ssrc, self.media_ssrc)
    }

}
/// Authenticated stream configuration, never infer RTCP destination from the offer.
fn feedback_endpoint(value: &plist::Value) -> Option<(u16,u32,u32)> {
    fn number(d: &plist::Dictionary, key: &str) -> Option<u64> { d.get(key)?.as_unsigned_integer() }
    fn visit(v: &plist::Value, depth: usize, found: &mut Vec<(u16,u32,u32)>) {
        if depth > 5 { return; }
        if let Some(d) = v.as_dictionary() {
            if let (Some(port),Some(sender),Some(receiver)) = (number(d,"SourcePort"),number(d,"LocalSSRC"),number(d,"RemoteSSRC")) {
                if let (Ok(port),Ok(sender),Ok(receiver)) = (u16::try_from(port),u32::try_from(sender),u32::try_from(receiver)) {
                    if port != 0 && sender != 0 && receiver != 0 { found.push((port,sender,receiver)); }
                }
            }
            for child in d.values() { visit(child,depth+1,found); }
        }
    }
    let mut found=Vec::new(); visit(value,0,&mut found);
    if found.len()==1 { Some(found[0]) } else { None }
}
fn extract_answer(value: &plist::Value) -> Result<&[u8], Error> {
    fn visit<'a>(
        v: &'a plist::Value,
        depth: usize,
        count: &mut usize,
        answer: &mut Option<&'a [u8]>,
    ) {
        if depth > 4 {
            return;
        }
        match v {
            plist::Value::Dictionary(d) => {
                for (k, v) in d {
                    if k == "negotiatorAnswer" {
                        *count += 1;
                        *answer = v.as_data();
                    } else {
                        visit(v, depth + 1, count, answer);
                    }
                }
            }
            plist::Value::Array(a) => {
                for v in a {
                    visit(v, depth + 1, count, answer);
                }
            }
            _ => {}
        }
    }
    let mut count = 0;
    let mut answer = None;
    visit(value, 0, &mut count, &mut answer);
    answer
        .filter(|v| count == 1 && !v.is_empty() && v.len() <= 1024 * 1024)
        .ok_or(error(Stage::Media, Cause::Protocol))
}
#[cfg(test)]
mod tests {
    #[test]
    fn changed_geometry_is_rejected_at_last_pre_down_gate() {
        let video = crate::video::VideoMailbox::default(); video.begin_stream();
        let capture = video.geometry_generation();
        assert!(super::check_geometry(Some((&video, capture))).is_ok());
        video.invalidate_geometry();
        assert!(super::check_geometry(Some((&video, capture))).is_err());
        assert!(super::check_geometry(None).is_ok());
    }
    #[test]
    fn stop_requires_peer_confirmation_and_does_not_confuse_other_streams() {
        fn response(ids: &[u32]) -> plist::Value {
            let sessions = ids.iter().map(|id| {
                let mut config = plist::Dictionary::new(); config.insert("RemoteSSRC".into(), (*id).into());
                let mut connection = plist::Dictionary::new(); connection.insert("streamConfig".into(), config.into());
                let mut session = plist::Dictionary::new(); session.insert("connection".into(), connection.into());
                session.into()
            }).collect();
            let mut server = plist::Dictionary::new(); server.insert("sessions".into(), plist::Value::Array(sessions));
            let mut reply = plist::Dictionary::new(); reply.insert("serverInfo".into(), server.into()); reply.into()
        }
        assert!(!super::stop_confirmed(&response(&[7,9]),7));
        assert!(super::stop_confirmed(&response(&[9]),7));
        assert!(super::stop_confirmed(&response(&[]),7));
        assert!(!super::stop_confirmed(&plist::Value::Dictionary(Default::default()),7));
    }
    #[test]
    fn geometry_selects_exact_display_and_rejects_stale_or_ambiguous_data() {
        use plist::Value as V;
        fn display(id: i64, w: f64, h: f64) -> V {
            V::Dictionary(plist::Dictionary::from_iter([
                (String::from("displayId"), V::Integer(id.into())),
                (
                    String::from("frame"),
                    V::Array(vec![
                        V::Array(vec![V::Real(0.0), V::Real(0.0)]),
                        V::Array(vec![V::Real(w), V::Real(h)]),
                    ]),
                ),
            ]))
        }
        fn root(current: bool, displays: Vec<V>) -> V {
            V::Dictionary(plist::Dictionary::from_iter([
                (String::from("current"), V::Boolean(current)),
                (String::from("displays"), V::Array(displays)),
            ]))
        }
        let phone = display(1, 1179.0, 2556.0);
        assert_eq!(
            super::display_geometry(
                &root(true, vec![display(3, 1184.0, 2560.0), phone.clone()]),
                1
            ),
            Some((1179, 2556))
        );
        assert_eq!(
            super::display_geometry(&root(true, vec![display(1, 2556.0, 1179.0)]), 1),
            Some((2556, 1179))
        );
        for value in [
            root(false, vec![phone.clone()]),
            root(true, vec![phone.clone(), phone]),
            root(true, vec![display(3, 1184.0, 2560.0)]),
            root(true, vec![display(1, 1179.5, 2556.0)]),
            root(true, vec![display(1, 0.0, 0.0)]),
        ] {
            assert_eq!(super::display_geometry(&value, 1), None);
        }
    }

    use super::*;
    #[test]
    fn media_admission_keeps_authenticated_identity_without_assuming_source_port() {
        let expected = idevice::core_device::display_stream::negotiation::ScreenVideoStream {
            payload_type: 100,
            ssrc: 7,
        };
        let mut p = vec![0x80, 100, 255, 255, 0, 0, 0, 0, 0, 0, 0, 7, 1];
        assert!(parse_video_packet(&p, expected).is_some());
        // Reorder/duplicates belong to the AU assembler, not a separate sequence filter.
        p[2] = 0;
        p[3] = 0;
        assert!(parse_video_packet(&p, expected).is_some());
        p[11] = 8;
        assert!(parse_video_packet(&p, expected).is_none());
        p[11] = 7;
        p[1] = 101;
        assert!(parse_video_packet(&p, expected).is_none());
        assert!(parse_video_packet(&[0; 11], expected).is_none());
        assert!(parse_video_packet(&build_liveness(7, "test", &[]), expected).is_none());
    }
    #[test]
    fn synthetic_rtp_reaches_complete_hevc_handoff_and_frame_ack() {
        // Same synthetic green 64x96 sample decoded by the Swift/VideoToolbox tests.
        let mut bytes = vec![0x80, 0x80 | 100, 0, 1, 0, 0, 0, 2, 0, 0, 0, 7];
        bytes.extend_from_slice(&[
            96, 1, 0, 24, 64, 1, 12, 1, 255, 255, 1, 96, 0, 0, 3, 0, 144, 0, 0, 3, 0, 0, 3, 0, 30,
            149, 152, 9, 0, 41, 66, 1, 1, 1, 96, 0, 0, 3, 0, 144, 0, 0, 3, 0, 0, 3, 0, 30, 160, 32,
            129, 133, 150, 86, 105, 36, 202, 240, 22, 128, 128, 0, 0, 3, 0, 128, 0, 0, 3, 0, 132,
            0, 7, 68, 1, 193, 114, 180, 34, 64, 0, 22, 40, 1, 175, 19, 128, 229, 50, 81, 255, 218,
            40, 255, 167, 213, 254, 128, 107, 64, 8, 35, 29, 135,
        ]);
        let stream = idevice::core_device::display_stream::negotiation::ScreenVideoStream {
            payload_type: 100,
            ssrc: 7,
        };
        let packet = parse_video_packet(&bytes, stream).unwrap();
        let mut assembler = HevcAccessUnitAssembler::new(100, 7);
        let mailbox = crate::video::VideoMailbox::default();
        mailbox.begin_stream();
        mailbox.received_from(49152); // Dynamic inbound source port must be admitted.
        let mut feedback = VideoFeedback::new(11, 7, "synthetic".into());
        assert_eq!(feedback.observe_packet(&packet), Some(build_frame_ack(11, 2)));
        for event in assembler.push_packet(&packet) {
            if let HevcDepacketizerEvent::AccessUnit(unit) = event {
                assert!(mailbox.push(unit, assembler.parameter_sets().unwrap()));
            }
        }
        assert!(assembler.is_complete());
        mailbox.sender_report(feedback.unique_packets == 1 && assembler.is_complete());
        assert_eq!(mailbox.snapshot().serial, 1);
        // A missing FU fragment invalidates an otherwise complete picture.
        let partial = RtpPacket { sequence_number: 3, timestamp: 3, marker: true, ..packet.clone() };
        assembler.push_packet(&partial);
        assert!(!assembler.is_complete());
        mailbox.sender_report(assembler.is_complete());
        assert_eq!(mailbox.snapshot().serial, 0);
        assert_eq!(mailbox.poll(0).0, 14);
        let (_, size, _) = mailbox.poll(0);
        let (_, _, data) = mailbox.poll(size);
        let data = data.expect("complete HEVC access unit reaches App handoff");
        assert_eq!(u32::from_le_bytes(data[40..44].try_into().unwrap()), 64);
        assert_eq!(u32::from_le_bytes(data[44..48].try_into().unwrap()), 96);
        assert_eq!(feedback.packets, 1);
    }
    #[test]
    fn receiver_feedback_tracks_real_frames_wraparound_and_compound_refresh() {
        let mut f = VideoFeedback::new(11, 22, "public-fixture".into());
        assert!(f.control_report().is_none());
        let raw = |seq: u16, ts: u32, marker: bool| {
            let mut b = vec![0x80, 100 | if marker { 0x80 } else { 0 }];
            b.extend_from_slice(&seq.to_be_bytes()); b.extend_from_slice(&ts.to_be_bytes());
            b.extend_from_slice(&22u32.to_be_bytes()); b.extend_from_slice(&[2,1,0x80]); b
        };
        let a = raw(65535, 1000, false); let b = raw(0, 1234, true);
        assert!(f.observe_packet(&RtpPacket::parse_checked(&a).unwrap()).is_none());
        assert_eq!(f.observe_packet(&RtpPacket::parse_checked(&b).unwrap()), Some(build_frame_ack(11,1234)));
        assert!(f.observe_packet(&RtpPacket::parse_checked(&a).unwrap()).is_none());
        assert_eq!(f.highest, 1);
        assert_eq!(f.control_report().unwrap(), build_rctl(11,1234,2,3, RECEIVER_BANDWIDTH_KBPS));
        // Sequence loss must not stop sender receipt pacing while awaiting IDR.
        let c = raw(50, 2000, true);
        assert_eq!(f.observe_packet(&RtpPacket::parse_checked(&c).unwrap()), Some(build_frame_ack(11,2000)));
        let rr = f.liveness_report();
        assert_eq!(rr[0] & 31,1,"One receiver-report block must be sent even during IDR recovery");
        assert_eq!(&rr[8..12],&22u32.to_be_bytes());
        assert_eq!(&rr[16..20],&65586u32.to_be_bytes(),"Extended sequence includes the initial base and wrap");
        assert!(rr[12] > 0,"Loss is reported to the sender rather than assumed zero");
        let request = f.keyframe_request();
        assert_eq!(request, build_pli(11,22));
        assert_eq!(f.unique_packets, 3, "Duplicates must not satisfy a sender progress barrier");
    }
    #[test]
    fn reordered_marker_is_received_and_acknowledged_without_false_loss() {
        let mut feedback = VideoFeedback::new(11,22,"reorder".into());
        for (seq,marker) in [(10u16,false),(12,false),(11,true)] {
            let mut bytes = vec![0x80,100 | if marker { 0x80 } else { 0 }];
            bytes.extend_from_slice(&seq.to_be_bytes());
            bytes.extend_from_slice(&1234u32.to_be_bytes());
            bytes.extend_from_slice(&22u32.to_be_bytes());
            bytes.extend_from_slice(&[2,1,0x80]);
            let ack = feedback.observe_packet(&RtpPacket::parse_checked(&bytes).unwrap());
            assert_eq!(ack, marker.then(|| build_frame_ack(11,1234)));
        }
        let report = feedback.liveness_report();
        assert_eq!(&report[12..16], &[0,0,0,0], "Reordering must not report packet loss");
        assert_eq!(&report[16..20], &12u32.to_be_bytes());
        assert_eq!(feedback.control_report().unwrap(), build_rctl(11,1234,3,3, RECEIVER_BANDWIDTH_KBPS));
    }
    #[test]
    fn feedback_uses_authenticated_dynamic_port_and_both_ssrc_roles() {
        let mut cfg=plist::Dictionary::new();
        cfg.insert("SourcePort".into(),plist::Value::Integer(53134u64.into()));
        cfg.insert("LocalSSRC".into(),plist::Value::Integer(22u64.into()));
        cfg.insert("RemoteSSRC".into(),plist::Value::Integer(11u64.into()));
        let mut connection=plist::Dictionary::new();
        connection.insert("streamConfig".into(),plist::Value::Dictionary(cfg.clone()));
        let mut answer=plist::Dictionary::new(); answer.insert("connection".into(),plist::Value::Dictionary(connection));
        assert_eq!(feedback_endpoint(&plist::Value::Dictionary(answer)),Some((53134,22,11)));
        cfg.insert("SourcePort".into(),plist::Value::Integer(65536u64.into()));
        assert_eq!(feedback_endpoint(&plist::Value::Dictionary(cfg.clone())),None);
        cfg.insert("SourcePort".into(),plist::Value::Integer(0u64.into()));
        assert_eq!(feedback_endpoint(&plist::Value::Dictionary(cfg)),None);
    }
    #[test]
    fn answer_must_be_unique_bounded_data() {
        let mut d = plist::Dictionary::new();
        d.insert("negotiatorAnswer".into(), plist::Value::Data(vec![1]));
        let one = plist::Value::Dictionary(d);
        assert_eq!(extract_answer(&one).unwrap(), &[1]);
        assert!(extract_answer(&plist::Value::Array(vec![one.clone(), one])).is_err());
        assert!(extract_answer(&plist::Value::Data(vec![])).is_err());
    }
    #[tokio::test]
    async fn dropping_drains_aborts_consumers() {
        let task = tokio::spawn(std::future::pending::<()>());
        let handle = task.abort_handle();
        drop(Drains(vec![task]));
        tokio::task::yield_now().await;
        assert!(handle.is_finished());
    }
}
