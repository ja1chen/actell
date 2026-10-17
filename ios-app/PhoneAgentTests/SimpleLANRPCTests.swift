import CryptoKit
import Network
import XCTest
@testable import PhoneAgent

private actor SimpleLANImageBridge: DeviceBridge {
    private let demo = DemoBridge()
    private(set) var geometryQueries = 0
    func inputDisplaySnapshot() throws -> InputDisplaySnapshot {
        geometryQueries += 1
        throw RemoteRPCError("geometry_unavailable", "Synthetic geometry failure",
            underlying: NativeInputGeometryError(.metadataQuery, stage: 11, cause: 2))
    }
    func setRemoteDeadline(_ deadline: Date) throws { guard deadline > Date() else { throw AppError.stopped } }
    func screenshot() async throws -> FrameImage { try await demo.screenshot() }
    func tap(x: Int, y: Int, imageID: String) throws { throw AppError.stopped }
    func drag(fromX: Int, fromY: Int, toX: Int, toY: Int, durationMS: Int, imageID: String) throws { throw AppError.stopped }
    func stop() async { await demo.stop() }
}

@MainActor final class SimpleLANRPCTests: XCTestCase {
    func testAuthenticationReasonsPersistLocallyWhile401StaysGeneric() async throws {
        let model = AgentViewModel(loadPersistentState: false)
        model.setForeground(true); model.setProtectedDataAvailable(true)
        let provider = RemoteGeneratedIdentityProvider(namespace: "actell.tests.auth-reasons." + UUID().uuidString)
        let identity = try provider.provision(host: "actell-auth-test.local")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let service = RemoteToolsService(model: model)
        let key = Data(repeating: 0x33, count: 32)
        var liveKey: Data? = key
        service.keyLookupDiagnostic = { _ in "unknown_client" }
        service.authorizeRequest = { _, _, _ in true }
        defer { service.stop(); try? provider.remove(); try? FileManager.default.removeItem(at: directory) }
        try service.start(configuration: .init(enabled: true, port: UInt16.random(in: 20000...40000),
                          allowedSources: [RemoteSourceAddress(literal: "127.0.0.1")!]),
                          identity: identity.identity, keyLookup: { _ in liveKey }, directory: directory)
        let client = "synthetic-unverified-client"
        func packet(offset: Int64 = 0, signingKey: Data? = nil) throws -> (Data, [String: String], String) {
            let id = UUID().uuidString.lowercased(), nonce = UUID().uuidString.lowercased()
            let time = String(Int64(Date().timeIntervalSince1970) + offset)
            let body = try JSONSerialization.data(withJSONObject: ["v": 1, "client_id": client, "request_id": id, "op": "capabilities", "params": [:]])
            let signature = HMAC<SHA256>.authenticationCode(for: RemoteRequestAuthenticator.signingMessage(clientID: client, requestID: id, time: time, nonce: nonce, body: body), using: SymmetricKey(data: signingKey ?? key)).map { String(format: "%02x", $0) }.joined()
            return (body, ["x-actell-time": time, "x-actell-nonce": nonce, "x-actell-signature": signature], id)
        }
        func rejected(_ packet: (Data, [String: String], String), reason: String) async throws {
            let response = await service.handle(body: packet.0, headers: packet.1)
            XCTAssertEqual(response.status, 401)
            let envelope = try XCTUnwrap(JSONSerialization.jsonObject(with: response.body) as? [String: Any])
            let error = try XCTUnwrap(envelope["error"] as? [String: Any])
            XCTAssertEqual(error["message"] as? String, "Authentication failed")
            XCTAssertEqual(error["code"] as? String, reason == "replayed" ? "replay" : "unauthorized")
            let event = try XCTUnwrap(MuseDiagnosticsLog(directory: directory).events.last)
            XCTAssertEqual(event.stage, "rpc.authentication.rejected")
            XCTAssertEqual(event.code, reason)
            XCTAssertEqual(event.diagnosticID, MuseDiagnosticsLog.tag(packet.2))
            XCTAssertEqual(event.state["authenticated"], "false")
        }
        let malformed = try packet()
        try await rejected((malformed.0, [:], malformed.2), reason: "malformed")
        try await rejected(packet(offset: -120), reason: "clock_skew")
        liveKey = nil
        try await rejected(packet(), reason: "key_unavailable")
        XCTAssertEqual(model.museDiagnostics.events.last?.state["key_state"], "unknown_client")
        liveKey = key
        try await rejected(packet(signingKey: Data(repeating: 0, count: 32)), reason: "signature_mismatch")
        let valid = try packet()
        let accepted = await service.handle(body: valid.0, headers: valid.1)
        XCTAssertEqual(accepted.status, 200)
        try await rejected(valid, reason: "replayed")
        let report = model.museDiagnostics.report()
        XCTAssertFalse(report.contains(client))
        XCTAssertFalse(report.contains(valid.2))
        XCTAssertFalse(report.contains("x-actell-signature"))
    }

