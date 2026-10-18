// SPDX-License-Identifier: GPL-3.0-only
//! Bounded, generation-scoped HEVC handoff. Never persists media or replays input.
use idevice::core_device::display_stream::hevc::{HevcAccessUnit, HevcParameterSets};
use std::{
    collections::VecDeque,
    sync::{
        Mutex,
        atomic::{AtomicBool, AtomicU64, Ordering},
    },
    time::Instant,
};
const MAX_BYTES: usize = 8 * 1024 * 1024;
const MAX_FRAMES: usize = 64;
struct Sample {
    unit: HevcAccessUnit,
    params: HevcParameterSets,
    received: Instant,
    serial: u64,
    epoch: u64,
    visible: Option<(u32, u32)>,
    geometry_generation: u64,
}
#[derive(Default)]
struct Queue {
    samples: VecDeque<Sample>,
    bytes: usize,
    have_sync: bool,
    serial: u64,
    epoch: u64,
    revision: Option<u64>,
    reset: bool,
    visible: Option<(u32, u32)>,
    report: u64,
    confirmed_serial: u64,
    geometry_generation: u64,
    delivered_geometry: Option<(u64, u64, u64)>,
}
#[derive(Default)]
pub(crate) struct VideoMailbox(Mutex<Queue>, AtomicBool, [AtomicU64; 8]);
#[repr(C)]
#[derive(Default, Copy, Clone, Debug)]
pub struct VideoStatus {
    pub datagrams: u64,
    pub rtp: u64,
    pub rejected: u64,
    pub frames: u64,
    pub discontinuities: u64,
    pub overflows: u64,
    pub refreshes: u64,
    pub source_port: u64,
}
/// Separate additive ABI: the existing statistics struct keeps its layout.
#[repr(C)]
#[derive(Default, Copy, Clone, Debug)]
pub struct VideoSnapshot {
    pub report: u64,
    pub epoch: u64,
    pub serial: u64,
}
impl VideoMailbox {
    pub fn geometry_generation(&self) -> u64 {
        self.0.lock().map(|q| q.geometry_generation).unwrap_or(0)
    }
    pub fn invalidate_geometry(&self) -> u64 {
        self.0.lock().map(|mut q| {
            q.geometry_generation = q.geometry_generation.wrapping_add(1).max(1);
            q.geometry_generation
        }).unwrap_or(0)
    }
    pub fn sample_geometry(&self, serial: u64, epoch: u64) -> u64 {
        self.0.lock().map(|q| match q.delivered_geometry {
            Some((s, e, g)) if s == serial && e == epoch && g == q.geometry_generation => g,
            _ => 0,
        }).unwrap_or(0)
    }
    pub fn publish_decoded_geometry(&self, expected: u64) -> u64 {
        self.0.lock().map(|mut q| {
            if expected == 0 || expected != q.geometry_generation { return 0; }
            q.geometry_generation = q.geometry_generation.wrapping_add(1).max(1);
            q.geometry_generation
        }).unwrap_or(0)
    }
    pub fn matches_geometry(&self, expected: u64) -> bool {
        expected != 0 && self.geometry_generation() == expected
    }

    pub fn snapshot(&self) -> VideoSnapshot {
        self.0.lock().map(|q| VideoSnapshot { report: q.report, epoch: q.epoch, serial: q.confirmed_serial }).unwrap_or_default()
    }
    pub fn packet_pending(&self) {
        if let Ok(mut q) = self.0.lock() { q.confirmed_serial = 0; }
    }
    pub fn sender_report(&self, complete: bool) {
        if let Ok(mut q) = self.0.lock() {
            q.report += 1;
            q.confirmed_serial = if complete && q.have_sync { q.serial } else { 0 };
        }
    }

