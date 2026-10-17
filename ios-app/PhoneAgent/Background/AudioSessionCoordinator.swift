import AVFoundation
import Foundation

struct AudioSessionToken: Hashable, Sendable {
    let owner: UUID
    let generation: UUID
    let id = UUID()
}

/// FIFO asynchronous worker; pending acquires precede releases. Only the last
/// unique owner token may deactivate. A stale release cannot affect a new token.
final class AudioSessionCoordinator: @unchecked Sendable {
    static let shared = AudioSessionCoordinator()
    typealias Completion = @Sendable (Bool) -> Void
    private typealias Operation = @Sendable (@escaping @Sendable () -> Void) -> Void
    private let activate: @Sendable (@escaping Completion) -> Void
    private let deactivate: @Sendable (@escaping @Sendable () -> Void) -> Void
    private let queue = DispatchQueue(label: "Actell.audio-session", qos: .userInitiated)
    private var operations: [Operation] = []
    private var running = false
    private var owners: Set<AudioSessionToken> = []
    init(activate: @escaping @Sendable (@escaping Completion) -> Void = { completion in
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .moviePlayback, options: [.mixWithOthers])
            session.activate(options: []) { ready, error in completion(ready && error == nil) }
        } catch { completion(false) }
    }, deactivate: @escaping @Sendable (@escaping @Sendable () -> Void) -> Void = { completion in
        AVAudioSession.sharedInstance().deactivate(options: [.notifyOthersOnDeactivation]) { _, _ in completion() }
    }) { self.activate = activate; self.deactivate = deactivate }
    private func enqueue(_ operation: @escaping Operation) {
        queue.async { self.operations.append(operation); self.advance() }
    }
    private func advance() {
        guard !running, !operations.isEmpty else { return }
        running = true
        let operation = operations.removeFirst()
        operation { self.queue.async { self.running = false; self.advance() } }
    }
    func acquire(_ token: AudioSessionToken) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            enqueue { finished in
                if !self.owners.isEmpty {
                    self.owners.insert(token); continuation.resume(); finished(); return
                }
                self.activate { ready in
                    self.queue.async {
                        if ready { self.owners.insert(token); continuation.resume() }
                        else { continuation.resume(throwing: AppError.unavailable(String(localized: "Media session unavailable"))) }
                        finished()
                    }
                }
            }
        }
    }
    func release(_ token: AudioSessionToken) {
        enqueue { finished in
            guard self.owners.remove(token) != nil, self.owners.isEmpty else { finished(); return }
            self.deactivate(finished)
        }
    }
    func drain() async { await withCheckedContinuation { continuation in enqueue { done in continuation.resume(); done() } } }
}
