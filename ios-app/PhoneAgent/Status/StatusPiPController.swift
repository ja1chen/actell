import AVKit
import AVFoundation
import CoreMedia
import CoreVideo
import SwiftUI
import UIKit
import Combine

@MainActor protocol TaskAudioPlayback: AnyObject {
    var onStopped: (() -> Void)? { get set }
    func start() async throws -> Bool
    func stop()
}

/// Tokens are installed only during initialization, then released on any thread.
private final class AudioNotificationTokens: @unchecked Sendable {
    var tokens: [NSObjectProtocol] = []
    deinit { for token in tokens { NotificationCenter.default.removeObserver(token) } }
}

/// A real, silent PCM loop; activating AVAudioSession alone is not playback.
@MainActor final class SilentTaskAudioPlayback: NSObject, TaskAudioPlayback, AVAudioPlayerDelegate {
    var onStopped: (() -> Void)?
    private var player: AVAudioPlayer?
    private var sessionToken: AudioSessionToken?
    private var generation = UUID()
    private let observations = AudioNotificationTokens()
    private var monitor: Task<Void, Never>?
    override init() {
        super.init()
        for name in [AVAudioSession.interruptionNotification, AVAudioSession.mediaServicesWereResetNotification, AVAudioSession.routeChangeNotification] {
            observations.tokens.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] notification in
                let interrupted = notification.name == AVAudioSession.interruptionNotification &&
                    (notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? NSNumber)?.uintValue == AVAudioSession.InterruptionType.began.rawValue
                let reset = notification.name == AVAudioSession.mediaServicesWereResetNotification
                let lostRoute = notification.name == AVAudioSession.routeChangeNotification &&
                    (notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? NSNumber)?.uintValue == AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue
                if interrupted || reset || lostRoute { Task { @MainActor [weak self] in
                    guard let self else { return }
                    if interrupted || reset || self.player?.isPlaying != true { self.failed() }
                } }
            })
        }
    }
    deinit { monitor?.cancel() }
    func start() async throws -> Bool {
        if let player, player.isPlaying { return true }
        stop()
        let current = generation
        let lease = AudioSessionToken(owner: UUID(), generation: current)
        sessionToken = lease
        do {
            try await AudioSessionCoordinator.shared.acquire(lease)
            guard current == generation, !Task.isCancelled else { AudioSessionCoordinator.shared.release(lease); throw CancellationError() }
            let next = try AVAudioPlayer(data: Self.silentPCM())
            next.numberOfLoops = -1; next.delegate = self
            guard next.prepareToPlay(), next.play(), next.isPlaying else { stop(); return false }
            player = next
            monitor = Task { [weak self] in
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .seconds(1)) } catch { return }
                    guard let self else { return }
                    guard self.player?.isPlaying == true else { self.failed(); return }
                }
            }
            return true
        } catch {
            if current == generation { stop() }
            throw error
        }
    }
    func stop() {
        generation = UUID()
        monitor?.cancel(); monitor = nil
        player?.stop(); player?.delegate = nil; player = nil
        if let sessionToken { AudioSessionCoordinator.shared.release(sessionToken) }; sessionToken = nil
    }
    private func failed() {
        guard player != nil || sessionToken != nil else { return }
        stop(); BackgroundExecutionTrace.record("audio.playbackEnded")
        onStopped?()
    }
    nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        let identity = ObjectIdentifier(player)
        Task { @MainActor [weak self] in
            guard let self, self.player.map(ObjectIdentifier.init) == identity else { return }
            self.failed()
        }
    }
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        let identity = ObjectIdentifier(player)
        Task { @MainActor [weak self] in
            guard let self, self.player.map(ObjectIdentifier.init) == identity else { return }
            self.failed()
        }
    }
    static func silentPCM() -> Data {
        // One second of mono PCM16 at 8 kHz. Zero samples generate actual silence.
        var data = Data()
        func ascii(_ value: String) { data.append(contentsOf: value.utf8) }
        func u16(_ value: UInt16) { var value = value.littleEndian; withUnsafeBytes(of: &value) { data.append(contentsOf: $0) } }
        func u32(_ value: UInt32) { var value = value.littleEndian; withUnsafeBytes(of: &value) { data.append(contentsOf: $0) } }
        ascii("RIFF"); u32(16036); ascii("WAVEfmt "); u32(16); u16(1); u16(1)
        u32(8000); u32(16000); u16(2); u16(16); ascii("data"); u32(16000)
        data.append(Data(repeating: 0, count: 16000)); return data
    }
}

