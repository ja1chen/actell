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
    private let observationArguments: [String]
    init(observationArguments: [String] = ["{}"]) { self.observationArguments = observationArguments }
    var requests: [ModelRequest] { lock.withLock { captured } }
    func complete(_ request: ModelRequest) async throws -> ModelResponse { throw ModelError.interrupted }
    func stream(_ request: ModelRequest) -> AsyncThrowingStream<ModelEvent, Error> {
        let count = lock.withLock { captured.append(request); return captured.count }
        return AsyncThrowingStream { continuation in
            let calls: [ModelToolCall] = count <= observationArguments.count
                ? [.init(id: count == 1 ? "ax-screenshot" : "screen-\(count)", name: "screenshot", arguments: observationArguments[count - 1])] : []
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
    private(set) var screenshotReads = 0
    private(set) var geometryReads = 0
    private(set) var coordinateDeliveries: [[Int]] = []
    var geometryError: Error?
    var geometryToken = "portrait"
    var logicalBounds: NativeDisplayBounds? = .init(x: 0, y: 0, width: 393, height: 852)
    private var independentGrant: String?
    var accessibilityData: Data?
    var accessibilityError: NativeBackendError?
    let tapError: AppError?
    let capturedAt: Date
    init(tapError: AppError? = nil, capturedAt: Date = Date()) { self.tapError = tapError; self.capturedAt = capturedAt }
    func screenshot() async throws -> FrameImage { screenshotReads += 1; return FrameImage(id: "fresh", png: Data(), width: 390, height: 844, capturedAt: capturedAt, isDemo: true) }
    func configureAccessibility(data: Data? = nil, error: NativeBackendError? = nil) { accessibilityData = data; accessibilityError = error }
    func accessibilityObservation() async throws -> Data? {
        accessibilityReads += 1
        if let accessibilityError { throw accessibilityError }
        return accessibilityData
    }
    func configureGeometry(token: String = "portrait", bounds: NativeDisplayBounds? = .init(x: 0, y: 0, width: 393, height: 852), error: Error? = nil) {
        geometryToken = token; logicalBounds = bounds; geometryError = error
    }
    func inputDisplaySnapshot() throws -> InputDisplaySnapshot {
        geometryReads += 1
        if let geometryError { throw geometryError }
        return .init(context: "synthetic-system-session", token: geometryToken, sampledAt: Date(), logicalBounds: logicalBounds)
    }
    func authorizeIndependentInput(_ snapshot: InputDisplaySnapshot, authorizationID: String) throws {
        guard snapshot.token == geometryToken, snapshot.logicalBounds == logicalBounds else { throw RemoteRPCError("geometry_changed", "Fixture geometry changed") }
        independentGrant = authorizationID
    }
    func independentInput(name: String, coordinates: [Int], durationMS: Int, snapshot: InputDisplaySnapshot, authorizationID: String) throws {
        guard independentGrant == authorizationID, snapshot.token == geometryToken else { throw AppError.stopped }
        independentGrant = nil
        coordinateDeliveries.append(coordinates)
        if name == "tap" { taps += 1; if let tapError { throw tapError } }
        else { drags += 1 }
    }
    func tap(x: Int, y: Int, imageID: String) async throws { taps += 1; if let tapError { throw tapError } }
    func drag(fromX: Int, fromY: Int, toX: Int, toY: Int, durationMS: Int, imageID: String) async throws { drags += 1 }
    func systemActionContext() async throws -> String { "synthetic-system-session" }
    func authorizeSystemAction(authorizationID: String, taskScoped: Bool) async throws {}
    func setRemoteDeadline(_ deadline: Date) throws { if deadline <= Date() { throw AppError.stopped } }
    private var appRows: [[String: Any]] = [["name": "Fixture", "bundle_id": "example.fixture", "path": "PRIVATE_PATH"]]
    func configureApps(_ rows: [[String: Any]]) { appRows = rows }
    func installedApplications() async throws -> Data { try JSONSerialization.data(withJSONObject: appRows) }
    func systemAction(name: String, text: String, arguments: [String], imageID: String) async throws -> NativeApplicationLaunch? {
        systemActions.append(name); insertedText = text; launchArguments = arguments
        return name == "launch_app" ? NativeApplicationLaunch(bundleID: text, pid: 7001) : nil
    }
    func stop() async { stopped = true }
}
final class SafetyTests: XCTestCase {
    func testModelCanChooseTextThenImageAfterUnavailableAccessibilityWithinOneRun() async throws {
        let bridge = SpyBridge(), provider = AccessibilityReplayProvider(observationArguments: [#"{"mode":"accessibility"}"#, #"{"mode":"screenshot"}"#])
        let coordinator = ActionCoordinator(bridge: bridge, limits: AgentLimits(), approve: { _ in true }, onImage: { _, _ in }, onReceipt: { _ in }, screenInformationMode: .automatic)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString), sessionID = UUID()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = JSONLSessionStore(root: root, sessionID: sessionID)
        let runtime = AgentRuntime(store: store, provider: provider, configuration: AgentConfiguration(model: "fixture", instructions: "Choose useful observations."),
            tools: [DeviceTool(name: "screenshot", coordinator: coordinator)])
        _ = try await runtime.createSession(id: sessionID)
        let run = try await runtime.startTurn(in: sessionID, input: .init(text: "Read this page"))
        let result = await run.result(); XCTAssertEqual(result.status, .completed)
        let records = try await store.readTransactions(sessionID).flatMap(\.toolResults)
        XCTAssertEqual(records.count, 2)
        XCTAssertTrue(records.first?.outcome.content.contains("unsupported_route") == true)
        XCTAssertFalse(records.first?.outcome.content.contains("image_id") == true)
        XCTAssertTrue(records.last?.outcome.content.contains("image_id") == true)
        let captures = await bridge.screenshotReads, reads = await bridge.accessibilityReads
        XCTAssertEqual(captures, 1); XCTAssertEqual(reads, 1)
        XCTAssertEqual(provider.requests.count, 3)
        let schema = try XCTUnwrap(provider.requests.first?.tools.first?.schema.foundation as? [String: Any])
        XCTAssertEqual(schema["required"] as? [String], ["mode"])
    }
    func testFixedAndAutomaticObservationsReadOnlyTheSelectedSources() async throws {
        for configured in ScreenInformationMode.allCases {
            let choices: [ScreenInformationMode] = configured == .automatic ? [.screenshot, .accessibility, .screenshotAndAccessibility] : [configured]
            for choice in choices {
                let bridge = SpyBridge()
                await bridge.configureAccessibility(data: Data(#"{"status":"available","nodes":[{"label":"Visible fixture"}]}"#.utf8))
                let coordinator = ActionCoordinator(bridge: bridge, limits: AgentLimits(), approve: { _ in true },
                    onImage: { _, _ in XCTAssertTrue(choice.includesScreenshot) }, onReceipt: { _ in }, screenInformationMode: configured)
                let result = try await coordinator.execute(name: "screenshot", parameters: configured == .automatic ? ["mode": choice.rawValue] : [:], callID: "observe")
                let captures = await bridge.screenshotReads, reads = await bridge.accessibilityReads
                XCTAssertEqual(captures, choice.includesScreenshot ? 1 : 0)
                XCTAssertEqual(reads, choice.includesAccessibility ? 1 : 0)
                XCTAssertEqual(result.images.count, choice.includesScreenshot ? 1 : 0)
                let value = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(result.content.utf8)) as? [String: Any])
                XCTAssertEqual(value["accessibility"] != nil, choice.includesAccessibility)
                XCTAssertEqual(value["image_id"] != nil, choice.includesScreenshot)
            }
        }
    }
    func testAutomaticRequiresModelChoiceAndFixedModeCannotBeOverridden() async throws {
        for mode in ScreenInformationMode.allCases {
            let bridge = SpyBridge()
            let coordinator = ActionCoordinator(bridge: bridge, limits: AgentLimits(), approve: { _ in true }, onImage: { _, _ in }, onReceipt: { _ in }, screenInformationMode: mode)
            let invalid: [[String: Any]] = mode == .automatic ? [[:], ["mode": "automatic"], ["mode": "unknown"], ["mode": true]] : [["mode": "screenshot"]]
            for parameters in invalid {
                do { _ = try await coordinator.execute(name: "screenshot", parameters: parameters, callID: UUID().uuidString); XCTFail("Expected invalid mode") }
                catch { XCTAssertNotNil(error as? AppError) }
            }
            let captures = await bridge.screenshotReads, reads = await bridge.accessibilityReads
            XCTAssertEqual(captures, 0); XCTAssertEqual(reads, 0)
            let next = try await coordinator.execute(name: "screenshot", parameters: mode == .automatic ? ["mode": "screenshot"] : [:], callID: "next")
            XCTAssertEqual(next.kind, .returned)
        }
    }
    func testAccessibilityOnlyFailureDoesNotCaptureOrBlockSystemActions() async throws {
        let bridge = SpyBridge()
        await bridge.configureAccessibility(error: .accessibilityFailure(stage: 29, cause: 14))
        let coordinator = ActionCoordinator(bridge: bridge, limits: AgentLimits(), approve: { _ in true }, onImage: { _, _ in XCTFail("No image expected") }, onReceipt: { _ in }, screenInformationMode: .accessibility)
        let result = try await coordinator.execute(name: "screenshot", parameters: [:], callID: "unavailable")
        XCTAssertEqual(result.kind, .returned); XCTAssertTrue(result.images.isEmpty)
        XCTAssertTrue(result.content.contains("selection_unavailable"))
        _ = try await coordinator.execute(name: "home", parameters: ["description": "fixture"], callID: "next-action")
        let captures = await bridge.screenshotReads, actions = await bridge.systemActions
        XCTAssertEqual(captures, 0); XCTAssertEqual(actions, ["home"])
    }
    func testAccessibilityOnlyInvalidatesOldPixelReferenceUntilModelChoosesScreenshot() async throws {
        let bridge = SpyBridge()
        let coordinator = ActionCoordinator(bridge: bridge, limits: AgentLimits(), approve: { _ in true }, onImage: { _, _ in }, onReceipt: { _ in }, screenInformationMode: .automatic)
        _ = try await coordinator.execute(name: "screenshot", parameters: ["mode": "screenshot"], callID: "image")
        _ = try await coordinator.execute(name: "screenshot", parameters: ["mode": "accessibility"], callID: "text")
        do { _ = try await coordinator.execute(name: "tap", parameters: ["x": 1, "y": 1, "description": "fixture"], callID: "stale"); XCTFail("Old screenshot must not survive text-only observation") } catch {}
        let before = await bridge.taps; XCTAssertEqual(before, 0)
        _ = try await coordinator.execute(name: "screenshot", parameters: ["mode": "screenshot"], callID: "fresh")
        _ = try await coordinator.execute(name: "tap", parameters: ["x": 1, "y": 1, "description": "fixture"], callID: "valid")
        let after = await bridge.taps; XCTAssertEqual(after, 1)
    }
    func testAccessibilityOnlyTapAndDragUseFractionalLogicalPointsWithoutImages() async throws {
        for mode: ScreenInformationMode in [.accessibility, .automatic] {
            let bridge = SpyBridge()
            await bridge.configureAccessibility(data: Data(#"{"status":"available","nodes":[{"label":"Button","frame":{"x":180,"y":400,"width":33,"height":52}}]}"#.utf8))
            let coordinator = ActionCoordinator(bridge: bridge, limits: AgentLimits(), approve: { _ in true },
                onImage: { _, _ in XCTFail("No screenshot") }, onReceipt: { _ in }, screenInformationMode: mode)
            let result = try await coordinator.execute(name: "screenshot", parameters: mode == .automatic ? ["mode": "accessibility"] : [:], callID: "observe")
            XCTAssertTrue(result.images.isEmpty); XCTAssertTrue(result.content.contains("logical-point"))
            _ = try await invoke(DeviceTool(name: "tap", coordinator: coordinator), callID: "tap", parameters: ["x": 196.5, "y": 426, "description": "fixture"])
            _ = try await invoke(DeviceTool(name: "drag", coordinator: coordinator), callID: "drag", parameters: ["from_x": 196.5, "from_y": 639, "to_x": 98.25, "to_y": 213, "duration_ms": 300, "description": "fixture"])
            let coordinates = await bridge.coordinateDeliveries, captures = await bridge.screenshotReads
            XCTAssertEqual(coordinates, [[32768, 32768], [32768, 49151, 16384, 16384]])
            XCTAssertEqual(captures, 0)
        }
    }
    func testAccessibilityInputFailureCanRecoverWithNewObservationAndNeverReplays() async throws {
        let bridge = SpyBridge(tapError: .unknownOutcome)
        await bridge.configureAccessibility(data: Data(#"{"status":"available","nodes":[]}"#.utf8))
        let coordinator = ActionCoordinator(bridge: bridge, limits: AgentLimits(), approve: { _ in true }, onImage: { _, _ in XCTFail("No screenshot") }, onReceipt: { _ in }, screenInformationMode: .accessibility)
        let tap = DeviceTool(name: "tap", coordinator: coordinator)
        _ = try await coordinator.execute(name: "screenshot", parameters: [:], callID: "observe")
        await bridge.configureGeometry(token: "changed")
        let stale = try await invoke(tap, callID: "stale", parameters: ["x": 100, "y": 100, "description": "fixture"])
        XCTAssertFalse(stale.kind == .returned)
        var count = await bridge.taps; XCTAssertEqual(count, 0)
        _ = try await coordinator.execute(name: "screenshot", parameters: [:], callID: "fresh")
        let unknown = try await invoke(tap, callID: "uncertain", parameters: ["x": 100, "y": 100, "description": "fixture"])
        XCTAssertEqual(unknown.kind, .outcomeUnknown)
        _ = try await coordinator.execute(name: "home", parameters: ["description": "fixture"], callID: "home")
        _ = try await coordinator.execute(name: "screenshot", parameters: [:], callID: "again")
        let drag = try await invoke(DeviceTool(name: "drag", coordinator: coordinator), callID: "next", parameters: ["from_x": 100, "from_y": 500, "to_x": 100, "to_y": 100, "duration_ms": 300, "description": "fixture"])
        XCTAssertEqual(drag.kind, .returned)
        count = await bridge.taps; let captures = await bridge.screenshotReads, stopped = await bridge.stopped
        XCTAssertEqual(count, 1); XCTAssertEqual(captures, 0); XCTAssertFalse(stopped)
    }
    func testAccessibilityInputRejectsOffscreenAndBooleanPointsBeforeDelivery() async throws {
        let bridge = SpyBridge()
        await bridge.configureAccessibility(data: Data(#"{"status":"available","nodes":[]}"#.utf8))
        let coordinator = ActionCoordinator(bridge: bridge, limits: AgentLimits(), approve: { _ in true }, onImage: { _, _ in }, onReceipt: { _ in }, screenInformationMode: .accessibility)
        for x: Any in [-1, 393, true, "100"] {
            _ = try await coordinator.execute(name: "screenshot", parameters: [:], callID: "observe")
            let result = try await invoke(DeviceTool(name: "tap", coordinator: coordinator), callID: "invalid", parameters: ["x": x, "y": 200, "description": "fixture"])
            XCTAssertEqual(result.kind, .validationFailed)
        }
        let taps = await bridge.taps, captures = await bridge.screenshotReads
        XCTAssertEqual(taps, 0); XCTAssertEqual(captures, 0)
    }
    func testUnavailableInputGeometryKeepsAccessibilityTextAndAllowsFreshObservation() async throws {
        let bridge = SpyBridge()
        await bridge.configureAccessibility(data: Data(#"{"status":"available","nodes":[{"label":"Read me"}]}"#.utf8))
        await bridge.configureGeometry(error: NativeInputGeometryError(.framePending))
        let coordinator = ActionCoordinator(bridge: bridge, limits: AgentLimits(), approve: { _ in true }, onImage: { _, _ in }, onReceipt: { _ in }, screenInformationMode: .accessibility)
        let unavailable = try await coordinator.execute(name: "screenshot", parameters: [:], callID: "text")
        XCTAssertTrue(unavailable.content.contains("Read me")); XCTAssertTrue(unavailable.content.contains("geometry_unavailable"))
        _ = try await coordinator.execute(name: "home", parameters: ["description": "fixture"], callID: "home")
        await bridge.configureGeometry()
        _ = try await coordinator.execute(name: "screenshot", parameters: [:], callID: "fresh")
        let result = try await invoke(DeviceTool(name: "tap", coordinator: coordinator), callID: "tap", parameters: ["x": 196.5, "y": 426, "description": "fixture"])
        XCTAssertEqual(result.kind, .returned)
        let captures = await bridge.screenshotReads; XCTAssertEqual(captures, 0)
    }
    func testRemoteScreenshotsKeepImageContractRegardlessOfLocalMode() async throws {
        for mode in ScreenInformationMode.allCases {
            let bridge = SpyBridge()
            let coordinator = ActionCoordinator(bridge: bridge, limits: AgentLimits(), approve: { _ in true }, onImage: { _, _ in }, onReceipt: { _ in }, screenInformationMode: mode)
            let result = try await coordinator.executeRemote(name: "screenshot", parameters: [:], callID: "remote", expectedImageID: nil, deadline: Date().addingTimeInterval(10))
            XCTAssertEqual(result.kind, .returned); XCTAssertEqual(result.images.count, 1)
            let reads = await bridge.accessibilityReads; XCTAssertEqual(reads, 0)
        }
    }
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
        let enabled = ActionCoordinator(bridge: bridge, limits: AgentLimits(), approve: { _ in true }, onImage: { _, _ in }, onReceipt: { _ in }, screenInformationMode: .screenshotAndAccessibility)
        let second = try await enabled.execute(name: "screenshot", parameters: [:], callID: "enabled")
        XCTAssertTrue(second.content.contains("fixture")); XCTAssertTrue(second.content.contains("accessibility"))
        await bridge.configureAccessibility(error: .accessibilityFailure(stage: 22, cause: 4))
        let third = try await enabled.execute(name: "screenshot", parameters: [:], callID: "fallback")
        XCTAssertEqual(third.kind, .returned); XCTAssertTrue(third.content.contains("service_unavailable"))
        _ = try await enabled.execute(name: "tap", parameters: ["x": 10, "y": 10, "description": "fixture"], callID: "after-fallback")
        let taps = await bridge.taps; XCTAssertEqual(taps, 1)
    }
    func testAccessibilityResultRemainsCompleteAndWirePrefixStableAfterJSONLReload() async throws {
        for mode: ScreenInformationMode in [.screenshotAndAccessibility, .accessibility] {
            let bridge = SpyBridge(), provider = AccessibilityReplayProvider(), sessionID = UUID()
            let nodes = (0..<400).map { ["label": "AX_FIXTURE_\($0)_" + String(repeating: "text ", count: 30)] }
            let observation = try JSONSerialization.data(withJSONObject: ["status": "available", "nodes": nodes, "atomic": false])
            await bridge.configureAccessibility(data: observation)
            let coordinator = ActionCoordinator(bridge: bridge, limits: AgentLimits(), approve: { _ in true },
                onImage: { _, _ in }, onReceipt: { _ in }, screenInformationMode: mode)
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
            XCTAssertEqual(receipt.contains("image_id"), mode.includesScreenshot)
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
    }
    func testSystemActionsForwardExactTextAndArgumentsWithoutScreenshotDependency() async throws {
        let bridge = SpyBridge()
        let coordinator = ActionCoordinator(bridge: bridge, limits: AgentLimits(), approve: { _ in true }, onImage: { _, _ in }, onReceipt: { _ in })
        _ = try await coordinator.execute(name: "type_text", parameters: ["text": "你好 ESP32 🌟\n ", "description": "insert requested whitespace"], callID: "text")
        let text = await bridge.insertedText; XCTAssertEqual(text, "你好 ESP32 🌟\n ")
        _ = try await coordinator.execute(name: "home", parameters: ["description": "home"], callID: "home-no-frame")
        let launched = try await coordinator.execute(name: "launch_app", parameters: ["bundle_id": "example.fixture", "arguments": ["--test", "值"], "description": "open fixture"], callID: "launch")
        let receipt = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(launched.content.utf8)) as? [String: Any])
        XCTAssertEqual(receipt["pid"] as? Int, 7001); XCTAssertEqual(receipt["bundle_id"] as? String, "example.fixture")
        XCTAssertNil(receipt["foregroundAppConfirmed"])
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
            let result = try await invoke(tool, callID: UUID().uuidString, parameters: ["text": text, "description": "unsupported fixture"])
            XCTAssertNotEqual(result.kind, .returned)
            XCTAssertTrue(result.content.contains("未发送任何按键"))
            XCTAssertFalse(result.finishTurn)
        }
        let dispatched = await bridge.systemActions
        XCTAssertTrue(dispatched.isEmpty)
        // Same session remains usable after preflight failure, with no reconnect.
        _ = try await coordinator.execute(name: "screenshot", parameters: [:], callID: "fresh-after-errors")
        _ = try await coordinator.execute(name: "type_text", parameters: ["text": "ESP32 direct!", "description": "valid fixture"], callID: "t")
        let inserted = await bridge.insertedText
        XCTAssertEqual(inserted, "ESP32 direct!")
    }
    func testAppQueryNeedsNoScreenshotAndDoesNotExposePrivatePaths() async throws {
        let coordinator = ActionCoordinator(bridge: SpyBridge(), limits: AgentLimits(), approve: { _ in XCTFail("read query requested input approval"); return false }, onImage: { _, _ in }, onReceipt: { _ in })
        let result = try await coordinator.execute(name: "list_apps", parameters: [:], callID: "apps")
        XCTAssertEqual(result.kind, .returned); XCTAssertTrue(result.content.contains("example.fixture"))
        XCTAssertFalse(result.content.contains("PRIVATE_PATH"))
    }
    func testAppQueryFiltersByNameAndBundleIDWithoutMatchingPrivateFields() async throws {
        let bridge = SpyBridge()
        await bridge.configureApps([["name": "Settings", "bundle_id": "com.apple.Preferences", "path": "PRIVATE_PATH"],
                                    ["name": "相机", "bundle_id": "com.apple.camera", "version": "1.0"],
                                    ["name": "Notes", "bundle_id": "com.apple.mobilenotes"]])
        let coordinator = ActionCoordinator(bridge: bridge, limits: AgentLimits(), approve: { _ in XCTFail("read query requested input approval"); return false }, onImage: { _, _ in }, onReceipt: { _ in })
        func apps(_ parameters: [String: Any], callID: String) async throws -> [[String: Any]] {
            let result = try await coordinator.execute(name: "list_apps", parameters: parameters, callID: callID)
            XCTAssertEqual(result.kind, .returned)
            return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(result.content.utf8)) as? [[String: Any]])
        }
        // Name match is case-insensitive; bundle ID match ignores case too.
        var rows = try await apps(["query": "settings"], callID: "name")
        XCTAssertEqual(rows.map { $0["bundle_id"] as? String }, ["com.apple.Preferences"])
        rows = try await apps(["query": "PREFERENCES"], callID: "bundle")
        XCTAssertEqual(rows.map { $0["bundle_id"] as? String }, ["com.apple.Preferences"])
        // CJK substring and full-width-insensitive matching.
        rows = try await apps(["query": "相"], callID: "cjk")
        XCTAssertEqual(rows.map { $0["bundle_id"] as? String }, ["com.apple.camera"])
        rows = try await apps(["query": "ＮＯＴＥＳ"], callID: "width")
        XCTAssertEqual(rows.map { $0["bundle_id"] as? String }, ["com.apple.mobilenotes"])
        // No match returns an empty list; no query returns everything unfiltered.
        rows = try await apps(["query": "不存在的应用"], callID: "none")
        XCTAssertTrue(rows.isEmpty)
        // Any |-separated alternative matches, so one query covers bilingual aliases.
        rows = try await apps(["query": "多邻国|duolingo|camera"], callID: "alias")
        XCTAssertEqual(rows.map { $0["bundle_id"] as? String }, ["com.apple.camera"])
        rows = try await apps(["query": "settings|camera"], callID: "any")
        XCTAssertEqual(rows.map { $0["bundle_id"] as? String }, ["com.apple.Preferences", "com.apple.camera"])
        // Empty alternatives are skipped instead of matching everything.
        rows = try await apps(["query": "Notes||camera"], callID: "empty-arm")
        XCTAssertEqual(rows.map { $0["bundle_id"] as? String }, ["com.apple.camera", "com.apple.mobilenotes"])
        // Blanks around alternatives are trimmed; a whitespace-only query behaves like no query.
        rows = try await apps(["query": " mobilenotes | camera "], callID: "padded")
        XCTAssertEqual(rows.map { $0["bundle_id"] as? String }, ["com.apple.camera", "com.apple.mobilenotes"])
        rows = try await apps(["query": "   "], callID: "blank")
        XCTAssertEqual(rows.count, 3)
        rows = try await apps([:], callID: "all")
        XCTAssertEqual(rows.count, 3)
        // Private fields stay excluded on filtered rows too.
        rows = try await apps(["query": "Settings"], callID: "safe")
        XCTAssertFalse(rows.contains { $0["path"] != nil })
        do { _ = try await coordinator.execute(name: "list_apps", parameters: ["query": String(repeating: "长", count: 101)], callID: "long"); XCTFail("Over-long query must be rejected") }
        catch let error as AppError { XCTAssertEqual(error, .invalid(String(localized: "The app query is too long"))) }
    }
    func testInputSchemasOnlyRequireCoordinatesDurationAndDescription() {
        let coordinator = ActionCoordinator(bridge: SpyBridge(), limits: AgentLimits(), approve: { _ in true }, onImage: { _, _ in }, onReceipt: { _ in })
        for (name, keys) in [("tap", ["x", "y", "description"]),
                             ("drag", ["from_x", "from_y", "to_x", "to_y", "duration_ms", "description"])] {
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
        _ = try await coordinator.execute(name: "tap", parameters: ["x": 100, "y": 100, "description": "fixture tap"], callID: "t")
        _ = try await coordinator.execute(name: "screenshot", parameters: [:], callID: "s2")
        _ = try await coordinator.execute(name: "drag", parameters: ["from_x": 100, "from_y": 100, "to_x": 120, "to_y": 120, "duration_ms": 200, "description": "fixture drag"], callID: "d")
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
        let failed = try await invoke(DeviceTool(name: "tap", coordinator: c), callID: "t", parameters: ["x": 100, "y": 100, "description": "test"])
        XCTAssertNotEqual(failed.kind, .returned)
        XCTAssertTrue(failed.content.contains("动作结果未知"))
        XCTAssertTrue(failed.content.contains("未自动重发"))
        XCTAssertFalse(failed.content.contains("截图"))
        XCTAssertFalse(failed.finishTurn)
        let noObservation = try await invoke(DeviceTool(name: "tap", coordinator: c), callID: "no-frame", parameters: ["x": 100, "y": 100, "description": "tap"])
        XCTAssertNotEqual(noObservation.kind, .returned, "An unknown action must consume its old image")
        for name in ["drag", "home", "launch_app", "type_text"] {
            _ = try await c.execute(name: "screenshot", parameters: [:], callID: "s-" + name)
            let result = try await invoke(DeviceTool(name: name, coordinator: c), callID: "next-" + name, parameters: ["from_x": 100, "from_y": 100, "to_x": 120, "to_y": 120, "duration_ms": 200, "description": "observed next step", "bundle_id": "example.fixture", "text": "fixture"])
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
            _ = try await c.execute(name: "tap", parameters: ["x": 100, "y": 100, "description": "test"], callID: "t")
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
            _ = try await c.execute(name: "tap", parameters: ["x": 100, "y": 100, "description": "fixture"], callID: "t")
            XCTFail("Task authorization must be explicitly supported by the input bridge")
        } catch { XCTAssertTrue(error.localizedDescription.contains("不支持任务内自动授权")) }
        let count = await bridge.taps; XCTAssertEqual(count, 0)
    }
    func testCoordinateReferencePersistsButEachInputStillNeedsApproval() async throws {
        let bridge = SpyBridge()
        let c = ActionCoordinator(bridge: bridge, limits: AgentLimits(), approve: { $0.callID != "denied" }, onImage: { _, _ in }, onReceipt: { _ in })
        _ = try await c.execute(name: "screenshot", parameters: [:], callID: "s")
        let p: [String: Any] = ["x": 100, "y": 100, "description": "test"]
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
        do { _ = try await c.execute(name: "tap", parameters: ["x": true, "y": 0, "description": "bad"], callID: "t"); XCTFail("Boolean must fail") } catch {}
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