    func testFormalHMACAcknowledgesWithDefaultScopesAndPreservesRevocation() async throws {
        var lastBridge: SimpleLANImageBridge?
        let model = AgentViewModel(loadPersistentState: false, backgroundCoordinator: BackgroundExecutionCoordinator.testing(selection: []), makeRemoteBridge: {
            let bridge = SimpleLANImageBridge(); lastBridge = bridge; return bridge
        })
        model.setForeground(true); model.setProtectedDataAvailable(true)
        let store = RemoteConnectionStore(vault: RemoteMemoryVault(), defaults: nil)
        try store.prepareCompanion()
        let provider = RemoteGeneratedIdentityProvider(namespace: "actell.muse.generated-tls.v1." + store.settings.host)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("slan-rpc-" + UUID().uuidString)
        let service = RemoteToolsService(model: model)
        var uptime: TimeInterval = 100
        let controller = RemoteConnectionController(service: service, store: store, uptime: { uptime })
        defer { controller.stop(); try? provider.remove(); try? FileManager.default.removeItem(at: directory) }
        // Transport stays loopback-only in this test. Pair request is injected at the route boundary.
        try service.start(configuration: .init(enabled: true, port: UInt16.random(in: 20000...40000), allowedSources: [RemoteSourceAddress(literal: "127.0.0.1")!]), identity: store.loadIdentity(), keyLookup: { id in controller.pairing.tick(); return store.key(for: id) }, directory: directory)
        for _ in 0..<100 where !service.isListening { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(service.isListening)
        try controller.openPairingWindow()
        let requestID = UUID().uuidString.lowercased()
        let body = try JSONSerialization.data(withJSONObject: ["v": 1, "request_id": requestID, "device_name": "Desk Muse"])
        let request = controller.pairing.handle(path: "/v1/pair/request", body: body, headers: ["content-type": "application/json", "authorization": "Bearer " + String(repeating: "A", count: 43)])
        XCTAssertEqual(request.status, 202)
        try controller.approvePairing()
        let client = try XCTUnwrap(store.settings.clients.first), key = try XCTUnwrap(store.key(for: client.id))
        func call(_ op: String, key: Data, parameters: [String: Any]? = nil) async throws -> RemoteHTTPResponse {
            let id = UUID().uuidString.lowercased(), nonce = UUID().uuidString.lowercased(), time = String(Int64(Date().timeIntervalSince1970))
            let params: [String: Any] = parameters ?? (op == "companion.hello" ? ["device_name": "Desk Muse", "protocol": 1] : [:])
            let body = try JSONSerialization.data(withJSONObject: ["v": 1, "client_id": client.id, "request_id": id, "op": op, "params": params])
            let signature = HMAC<SHA256>.authenticationCode(for: RemoteRequestAuthenticator.signingMessage(clientID: client.id, requestID: id, time: time, nonce: nonce, body: body), using: SymmetricKey(data: key)).map { String(format: "%02x", $0) }.joined()
            return await service.handle(body: body, headers: ["x-actell-time": time, "x-actell-nonce": nonce, "x-actell-signature": signature])
        }
        let denied = try await call("capabilities", key: key)
        XCTAssertEqual((try JSONSerialization.jsonObject(with: denied.body) as? [String: Any])?["ok"] as? Bool, false)
        let beforeInvalid = MuseDiagnosticsLog(directory: directory).events.count
        let wrong = try await call("companion.hello", key: Data(repeating: 0, count: 32))
        XCTAssertEqual(wrong.status, 401); XCTAssertFalse(store.settings.clients[0].identityConfirmed)
        let rejectedEvents = Array(MuseDiagnosticsLog(directory: directory).events.dropFirst(beforeInvalid))
        XCTAssertEqual(rejectedEvents.count, 1)
        XCTAssertEqual(rejectedEvents.first?.stage, "rpc.authentication.rejected")
        XCTAssertEqual(rejectedEvents.first?.code, "signature_mismatch")
        XCTAssertEqual(rejectedEvents.first?.state["authenticated"], "false")
        XCTAssertFalse(rejectedEvents.contains { $0.stage.hasPrefix("companion.hello") }) // No forged authenticated trace.
        XCTAssertFalse(controller.isPeerOnline(client.id))
        for _ in 0..<2 {
            let reply = try await call("companion.hello", key: key)
            let result = (try JSONSerialization.jsonObject(with: reply.body) as! [String: Any])["result"] as! [String: Any]
            XCTAssertEqual(result["pairing_state"] as? String, "active")
            XCTAssertEqual(result["state"] as? String, "authorized")
            XCTAssertEqual(result["scopes"] as? [String], MuseCompanionScope.allCases.map(\.rawValue).sorted())
            XCTAssertTrue(controller.isPeerOnline(client.id)) // Visible immediately, before a UI timer tick.
        }
        let helloEvents = MuseDiagnosticsLog(directory: directory).events
        XCTAssertTrue(helloEvents.contains { $0.stage == "companion.hello.received" })
        XCTAssertTrue(helloEvents.contains { $0.stage == "companion.hello.result" })
        let capabilities = try await call("capabilities", key: key)
        let capabilityEnvelope = try XCTUnwrap(JSONSerialization.jsonObject(with: capabilities.body) as? [String: Any])
        let capabilityID = try XCTUnwrap(capabilityEnvelope["request_id"] as? String)
        let capabilityEvent = try XCTUnwrap(MuseDiagnosticsLog(directory: directory).events.last)
        XCTAssertEqual(capabilityEvent.stage, "capabilities.result")
        XCTAssertEqual(capabilityEvent.diagnosticID, MuseDiagnosticsLog.tag(capabilityID))
        // Idle backgrounding preserves the listener and real authenticated presence.
        model.setScene(.background); controller.setScene(active: false, background: true)
        XCTAssertTrue(service.isListening)
        XCTAssertTrue(controller.isPeerOnline(client.id))
        XCTAssertFalse(controller.pairing.available)
        uptime += MuseCompanionProtocol.peerFreshness
        XCTAssertFalse(controller.isPeerOnline(client.id))
        let backgroundHello = try await call("companion.hello", key: key)
        XCTAssertEqual(backgroundHello.status, 200)
        let backgroundEnvelope = try XCTUnwrap(JSONSerialization.jsonObject(with: backgroundHello.body) as? [String: Any])
        XCTAssertEqual(backgroundEnvelope["ok"] as? Bool, true)
        XCTAssertNil(backgroundEnvelope["error"])
        let backgroundResult = try XCTUnwrap(backgroundEnvelope["result"] as? [String: Any])
        XCTAssertEqual(backgroundResult["state"] as? String, "authorized")
        XCTAssertEqual(backgroundResult["pairing_state"] as? String, "active")
        XCTAssertTrue(controller.isPeerOnline(client.id))
        XCTAssertFalse(controller.pairing.available)
        model.setScene(.active); controller.setScene(active: true, background: false)
        XCTAssertTrue(service.isListening)
        XCTAssertTrue(controller.isPeerOnline(client.id))
        let missingCall = try await call("calls.get", key: key, parameters: ["run_id": "missing-run", "call_id": "missing-call"])
        let missingEnvelope = try XCTUnwrap(JSONSerialization.jsonObject(with: missingCall.body) as? [String: Any])
        let missingID = try XCTUnwrap(missingEnvelope["request_id"] as? String)
        let missingEvent = try XCTUnwrap(MuseDiagnosticsLog(directory: directory).events.last)
        XCTAssertEqual(model.museDiagnostics.events.last?.diagnosticID, MuseDiagnosticsLog.tag(missingID))
        XCTAssertEqual(missingEvent.stage, "calls.get.rejected")
        XCTAssertEqual(missingEvent.code, "not_found")
        XCTAssertEqual(missingEvent.diagnosticID, MuseDiagnosticsLog.tag(missingID))
        XCTAssertEqual(missingEvent.state["call"], MuseDiagnosticsLog.tag("missing-call"))
        XCTAssertEqual(missingEvent.run, MuseDiagnosticsLog.tag("missing-run"))
        XCTAssertFalse(MuseDiagnosticsLog(directory: directory).report().contains("missing-call"))
        // Local display-name changes must not look like permission revocation or peer loss.
        let scopes = Set(MuseCompanionScope.allCases)
        try controller.authorize(client, scopes: scopes, identityConfirmed: true, name: "客厅 Muse")
        XCTAssertTrue(controller.isPeerOnline(client.id))
        XCTAssertEqual(controller.settings.clients.first?.name, "客厅 Muse")
        XCTAssertEqual(store.key(for: client.id), key)
        let helloAfterRename = try await call("companion.hello", key: key) // Peer still sends Desk Muse.
        XCTAssertEqual((try JSONSerialization.jsonObject(with: helloAfterRename.body) as? [String: Any])?["ok"] as? Bool, true)
        XCTAssertEqual(controller.settings.clients.first?.name, "客厅 Muse")
        XCTAssertEqual(controller.settings.clients.first?.scopes, scopes)
        XCTAssertTrue(controller.isPeerOnline(client.id))
        // Capture the actual admission state rather than inspecting UI after the failure.
        for code in ["protected_data_unavailable", "local_task_busy"] {
            model.setForeground(true)
            model.setProtectedDataAvailable(code != "protected_data_unavailable")
            model.running = code == "local_task_busy"
            let runID = UUID().uuidString.lowercased()
            let rejected = try await call("runs.open", key: key, parameters: [
                "run_id": runID, "deadline_ms": Int64(Date().timeIntervalSince1970 * 1000) + 60_000
            ])
            let envelope = try XCTUnwrap(JSONSerialization.jsonObject(with: rejected.body) as? [String: Any])
            let error = try XCTUnwrap(envelope["error"] as? [String: Any])
            XCTAssertEqual(error["code"] as? String, code)
            let requestID = try XCTUnwrap(envelope["request_id"] as? String)
            XCTAssertTrue((error["message"] as? String)?.contains(MuseDiagnosticsLog.tag(requestID)) == true)
            XCTAssertFalse((error["message"] as? String)?.contains("App must be unlocked") == true)
            let persisted = MuseDiagnosticsLog(directory: directory)
            let event = try XCTUnwrap(persisted.events.last)
            XCTAssertEqual(event.stage, "runs.open.rejected")
            XCTAssertEqual(event.code, code)
            XCTAssertEqual(event.diagnosticID, MuseDiagnosticsLog.tag(requestID))
            XCTAssertEqual(event.run, MuseDiagnosticsLog.tag(runID))
            XCTAssertEqual(event.state["foreground"], "true")
            XCTAssertEqual(event.state["protected_data"], String(code != "protected_data_unavailable"))
            XCTAssertEqual(event.state["remote_lease"], "false")
            model.running = false; model.setForeground(true); model.setProtectedDataAvailable(true)
            let status = try await call("runs.get", key: key, parameters: ["run_id": runID])
            let state = (try JSONSerialization.jsonObject(with: status.body) as? [String: Any])?["result"] as? [String: Any]
            XCTAssertEqual(state?["state"] as? String, "cancelled") // Durable tombstone; no replay.
        }
        // Closing a run in the background must release execution without closing
        // the listener. Use a synthetic bridge; no device actions are dispatched.
        model.setForeground(false)
        service.setBackground(true) // A first authenticated background run is admitted.
        let closingRun = UUID().uuidString.lowercased()
        let opened = try await call("runs.open", key: key, parameters: [
            "run_id": closingRun, "deadline_ms": Int64(Date().timeIntervalSince1970 * 1000) + 60_000
        ])
        XCTAssertEqual((try JSONSerialization.jsonObject(with: opened.body) as? [String: Any])?["ok"] as? Bool, true)
        service.setBackground(true)
        _ = try await call("runs.cancel", key: key, parameters: ["run_id": closingRun])
        for _ in 0..<100 where model.hasBusySessions { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertFalse(model.hasBusySessions)
        XCTAssertTrue(service.isListening)
        XCTAssertTrue(controller.isPeerOnline(client.id))
        service.setBackground(false)
        model.setForeground(true)
        // New contract: screenshot results survive execution release, and a
        // normalized coordinate cannot silently enter the legacy pixel path.
        let imageRun = UUID().uuidString.lowercased(), imageCall = UUID().uuidString.lowercased()
        let imageDeadline = Int64(Date().timeIntervalSince1970 * 1000) + 300_000
        let imageOpened = try await call("runs.open", key: key, parameters: ["run_id": imageRun, "deadline_ms": imageDeadline,
            "input_contract": InputDisplaySnapshot.contract, "image_contract": RemoteImageGeometry.contract])
        XCTAssertEqual((try JSONSerialization.jsonObject(with: imageOpened.body) as? [String: Any])?["ok"] as? Bool, true)
        let mismatched = try await call("runs.open", key: key, parameters: ["run_id": imageRun, "deadline_ms": imageDeadline,
            "input_contract": "image-pixels-v1", "image_contract": RemoteImageGeometry.contract])
        XCTAssertEqual(((try JSONSerialization.jsonObject(with: mismatched.body) as? [String: Any])?["error"] as? [String: Any])?["code"] as? String, "idempotency_conflict")
        let outOfBounds = try await call("tools.call", key: key, parameters: ["run_id": imageRun, "call_id": "bounds", "deadline_ms": imageDeadline,
            "tool": "tap", "arguments": ["x": 1001, "y": 0, "purpose": "Synthetic input"]])
        XCTAssertEqual(((try JSONSerialization.jsonObject(with: outOfBounds.body) as? [String: Any])?["error"] as? [String: Any])?["code"] as? String, "coordinate_out_of_bounds")
        let geometryCall = UUID().uuidString.lowercased()
        let geometryParams: [String: Any] = ["run_id": imageRun, "call_id": geometryCall, "deadline_ms": imageDeadline,
            "tool": "tap", "arguments": ["x": 394, "y": 571, "purpose": "Private synthetic purpose"]]
        _ = try await call("tools.call", key: key, parameters: geometryParams)
        var failedReceipt: [String: Any]?
        for _ in 0..<100 {
            let status = try await call("calls.get", key: key, parameters: ["run_id": imageRun, "call_id": geometryCall])
            let result = (try JSONSerialization.jsonObject(with: status.body) as? [String: Any])?["result"] as? [String: Any]
            if result?["state"] as? String == "failed" { failedReceipt = result; break }
            try await Task.sleep(for: .milliseconds(20))
        }
        let failure = try XCTUnwrap(failedReceipt)
        XCTAssertEqual(failure["effect"] as? String, "not_sent")
        let failureError = try XCTUnwrap(failure["error"] as? [String: Any])
        XCTAssertEqual(failureError["code"] as? String, "geometry_unavailable")
        XCTAssertEqual(failureError["message"] as? String, String(localized: "Could not verify the current screen layout. No input was sent."))
        let restoredLog = MuseDiagnosticsLog(directory: directory)
        let failureEvent = try XCTUnwrap(restoredLog.events.last { $0.stage == "tool.execution.failed" })
        XCTAssertEqual(failureEvent.run, MuseDiagnosticsLog.tag(imageRun))
        XCTAssertEqual(failureEvent.state["call"], MuseDiagnosticsLog.tag(geometryCall))
        XCTAssertEqual(failureEvent.state["geometry_reason"], "metadata_query")
        XCTAssertEqual(failureEvent.state["native_stage"], "11")
        XCTAssertEqual(failureEvent.state["native_cause"], "2")
        XCTAssertFalse(restoredLog.report().contains("Private synthetic purpose"))
        _ = try await call("tools.call", key: key, parameters: geometryParams)
        let queries = await lastBridge?.geometryQueries
        XCTAssertEqual(queries, 1, "Reading the terminal receipt must never replay input preparation")
        // A subsequent independent call in the same run can still execute.
        _ = try await call("tools.call", key: key, parameters: ["run_id": imageRun, "call_id": imageCall, "deadline_ms": imageDeadline,
            "tool": "screenshot", "arguments": [:]])
        var imageReceipt: [String: Any]?
        for _ in 0..<100 {
            let status = try await call("calls.get", key: key, parameters: ["run_id": imageRun, "call_id": imageCall])
            let result = (try JSONSerialization.jsonObject(with: status.body) as? [String: Any])?["result"] as? [String: Any]
            if result?["state"] as? String == "succeeded" { imageReceipt = result?["result"] as? [String: Any]; break }
            if result?["state"] as? String == "failed" { XCTFail("Synthetic screenshot failed: \(result?["error"] ?? "missing error")"); break }
            try await Task.sleep(for: .milliseconds(20))
        }
        let receipt = try XCTUnwrap(imageReceipt)
        XCTAssertEqual(receipt["coordinate_space"] as? String, InputDisplaySnapshot.contract)
        XCTAssertEqual(receipt["image_status"] as? String, "available")
        XCTAssertEqual(try XCTUnwrap(receipt["expires_at_ms"] as? Int64) - XCTUnwrap(receipt["captured_at_ms"] as? Int64), 1_800_000)
        _ = try await call("runs.cancel", key: key, parameters: ["run_id": imageRun])
        for _ in 0..<100 where model.hasBusySessions { try await Task.sleep(for: .milliseconds(20)) }
        let original = try await call("images.get", key: key, parameters: ["run_id": imageRun, "image_id": try XCTUnwrap(receipt["image_id"]), "generation": try XCTUnwrap(receipt["generation"])])
        XCTAssertTrue(original.body.starts(with: [0xff, 0xd8, 0xff]))
        // Losing retained pixels must not hide a terminal call receipt or leave
        // the caller unable to finish releasing its original run.
        let imageDirectory = directory.appendingPathComponent("ImageResults", isDirectory: true)
        let cacheFile = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: imageDirectory, includingPropertiesForKeys: nil).first)
        try Data("damaged historical image".utf8).write(to: cacheFile)
        let damagedStatus = try await call("calls.get", key: key, parameters: ["run_id": imageRun, "call_id": imageCall])
        let damagedCall = try XCTUnwrap((try JSONSerialization.jsonObject(with: damagedStatus.body) as? [String: Any])?["result"] as? [String: Any])
        XCTAssertEqual(damagedCall["state"] as? String, "succeeded")
        XCTAssertEqual((damagedCall["result"] as? [String: Any])?["image_status"] as? String, "unavailable")
        let unavailable = try await call("images.get", key: key, parameters: ["run_id": imageRun, "image_id": try XCTUnwrap(receipt["image_id"]), "generation": try XCTUnwrap(receipt["generation"])])
        XCTAssertEqual(((try JSONSerialization.jsonObject(with: unavailable.body) as? [String: Any])?["error"] as? [String: Any])?["code"] as? String, "image_unavailable")
        let lastActivityUptime = uptime
        for gap in [0.0, 30, 42, 84, 89.999] {
            uptime = lastActivityUptime + gap
            XCTAssertTrue(controller.isPeerOnline(client.id), "Normal probe/retry gap \(gap) must not flap offline")
        }
        uptime = lastActivityUptime + MuseCompanionProtocol.peerFreshness
        XCTAssertFalse(controller.isPeerOnline(client.id)) // Real silence still expires.
        _ = try await call("companion.hello", key: Data(repeating: 0, count: 32))
        XCTAssertFalse(controller.isPeerOnline(client.id)) // Invalid traffic cannot renew presence.
        _ = try await call("capabilities", key: key)
        XCTAssertTrue(controller.isPeerOnline(client.id)) // Ordinary authenticated RPC refreshes too.
        XCTAssertEqual(store.settings.clients.count, 1)
        try store.setAuthorization(clientID: client.id, scopes: [], identityConfirmed: true)
        let repeated = try await call("companion.hello", key: key)
        let result = (try JSONSerialization.jsonObject(with: repeated.body) as! [String: Any])["result"] as! [String: Any]
        XCTAssertEqual(result["pairing_state"] as? String, "active")
        XCTAssertEqual(result["state"] as? String, "pending_authorization")
        XCTAssertEqual(result["scopes"] as? [String], []) // Reconnect cannot reopen revoked permissions.
        controller.stop()
        XCTAssertFalse(controller.isPeerOnline(client.id)) // Stop overrides the grace period immediately.
        XCTAssertNotNil(store.key(for: client.id))
        let stopped = try await call("companion.hello", key: key)
        XCTAssertEqual(stopped.status, 401)
        XCTAssertTrue(store.settings.clients[0].scopes.isEmpty)
    }
}

