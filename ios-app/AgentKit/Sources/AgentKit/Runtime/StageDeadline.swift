import Foundation
import ProviderCore

/// A local deadline terminates consumption. It never asserts that a remote request was cancelled.
enum StageDeadline {
    static func perform<Value: Sendable>(seconds: TimeInterval, operation: @escaping @Sendable () async throws -> Value) async throws -> Value {
        let stream = AsyncThrowingStream<Value, Error>(bufferingPolicy: .bufferingOldest(1)) { continuation in
            let worker = Task {
                do {
                    let value = try await operation()
                    try Task.checkCancellation()
                    switch continuation.yield(value) { case .dropped: continuation.finish(throwing: ModelError.streamingError("Operation result overflow")); default: continuation.finish() }
                } catch { continuation.finish(throwing: error) }
            }
            let timeout = Task {
                do { try await Task.sleep(for: .seconds(seconds)); continuation.finish(throwing: ModelStreamStalled(seconds: seconds)) }
                catch {}
            }
            continuation.onTermination = { _ in worker.cancel(); timeout.cancel() }
        }
        for try await value in stream { return value }
        try Task.checkCancellation()
        throw ModelError.interrupted
    }
    static func stream(_ source: AsyncThrowingStream<ModelEvent, Error>, idleSeconds: TimeInterval) -> InferenceEventSequence {
        let channel = InferenceEventSequence()
        let worker = Task {
            func deadline() -> Task<Void, Never> {
                Task {
                    do { try await Task.sleep(for: .seconds(idleSeconds)); await channel.close(ModelStreamStalled(seconds: idleSeconds)) }
                    catch {}
                }
            }
            var timeout = deadline()
            defer { timeout.cancel() }
            do {
                for try await event in source {
                    try Task.checkCancellation()
                    timeout.cancel()
                    guard await channel.send(event) else { return }
                    timeout = deadline()
                }
                await channel.close(nil)
            } catch { await channel.close(error) }
        }
        Task { await channel.attach(worker) }
        return channel
    }
}

/// One awaited producer and one consumer. A full queue suspends the producer rather than discarding protocol data.
struct InferenceEventSequence: AsyncSequence, Sendable {
    typealias Element = ModelEvent
    struct AsyncIterator: AsyncIteratorProtocol {
        fileprivate let mailbox: InferenceMailbox
        mutating func next() async throws -> ModelEvent? { try await mailbox.next() }
    }
    private let mailbox = InferenceMailbox()
    func makeAsyncIterator() -> AsyncIterator { .init(mailbox: mailbox) }
    func send(_ value: ModelEvent) async -> Bool { await mailbox.send(value) }
    func attach(_ worker: Task<Void, Never>) async { await mailbox.attach(worker) }
    func close(_ error: (any Error)?) async { await mailbox.close(error) }
    func cancel() async { await mailbox.close(CancellationError()) }
}
private actor InferenceMailbox {
    private var buffer: [ModelEvent] = []
    private var receiver: CheckedContinuation<ModelEvent?, any Error>?
    private var sender: (ModelEvent, CheckedContinuation<Bool, Never>)?
    private var ended = false
    private var failure: (any Error)?
    private var worker: Task<Void, Never>?
    func attach(_ task: Task<Void, Never>) { worker = task; if ended { task.cancel() } }
    func send(_ value: ModelEvent) async -> Bool {
        guard !ended else { return false }
        if let receiver { self.receiver = nil; receiver.resume(returning: value); return true }
        if buffer.count < 32 { buffer.append(value); return true }
        return await withCheckedContinuation { sender = (value, $0) }
    }
    func next() async throws -> ModelEvent? {
        try Task.checkCancellation()
        return try await withTaskCancellationHandler {
            if !buffer.isEmpty {
                let value = buffer.removeFirst()
                if let sender { self.sender = nil; buffer.append(sender.0); sender.1.resume(returning: true) }
                return value
            }
            if ended { if let failure { throw failure }; return nil }
            return try await withCheckedThrowingContinuation { receiver = $0 }
        } onCancel: { Task { await self.close(CancellationError()) } }
    }
    func close(_ error: (any Error)?) {
        guard !ended else { return }
        ended = true; failure = error
        if let sender { self.sender = nil; sender.1.resume(returning: false) }
        if let receiver {
            self.receiver = nil
            if let error { receiver.resume(throwing: error) } else { receiver.resume(returning: nil) }
        }
        worker?.cancel(); worker = nil
    }
}