/// A dismissal suppresses re-opening during the same background visit.
struct TaskPiPPolicy {
    var running = false
    var foreground = true
    var dismissed = false
    var shouldStart: Bool { running && !foreground && !dismissed }
    mutating func setRunning(_ value: Bool) { running = value; if !value { dismissed = false } }
    mutating func setForeground(_ value: Bool) { foreground = value; if value { dismissed = false } }
}

/// AVKit may query playback state off the main actor.
private final class PiPPlaybackState: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var playing: Bool {
        get { lock.lock(); defer { lock.unlock() }; return value }
        set { lock.lock(); value = newValue; lock.unlock() }
    }
}

/// Keep the native object alive across an actor hop so its address cannot be reused by a new controller.
private final class PiPCallbackReference: @unchecked Sendable {
    private let controller: AVPictureInPictureController
    let identity: ObjectIdentifier
    init(_ controller: AVPictureInPictureController) {
        self.controller = controller; identity = ObjectIdentifier(controller)
    }
}

/// Allows lifecycle tests to deliver AVKit callbacks without a native PiP window.
@MainActor protocol StatusPiPControlling: AnyObject {
    var isPictureInPictureActive: Bool { get }
    var isPictureInPicturePossible: Bool { get }
    var isPictureInPictureSuspended: Bool { get }
    var canStartPictureInPictureAutomaticallyFromInline: Bool { get set }
    func startPictureInPicture()
    func stopPictureInPicture()
    func invalidatePlaybackState()
    func detachDelegate()
}
extension AVPictureInPictureController: StatusPiPControlling {
    func detachDelegate() { delegate = nil }
}