@MainActor final class MuseConnectionLifecycleTests: XCTestCase {
    func testEnableChoiceSurvivesFailedStartupAndRelaunchUntilExplicitOptOut() throws {
        let suite = "actell.muse.failed-start-choice." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let vault = RemoteMemoryVault()
        let model = AgentViewModel(loadPersistentState: false)
        let service = RemoteToolsService(model: model)
        let store = RemoteConnectionStore(vault: vault, defaults: defaults)
        let controller = RemoteConnectionController(service: service, store: store, canConfigure: { false })
        XCTAssertFalse(controller.isEnabled)
        XCTAssertThrowsError(try controller.start()) // Admission rejects before a listener/identity is created.
        XCTAssertTrue(controller.isEnabled)
        XCTAssertTrue(store.serviceEnabled)
        XCTAssertEqual(controller.status, .stopped)
        XCTAssertNotNil(controller.connectionIssue)
        XCTAssertEqual(model.museDiagnostics.events.last?.stage, "service.start.rejected")
        XCTAssertEqual(model.museDiagnostics.events.last?.state["saved_enabled"], "true")

        let reloadedDefaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let reloadedStore = RemoteConnectionStore(vault: vault, defaults: reloadedDefaults)
        let relaunched = RemoteConnectionController(service: RemoteToolsService(model: model), store: reloadedStore,
                                                    canConfigure: { false })
        XCTAssertTrue(relaunched.isEnabled)
        XCTAssertEqual(model.museDiagnostics.events.last?.stage, "service.preference.loaded")
        XCTAssertEqual(model.museDiagnostics.events.last?.state["saved_enabled"], "true")
        relaunched.setScene(active: false, background: true)
        relaunched.setScene(active: true, background: false)
        XCTAssertTrue(relaunched.isEnabled)
        XCTAssertEqual(relaunched.status, .stopped)
        relaunched.stop()
        let afterOff = RemoteConnectionStore(vault: vault, defaults: reloadedDefaults)
        XCTAssertFalse(afterOff.serviceEnabled)
        XCTAssertEqual(model.museDiagnostics.events.last?.stage, "service.preference.disabled")
        XCTAssertTrue(model.museDiagnostics.events.contains { $0.stage == "service.preference.disabled" && $0.state["saved_enabled"] == "false" })
    }

