import XCTest
import SwiftAgentKit
import ProviderCore
@testable import PhoneAgent

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
    func systemAction(name: String, text: String, arguments: [String], imageID: String) async throws {
        systemActions.append(name); insertedText = text; launchArguments = arguments
    }
    func stop() async { stopped = true }
}
final class SafetyTests: XCTestCase {
    func testAccessibilityObservationIsOptInAndFailureKeepsScreenshot() async throws {
        let bridge = SpyBridge()
        let disabled = ActionCoordinator(bridge: bridge, limits: AgentLimits(), approve: { _ in true }, onImage: { _, _ in }, onReceipt: { _ in })
        let first = try await disabled.execute(name: "screenshot", parameters: [:], callID: "disabled")
        XCTAssertFalse(first.result.contains("accessibility"))
        let readsBefore = await bridge.accessibilityReads; XCTAssertEqual(readsBefore, 0)
        await bridge.configureAccessibility(data: Data(#"{"status":"available","nodes":[{"label":"fixture"}],"atomic":false}"#.utf8))
        let enabled = ActionCoordinator(bridge: bridge, limits: AgentLimits(), approve: { _ in true }, onImage: { _, _ in }, onReceipt: { _ in }, includeAccessibilityTree: true)
        let second = try await enabled.execute(name: "screenshot", parameters: [:], callID: "enabled")
        XCTAssertTrue(second.result.contains("fixture")); XCTAssertTrue(second.result.contains("accessibility"))
        await bridge.configureAccessibility(error: .accessibilityFailure(stage: 22, cause: 4))
        let third = try await enabled.execute(name: "screenshot", parameters: [:], callID: "fallback")
        XCTAssertFalse(third.isError); XCTAssertTrue(third.result.contains("service_unavailable"))
        _ = try await enabled.execute(name: "tap", parameters: ["x": 10, "y": 10, "purpose": "fixture"], callID: "after-fallback")
        let taps = await bridge.taps; XCTAssertEqual(taps, 1)
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
        let actions = ToolActions()
        let tool = DeviceTool(name: "type_text", coordinator: coordinator)
        for text in ["a\0b", String(repeating: "a", count: 8193)] {
            _ = try await coordinator.execute(name: "screenshot", parameters: [:], callID: UUID().uuidString)
            let result = try await tool.execute(context: ToolContext(callId: UUID().uuidString, toolName: "type_text", parameters: ["text": text, "purpose": "unsupported fixture"], state: AgentState(), actions: actions))
            XCTAssertTrue(result.isError)
            XCTAssertTrue(result.result.contains("未发送任何按键"))
            XCTAssertFalse(actions.shouldStop)
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
        XCTAssertFalse(result.isError); XCTAssertTrue(result.result.contains("example.fixture"))
        XCTAssertFalse(result.result.contains("PRIVATE_PATH"))
    }
    func testInputSchemasOnlyRequireCoordinatesDurationAndPurpose() {
        let coordinator = ActionCoordinator(bridge: SpyBridge(), limits: AgentLimits(), approve: { _ in true }, onImage: { _, _ in }, onReceipt: { _ in })
        for (name, keys) in [("tap", ["x", "y", "purpose"]),
                             ("drag", ["from_x", "from_y", "to_x", "to_y", "duration_ms", "purpose"])] {
            let schema = DeviceTool(name: name, coordinator: coordinator).parameters
            XCTAssertEqual(Set(schema.properties.keys), Set(keys))
            XCTAssertEqual(Set(schema.required), Set(keys))
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
        let actions = ToolActions()
        let tool = DeviceTool(name: "wait", coordinator: c)
        let failed = try await tool.execute(context: ToolContext(callId: "bad", toolName: "wait", parameters: ["duration_ms": 0], state: AgentState(), actions: actions))
        XCTAssertTrue(failed.isError)
        XCTAssertEqual(failed.result, "等待必须为 1–3000 毫秒")
        XCTAssertEqual(failed.toolCallId, "bad")
        XCTAssertFalse(actions.shouldStop)
        let corrected = try await tool.execute(context: ToolContext(callId: "corrected", toolName: "wait", parameters: ["duration_ms": 1], state: AgentState(), actions: actions))
        XCTAssertFalse(corrected.isError)
        XCTAssertFalse(actions.shouldStop)
    }
    func testUncertainInputReturnsErrorThenAllowsObservedNextActionWithoutReplay() async throws {
        let bridge = SpyBridge(tapError: .unknownOutcome)
        let c = ActionCoordinator(bridge: bridge, limits: AgentLimits(), approve: { _ in true }, onImage: { _, _ in }, onReceipt: { _ in })
        let actions = ToolActions()
        _ = try await c.execute(name: "screenshot", parameters: [:], callID: "s")
        let failed = try await DeviceTool(name: "tap", coordinator: c).execute(context:
            ToolContext(callId: "t", toolName: "tap", parameters: ["x": 100, "y": 100, "purpose": "test"], state: AgentState(), actions: actions))
        XCTAssertTrue(failed.isError)
        XCTAssertTrue(failed.result.contains("动作结果未知"))
        XCTAssertTrue(failed.result.contains("未自动重发"))
        XCTAssertFalse(failed.result.contains("截图"))
        XCTAssertFalse(actions.shouldStop)
        let noObservation = try await DeviceTool(name: "tap", coordinator: c).execute(context:
            ToolContext(callId: "no-frame", toolName: "tap", parameters: ["x": 100, "y": 100, "purpose": "tap"], state: AgentState(), actions: actions))
        XCTAssertTrue(noObservation.isError, "An unknown action must consume its old image")
        for name in ["drag", "home", "launch_app", "type_text"] {
            _ = try await c.execute(name: "screenshot", parameters: [:], callID: "s-" + name)
            let result = try await DeviceTool(name: name, coordinator: c).execute(context:
                ToolContext(callId: "next-" + name, toolName: name, parameters: ["from_x": 100, "from_y": 100, "to_x": 120, "to_y": 120, "duration_ms": 200, "purpose": "observed next step", "bundle_id": "example.fixture", "text": "fixture"], state: AgentState(), actions: actions))
            XCTAssertFalse(result.isError)
            XCTAssertFalse(actions.shouldStop)
        }
        let taps = await bridge.taps, drags = await bridge.drags
        XCTAssertEqual(taps, 1, "The unknown tap is never resent automatically")
        XCTAssertEqual(drags, 1)
    }
    func testExplicitStopStillEndsToolExecution() async throws {
        let c = ActionCoordinator(bridge: SpyBridge(), limits: AgentLimits(), approve: { _ in true }, onImage: { _, _ in }, onReceipt: { _ in })
        await c.stop()
        let actions = ToolActions()
        do {
            _ = try await DeviceTool(name: "screenshot", coordinator: c).execute(context: ToolContext(callId: "s", toolName: "screenshot", parameters: [:], state: AgentState(), actions: actions))
            XCTFail("An explicit stop must not become a recoverable tool result")
        } catch { XCTAssertEqual(error as? AppError, .stopped) }
        XCTAssertTrue(actions.shouldStop)
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
        catch { XCTAssertEqual(error as? AppError, .stopped) }
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
        let provider = try PrivateVisionProvider(settings: settings, apiKey: "test-only-not-a-real-key", limits: AgentLimits())
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