/// A PiP adapter and audio loop with independent generations and receipts.
@MainActor final class StatusPiPController: NSObject, ObservableObject {
    @Published private(set) var active = false
    @Published private(set) var audioActive = false
    @Published private(set) var audioState: BackgroundDriverState = .idle
    @Published private(set) var pipState: BackgroundDriverState = .idle
    @Published private(set) var message = String(localized: "Status card is off by default")
    @Published var previewEnabled = false
    let displayLayer = AVSampleBufferDisplayLayer()
    let supported: Bool
    let backgroundModeConfigured = (Bundle.main.object(forInfoDictionaryKey: "UIBackgroundModes") as? [String] ?? []).contains("audio")
    private let registry: BackgroundExecutionRegistry
    private let audioPlayback: any TaskAudioPlayback
    private let audioSession: AudioSessionCoordinator
    private let controllerFactory: ((AVSampleBufferDisplayLayer, StatusPiPController) -> any StatusPiPControlling)?
    private let audioOwner = UUID(), pipOwner = UUID()
    private var audioToken: BackgroundSourceToken?
    private var pipToken: BackgroundSourceToken?
    private var sessionToken: AudioSessionToken?
    private var audioTask: Task<Void, Never>?
    private var sessionTask: Task<Void, Never>?
    private var frameTask: Task<Void, Never>?
    private var audioAttempted = false, pipAttempted = false
    private var demand: Set<BackgroundMechanism> = []
    private var controller: (any StatusPiPControlling)?
    private var retiredControllers: [ObjectIdentifier: any StatusPiPControlling] = [:]
    private var retirementTasks: [ObjectIdentifier: Task<Void, Never>] = [:]
    private var foreground = true
    private(set) var policy = TaskPiPPolicy()
    private var starting = false
    private let playback = PiPPlaybackState()
    private var snapshot = AgentStatusSnapshot(isDemo: true, phase: .idle)
    private var modelObservation: AnyCancellable?
    private let notifications = AudioNotificationTokens()
    override convenience init() { self.init(registry: .shared) }
    init(registry: BackgroundExecutionRegistry, audioPlayback: (any TaskAudioPlayback)? = nil,
         supported: Bool? = nil, audioSession: AudioSessionCoordinator = .shared,
         controllerFactory: ((AVSampleBufferDisplayLayer, StatusPiPController) -> any StatusPiPControlling)? = nil) {
        self.registry = registry; self.audioPlayback = audioPlayback ?? SilentTaskAudioPlayback()
        self.supported = supported ?? AVPictureInPictureController.isPictureInPictureSupported()
        self.audioSession = audioSession; self.controllerFactory = controllerFactory
        super.init()
        self.audioPlayback.onStopped = { [weak self] in
            guard let self, let token = self.audioToken else { return }
            self.registry.revoke(token); self.audioActive = false; self.audioState = .interrupted
        }
        displayLayer.videoGravity = .resizeAspect
        var timebase: CMTimebase?
        if CMTimebaseCreateWithSourceClock(allocator: kCFAllocatorDefault, sourceClock: CMClockGetHostTimeClock(), timebaseOut: &timebase) == noErr, let timebase {
            CMTimebaseSetTime(timebase, time: .zero); CMTimebaseSetRate(timebase, rate: 1); displayLayer.controlTimebase = timebase
        }
        for name in [AVAudioSession.interruptionNotification, AVAudioSession.mediaServicesWereResetNotification] {
            notifications.tokens.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                let ended = note.name == AVAudioSession.interruptionNotification &&
                    (note.userInfo?[AVAudioSessionInterruptionTypeKey] as? NSNumber)?.uintValue == AVAudioSession.InterruptionType.ended.rawValue
                if !ended { Task { @MainActor [weak self] in self?.stop(); self?.pipState = .interrupted } }
            })
        }
    }
    func observeTasks(in model: AgentViewModel) {
        modelObservation = model.objectWillChange.sink { [weak self, weak model] in
            Task { @MainActor in await Task.yield(); if let model { self?.update(model.displayStatus) } }
        }
        update(model.displayStatus)
    }
    func update(_ next: AgentStatusSnapshot) { snapshot = next; if previewEnabled { render() } }
    func setDemand(_ next: Set<BackgroundMechanism>) {
        let old = demand; demand = next
        policy.setRunning(next.contains(.pictureInPicture))
        if !next.contains(.audio) { stopAudio(); audioAttempted = false }
        else if !old.contains(.audio) { audioAttempted = false }
        if !next.contains(.pictureInPicture) { stop(); pipAttempted = false; previewEnabled = false }
        else if !old.contains(.pictureInPicture) { pipAttempted = false }
        reconcile()
    }
    func setForeground(_ value: Bool) {
        let returning = value && !foreground
        foreground = value; policy.setForeground(value)
        if returning { pipAttempted = false }
        if value, active || starting { stop() }
        reconcile()
    }
    func retryFailedDrivers() {
        guard foreground else { return }
        if [.failed, .interrupted].contains(audioState) { stopAudio(); audioAttempted = false }
        if [.failed, .interrupted, .pausedBySystem].contains(pipState) { stop(); pipAttempted = false }
        reconcile()
    }
    func retry() {
        guard foreground else { return }
        stopAudio(); stop(); audioAttempted = false; pipAttempted = false; reconcile()
    }
    private func reconcile() {
        if demand.contains(.audio), !audioAttempted {
            guard foreground else { audioState = .waitingForForeground; return }
            audioAttempted = true
            guard backgroundModeConfigured else { audioState = .failed; return }
            let token = BackgroundSourceToken(mechanism: .audio, owner: audioOwner)
            audioToken = token; audioState = .starting
            audioTask = Task { [weak self] in
                guard let self, !Task.isCancelled, self.audioToken == token else { return }
                do {
                    let ready = try await self.audioPlayback.start()
                    guard !Task.isCancelled, self.audioToken == token else { return }
                    self.audioActive = ready; self.audioState = ready ? .active : .failed
                    if ready { self.registry.publish(token) }
                } catch { if self.audioToken == token { self.audioState = .failed } }
            }
        }
        guard demand.contains(.pictureInPicture), supported, backgroundModeConfigured, !policy.dismissed else { return }
        // AVKit's retiring controller still owns this layer until its terminal callback.
        // Creating another content source here can invalidate AVKit's layer/player association.
        guard retiredControllers.isEmpty else { return }
        previewEnabled = true
        if controller == nil { makeController() }
        if sessionToken == nil, sessionTask == nil, !pipAttempted, foreground { prepareSession() }
        guard sessionToken != nil, sessionTask == nil else { return }
        playback.playing = true; render()
        controller?.canStartPictureInPictureAutomaticallyFromInline = !policy.dismissed
        if frameTask == nil {
            frameTask = Task { [weak self] in
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .seconds(1)) } catch { return }
                    self?.render() // Rendering never retries a failed start.
                }
            }
        }
        if policy.shouldStart { start() }
    }
    private func makeController() {
        if let controllerFactory { controller = controllerFactory(displayLayer, self) }
        else {
            let source = AVPictureInPictureController.ContentSource(sampleBufferDisplayLayer: displayLayer, playbackDelegate: self)
            let next = AVPictureInPictureController(contentSource: source)
            next.delegate = self; next.requiresLinearPlayback = true
            controller = next
        }
        pipToken = BackgroundSourceToken(mechanism: .pictureInPicture, owner: pipOwner)
    }
    private func prepareSession() {
        let token = AudioSessionToken(owner: pipOwner, generation: UUID()); sessionToken = token
        pipState = .starting
        sessionTask = Task { [weak self] in
            guard let self, !Task.isCancelled else { return }
            do {
                try await self.audioSession.acquire(token)
                guard !Task.isCancelled, self.sessionToken == token else { self.audioSession.release(token); return }
                self.sessionTask = nil; self.reconcile()
            } catch {
                guard self.sessionToken == token else { return }
                self.stop(); self.pipAttempted = true; self.pipState = .failed
            }
        }
    }
    private func stopAudio() {
        let old = audioToken; audioToken = nil
        if let old { registry.revoke(old) }
        audioTask?.cancel(); audioTask = nil
        audioPlayback.stop(); audioActive = false; audioState = .stopped
    }
    func setPreviewEnabled(_ value: Bool) {
        previewEnabled = value
        if value { render() } else { stop(); displayLayer.flushAndRemoveImage() }
    }
    func start() {
        guard demand.contains(.pictureInPicture), policy.shouldStart, !pipAttempted, !starting, !active,
              let controller, sessionToken != nil, sessionTask == nil else { return }
        pipAttempted = true
        guard controller.isPictureInPicturePossible else { pipState = .failed; message = String(localized: "Picture in Picture is not available yet. Return to the app to try again manually."); return }
        starting = true; pipState = .starting; controller.startPictureInPicture()
    }
    /// Only PiP is stopped by this UI/AVKit operation. Other sources keep their leases.
    func stop(confirmedStopped: Bool = false) {
        let old = pipToken; pipToken = nil
        var retired = controller; controller = nil
        let wasInFlight = !confirmedStopped && (starting || active || retired?.isPictureInPictureActive == true)
        let oldSession = sessionToken; sessionToken = nil
        sessionTask?.cancel(); sessionTask = nil
        frameTask?.cancel(); frameTask = nil
        starting = false; active = false; playback.playing = false; pipState = .stopped
        if let current = retired {
            let identity = ObjectIdentifier(current)
            current.canStartPictureInPictureAutomaticallyFromInline = false
            if wasInFlight {
                retiredControllers[identity] = current
                retirementTasks[identity] = Task { [weak self] in
                    do { try await Task.sleep(for: .seconds(5)) } catch { return }
                    self?.retirementTimedOut(identity)
                }
                current.stopPictureInPicture()
            } else { current.detachDelegate() }
        }
        retired = nil
        // Invalidate ownership before notifying observers, which may synchronously change demands.
        if let oldSession { audioSession.release(oldSession) }
        if let old { registry.revoke(old) }
    }
    func retirementTimedOut(_ identity: ObjectIdentifier) {
        guard retiredControllers[identity] != nil else { return }
        retirementTasks.removeValue(forKey: identity)?.cancel()
        // A timer is not proof that AVKit released its content source. Keep the layer fenced.
        pipState = .failed
        message = String(localized: "Picture in Picture has not stopped yet")
    }
    private func finishRetirement(_ identity: ObjectIdentifier) {
        guard retiredControllers[identity] != nil else { return }
        retiredControllers[identity]?.detachDelegate()
        retiredControllers.removeValue(forKey: identity)
        retirementTasks.removeValue(forKey: identity)?.cancel()
        // Do not issue stop again from didStop or reuse the layer inside AVKit's callback turn.
        Task { @MainActor [weak self] in self?.reconcile() }
    }
    private func render() {
        do { displayLayer.flushAndRemoveImage(); displayLayer.enqueue(try StatusFrameRenderer.sample(for: snapshot)); controller?.invalidatePlaybackState() }
        catch { message = String(localized: "Could not create the status image") }
    }
    func setSystemPlayback(_ playing: Bool, suspended: Bool) {
        if !suspended { playback.playing = playing && policy.running }; controller?.invalidatePlaybackState()
    }
    #if DEBUG
    private var probeDemand: UUID?
    func setControlProbeRunning(_ value: Bool) {
        let coordinator = BackgroundExecutionCoordinator.shared
        if value, probeDemand == nil { probeDemand = coordinator.acquireDemand(runID: UUID(), allowed: [.audio]) }
        if !value, let probeDemand { coordinator.releaseDemand(probeDemand); self.probeDemand = nil }
    }
    func recordTaskProbe(step: Int, running: Bool, liveActivities: Int) {
        BackgroundExecutionTrace.record("probe step=\(step) running=\(running) audio=\(audioActive) pip=\(active) activities=\(liveActivities)")
    }
    #endif
}

