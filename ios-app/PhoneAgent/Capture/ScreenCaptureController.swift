import Foundation
import Combine
import CoreMedia
import UIKit

/// Main-actor state: exactly one caller owns the SDK stop. A stop requested
/// during start waits for start's completion; system termination needs no stop.
struct CaptureStreamLifecycle {
    private enum Phase { case starting, running, stopAfterStart, stopping }
    private var phase: Phase?
    private(set) var token: UUID?
    mutating func begin() -> UUID? {
        guard token == nil else { return nil }
        let next = UUID(); token = next; phase = .starting; return next
    }
    func owns(_ expected: UUID) -> Bool { token == expected }
    mutating func started(_ expected: UUID) -> Bool {
        guard owns(expected) else { return false }
        if phase == .stopAfterStart { phase = .stopping; return true }
        if phase == .starting { phase = .running }
        return false
    }
    mutating func requestStop() -> Bool {
        if phase == .starting { phase = .stopAfterStart }
        else if phase == .running { phase = .stopping; return true }
        return false
    }
    @discardableResult mutating func ended(_ expected: UUID) -> Bool {
        guard owns(expected) else { return false }
        token = nil; phase = nil; return true
    }
}

#if canImport(ScreenCaptureKit) && !targetEnvironment(simulator)
import ScreenCaptureKit

// Picker filters are read-only framework snapshots, handed once to the main actor.
private struct PickerSelection: @unchecked Sendable { let filter: SCContentFilter }

@available(iOS 27.0, *)
final class ScreenSampleSink: NSObject, SCStreamOutput, @unchecked Sendable {
    let frames: LatestScreenFrame
    let epoch: UUID
    let onLoss: @Sendable (Bool) -> Void
    init(frames: LatestScreenFrame, epoch: UUID, onLoss: @escaping @Sendable (Bool) -> Void) {
        self.frames = frames; self.epoch = epoch; self.onLoss = onLoss
    }
    func stream(_ stream: SCStream, didOutputSampleBuffer buffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen else { return }
        func reject(_ reason: String, orientation: String? = nil) {
            frames.recordSample(epoch: epoch, rejection: reason, orientation: orientation)
        }
        guard buffer.isValid else { reject("invalidBuffer"); return }
        guard let info = (CMSampleBufferGetSampleAttachmentsArray(buffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]])?.first else {
            reject("missingAttachments"); return
        }
        let status = (info[.status] as? SCFrameStatus) ?? (info[.status] as? Int).flatMap(SCFrameStatus.init(rawValue:))
        guard let status else { reject("missingStatus"); return }
        if status == .stopped || status == .suspended || status == .blank {
            reject(status == .stopped ? "stopped" : (status == .blank ? "blank" : "suspended"))
            frames.invalidate(epoch: epoch); onLoss(status == .stopped); return
        }
        // .started can contain the first valid frame. Idle retains the existing sample.
        guard status == .complete || status == .started else { reject("idle"); return }
        guard let pixel = CMSampleBufferGetImageBuffer(buffer) else { reject("missingPixelBuffer"); return }
        let metadata = CaptureSampleMetadata.videoOrientation(in: buffer, key: SCStreamFrameInfo.videoOrientation.rawValue)
        guard let orientation = metadata.value else {
            reject(metadata.rejection ?? "invalidVideoOrientation", orientation: metadata.diagnostic); return
        }
        let timestamp = buffer.presentationTimeStamp.seconds
        guard timestamp.isFinite else { reject("invalidTimestamp", orientation: metadata.diagnostic); return }
        frames.recordSample(epoch: epoch, orientation: metadata.diagnostic)
        frames.put(pixel, orientation: orientation, presentationSeconds: timestamp, epoch: epoch)
    }
}

@available(iOS 27.0, *)
@MainActor final class ScreenCaptureController: NSObject, ObservableObject, SCContentSharingPickerObserver, SCStreamDelegate {
    @Published private(set) var status = String(localized: "Capture is off. Confirm full-screen capture in the system panel.")
    @Published private(set) var active = false
    @Published private(set) var busy = false
    let isSupported = true
    let frames = LatestScreenFrame()
    private var stream: SCStream?
    private var sink: ScreenSampleSink?
    private var lifecycle = CaptureStreamLifecycle()
    private var pending = false
    private var monitor: Task<Void, Never>?
    private let sampleQueue = DispatchQueue(label: "phoneagent.capture.latest", qos: .userInitiated)
    var onLoss: (@MainActor () -> Void)?
    var onDiagnostic: (@MainActor (String) -> Void)?

