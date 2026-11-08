import XCTest
import CoreVideo
import ProviderCore
import AgentKit
@testable import PhoneAgent

@MainActor final class ProviderStoreTests: XCTestCase {
    private func defaults() -> UserDefaults {
        let name = "test.providers.\(UUID())", defaults = UserDefaults(suiteName: name)!
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        return defaults
    }
    func testLegacyMigrationKeepsOriginalDataAndKeychainReferenceAcrossRestart() throws {
        let defaults = defaults(), legacy = ProviderSettings(baseURL: "https://example.com/v1/", model: "original")
        let data = try JSONEncoder().encode(legacy); defaults.set(data, forKey: "providerSettings")
        let store = ProviderStore(defaults: defaults)
        let profile = try XCTUnwrap(store.profiles.first)
        XCTAssertEqual(profile.settings, legacy); XCTAssertEqual(profile.keyAccount, legacy.keyAccount)
        XCTAssertEqual(defaults.data(forKey: "providerSettings"), data)
        let restored = ProviderStore(defaults: defaults)
        XCTAssertEqual(restored.profiles, [profile]); XCTAssertEqual(restored.profiles.count, 1)
    }
    func testProviderKeysAreIndependentAndURLChangesCannotReuseOldDestinationKey() throws {
        let store = ProviderStore(defaults: defaults())
        var first = ProviderProfile(name: "one", settings: .init(baseURL: "https://example.com/v1", model: "vision"))
        let second = ProviderProfile(name: "two", settings: first.settings)
        try store.save(first); try store.save(second)
        XCTAssertNotEqual(store.profiles[0].keyAccount, store.profiles[1].keyAccount)
        let oldReference = store.profiles[0].keyAccount
        first.name = "renamed"; try store.save(first)
        XCTAssertEqual(store.profiles[0].keyAccount, oldReference)
        first.settings.baseURL = "https://different.example/v1"; try store.save(first)
        XCTAssertNotEqual(store.profiles[0].keyAccount, oldReference)
    }
    func testRemoveRestoreAndConversationSelectionSurviveWithoutReassignment() throws {
        let defaults = defaults(), store = ProviderStore(defaults: defaults)
        let first = ProviderProfile(name: "one", settings: .init(baseURL: "https://one.example/v1", model: "a"))
        let second = ProviderProfile(name: "two", settings: .init(baseURL: "https://two.example/v1", model: "b"))
        try store.save(first); try store.save(second)
        let sessions = ConversationStore(inMemory: true), id = sessions.create(mode: .live)
        sessions.selectProvider(first.id, model: "custom-model", in: id)
        try store.remove(first.id)
        let restored = ProviderStore(defaults: defaults)
        XCTAssertNil(restored.profile(sessions.conversation(id)?.providerID), "Never silently send to another provider")
        XCTAssertEqual(restored.removed.first?.keyAccount, first.keyAccount)
        try restored.restore(first.id)
        XCTAssertEqual(restored.profile(first.id)?.id, first.id)
        XCTAssertEqual(sessions.conversation(id)?.modelID, "custom-model")
        let run = try XCTUnwrap(sessions.begin(in: id, query: "task"))
        sessions.selectProvider(second.id, model: "b", in: id)
        XCTAssertEqual(sessions.conversation(id)?.providerID, first.id)
        sessions.finish(run, phase: .completed, summary: "")
    }
    func testCorruptProviderArchiveIsPreservedAndCannotBeOverwritten() {
        let defaults = defaults(), data = Data("broken".utf8)
        defaults.set(data, forKey: ProviderStore.storageKey)
        let store = ProviderStore(defaults: defaults)
        XCTAssertNotNil(store.warning)
        XCTAssertThrowsError(try store.save(ProviderProfile(settings: .init(model: "fixture"))))
        XCTAssertEqual(defaults.data(forKey: ProviderStore.storageKey), data)
    }
}