    func testRelaunchRestoresSavedSwitchAfterForegroundUnlockAndIdle() async throws {
        let suite = "actell.muse.restore-test." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let vault = RemoteMemoryVault()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: directory) }
        let firstStore = RemoteConnectionStore(vault: vault, defaults: defaults)
        XCTAssertFalse(firstStore.serviceEnabled) // New installations remain off.
        try firstStore.prepareCompanion()
        let provider = RemoteGeneratedIdentityProvider(namespace: "actell.muse.generated-tls.v1." + firstStore.settings.host)
        defer { try? provider.remove() }
        try firstStore.configure(host: firstStore.settings.host, port: String(UInt16.random(in: 20000...40000)), sources: "127.0.0.1")
        let client = try firstStore.createLANPending(name: "Muse", requestID: UUID().uuidString.lowercased())
        try firstStore.activateLANClient(client.id, name: "Muse")
        try firstStore.setAuthorization(clientID: client.id, scopes: [.screenshot], identityConfirmed: true)
        let originalSettings = firstStore.settings
        let model = AgentViewModel(loadPersistentState: false)
        model.setForeground(true); model.setProtectedDataAvailable(true)
        let firstService = RemoteToolsService(model: model)
        let first = RemoteConnectionController(service: firstService, store: firstStore, journalDirectory: directory)
        defer { first.stop() }
        try first.start()
        XCTAssertTrue(firstStore.serviceEnabled)
        firstService.stop() // Simulate process/runtime loss, not a user toggle.
        XCTAssertTrue(firstStore.serviceEnabled)

        let restoredStore = RemoteConnectionStore(vault: vault, defaults: defaults)
        let restoredModel = AgentViewModel(loadPersistentState: false)
        restoredModel.setForeground(false); restoredModel.setProtectedDataAvailable(false)
        var idle = false
        let restoredService = RemoteToolsService(model: restoredModel)
        let restored = RemoteConnectionController(service: restoredService, store: restoredStore, journalDirectory: directory,
                                                   canConfigure: { restoredModel.remoteCanConfigure && idle })
        defer { restored.stop() }
        XCTAssertTrue(restored.isEnabled)
        XCTAssertFalse(restoredService.isListening) // Initializer does not open a listener.
        restored.setScene(active: false, background: true)
        XCTAssertEqual(restored.status, .stopped)
        restoredModel.setForeground(true)
        restored.setScene(active: true, background: false)
        XCTAssertEqual(restored.status, .stopped) // Still locked and busy.
        restoredModel.setProtectedDataAvailable(true); restored.resumeIfEnabled()
        XCTAssertEqual(restored.status, .stopped) // Still busy.
        idle = true; restored.resumeIfEnabled()
        for _ in 0..<150 where !restoredService.isListening { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(restoredService.isListening)
        XCTAssertNil(restored.pairing.windowDeadline)
        XCTAssertFalse(restoredModel.hasBusySessions)
        XCTAssertEqual(restoredStore.settings.certificate, originalSettings.certificate)
        XCTAssertEqual(restoredStore.settings.clients, originalSettings.clients)
        XCTAssertEqual(restoredStore.key(for: client.id), firstStore.key(for: client.id))
        restored.stop() // A manual OFF must survive the next launch too.
        let offStore = RemoteConnectionStore(vault: vault, defaults: defaults)
        let offService = RemoteToolsService(model: restoredModel)
        let off = RemoteConnectionController(service: offService, store: offStore, journalDirectory: directory)
        defer { off.stop() }
        off.setScene(active: true, background: false)
        XCTAssertFalse(off.isEnabled); XCTAssertEqual(off.status, .stopped)
    }

    func testForegroundRestoresOptInWithoutPairingOrReplayAndManualStopStaysOff() async throws {
        let model = AgentViewModel(loadPersistentState: false)
        model.setForeground(true); model.setProtectedDataAvailable(true)
        let store = RemoteConnectionStore(vault: RemoteMemoryVault(), defaults: nil)
        try store.prepareCompanion()
        let provider = RemoteGeneratedIdentityProvider(namespace: "actell.muse.generated-tls.v1." + store.settings.host)
        let fingerprint = store.settings.certificate?.fingerprint
        // Exercise the real listener, but bind admission to loopback only.
        try store.configure(host: store.settings.host, port: String(UInt16.random(in: 20000...40000)), sources: "127.0.0.1")
        let client = try store.createLANPending(name: "Muse", requestID: UUID().uuidString.lowercased())
        try store.activateLANClient(client.id, name: "Muse")
        try store.setAuthorization(clientID: client.id, scopes: [.screenshot], identityConfirmed: true)
        let key = store.key(for: client.id)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("muse-lifecycle-" + UUID().uuidString)
        var idle = true
        let service = RemoteToolsService(model: model)
        let controller = RemoteConnectionController(service: service, store: store, journalDirectory: directory,
                                                    recoveryDelay: { _ in .milliseconds(40) },
                                                    canConfigure: { model.remoteCanConfigure && idle })
        defer { controller.stop(); try? provider.remove(); try? FileManager.default.removeItem(at: directory) }
        func listening() async throws {
            for _ in 0..<150 where !service.isListening { try await Task.sleep(for: .milliseconds(20)) }
            XCTAssertTrue(service.isListening)
        }
        func background() {
            model.setScene(.background)
            controller.setScene(active: false, background: true)
        }
        func foreground() {
            model.setScene(.active)
            controller.setScene(active: true, background: false)
        }
        foreground()
        XCTAssertFalse(controller.isEnabled); XCTAssertFalse(service.isListening) // Cold start stays dormant.
        try controller.start(); try await listening()
        XCTAssertTrue(controller.isEnabled)
        service.listenerFailed("Synthetic network interruption")
        XCTAssertTrue(controller.isEnabled); XCTAssertNotNil(controller.connectionIssue)
        try await listening() // Same-foreground recovery without a lifecycle or explicit user event.
        XCTAssertNil(controller.connectionIssue)
        XCTAssertNil(controller.pairing.windowDeadline)
        XCTAssertEqual(store.settings.certificate?.fingerprint, fingerprint)
        XCTAssertEqual(store.key(for: client.id), key)
        // A transient failure while locked must not restart until the unlock event.
        model.setProtectedDataAvailable(false); service.listenerFailed("Synthetic network interruption while locked")
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertFalse(service.isListening)
        model.setProtectedDataAvailable(true); controller.resumeIfEnabled(); try await listening()
        service.stop() // Non-network fail-closed stops must not restart automatically.
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertFalse(service.isListening)
        controller.resumeIfEnabled(); try await listening()
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: directory.path)
        service.listenerFailed("Synthetic interruption before journal failure")
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertFalse(service.isListening)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertFalse(service.isListening) // Recovery must stop on a journal failure, even after storage recovers.
        controller.resumeIfEnabled(); try await listening()
        service.listenerFailed("Synthetic interruption before background")
        background()
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertFalse(service.isListening)
        foreground(); try await listening()
        service.listenerFailed("Synthetic interruption before explicit opt-out")
        controller.stop()
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertFalse(controller.isEnabled); XCTAssertFalse(service.isListening)
        try controller.start(); try await listening()
        try controller.pairing.openWindow()
        let request = try JSONSerialization.data(withJSONObject: ["v": 1, "request_id": UUID().uuidString.lowercased(), "device_name": "Pending Muse"])
        XCTAssertEqual(controller.pairing.handle(path: "/v1/pair/request", body: request,
                         headers: ["content-type": "application/json", "authorization": "Bearer " + String(repeating: "A", count: 43)]).status, 202)
        try controller.approvePairing()
        let pending = try XCTUnwrap(store.settings.clients.first { $0.lanPairingState == .pendingAck })
        background()
        XCTAssertTrue(controller.isEnabled); XCTAssertEqual(controller.status, .listening)
        XCTAssertNil(controller.connectionIssue); XCTAssertTrue(service.isListening)
        XCTAssertNil(store.key(for: pending.id)); XCTAssertEqual(store.key(for: client.id), key)
        model.setScene(.inactive); controller.setScene(active: false, background: false)
        XCTAssertTrue(service.isListening) // Inactive also preserves the existing listener.
        foreground(); try await listening()
        XCTAssertTrue(controller.isEnabled); XCTAssertNil(controller.pairing.windowDeadline)
        XCTAssertNil(controller.pairing.pending); XCTAssertFalse(model.hasBusySessions)
        XCTAssertEqual(store.settings.certificate?.fingerprint, fingerprint)
        XCTAssertEqual(store.settings.clients.first?.scopes, [.screenshot])
        // Foreground restoration waits for an idle event instead of starting during another task.
        background(); service.stop(); idle = false; foreground()
        XCTAssertTrue(controller.isEnabled); XCTAssertFalse(service.isListening)
        idle = true; controller.resumeIfEnabled(); try await listening()
        background(); service.stop(); idle = false; foreground()
        controller.stop() // Cancel a deferred restoration explicitly.
        idle = true; controller.resumeIfEnabled()
        XCTAssertFalse(controller.isEnabled); XCTAssertFalse(service.isListening)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertFalse(service.isListening) // Explicit opt-out also cancels scheduled recovery.
        background(); foreground()
        XCTAssertFalse(controller.isEnabled); XCTAssertFalse(service.isListening)
        let relaunched = RemoteConnectionController(service: RemoteToolsService(model: model), store: store,
                                                     journalDirectory: directory)
        relaunched.setScene(active: true, background: false)
        XCTAssertFalse(relaunched.isEnabled); XCTAssertEqual(relaunched.status, .stopped)
    }
}

