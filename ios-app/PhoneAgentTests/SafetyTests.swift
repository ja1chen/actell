import XCTest
import AgentKit
import ProviderCore
@testable import PhoneAgent

private actor SpyBridge: DeviceBridge {
    private(set) var taps = 0
    private(set) var drags = 0
    private(set) var stopped = false
    private(set) var systemActions: [String] = []
    private(set) var insertedText = ""
    private(set) var launchArguments: [String] = []
    let tapError: AppError?
    let capturedAt: Date
    init(tapError: AppError? = nil, capturedAt: Date = Date()) { self.tapError = tapError; self.capturedAt = capturedAt }
    func screenshot() async throws -> FrameImage { FrameImage(id: "fresh", png: Data(), width: 390, height: 844, capturedAt: capturedAt, isDemo: true) }
    func tap(x: Int, y: Int, imageID: String) async throws { taps += 1; if let tapError { throw tapError } }
    func drag(fromX: Int, fromY: Int, toX: Int, toY: Int, durationMS: Int, imageID: String) async throws { drags += 1 }
    func systemActionContext() async throws -> String { "synthetic-system-session" }
    func authorizeSystemAction(authorizationID: String, taskScoped: Bool) async throws {}
    func installedApplications() async throws -> Data { Data("[{\"name\":\"Fixture\",\"bundle_id\":\"example.fixture\",\"path\":\"PRIVATE_PATH\"}]".utf8) }
    func systemAction(name: String, text: String, arguments: [String], imageID: String) async throws {
        systemActions.append(name); insertedText = text; launchArguments = arguments
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
    func testSystemActionsForwardExactTextAndArgumentsWithoutScreenshotDependency() async throws {
        let bridge = SpyBridge()
        let coordinator = ActionCoordinator(bridge: bridge, limits: AgentLimits(), approve: { _ in true }, onImage: { _, _ in }, onReceipt: { _ in })
        _ = try await coordinator.execute(name: "type_text", parameters: ["text": "你好 ESP32 🌟\n ", "purpose": "insert requested whitespace"], callID: "text")
        let text = await bridge.insertedText; XCTAssertEqual(text, "你好 ESP32 🌟\n ")
        _ = try await coordinator.execute(name: "home", parameters: ["purpose": "home"], callID: "home-no-frame")
        _ = try await coordinator.execute(name: "launch_app", parameters: ["bundle_id": "example.fixture", "arguments": ["--test", "值"], "purpose": "open fixture"], callID: "launch")
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