@MainActor private final class RecoveryScheduler: RunBackgroundScheduler {
    var submissions = 0
    var cancelled: [String] = []
    func submit(identifier: String, launched: @escaping @MainActor (any RunBackgroundLease) -> Void) throws { submissions += 1 }
    func cancel(identifier: String) { cancelled.append(identifier) }
}
@MainActor final class CheckpointMergeTests: XCTestCase {
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
    private func checkpoint(conversation: UUID, call: String) -> RunCheckpoint {
        var value = RunCheckpoint(runID: UUID(), conversationID: conversation, generation: UUID())
        value.tools = [.init(callID: call, name: "tap", parameterSummary: "{}", argumentDigest: call, delivery: .dispatching)]
        value.pendingApproval = call; value.segmentID = "test.backgroundRun.\(call)"
        return value
    }
    func testBothFilesRecoverDistinctUnknownActionsAndNeverRestoreAuthorization() throws {
        let root = try directory(), sessions = ConversationStore(inMemory: true)
        let a = checkpoint(conversation: sessions.create(mode: .live), call: "a")
        let b = checkpoint(conversation: sessions.create(mode: .live), call: "b")
        try JSONEncoder().encode(a).write(to: root.appendingPathComponent("run-checkpoint-v1.json"))
        let legacy = try JSONEncoder().encode(b), legacyURL = root.appendingPathComponent("usb-run-checkpoint-v1.json")
        try legacy.write(to: legacyURL)
        let scheduler = RecoveryScheduler()
        let restored = RunLifecycleCoordinator(scheduler: scheduler, storage: try RunCheckpointStore(directory: root), identifierPrefix: "test.backgroundRun")
        XCTAssertEqual(restored.recoveries.count, 2)
        XCTAssertEqual(Set(scheduler.cancelled), Set([a.segmentID!, b.segmentID!]))
        XCTAssertEqual(scheduler.submissions, 0); XCTAssertFalse(restored.hasLease)
        for value in restored.recoveries {
            XCTAssertEqual(value.tools[0].delivery, .outcomeUnknown)
            XCTAssertNil(value.pendingApproval); XCTAssertNil(value.segmentID)
            XCTAssertThrowsError(try restored.resumeApproved(callID: value.tools[0].callID, digest: value.tools[0].argumentDigest, generation: value.generation))
            sessions.reconcileRecovery(value); sessions.reconcileRecovery(value)
            XCTAssertEqual(sessions.conversation(value.conversationID)?.messages.filter { $0.role == .notice }.count, 0)
        }
        try restored.begin(identity: .init(conversationID: a.conversationID, runID: UUID()), generation: UUID())
        restored.stop(message: "new task")
        let again = RunLifecycleCoordinator(scheduler: scheduler, storage: try RunCheckpointStore(directory: root), identifierPrefix: "test.backgroundRun")
        XCTAssertEqual(again.recoveries.flatMap(\.tools).filter { $0.delivery == .outcomeUnknown }.count, 2)
        for value in again.recoveries { sessions.reconcileRecovery(value) }
        XCTAssertEqual(sessions.conversation(a.conversationID)?.messages.filter { $0.role == .notice }.count, 0)
        XCTAssertEqual(try Data(contentsOf: legacyURL), legacy)
    }
    func testSameRunDeduplicatesButRetainsBothTransactionsAndUnknownWins() throws {
        let a = checkpoint(conversation: UUID(), call: "a")
        var b = a; b.tools[0].delivery = .observedResult
        b.tools.append(.init(callID: "b", name: "drag", parameterSummary: "{}", argumentDigest: "b", delivery: .dispatching))
        let merged = RunCheckpoint.mergedRecoveries([a, b, a]).map { $0.recovered() }
        XCTAssertEqual(merged.count, 1); XCTAssertEqual(merged[0].tools.count, 2)
        XCTAssertTrue(merged[0].tools.allSatisfy { $0.delivery == .outcomeUnknown })
    }
    func testNoDefaultInactivityBudgetButSystemLossStillPauses() throws {
        var now = Date()
        let lifecycle = RunLifecycleCoordinator(scheduler: RecoveryScheduler(), storage: MemoryRunCheckpointStore(), now: { now })
        let token = UUID()
        try lifecycle.begin(identity: .init(conversationID: UUID(), runID: UUID()), generation: token)
        now.addTimeInterval(3_600); lifecycle.checkInactivity()
        XCTAssertNoThrow(try lifecycle.requireExecution(generation: token, backgroundCapable: true))
        lifecycle.setForeground(false)
        XCTAssertThrowsError(try lifecycle.requireExecution(generation: token, backgroundCapable: true))
    }
}

private actor ReleaseCounter: DeviceBridge {
    private(set) var releases = 0
    private(set) var inputs = 0
    func screenshot() async throws -> FrameImage { .init(id: UUID().uuidString, png: Data(), width: 20, height: 20, capturedAt: Date(), isDemo: true) }
    func tap(x: Int, y: Int, imageID: String) async throws { inputs += 1 }
    func drag(fromX: Int, fromY: Int, toX: Int, toY: Int, durationMS: Int, imageID: String) async throws { inputs += 1 }
    func stop() async { releases += 1; try? await Task.sleep(nanoseconds: 20_000_000) }
}
final class RunCleanupTests: XCTestCase {
    func testConcurrentAndRepeatedCleanupCallsBridgeExactlyOnceEvenAfterFinish() async throws {
        for finished in [false, true] {
            let bridge = ReleaseCounter()
            let actions = ActionCoordinator(bridge: bridge, limits: AgentLimits(), approve: { _ in true }, onImage: { _, _ in }, onReceipt: { _ in })
            if finished { _ = try await actions.execute(name: "finish", parameters: ["summary": "complete"], callID: "finish") }
            async let one: Void = actions.stop()
            async let two: Void = actions.stop()
            _ = await (one, two)
            await actions.stop()
            let count = await bridge.releases; XCTAssertEqual(count, 1)
        }
    }
    func testMoreThanSixteenInputsAreAllowedWithFreshObservationAndAuthorization() async throws {
        let bridge = ReleaseCounter()
        let actions = ActionCoordinator(bridge: bridge, limits: AgentLimits(), approve: { _ in true }, onImage: { _, _ in }, onReceipt: { _ in })
        for index in 0..<18 {
            _ = try await actions.execute(name: "screenshot", parameters: [:], callID: "s\(index)")
            _ = try await actions.execute(name: "tap", parameters: ["x": 1, "y": 1, "description": "fixture"], callID: "t\(index)")
        }
        let count = await bridge.inputs; XCTAssertEqual(count, 18)
        await actions.stop()
    }
    func testHealthObserversShareOneScheduleAndLoseAuthorityExactlyOnce() async throws {
        let frames = LatestScreenFrame(), epoch = frames.begin()
        var pixel: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault, 8, 4, kCVPixelFormatType_32BGRA, nil, &pixel), kCVReturnSuccess)
        frames.put(try XCTUnwrap(pixel), orientation: 1, presentationSeconds: 1, epoch: epoch)
        let context = try ScreenUSBExecutionContext(frames: frames, backgroundEnabled: true)
        let first = expectation(description: "model loss"), second = expectation(description: "lease loss")
        let a = context.observeHealth { first.fulfill() }, b = context.observeHealth { second.fulfill() }
        XCTAssertEqual(context.healthMonitorStarts, 1)
        try await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertNoThrow(try context.requireHealthy())
        frames.invalidate()
        await fulfillment(of: [first, second], timeout: 2)
        XCTAssertThrowsError(try context.requireHealthy())
        context.removeHealthObserver(a); context.removeHealthObserver(b)
    }
}