private actor PerformanceWaitBridge: DeviceBridge {
    private let demo = DemoBridge()
    private(set) var captures = 0
    var delay: Duration = .milliseconds(180)
    func setRemoteDeadline(_ deadline: Date) throws { guard deadline > Date() else { throw AppError.stopped } }
    func screenshot() async throws -> FrameImage {
        captures += 1
        try await Task.sleep(for: delay)
        return try await demo.screenshot()
    }
    func tap(x: Int, y: Int, imageID: String) throws { throw AppError.stopped }
    func drag(fromX: Int, fromY: Int, toX: Int, toY: Int, durationMS: Int, imageID: String) throws { throw AppError.stopped }
    func stop() async { try? await Task.sleep(for: .milliseconds(150)); await demo.stop() }
}

@MainActor private final class PerformanceRPCFixture {
    let bridge = PerformanceWaitBridge()
    let service: RemoteToolsService
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let provider = RemoteGeneratedIdentityProvider(namespace: "actell.tests.performance." + UUID().uuidString)
    let key = Data(repeating: 0x43, count: 32)
    var allowed = true
    let deadline = Int64(Date().addingTimeInterval(20).timeIntervalSince1970 * 1000)
    let operation = String(repeating: "a", count: 64)
    init() throws {
        let bridge = bridge
        let model = AgentViewModel(loadPersistentState: false, backgroundCoordinator: BackgroundExecutionCoordinator.testing(selection: []), makeRemoteBridge: { bridge })
        model.setForeground(true); model.setProtectedDataAvailable(true)
        service = RemoteToolsService(model: model)
        let identity = try provider.provision(host: "actell-performance-test.local")
        service.authorizeRequest = { [weak self] _, _, _ in self?.allowed == true }
        let key = key
        try service.start(configuration: .init(enabled: true, port: UInt16.random(in: 20000...40000), allowedSources: [RemoteSourceAddress(literal: "127.0.0.1")!]), identity: identity.identity, keyLookup: { _ in key }, directory: directory)
    }
    func close() { service.stop(); try? provider.remove(); try? FileManager.default.removeItem(at: directory) }
    func call(_ op: String, _ params: [String: Any] = [:], operation: String? = nil) async throws -> [String: Any] {
        let id = UUID().uuidString.lowercased(), nonce = UUID().uuidString.lowercased(), time = String(Int64(Date().timeIntervalSince1970))
        let body = try JSONSerialization.data(withJSONObject: ["v": 1, "client_id": "client", "request_id": id, "op": op, "params": params])
        let signature = HMAC<SHA256>.authenticationCode(for: RemoteRequestAuthenticator.signingMessage(clientID: "client", requestID: id, time: time, nonce: nonce, body: body), using: SymmetricKey(data: key)).map { String(format: "%02x", $0) }.joined()
        let response = await service.handle(body: body, headers: ["x-actell-time": time, "x-actell-nonce": nonce, "x-actell-signature": signature, "x-actell-operation-id": operation ?? self.operation])
        return try XCTUnwrap(JSONSerialization.jsonObject(with: response.body) as? [String: Any])
    }
    func open() async throws {
        let response = try await call("runs.open", ["run_id": "run", "deadline_ms": deadline, "image_contract": RemoteImageGeometry.contract])
        XCTAssertEqual(response["ok"] as? Bool, true)
    }
    func screenshot(wait: Any? = nil, deadline: Int64? = nil) -> [String: Any] {
        var p: [String: Any] = ["run_id": "run", "call_id": "capture", "deadline_ms": deadline ?? self.deadline, "tool": "screenshot", "arguments": [:]]
        p["wait_ms"] = wait
        return p
    }
    func result(_ response: [String: Any]) throws -> [String: Any] { try XCTUnwrap(response["result"] as? [String: Any]) }
    func error(_ response: [String: Any]) -> String? { (response["error"] as? [String: Any])?["code"] as? String }
}