    pub fn begin_stream(&self) {
        for value in &self.2 {
            value.store(0, Ordering::Relaxed);
        }
        self.1.store(false, Ordering::SeqCst);
        self.reset();
        self.set_visible_size(None);
    }
    pub fn set_visible_size(&self, size: Option<(u32, u32)>) {
        if let Ok(mut q) = self.0.lock() {
            if q.visible != size {
                q.geometry_generation = q.geometry_generation.wrapping_add(1).max(1);
                q.visible = size;
            }
        }
    }
    pub fn count(&self, index: usize) {
        self.2[index].fetch_add(1, Ordering::Relaxed);
    }
    pub fn received_from(&self, port: u16) {
        self.count(0);
        self.2[7].store(u64::from(port), Ordering::Relaxed);
    }
    pub fn status(&self) -> VideoStatus {
        let v = self.2.each_ref().map(|v| v.load(Ordering::Relaxed));
        VideoStatus {
            datagrams: v[0],
            rtp: v[1],
            rejected: v[2],
            frames: v[3],
            discontinuities: v[4],
            overflows: v[5],
            refreshes: v[6],
            source_port: v[7],
        }
    }
    pub fn request_refresh(&self) {
        self.1.store(true, Ordering::SeqCst);
    }
    pub fn take_refresh(&self) -> bool {
        self.1.swap(false, Ordering::SeqCst)
    }
    pub fn reset(&self) {
        if let Ok(mut q) = self.0.lock() {
            q.samples.clear();
            q.bytes = 0;
            q.have_sync = false;
            q.revision = None;
            q.epoch += 1;
            q.geometry_generation = q.geometry_generation.wrapping_add(1).max(1);
            q.reset = true;
            q.confirmed_serial = 0;
        }
    }
    pub fn push(&self, unit: HevcAccessUnit, params: HevcParameterSets) -> bool {
        let Ok(mut q) = self.0.lock() else {
            return false;
        };
        // Even when no sample is pending, a configuration change invalidates
        // the previously decoded image in Swift before any new pixels are used.
        if q.revision
            .is_some_and(|revision| revision != params.revision)
        {
            q.samples.clear();
            q.bytes = 0;
            q.have_sync = false;
            q.epoch += 1;
            q.geometry_generation = q.geometry_generation.wrapping_add(1).max(1);
            q.reset = true;
            q.confirmed_serial = 0;
        }
        q.revision = Some(params.revision);
        // P-frames are required to update the decoded picture after the first
        // keyframe. Ignore them only until a valid reference chain exists.
        if !unit.is_sync && !q.have_sync {
            return true;
        }
        if unit.is_sync {
            q.samples.clear();
            q.bytes = 0;
            q.have_sync = true;
        }
        let visible = q.visible.filter(|&(w, h)| {
            w > 0
                && h > 0
                && w <= params.pixel_width
                && h <= params.pixel_height
                && params.pixel_width - w < 64
                && params.pixel_height - h < 64
        });
        let size = unit.bytes.len()
            + params.video_parameter_set.len()
            + params.sequence_parameter_set.len()
            + params.picture_parameter_set.len()
            + 64
            + if visible.is_some() { 8 } else { 0 };
        if size > MAX_BYTES || q.bytes + size > MAX_BYTES || q.samples.len() >= MAX_FRAMES {
            self.count(5);
            q.samples.clear();
            q.bytes = 0;
            q.have_sync = false;
            q.epoch += 1;
            q.geometry_generation = q.geometry_generation.wrapping_add(1).max(1);
            q.reset = true;
            q.confirmed_serial = 0;
            return false;
        }
        q.serial += 1;
        let (serial, epoch, geometry_generation) = (q.serial, q.epoch, q.geometry_generation);
        q.bytes += size;
        q.samples.push_back(Sample {
            unit,
            params,
            received: Instant::now(),
            serial,
            epoch,
            visible,
            geometry_generation,
        });
        true
    }
    /// Reset receipts precede all new-generation samples. Insufficient capacity
    /// never consumes a sample. Header: four LE u64s, then eight LE u32s.
    pub fn poll(&self, capacity: usize) -> (u32, usize, Option<Vec<u8>>) {
        let Ok(mut q) = self.0.lock() else {
            return (0, 0, None);
        };
        if q.reset {
            q.reset = false;
            return (14, 0, Some(Vec::new()));
        }
        let Some(s) = q.samples.front() else {
            return (0, 0, None);
        };
        let size = 64
            + if s.visible.is_some() { 8 } else { 0 }
            + s.params.video_parameter_set.len()
            + s.params.sequence_parameter_set.len()
            + s.params.picture_parameter_set.len()
            + s.unit.bytes.len();
        if capacity < size {
            return (13, size, None);
        }
        let s = q.samples.pop_front().unwrap();
        q.delivered_geometry = Some((s.serial, s.epoch, s.geometry_generation));
        q.bytes -= size;
        let mut out = Vec::with_capacity(size);
        for n in [
            s.serial,
            s.epoch,
            s.received.elapsed().as_millis().min(u64::MAX as u128) as u64,
            s.params.revision,
        ] {
            out.extend_from_slice(&n.to_le_bytes());
        }
        for n in [
            s.unit.rtp_timestamp,
            u32::from(s.unit.is_sync) | if s.visible.is_some() { 2 } else { 0 },
            s.params.pixel_width,
            s.params.pixel_height,
            s.params.video_parameter_set.len() as u32,
            s.params.sequence_parameter_set.len() as u32,
            s.params.picture_parameter_set.len() as u32,
            s.unit.bytes.len() as u32,
        ] {
            out.extend_from_slice(&n.to_le_bytes());
        }
        if let Some((w, h)) = s.visible {
            out.extend_from_slice(&w.to_le_bytes());
            out.extend_from_slice(&h.to_le_bytes());
        }
        for bytes in [
            &s.params.video_parameter_set,
            &s.params.sequence_parameter_set,
            &s.params.picture_parameter_set,
            &s.unit.bytes,
        ] {
            out.extend_from_slice(bytes);
        }
        (13, size, Some(out))
    }
}
#[cfg(test)]
mod tests {
    use super::*;
    fn sample(sync: bool) -> (HevcAccessUnit, HevcParameterSets) {
        (
            HevcAccessUnit {
                ssrc: 1,
                rtp_timestamp: 2,
                first_sequence_number: 1,
                last_sequence_number: 1,
                parameter_set_revision: 1,
                is_sync: sync,
                bytes: vec![0, 0, 0, 2, 2, 1],
            },
            HevcParameterSets {
                revision: 1,
                pixel_width: 10,
                pixel_height: 20,
                video_parameter_set: vec![1],
                sequence_parameter_set: vec![2],
                picture_parameter_set: vec![3],
            },
        )
    }
    #[test]
    fn stale_queued_sample_cannot_receive_a_new_geometry_credential() {
        let q = VideoMailbox::default(); q.begin_stream(); q.poll(0);
        let (u, p) = sample(true); q.push(u, p);
        let old = q.geometry_generation();
        q.set_visible_size(Some((9, 18)));
        let current = q.geometry_generation(); assert_ne!(old, current);
        let (_, _, bytes) = q.poll(1024); let bytes = bytes.unwrap();
        let serial = u64::from_le_bytes(bytes[0..8].try_into().unwrap());
        let epoch = u64::from_le_bytes(bytes[8..16].try_into().unwrap());
        assert_eq!(q.sample_geometry(serial, epoch), 0, "Old decoded raster cannot borrow a newly observed source credential");
        assert_eq!(q.publish_decoded_geometry(old), 0, "A delayed Swift crop publication cannot resurrect invalidated input");
        let (u, p) = sample(true); q.push(u, p);
        let (_, _, bytes) = q.poll(1024); let bytes = bytes.unwrap();
        let serial = u64::from_le_bytes(bytes[0..8].try_into().unwrap());
        let epoch = u64::from_le_bytes(bytes[8..16].try_into().unwrap());
        assert_eq!(q.sample_geometry(serial, epoch), current);
        let published = q.publish_decoded_geometry(current);
        assert_ne!(published, 0); assert_ne!(published, current);
        assert!(q.matches_geometry(published));
    }
    #[test]
    fn geometry_credentials_track_known_changes_not_animation() {
        let q = VideoMailbox::default();
        assert!(!q.matches_geometry(0));
        q.begin_stream(); q.poll(0);
        q.set_visible_size(Some((9, 18)));
        let (u, p) = sample(true); q.push(u, p);
        let capture = q.geometry_generation();
        q.set_visible_size(Some((9, 18)));
        let (u, p) = sample(false); q.push(u, p);
        assert!(q.matches_geometry(capture), "Repeated dimensions and P-frame pixels do not revoke coordinates");
        q.set_visible_size(Some((18, 9)));
        assert!(!q.matches_geometry(capture));
        let capture = q.geometry_generation();
        let (u, mut p) = sample(true); p.revision = 2; q.push(u, p);
        assert!(!q.matches_geometry(capture), "SPS revision invalidates queued input");
        let capture = q.geometry_generation();
        q.invalidate_geometry();
        assert!(!q.matches_geometry(capture), "Swift decoded crop changes publish invalidation without a system query");
        let capture = q.geometry_generation(); q.reset();
        assert!(!q.matches_geometry(capture));
    }
    #[test]
    fn snapshot_requires_sender_progress_and_valid_complete_epoch() {
        let q = VideoMailbox::default(); q.begin_stream(); q.poll(0);
        let (u,p) = sample(true); assert!(q.push(u,p));
        assert_eq!(q.snapshot().serial, 0, "No sender confirmation yet");
        q.sender_report(false); assert_eq!(q.snapshot().serial, 0, "Unreceived/partial packets cannot confirm a picture");
        q.sender_report(true); let confirmed=q.snapshot();
        assert_eq!(confirmed.serial, 1); assert_eq!(confirmed.report, 2);
        q.sender_report(true);
        assert_eq!(q.snapshot().serial, 1, "Idle screen keeps the same valid picture");
        assert!(q.snapshot().report > confirmed.report, "Fresh peer progress without a new frame");
        q.packet_pending(); assert_eq!(q.snapshot().serial, 0, "New unassembled data invalidates the old confirmation");
        q.reset(); q.sender_report(true);
        assert_eq!(q.snapshot().serial, 0); assert_ne!(q.snapshot().epoch, confirmed.epoch);
    }
    #[test]
    fn display_geometry_is_snapshotted_and_checked_against_each_picture() {
        let q = VideoMailbox::default();
        q.begin_stream();
        q.poll(0);
        q.set_visible_size(Some((9, 18)));
        let (u, p) = sample(true);
        assert!(q.push(u, p));
        q.set_visible_size(Some((18, 9))); // orientation changed after enqueue
        let (_, size, data) = q.poll(1024);
        let data = data.unwrap();
        assert_eq!(size, 81);
        assert_eq!(data[36], 3);
        assert_eq!(u32::from_le_bytes(data[64..68].try_into().unwrap()), 9);
        assert_eq!(u32::from_le_bytes(data[68..72].try_into().unwrap()), 18);
        let (u, p) = sample(true);
        assert!(q.push(u, p));
        let (_, size, data) = q.poll(1024);
        assert_eq!(size, 73);
        assert_eq!(
            data.unwrap()[36],
            1,
            "Wrong orientation must never crop the picture"
        );
        q.begin_stream();
        q.set_visible_size(None);
        q.poll(0);
        let (u, p) = sample(true);
        assert!(q.push(u, p));
        assert_eq!(q.poll(1024).2.unwrap()[36], 1);
    }
    #[test]
    fn slow_consumer_keeps_latest_independent_picture_without_overflow_or_reset() {
        let q = VideoMailbox::default();
        q.begin_stream();
        assert_eq!(q.poll(0).0, 14);
        for timestamp in 0..1000 {
            let (mut u, p) = sample(true);
            u.rtp_timestamp = timestamp;
            assert!(q.push(u, p));
            for _ in 0..10 {
                let (u, p) = sample(false);
                assert!(q.push(u, p));
            }
        }
        assert_eq!(q.status().overflows, 0);
        assert_eq!(q.poll(0).0, 13);
        assert_eq!(q.poll(0).1, 73);
        let (_, size, data) = q.poll(73);
        assert_eq!(size, 73);
        let data = data.unwrap();
        assert_eq!(u32::from_le_bytes(data[32..36].try_into().unwrap()), 999);
        assert_eq!(u64::from_le_bytes(data[0..8].try_into().unwrap()), 10990);
        for _ in 0..10 {
            assert_eq!(q.poll(100).0, 13);
        }
        assert_eq!(q.poll(100).0, 0);
    }
    #[test]
    fn inter_frames_preserve_order_and_overflow_discards_the_reference_chain() {
        let q = VideoMailbox::default();
        let (u, p) = sample(true);
        assert!(q.push(u, p));
        for _ in 1..MAX_FRAMES {
            let (u, p) = sample(false);
            assert!(q.push(u, p));
        }
        let (u, p) = sample(false);
        assert!(!q.push(u, p));
        assert_eq!(q.status().overflows, 1);
        assert_eq!(q.poll(100).0, 14);
        let (u, p) = sample(false);
        assert!(q.push(u, p));
        assert_eq!(q.poll(100).0, 0);
        let (u, p) = sample(true);
        assert!(q.push(u, p));
        let (u, p) = sample(false);
        assert!(q.push(u, p));
        let a = q.poll(100).2.unwrap();
        let b = q.poll(100).2.unwrap();
        assert_eq!(u32::from_le_bytes(a[36..40].try_into().unwrap()), 1);
        assert_eq!(u32::from_le_bytes(b[36..40].try_into().unwrap()), 0);
        assert!(
            u64::from_le_bytes(b[0..8].try_into().unwrap())
                > u64::from_le_bytes(a[0..8].try_into().unwrap())
        );
    }
    #[test]
    fn oversized_picture_is_bounded_and_requires_a_new_independent_picture() {
        let q = VideoMailbox::default();
        let (mut u, p) = sample(true);
        u.bytes.resize(MAX_BYTES + 1, 0);
        assert!(!q.push(u, p));
        assert_eq!(q.status().overflows, 1);
        assert_eq!(q.poll(0).0, 14);
        let (u, p) = sample(false);
        assert!(q.push(u, p));
        assert_eq!(q.poll(0).0, 0);
        let (u, p) = sample(true);
        assert!(q.push(u, p));
        assert_eq!(q.poll(0).0, 13);
    }
    #[test]
    fn configuration_change_without_a_sync_picture_invalidates_previous_pixels() {
        let q = VideoMailbox::default();
        let (u, p) = sample(true);
        assert!(q.push(u, p));
        let (_, size, _) = q.poll(0);
        assert!(q.poll(size).2.is_some());
        let (u, mut p) = sample(false);
        p.revision = 2;
        assert!(q.push(u, p));
        assert_eq!(
            q.poll(0).0,
            14,
            "Invalidate decoded pixels even if Rust slot was consumed"
        );
        assert_eq!(
            q.poll(0).0,
            0,
            "Never hand an inter picture to an independent decoder"
        );
        let (u, mut p) = sample(true);
        p.revision = 2;
        assert!(q.push(u, p));
        assert_eq!(q.poll(0).0, 13);
    }
    #[test]
    fn receiver_status_survives_frame_resets_but_not_a_new_stream() {
        let q = VideoMailbox::default();
        q.begin_stream();
        q.received_from(49152);
        q.count(1);
        q.count(6);
        let s = q.status();
        assert_eq!(s.datagrams, 1);
        assert_eq!(s.rtp, 1);
        assert_eq!(s.source_port, 49152);
        q.reset();
        assert_eq!(q.status().refreshes, 1);
        q.begin_stream();
        assert_eq!(q.status().datagrams, 0);
        assert_eq!(q.status().refreshes, 0);
    }
    #[test]
    fn reset_drops_old_images_before_new_generation() {
        let q = VideoMailbox::default();
        let (u, p) = sample(true);
        assert!(q.push(u, p));
        q.reset();
        assert_eq!(q.poll(100).0, 14);
        assert_eq!(q.poll(100).0, 0);
        let (u, p) = sample(false);
        assert!(q.push(u, p));
        assert_eq!(q.poll(100).0, 0);
    }
}