private final class LongRunProvider: ModelProvider, @unchecked Sendable {
    static let name = "long-run-fixture"
    let configuration = ProviderConfiguration(name: LongRunProvider.name, baseURL: URL(string: "https://invalid.invalid")!, defaultModel: "fixture")
    private var calls = 0
    func complete(_ request: ModelRequest) async throws -> ModelResponse {
        guard !request.tools.isEmpty else { throw ModelError.unsupportedCapability("The long-run fixture has no summary path") }
        calls += 1
        XCTAssertNil(request.maxTokens, "No forced output-token budget")
        XCTAssertFalse(request.tools.contains { $0.name == "finish" }, "Live runs use the final answer")
        let done = calls > 14
        return ModelResponse(text: done ? "Observed fourteen frames" : "", finishReason: done ? .stop : .toolCalls,
            usage: ModelUsage(totalTokens: 25_000),
            toolCalls: done ? [] : [ModelToolCall(id: "screen-\(calls)", name: "screenshot", arguments: "{}")], request: request, providerName: Self.name)
    }
    func stream(_ request: ModelRequest) -> AsyncThrowingStream<ModelEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let response = try await complete(request)
                    if !response.text.isEmpty { continuation.yield(.text(response.text)) }
                    for call in response.toolCalls { continuation.yield(.toolCall(call)) }
                    continuation.yield(.terminal(response))
                    continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
@MainActor final class UnbudgetedRunTests: XCTestCase {
    func testRepeatedObservationsBeyondOldTurnAndUsageLimitsEndWithFinalAnswerAndOneCleanup() async throws {
        let bridge = ReleaseCounter(), sessions = ConversationStore(inMemory: true)
        let model = AgentViewModel(sessions: sessions, loadPersistentState: false,
            runServices: .init(provider: LongRunProvider(), bridge: bridge))
        let id = model.createConversation(mode: .live)
        XCTAssertTrue(model.send("Observe repeatedly", in: id, cloudConsent: true))
        for _ in 0..<500 {
            if !model.running { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertFalse(model.running)
        XCTAssertEqual(sessions.conversation(id)?.phase, .completed)
        XCTAssertEqual(sessions.conversation(id)?.messages.compactMap(\.tool).count, 14)
        XCTAssertEqual(sessions.conversation(id)?.messages.last?.text, "Observed fourteen frames")
        let releases = await bridge.releases; XCTAssertEqual(releases, 1)
    }
}

private final class MonotonicTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var time: TimeInterval = 100
    func read() -> TimeInterval { lock.withLock { time } }
    func set(_ value: TimeInterval) { lock.withLock { time = value } }
}
final class HeartbeatSamplingTests: XCTestCase {
    func testLiveClockValidatesNewReceiptAndStillRejectsTimeoutOrDisconnect() throws {
        let health = USBTransportHealth(), clock = MonotonicTestClock(), token = UUID()
        health.begin(token); health.receivedPing(token, now: clock.read())
        let earlierSample = clock.read()
        clock.set(100.1); health.receivedPing(token, now: clock.read())
        XCTAssertThrowsError(try health.requireHealthy(now: earlierSample), "A stale pre-lock sample reproduces the old false failure")
        XCTAssertNoThrow(try health.requireHealthy(clock: { clock.read() }))
        clock.set(100.86)
        XCTAssertThrowsError(try health.requireHealthy(clock: { clock.read() }))
        health.receivedPing(token, now: clock.read()); health.invalidate(token)
        XCTAssertThrowsError(try health.requireHealthy(clock: { clock.read() }))
    }
}