extension SimpleLANRPCTests {
    func testPerformanceCapabilitiesStrictWaitAndDiagnosticHeaderValidation() async throws {
        let f = try PerformanceRPCFixture(); defer { f.close() }
        let capabilities = try f.result(await f.call("capabilities"))
        let performance = try XCTUnwrap(capabilities["performance"] as? [String: Any])
        XCTAssertEqual(performance["http_keep_alive"] as? Bool, true)
        XCTAssertEqual(performance["tools_call_wait_ms_max"] as? Int, 1500)
        XCTAssertEqual(performance["runs_cancel_wait_ms_max"] as? Int, 500)
        for invalid in ["bad", String(repeating: "A", count: 64), String(repeating: "0", count: 65)] {
            let response = try await f.call("capabilities", operation: invalid)
            XCTAssertEqual(f.error(response), "bad_request")
        }
        try await f.open()
        for invalid: Any in [-1, 1501, 1.5, true, "100", NSNull()] {
            let response = try await f.call("tools.call", f.screenshot(wait: invalid))
            XCTAssertEqual(f.error(response), "bad_request")
        }
        for invalid: Any in [-1, 501, 1.5, true, "100"] {
            let response = try await f.call("runs.cancel", ["run_id": "run", "wait_ms": invalid])
            XCTAssertEqual(f.error(response), "bad_request")
        }
        let run = try f.result(await f.call("runs.get", ["run_id": "run"]))
        XCTAssertEqual(run["state"] as? String, "open")
        let captures = await f.bridge.captures
        XCTAssertEqual(captures, 0, "Invalid waiting options must not enqueue work")
        _ = try await f.call("runs.cancel", ["run_id": "run", "wait_ms": 500])
    }
    func testBoundedWaitReturnsReceiptAndChangingWaitDoesNotResubmit() async throws {
        let f = try PerformanceRPCFixture(); defer { f.close() }
        try await f.open()
        let began = ContinuousClock.now
        let pending = try f.result(await f.call("tools.call", f.screenshot(wait: 10)))
        XCTAssertTrue(["queued", "running"].contains(pending["state"] as? String ?? ""))
        XCTAssertLessThan(began.duration(to: .now), .milliseconds(500))
        let completed = try f.result(await f.call("tools.call", f.screenshot(wait: 1500), operation: String(repeating: "b", count: 64)))
        XCTAssertEqual(completed["state"] as? String, "succeeded")
        let duplicate = try f.result(await f.call("tools.call", f.screenshot()))
        XCTAssertEqual(duplicate["state"] as? String, "succeeded")
        let captures = await f.bridge.captures
        XCTAssertEqual(captures, 1)
        let cancelled = try f.result(await f.call("runs.cancel", ["run_id": "run", "wait_ms": 500]))
        XCTAssertEqual(cancelled["execution_released"] as? Bool, true)
        // Native timing callbacks persist asynchronously with the original call's
        // correlation, even after a second request changes its unsigned hint.
        for _ in 0..<50 where !MuseDiagnosticsLog(directory: f.directory).events.contains(where: { $0.stage == "performance.release" }) { try await Task.sleep(for: .milliseconds(5)) }
        let events = MuseDiagnosticsLog(directory: f.directory).events
        for stage in ["thumbnail_encoding", "cache_write", "result_ready", "release"] {
            let event = try XCTUnwrap(events.first { $0.stage == "performance." + stage })
            XCTAssertEqual(event.state["operation"], f.operation)
            XCTAssertNotNil(event.diagnosticID)
            XCTAssertNotNil(UInt64(event.state["elapsed_ns"] ?? ""))
        }
        XCTAssertFalse(String(describing: events).contains("x-actell-signature"))
    }
    func testLegacyCancelReturnsBeforeReleaseAndLaterGetReconciles() async throws {
        let f = try PerformanceRPCFixture(); defer { f.close() }
        try await f.open()
        let cancelled = try f.result(await f.call("runs.cancel", ["run_id": "run"]))
        XCTAssertEqual(cancelled["execution_released"] as? Bool, false)
        let timedOut = try f.result(await f.call("runs.cancel", ["run_id": "run", "wait_ms": 10]))
        XCTAssertEqual(timedOut["execution_released"] as? Bool, false)
        let released = try f.result(await f.call("runs.cancel", ["run_id": "run", "wait_ms": 500]))
        XCTAssertEqual(released["execution_released"] as? Bool, true)
        let reconciled = try f.result(await f.call("runs.get", ["run_id": "run"]))
        XCTAssertEqual(reconciled["execution_released"] as? Bool, true)
    }
    func testCancelledResponseWaitDoesNotCancelOrReplayAcceptedWork() async throws {
        let f = try PerformanceRPCFixture(); defer { f.close() }
        try await f.open()
        let waiter = Task { try await f.call("tools.call", f.screenshot(wait: 1500)) }
        for _ in 0..<100 {
            if await f.bridge.captures == 1 { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        waiter.cancel()
        _ = try await waiter.value
        try await Task.sleep(for: .milliseconds(300))
        let receipt = try f.result(await f.call("calls.get", ["run_id": "run", "call_id": "capture"]))
        XCTAssertEqual(receipt["state"] as? String, "succeeded")
        let captures = await f.bridge.captures; XCTAssertEqual(captures, 1)
        _ = try await f.call("runs.cancel", ["run_id": "run", "wait_ms": 500])
    }
    func testWaitRechecksPermissionBeforeReturningResult() async throws {
        let f = try PerformanceRPCFixture(); defer { f.close() }
        try await f.open()
        let waiter = Task { try await f.call("tools.call", f.screenshot(wait: 1500)) }
        for _ in 0..<100 {
            if await f.bridge.captures == 1 { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        f.allowed = false
        let response = try await waiter.value
        XCTAssertEqual(f.error(response), "forbidden")
        f.allowed = true
        _ = try await f.call("runs.cancel", ["run_id": "run", "wait_ms": 500])
    }
}

extension SimpleLANRPCTests {
    func testCallWaitCannotExtendRemainingExecutionDeadline() async throws {
        let f = try PerformanceRPCFixture(); defer { f.close() }
        try await f.open()
        let deadline = Int64(Date().addingTimeInterval(0.1).timeIntervalSince1970 * 1000)
        let began = ContinuousClock.now
        let response = try await f.call("tools.call", f.screenshot(wait: 1500, deadline: deadline))
        let receipt = try f.result(response)
        XCTAssertLessThan(began.duration(to: .now), .milliseconds(700))
        XCTAssertNotEqual(receipt["state"] as? String, "succeeded")
        let cancelled = try f.result(await f.call("runs.cancel", ["run_id": "run", "wait_ms": 500]))
        XCTAssertEqual(cancelled["execution_released"] as? Bool, true)
        let captures = await f.bridge.captures; XCTAssertLessThanOrEqual(captures, 1)
    }
}