    override init() { super.init(); SCContentSharingPicker.shared.add(self) }
    func present() {
        guard UIApplication.shared.applicationState == .active, !pending, stream == nil else { return }
        pending = true; busy = true
        let picker = SCContentSharingPicker.shared
        var config = SCContentSharingPickerConfiguration()
        config.showsMicrophoneControl = false; config.showsCameraControl = false
        picker.defaultConfiguration = config; picker.isActive = true
        picker.present() // Full display; intentionally not presentForCurrentApplication().
        status = String(localized: "Waiting for screen capture permission"); onDiagnostic?("capture.picker presented")
    }
    private func revoke(message: String) {
        let hadSession = active || frames.diagnostics().active
        active = false; monitor?.cancel(); monitor = nil; frames.invalidate()
        status = message
        if hadSession { onLoss?() }
    }
    func stop() async {
        pending = false
        revoke(message: String(localized: "Capture stopped"))
        guard let target = stream, let token = lifecycle.token else {
            busy = false; SCContentSharingPicker.shared.isActive = false; return
        }
        if lifecycle.requestStop() { await stopStream(target, token: token) }
        // If startCapture is still pending, its completion owns the stop.
    }
    private func stopStream(_ target: SCStream, token: UUID) async {
        onDiagnostic?("capture.stop requested")
        var message = String(localized: "Capture stopped")
        do { try await target.stopCapture() }
        catch {
            let failure = error as NSError, code = failure.code
            // A system stop can race this one request. Do not retry or restart.
            onDiagnostic?("capture.stop completion code=\(code)")
            if failure.domain != SCStreamErrorDomain || code != -3808 {
                message = String(localized: "The stop request returned error \(code). Input is disabled. Check the system capture panel.")
            }
        }
        finish(token: token, message: message)
    }
    private func finish(token: UUID, message: String) {
        guard lifecycle.ended(token) else { return }
        stream = nil; sink = nil; pending = false; busy = false
        revoke(message: message)
        // Deactivate only after stopping, so picker teardown cannot race our stop.
        SCContentSharingPicker.shared.isActive = false
        onDiagnostic?("capture.ended \(frames.diagnostics().summary)")
    }
    private func start(_ filter: SCContentFilter) async {
        guard pending, let token = lifecycle.begin() else { return }
        pending = false
        let config = SCStreamConfiguration(); config.capturesAudio = false
        let target = SCStream(filter: filter, configuration: config, delegate: self)
        let output = ScreenSampleSink(frames: frames, epoch: frames.begin()) { [weak self] alreadyStopped in
            Task { @MainActor in
                guard let self, self.lifecycle.owns(token) else { return }
                if alreadyStopped { self.finish(token: token, message: String(localized: "The system stopped capture")) }
                else { await self.stop() }
            }
        }
        stream = target; sink = output
        do {
            try target.addStreamOutput(output, type: .screen, sampleHandlerQueue: sampleQueue)
            try await target.startCapture()
            guard lifecycle.owns(token) else { return }
            if lifecycle.started(token) { await stopStream(target, token: token); return }
            active = true; busy = false; status = String(localized: "Capture started. Waiting for the first image…")
            onDiagnostic?("capture.start completed; waiting for samples; metadataReader=sck-orientation-2")
            monitor = Task { [weak self] in
                while !Task.isCancelled {
                    guard let self, self.lifecycle.owns(token), self.active else { return }
                    let snapshot = self.frames.diagnostics()
                    if snapshot.accepted == 0 {
                        self.status = String(localized: "Capture started. Waiting for the first image (\(snapshot.received) samples received).")
                    } else { self.status = String(localized: "Full-screen capture is active. Screenshots are sent as needed for the task.") }
                    self.onDiagnostic?(snapshot.summary)
                    do { try await Task.sleep(nanoseconds: 2_000_000_000) } catch { return }
                }
            }
        } catch {
            onDiagnostic?("capture.start failed code=\((error as NSError).code)")
            // A failed start is already stopped. Calling stopCapture here caused -3808.
            finish(token: token, message: String(localized: "The system could not start capture. Authorize it again."))
        }
    }
    nonisolated func contentSharingPicker(_ picker: SCContentSharingPicker, didUpdateWith filter: SCContentFilter, for stream: SCStream?) {
        let selection = PickerSelection(filter: filter)
        Task { @MainActor [weak self, selection] in await self?.start(selection.filter) }
    }
    nonisolated func contentSharingPicker(_ picker: SCContentSharingPicker, didCancelFor stream: SCStream?) {
        Task { @MainActor [weak self] in
            guard let self, self.pending else { return }
            await self.stop()
        }
    }
    nonisolated func contentSharingPickerStartDidFailWithError(_ error: Error) {
        let code = (error as NSError).code
        Task { @MainActor [weak self] in
            guard let self, self.pending else { return }
            self.onDiagnostic?("capture.picker failed code=\(code)"); await self.stop()
        }
    }
    nonisolated func stream(_ stream: SCStream, didStopWithError error: Error) {
        let identity = ObjectIdentifier(stream), code = (error as NSError).code
        Task { @MainActor [weak self] in
            guard let self, self.stream.map(ObjectIdentifier.init) == identity, let token = self.lifecycle.token else { return }
            self.onDiagnostic?("capture.systemStopped code=\(code)")
            self.finish(token: token, message: String(localized: "The system stopped capture (\(code))"))
        }
    }
}
#else
// Xcode 27A266a has no ScreenCaptureKit in the iOS Simulator SDK.
@MainActor final class ScreenCaptureController: ObservableObject {
    @Published private(set) var status = String(localized: "Screen capture is unavailable in this simulator. Authorize it on an iPhone running iOS 27.")
    @Published private(set) var active = false
    @Published private(set) var busy = false
    let isSupported = false
    let frames = LatestScreenFrame()
    var onLoss: (@MainActor () -> Void)?
    var onDiagnostic: (@MainActor (String) -> Void)?
    func present() {}
    func stop() async { let wasActive = frames.diagnostics().active; frames.invalidate(); if wasActive { onLoss?() } }
}
#endif
