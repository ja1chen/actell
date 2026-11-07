import XCTest
import AgentKit
import ProviderCore
import OpenAIAdapter
@testable import PhoneAgent

private final class AccessibilityReplayProvider: ModelProvider, @unchecked Sendable {
    static let name = "accessibility-replay-fixture"
    let configuration = ProviderConfiguration(name: name, baseURL: URL(string: "https://invalid.invalid")!, defaultModel: "fixture")
    private let lock = NSLock()
    private var captured: [ModelRequest] = []
    var requests: [ModelRequest] { lock.withLock { captured } }
    func complete(_ request: ModelRequest) async throws -> ModelResponse { throw ModelError.interrupted }
    func stream(_ request: ModelRequest) -> AsyncThrowingStream<ModelEvent, Error> {
        let count = lock.withLock { captured.append(request); return captured.count }
        return AsyncThrowingStream { continuation in
            let calls: [ModelToolCall] = count == 1 ? [.init(id: "ax-screenshot", name: "screenshot", arguments: "{}")] : []
            continuation.yield(.terminal(.init(text: calls.isEmpty ? "observed" : "", toolCalls: calls, request: request, providerName: Self.name)))
            continuation.finish()
        }
    }
}

private actor SpyBridge: DeviceBridge {
    private(set) var taps = 0
    private(set) var drags = 0
    private(set) var stopped = false
    private(set) var systemActions: [String] = []
    private(set) var insertedText = ""
    private(set) var launchArguments: [String] = []
    private(set) var accessibilityReads = 0
    var accessibilityData: Data?
    var accessibilityError: NativeBackendError?
    let tapError: AppError?
    let capturedAt: Date
    init(tapError: AppError? = nil, capturedAt: Date = Date()) { self.tapError = tapError; self.capturedAt = capturedAt }
    func screenshot() async throws -> FrameImage { FrameImage(id: "fresh", png: Data(), width: 390, height: 844, capturedAt: capturedAt, isDemo: true) }
    func configureAccessibility(data: Data? = nil, error: NativeBackendError? = nil) { accessibilityData = data; accessibilityError = error }
    func accessibilityObservation() async throws -> Data? {
        accessibilityReads += 1
        if let accessibilityError { throw accessibilityError }
        return accessibilityData
    }
    func tap(x: Int, y: Int, imageID: String) async throws { taps += 1; if let tapError { throw tapError } }
    func drag(fromX: Int, fromY: Int, toX: Int, toY: Int, durationMS: Int, imageID: String) async throws { drags += 1 }
    func systemActionContext() async throws -> String { "synthetic-system-session" }
    func authorizeSystemAction(authorizationID: String, taskScoped: Bool) async throws {}
    func installedApplications() async throws -> Data { Data("[{\"name\":\"Fixture\",\"bundle_id\":\"example.fixture\",\"path\":\"PRIVATE_PATH\"}]".utf8) }
    func systemAction(name: String, text: String, arguments: [String], imageID: String) async throws -> NativeApplicationLaunch? {
        systemActions.append(name); insertedText = text; launchArguments = arguments
        return name == "launch_app" ? NativeApplicationLaunch(bundleID: text, pid: 7001) : nil
    }
    func stop() async { stopped = true }
}
final class SafetyTests: XCTestCase {
    private func invoke(_ tool: any AgentTool, callID: String, parameters: [String: Any]) async throws -> ToolOutcome {
        let sessionID = UUID(), turnID = UUID()
        let call = ModelToolCall(id: callID, name: tool.descriptor.name, arguments: String(decoding: try JSONSerialization.data(withJSONObject: parameters), as: UTF8.self))
        return try await tool.execute(.init(sessionID: sessionID, turnID: turnID, call: call),
                                      context: .init(sessionID: sessionID, turnID: turnID, generation: UUID(), fence: ExecutionFence()))
    }
    func testAccessibilityObservationIsOptInAndFailureKeepsScreenshot() async throws {
        let bridge = SpyBridge()
        let disabled = ActionCoordinator(bridge: bridge, limits: AgentLimits(), approve: { _ in true }, onImage: { _, _ in }, onReceipt: { _ in })
        let first = try await disabled.execute(name: "screenshot", parameters: [:], callID: "disabled")
        XCTAssertFalse(first.content.contains("accessibility"))
        let readsBefore = await bridge.accessibilityReads; XCTAssertEqual(readsBefore, 0)
        await bridge.configureAccessibility(data: Data(#"{"status":"available","nodes":[{"label":"fixture"}],"atomic":false}"#.utf8))
        let enabled = ActionCoordinator(bridge: bridge, limits: AgentLimits(), approve: { _ in true }, onImage: { _, _ in }, onReceipt: { _ in }, includeAccessibilityTree: true)
        let second = try await enabled.execute(name: "screenshot", parameters: [:], callID: "enabled")
        XCTAssertTrue(second.content.contains("fixture")); XCTAssertTrue(second.content.contains("accessibility"))
        await bridge.configureAccessibility(error: .accessibilityFailure(stage: 22, cause: 4))
        let third = try await enabled.execute(name: "screenshot", parameters: [:], callID: "fallback")
        XCTAssertEqual(third.kind, .returned); XCTAssertTrue(third.content.contains("service_unavailable"))
        _ = try await enabled.execute(name: "tap", parameters: ["x": 10, "y": 10, "purpose": "fixture"], callID: "after-fallback")
        let taps = await bridge.taps; XCTAssertEqual(taps, 1)
    }
    func testAccessibilityResultRemainsCompleteAndWirePrefixStableAfterJSONLReload() async throws {
        let bridge = SpyBridge(), provider = AccessibilityReplayProvider(), sessionID = UUID()
        let nodes = (0..<400).map { ["label": "AX_FIXTURE_\($0)_" + String(repeating: "text ", count: 30)] }
        let observation = try JSONSerialization.data(withJSONObject: ["status": "available", "nodes": nodes, "atomic": false])
        await bridge.configureAccessibility(data: observation)
        let coordinator = ActionCoordinator(bridge: bridge, limits: AgentLimits(), approve: { _ in true },
            onImage: { _, _ in }, onReceipt: { _ in }, includeAccessibilityTree: true)
        let tool = DeviceTool(name: "screenshot", coordinator: coordinator)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let scope = ProviderReplayScope(provider: provider.identity.implementation, endpoint: provider.identity.endpoint.absoluteString,
            account: "fixture", model: "fixture", session: sessionID)
        let configuration = AgentConfiguration(model: "fixture", instructions: "Keep the same observation.", scope: scope,
            budget: .init(planningTokens: 131_072), cacheKey: sessionID.uuidString)
        let store = JSONLSessionStore(root: root, sessionID: sessionID)
        let runtime = AgentRuntime(store: store, provider: provider, configuration: configuration, tools: [tool])
        _ = try await runtime.createSession(id: sessionID)
        let first = try await runtime.startTurn(in: sessionID, input: .init(text: "observe"))
        let firstResult = await first.result(); XCTAssertEqual(firstResult.status, .completed)
        let records = try await store.readTransactions(sessionID).flatMap(\.toolResults)
        let receipt = try XCTUnwrap(records.first?.outcome.content)
        XCTAssertGreaterThan(receipt.utf8.count, 12 * 1024)
        let decoded = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(receipt.utf8)) as? [String: Any])
        XCTAssertEqual((decoded["accessibility"] as? [String: Any])?["nodes"] as? [[String: String]], nodes)
        let reloadedStore = JSONLSessionStore(root: root, sessionID: sessionID)
        let reloaded = AgentRuntime(store: reloadedStore, provider: provider, configuration: configuration, tools: [tool])
        let loaded = try await reloaded.loadSession(sessionID)
        let outputs = loaded.context.compactMap { item -> String? in
            if case .functionResult(let id, let output) = item, id == "ax-screenshot" { return output }; return nil
        }
        XCTAssertEqual(outputs, [receipt])
        let second = try await reloaded.startTurn(in: sessionID, input: .init(text: "continue"))
        let secondResult = await second.result(); XCTAssertEqual(secondResult.status, .completed)
        let requests = provider.requests
        XCTAssertEqual(requests.count, 3)
        guard requests.count == 3 else { return }
        XCTAssertEqual(requests[1].cachePolicy, requests[2].cachePolicy)
        for (wire, key) in [(OpenAIWireProtocol.responses, "input"), (.chatCompletions, "messages")] {
            let codec = OpenAIWireCodec(configuration: provider.configuration, wire: wire, scope: scope)
            func input(_ request: ModelRequest) throws -> [Any] {
                let body = try XCTUnwrap(codec.prepareRequest(request, stream: true).httpBody)
                let object = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
                return try XCTUnwrap(object[key] as? [Any])
            }
            let before = try input(requests[1]), after = try input(requests[2])
            XCTAssertGreaterThan(after.count, before.count)
            XCTAssertEqual(try JSONSerialization.data(withJSONObject: before, options: [.sortedKeys]),
                try JSONSerialization.data(withJSONObject: Array(after.prefix(before.count)), options: [.sortedKeys]))
        }
        let reads = await bridge.accessibilityReads; XCTAssertEqual(reads, 1)
    }
    func testSystemActionsForwardExactTextAndArgumentsWithoutScreenshotDependency() async throws {
        let bridge = SpyBridge()
        let coordinator = ActionCoordinator(bridge: bridge, limits: AgentLimits(), approve: { _ in true }, onImage: { _, _ in }, onReceipt: { _ in })
        _ = try await coordinator.execute(name: "type_text", parameters: ["text": "你好 ESP32 🌟\n ", "purpose": "insert requested whitespace"], callID: "text")
        let text = await bridge.insertedText; XCTAssertEqual(text, "你好 ESP32 🌟\n ")
        _ = try await coordinator.execute(name: "home", parameters: ["purpose": "home"], callID: "home-no-frame")
        let launched = try await coordinator.execute(name: "launch_app", parameters: ["bundle_id": "example.fixture", "arguments": ["--test", "值"], "purpose": "open fixture"], callID: "launch")
        let receipt = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(launched.content.utf8)) as? [String: Any])
        XCTAssertEqual(receipt["pid"] as? Int, 7001); XCTAssertEqual(receipt["bundle_id"] as? String, "example.fixture")
        XCTAssertEqual(receipt["foregroundAppConfirmed"] as? Bool, false)
        let arguments = await bridge.launchArguments, actions = await bridge.systemActions
        XCTAssertEqual(arguments, ["--test", "值"]); XCTAssertEqual(actions, ["type_text", "home", "launch_app"])
    }
    func testInvalidTextFailsBeforeApprovalAndKeepsSessionUsable() async throws {
        let bridge = SpyBridge()
        let coordinator = ActionCoordinator(bridge: bridge, limits: AgentLimits(), approve: { request in XCTAssertEqual(request.detail, "valid fixture"); return true }, onImage: { _, _ in }, onReceipt: { _ in })
        _ = try await coordinator.execute(name: "screenshot", parameters: [:], callID: "image")
        let tool = DeviceTool(name: "type_text", coordinator: coordinator)
        for text in ["a\0b", String(repeating: "a", count: 8193)] {
            _ = try await coordinator.execute(name: "screenshot", parameters: [:], callID: UUID().uuidString)
            let result = try await invoke(tool, callID: UUID().uuidString, parameters: ["text": text, "purpose": "unsupported fixture"])
            XCTAssertNotEqual(result.kind, .returned)
            XCTAssertTrue(result.content.contains("未发送任何按键"))
            XCTAssertFalse(result.finishTurn)
        }
        let dispatched = await bridge.systemActions
        XCTAssertTrue(dispatched.isEmpty)
        // Same session remains usable after preflight failure, with no reconnect.
        _ = try await coordinator.execute(name: "screenshot", parameters: [:], callID: "fresh-after-errors")
        _ = try await coordinator.execute(name: "type_text", parameters: ["text": "ESP32 direct!", "purpose": "valid fixture"], callID: "t")
        let inserted = await bridge.insertedText
        XCTAssertEqual(inserted, "ESP32 direct!")
    }
    func testAppQueryNeedsNoScreenshotAndDoesNotExposePrivatePaths() async throws {
        let coordinator = ActionCoordinator(bridge: SpyBridge(), limits: AgentLimits(), approve: { _ in XCTFail("read query requested input approval"); return false }, onImage: { _, _ in }, onReceipt: { _ in })
        let result = try await coordinator.execute(name: "list_apps", parameters: [:], callID: "apps")
        XCTAssertEqual(result.kind, .returned); XCTAssertTrue(result.content.contains("example.fixture"))
        XCTAssertFalse(result.content.contains("PRIVATE_PATH"))
    }
    func testInputSchemasOnlyRequireCoordinatesDurationAndPurpose() {
        let coordinator = ActionCoordinator(bridge: SpyBridge(), limits: AgentLimits(), approve: { _ in true }, onImage: { _, _ in }, onReceipt: { _ in })
        for (name, keys) in [("tap", ["x", "y", "purpose"]),
                             ("drag", ["from_x", "from_y", "to_x", "to_y", "duration_ms", "purpose"])] {
            let schema = DeviceTool(name: name, coordinator: coordinator).descriptor.parameters
            guard case .object(let object) = schema, case .object(let properties) = object["properties"], case .array(let required) = object["required"] else { return XCTFail("Expected object schema") }
            XCTAssertEqual(Set(properties.keys), Set(keys))
            XCTAssertEqual(Set(required.compactMap { if case .string(let key) = $0 { return key }; return nil }), Set(keys))
        }
    }
    func testOldScreenshotSupportsTapDragAndFinishWithoutModelImageIdentifier() async throws {
        let bridge = SpyBridge(capturedAt: Date().addingTimeInterval(-3_600))
        let coordinator = ActionCoordinator(bridge: bridge, limits: AgentLimits(), approve: { request in
            XCTAssertGreaterThan(request.expiresAt.timeIntervalSinceNow, 40, "Request timeout must not be based on capture time")
            return true
        }, onImage: { _, _ in }, onReceipt: { _ in })
        _ = try await coordinator.execute(name: "screenshot", parameters: [:], callID: "s1")
        _ = try await coordinator.execute(name: "tap", parameters: ["x": 100, "y": 100, "purpose": "fixture tap"], callID: "t")
        _ = try await coordinator.execute(name: "screenshot", parameters: [:], callID: "s2")
        _ = try await coordinator.execute(name: "drag", parameters: ["from_x": 100, "from_y": 100, "to_x": 120, "to_y": 120, "duration_ms": 200, "purpose": "fixture drag"], callID: "d")
        _ = try await coordinator.execute(name: "screenshot", parameters: [:], callID: "s3")
        _ = try await coordinator.execute(name: "finish", parameters: ["summary": "fixture finished"], callID: "f")
        let taps = await bridge.taps, drags = await bridge.drags
        XCTAssertEqual(taps, 1); XCTAssertEqual(drags, 1)
    }
    func testToolValidationErrorReturnsNormallyAndAllowsCorrectedCall() async throws {
        let c = ActionCoordinator(bridge: SpyBridge(), limits: AgentLimits(), approve: { _ in true }, onImage: { _, _ in }, onReceipt: { _ in })
        let tool = DeviceTool(name: "wait", coordinator: c)
        let failed = try await invoke(tool, callID: "bad", parameters: ["duration_ms": 0])
        XCTAssertNotEqual(failed.kind, .returned)
        XCTAssertEqual(failed.content, "等待必须为 1–3000 毫秒")
        XCTAssertEqual(failed.kind, .validationFailed)
        XCTAssertFalse(failed.finishTurn)
        let corrected = try await invoke(tool, callID: "corrected", parameters: ["duration_ms": 1])
        XCTAssertEqual(corrected.kind, .returned)
        XCTAssertFalse(corrected.finishTurn)
    }
    func testUncertainInputReturnsErrorThenAllowsObservedNextActionWithoutReplay() async throws {
        let bridge = SpyBridge(tapError: .unknownOutcome)
        let c = ActionCoordinator(bridge: bridge, limits: AgentLimits(), approve: { _ in true }, onImage: { _, _ in }, onReceipt: { _ in })
        _ = try await c.execute(name: "screenshot", parameters: [:], callID: "s")
        let failed = try await invoke(DeviceTool(name: "tap", coordinator: c), callID: "t", parameters: ["x": 100, "y": 100, "purpose": "test"])
        XCTAssertNotEqual(failed.kind, .returned)
        XCTAssertTrue(failed.content.contains("动作结果未知"))
        XCTAssertTrue(failed.content.contains("未自动重发"))
        XCTAssertFalse(failed.content.contains("截图"))
        XCTAssertFalse(failed.finishTurn)
        let noObservation = try await invoke(DeviceTool(name: "tap", coordinator: c), callID: "no-frame", parameters: ["x": 100, "y": 100, "purpose": "tap"])
        XCTAssertNotEqual(noObservation.kind, .returned, "An unknown action must consume its old image")
        for name in ["drag", "home", "launch_app", "type_text"] {
            _ = try await c.execute(name: "screenshot", parameters: [:], callID: "s-" + name)
            let result = try await invoke(DeviceTool(name: name, coordinator: c), callID: "next-" + name, parameters: ["from_x": 100, "from_y": 100, "to_x": 120, "to_y": 120, "duration_ms": 200, "purpose": "observed next step", "bundle_id": "example.fixture", "text": "fixture"])
            XCTAssertEqual(result.kind, .returned)
            XCTAssertFalse(result.finishTurn)
        }
        let taps = await bridge.taps, drags = await bridge.drags
        XCTAssertEqual(taps, 1, "The unknown tap is never resent automatically")
        XCTAssertEqual(drags, 1)
    }
    func testExplicitStopStillEndsToolExecution() async throws {
        let bridge = SpyBridge()
        let c = ActionCoordinator(bridge: bridge, limits: AgentLimits(), approve: { _ in true }, onImage: { _, _ in }, onReceipt: { _ in })
        await c.stop()
        do {
            _ = try await invoke(DeviceTool(name: "screenshot", coordinator: c), callID: "s", parameters: [:])
            XCTFail("An explicit stop must not become a recoverable tool result")
        } catch { XCTAssertTrue(error is CancellationError) }
        let stopped = await bridge.stopped
        XCTAssertTrue(stopped)
    }
    func testApprovalDeniedNeverSendsInput() async throws {
        let bridge = SpyBridge()
        let c = ActionCoordinator(bridge: bridge, limits: AgentLimits(), approve: { _ in false }, onImage: { _, _ in }, onReceipt: { _ in })
        _ = try await c.execute(name: "screenshot", parameters: [:], callID: "s")
        do {
            _ = try await c.execute(name: "tap", parameters: ["x": 100, "y": 100, "purpose": "test"], callID: "t")
            XCTFail("Denied input must not run")
        } catch {}
        let count = await bridge.taps; XCTAssertEqual(count, 0)
    }
    func testTaskAuthorizationCannotGrantAnUnsupportedBridgeInputPermission() async throws {
        let bridge = SpyBridge()
        let c = ActionCoordinator(bridge: bridge, limits: AgentLimits(), approve: { _ in true },
                                  onImage: { _, _ in }, onReceipt: { _ in }, authorizationMode: .task)
        _ = try await c.execute(name: "screenshot", parameters: [:], callID: "s")
        do {
            _ = try await c.execute(name: "tap", parameters: ["x": 100, "y": 100, "purpose": "fixture"], callID: "t")
            XCTFail("Task authorization must be explicitly supported by the input bridge")
        } catch { XCTAssertTrue(error.localizedDescription.contains("不支持任务内自动授权")) }
        let count = await bridge.taps; XCTAssertEqual(count, 0)
    }
    func testCoordinateReferencePersistsButEachInputStillNeedsApproval() async throws {
        let bridge = SpyBridge()
        let c = ActionCoordinator(bridge: bridge, limits: AgentLimits(), approve: { $0.callID != "denied" }, onImage: { _, _ in }, onReceipt: { _ in })
        _ = try await c.execute(name: "screenshot", parameters: [:], callID: "s")
        let p: [String: Any] = ["x": 100, "y": 100, "purpose": "test"]
        _ = try await c.execute(name: "tap", parameters: p, callID: "t1")
        _ = try await c.execute(name: "tap", parameters: p, callID: "t2")
        do { _ = try await c.execute(name: "tap", parameters: p, callID: "denied"); XCTFail("Retained reference cannot bypass approval") }
        catch { XCTAssertTrue(error is ToolAuthorizationDenied) }
        let count = await bridge.taps; XCTAssertEqual(count, 2)
    }
    func testStopFencesLaterTools() async throws {
        let bridge = SpyBridge()
        let c = ActionCoordinator(bridge: bridge, limits: AgentLimits(), approve: { _ in true }, onImage: { _, _ in }, onReceipt: { _ in })
        await c.stop()
        do { _ = try await c.execute(name: "screenshot", parameters: [:], callID: "s"); XCTFail("Stopped session must fail") } catch {}
        let value = await bridge.stopped; XCTAssertTrue(value)
    }
    func testLegacyFinishCanEndWithoutAnExtraObservation() async throws {
        let c = ActionCoordinator(bridge: SpyBridge(), limits: AgentLimits(), approve: { _ in true }, onImage: { _, _ in }, onReceipt: { _ in })
        _ = try await c.execute(name: "finish", parameters: ["summary": "done"], callID: "f")
        let summary = await c.finishSummary; XCTAssertEqual(summary, "done")
    }
    func testBooleansCannotBecomePixelCoordinates() async throws {
        let bridge = SpyBridge()
        let c = ActionCoordinator(bridge: bridge, limits: AgentLimits(), approve: { _ in true }, onImage: { _, _ in }, onReceipt: { _ in })
        _ = try await c.execute(name: "screenshot", parameters: [:], callID: "s")
        do { _ = try await c.execute(name: "tap", parameters: ["x": true, "y": 0, "purpose": "bad"], callID: "t"); XCTFail("Boolean must fail") } catch {}
        let count = await bridge.taps; XCTAssertEqual(count, 0)
    }
    func testOpenAIToolImagesUseAdjacentUserMessage() throws {
        let settings = ProviderSettings(baseURL: "https://example.com/v1", model: "vision")
        let provider = try PrivateVisionProvider(settings: settings, apiKey: "test-only-not-a-real-key", limits: AgentLimits(), sessionID: UUID())
        defer { provider.cancel() }
        let image = ModelImage(data: Data([1,2,3]))
        let request = ModelRequest(model: "vision", messages: [
            .assistant(content: "", toolCalls: [ModelToolCall(id: "call", name: "screenshot", arguments: "{}")]),
            ModelMessage(role: .tool, content: "screen", images: [image], toolCallId: "call")
        ])
        let body = try XCTUnwrap(try provider.prepareRequest(request, stream: false).httpBody)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let messages = try XCTUnwrap(object["messages"] as? [[String: Any]])
        XCTAssertEqual(messages.map { $0["role"] as? String }, ["assistant", "tool", "user"])
        XCTAssertTrue(messages[1]["content"] is String)
        XCTAssertTrue(messages[2]["content"] is [[String: Any]])
        XCTAssertEqual(object["parallel_tool_calls"] as? Bool, true)
    }
}