extension StatusPiPController: AVPictureInPictureControllerDelegate, AVPictureInPictureSampleBufferPlaybackDelegate {
    func didStartPictureInPicture(_ identity: ObjectIdentifier) {
        guard controller.map(ObjectIdentifier.init) == identity else {
            retiredControllers[identity]?.stopPictureInPicture(); return
        }
        guard policy.shouldStart, demand.contains(.pictureInPicture), let token = pipToken else { stop(); return }
        starting = false; active = true; pipState = .active; registry.publish(token)
    }
    func didStopPictureInPicture(_ identity: ObjectIdentifier) {
        guard controller.map(ObjectIdentifier.init) == identity else { finishRetirement(identity); return }
        if policy.shouldStart { policy.dismissed = true }
        stop(confirmedStopped: true)
    }
    func failedToStartPictureInPicture(_ identity: ObjectIdentifier) {
        guard controller.map(ObjectIdentifier.init) == identity else { finishRetirement(identity); return }
        stop(confirmedStopped: true); pipAttempted = true; pipState = .failed
    }
    nonisolated func pictureInPictureControllerDidStartPictureInPicture(_ pip: AVPictureInPictureController) {
        let reference = PiPCallbackReference(pip)
        Task { @MainActor [weak self] in self?.didStartPictureInPicture(reference.identity) }
    }
    nonisolated func pictureInPictureControllerDidStopPictureInPicture(_ pip: AVPictureInPictureController) {
        let reference = PiPCallbackReference(pip)
        Task { @MainActor [weak self] in self?.didStopPictureInPicture(reference.identity) }
    }
    nonisolated func pictureInPictureController(_ pip: AVPictureInPictureController, failedToStartPictureInPictureWithError error: Error) {
        let reference = PiPCallbackReference(pip)
        Task { @MainActor [weak self] in self?.failedToStartPictureInPicture(reference.identity) }
    }
    nonisolated func pictureInPictureController(_ pip: AVPictureInPictureController, restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void) { completionHandler(false) }
    nonisolated func pictureInPictureController(_ pip: AVPictureInPictureController, setPlaying playing: Bool) {
        let reference = PiPCallbackReference(pip)
        Task { @MainActor [weak self] in
            guard let self, let current = self.controller, ObjectIdentifier(current) == reference.identity else { return }
            self.setSystemPlayback(playing, suspended: current.isPictureInPictureSuspended)
        }
    }
    nonisolated func pictureInPictureControllerTimeRangeForPlayback(_ pip: AVPictureInPictureController) -> CMTimeRange { CMTimeRange(start: .zero, duration: .positiveInfinity) }
    nonisolated func pictureInPictureControllerIsPlaybackPaused(_ pip: AVPictureInPictureController) -> Bool { !playback.playing }
    nonisolated func pictureInPictureController(_ pip: AVPictureInPictureController, didTransitionToRenderSize newRenderSize: CMVideoDimensions) {}
    nonisolated func pictureInPictureController(_ pip: AVPictureInPictureController, skipByInterval skipInterval: CMTime, completion completionHandler: @escaping () -> Void) { completionHandler() }
    // The selected audio loop owns an independent playback lease; PiP must not prohibit it.
    nonisolated func pictureInPictureControllerShouldProhibitBackgroundAudioPlayback(_ pip: AVPictureInPictureController) -> Bool { false }
}

@MainActor enum StatusFrameRenderer {
    static func sample(for snapshot: AgentStatusSnapshot) throws -> CMSampleBuffer {
        let width = 640, height = 360
        let format = UIGraphicsImageRendererFormat(); format.scale = 1; format.opaque = true
        let image = UIGraphicsImageRenderer(size: CGSize(width: width, height: height), format: format).image { context in
            UIColor(red: 0.07, green: 0.10, blue: 0.17, alpha: 1).setFill()
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            func text(_ value: String, y: CGFloat, size: CGFloat, color: UIColor, weight: UIFont.Weight) {
                let paragraph = NSMutableParagraphStyle(); paragraph.lineBreakMode = .byTruncatingTail
                (value as NSString).draw(in: CGRect(x: 32, y: y, width: 576, height: 62), withAttributes: [
                    .font: UIFont.systemFont(ofSize: size, weight: weight), .foregroundColor: color, .paragraphStyle: paragraph
                ])
            }
            text(String(localized: "Actell · Status preview"), y: 28, size: 22, color: .lightGray, weight: .semibold)
            text(snapshot.title, y: 83, size: 29, color: .white, weight: .medium)
            text(snapshot.phase.title, y: 143, size: 37, color: .systemTeal, weight: .bold)
            text(snapshot.detail, y: 216, size: 24, color: .white, weight: .regular)
        }
        var pixel: CVPixelBuffer?
        let attributes: [CFString: Any] = [kCVPixelBufferCGImageCompatibilityKey: true, kCVPixelBufferCGBitmapContextCompatibilityKey: true, kCVPixelBufferIOSurfacePropertiesKey: [:]]
        guard CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, attributes as CFDictionary, &pixel) == kCVReturnSuccess, let pixel else { throw AppError.unavailable(String(localized: "Could not allocate the status frame")) }
        CVPixelBufferLockBaseAddress(pixel, [])
        defer { CVPixelBufferUnlockBaseAddress(pixel, []) }
        guard let context = CGContext(data: CVPixelBufferGetBaseAddress(pixel), width: width, height: height, bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(pixel), space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue), let cgImage = image.cgImage else { throw AppError.unavailable(String(localized: "Could not draw the status frame")) }
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        var description: CMVideoFormatDescription?
        guard CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pixel, formatDescriptionOut: &description) == noErr, let description else { throw AppError.unavailable(String(localized: "Could not format the status frame")) }
        var timing = CMSampleTimingInfo(duration: CMTime(seconds: 1, preferredTimescale: 600), presentationTimeStamp: .zero, decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        guard CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pixel, formatDescription: description, sampleTiming: &timing, sampleBufferOut: &sample) == noErr, let sample else { throw AppError.unavailable(String(localized: "Could not package the status frame")) }
        // Live status frames are displayed immediately; AVKit owns the PiP timeline.
        if let array = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true) {
            let dictionary = unsafeBitCast(CFArrayGetValueAtIndex(array, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(dictionary, Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(), Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }
        return sample
    }
}
