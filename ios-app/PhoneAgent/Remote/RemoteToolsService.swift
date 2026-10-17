import Foundation
import CoreFoundation
import CryptoKit
import Security
import SwiftAgentKit

struct RemoteRPCError: LocalizedError {
    let code: String
    let message: String
    let underlyingDomain: String?
    let underlyingCode: Int?
    init(_ code: String, _ message: String, underlying: Error? = nil) {
        self.code = code; self.message = message
        underlyingDomain = underlying.map { ($0 as NSError).domain }
        underlyingCode = underlying.map { ($0 as NSError).code }
    }
    var errorDescription: String? { message }
}

/// No model is created here. The App owns this service; the controller may start
/// it explicitly or restore a previously saved local opt-in in the unlocked foreground.
@MainActor final class RemoteToolsService {
    enum ConnectionState: Equatable { case stopped, starting, listening, running, stopping }
    private(set) var connectionState = ConnectionState.stopped
    private(set) var listenerFailure: String?
    var connectionStateChanged: (@MainActor (ConnectionState) -> Void)?
    private func publishConnectionState(_ value: ConnectionState) {
        connectionState = value; connectionStateChanged?(value)
    }
    var companionHello: (@MainActor (String, String) throws -> [String: Any])?
    var keyLookupDiagnostic: (@MainActor (String) -> String)?
    var pairingRequest: (@MainActor (String, Data, [String: String]) -> RemoteHTTPResponse)?
    var isListening: Bool { activated && transport?.isListening == true }
    func setPairingWindow(_ enabled: Bool) { transport?.setPairingWindow(enabled && activated) }
    var authorizeRequest: (@MainActor (String, String, [String: Any]) -> Bool)?
    var authenticatedRequest: (@MainActor (String) -> Void)?
    static let toolNames = ["screenshot", "tap", "drag", "home", "list_apps", "launch_app", "type_text", "wait"]
    private struct Run: Codable {
        var clientID: String
        var runID: String
        var deadline: Int64
        var state: String
        var imageContract: String? = nil
        var wire: [String: Any] { ["run_id": runID, "deadline_ms": deadline, "state": state] }
    }
    private struct Call: Codable {
        var clientID: String
        var runID: String
        var callID: String
        var digest: String
        var state: String
        var result: Data?
        var error: String?
        var tool: String? = nil
        var executionDigest: String? = nil
        var wire: [String: Any] {
            var value: [String: Any] = ["run_id": runID, "call_id": callID, "state": state]
            if let result, let object = try? JSONSerialization.jsonObject(with: result, options: [.fragmentsAllowed]) { value["result"] = object }
            if let error { value["error"] = ["code": state, "message": error, "retryable": false] }
            return value
        }
    }
    private struct Journal: Codable {
        var version = 1
        var runs: [String: Run] = [:]
        var calls: [String: Call] = [:]
    }
    private struct Image {
        let clientID: String
        let runID: String
        let generation: Int
        let frame: FrameImage
        let thumbnail: RemoteThumbnail?
    }
    private let model: AgentViewModel
    private var transport: RemoteHTTPTransport?
    private var activated = false
    private var background = false
    private var authenticator: RemoteRequestAuthenticator?
    private var journal = Journal()
    private var journalURL: URL?
    private var healthy = false
    private var diagnostics: MuseDiagnosticsLog?
    private var diagnosticsDirectory: URL?
    private var worker: RemoteToolRuntime?
    private var activeRun: String?
    private var activeCall: String?
    private var execution: Task<Void, Never>?
    private var expiry: Task<Void, Never>?
    private var callExpiry: Task<Void, Never>?
    private var images: [String: Image] = [:]
    private var generation = 0
    private var draining = false

    init(model: AgentViewModel) { self.model = model }

    func recordPairing(_ stage: String, request: String?, client: String?, code: String?) {
        (diagnostics ?? model.museDiagnostics).record(stage, request: request, client: client, code: code,
                                                     state: diagnosticSnapshot)
    }

    func recordPreference(_ stage: String, enabled: Bool, error: Error? = nil) {
        var state = model.remoteAdmissionSnapshot
        state["saved_enabled"] = String(enabled)
        state["app_version"] = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
        state["app_build"] = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"
        if let error {
            let native = error as NSError
            state["underlying_domain"] = native.domain
            state["underlying_code"] = String(native.code)
        }
        (diagnostics ?? model.museDiagnostics).record(stage, state: state)
    }

    /// Call only from an explicit local setup flow after the user has approved
    /// the client, source IPs, TLS identity and screenshot/app-list disclosure.
    /// The controller may also restore a saved user opt-in after foreground/unlock checks.
    /// Environment variables, launch flags and bundled keys do not enable production service.
    func start(configuration: RemoteHTTPTransport.Configuration, identity: SecIdentity,
               keyLookup: @escaping @MainActor (String) -> Data?, directory: URL? = nil) throws {
        guard !background, model.remoteCanConfigure else { throw RemoteRPCError("not_foreground", "Local activation requires the unlocked foreground app") }
        guard transport == nil, !draining else { throw RemoteRPCError("busy", "Remote service is already active or draining") }
        guard configuration.enabled else { throw RemoteRPCError("disabled", "Remote service is disabled") }
        let logDirectory = directory ?? MuseDiagnosticsLog.defaultDirectory
        if diagnostics == nil || diagnosticsDirectory != logDirectory {
            diagnostics = directory == nil ? model.museDiagnostics : MuseDiagnosticsLog(directory: logDirectory)
            diagnosticsDirectory = logDirectory
        }
        // Export the live instance, including events which could not be persisted.
        // Keep it across listener restarts so a failed write cannot erase evidence.
        model.museDiagnostics = diagnostics!
        diagnostics?.record("service.start", state: model.remoteAdmissionSnapshot)
        try loadJournal(directory: directory)
        if let authenticator { authenticator.replaceKeyLookup(keyLookup) }
        else { authenticator = RemoteRequestAuthenticator(keyLookup: keyLookup) }
        listenerFailure = nil
        let listener = RemoteHTTPTransport(configuration: configuration, onStateChange: { [weak self] listening in
            if listening { self?.publishConnectionState(.listening) }
            else if self?.activated == true { self?.stop() }
        }, onFailure: { [weak self] reason in self?.listenerFailed(reason) }, pairingHandler: { [weak self] path, body, headers, _ in
            guard let self, self.activated, self.isListening, let pairingRequest = self.pairingRequest else {
                return RemoteHTTPResponse(status: 503, body: Data("{\"v\":1,\"error\":\"time_unavailable\"}".utf8))
            }
            return pairingRequest(path, body, headers)
        }, diagnostic: { [weak self] stage, fields in
            guard let self else { return }
            self.diagnostics?.record(stage, state: self.diagnosticSnapshot.merging(fields, uniquingKeysWith: { _, new in new }))
        }) { [weak self] body, headers, _ in
            guard let self else { throw RemoteRPCError("disabled", "Remote service is unavailable") }
            return await self.handle(body: body, headers: headers)
        }
        try listener.start(identity: identity)
        transport = listener; activated = true; publishConnectionState(.starting)
    }
    /// Keep the listener across scene changes. Execution eligibility is enforced
    /// separately by the run lifecycle; backgrounding does not revoke connectivity.
    func setBackground(_ value: Bool) {
        background = value
        diagnostics?.record(value ? "scene.background" : "scene.foreground", state: model.remoteAdmissionSnapshot)
    }
    func stop() {
        diagnostics?.record("service.stop", state: diagnosticSnapshot)
        activated = false
        // Fence the journal and coordinator first; only then close the listener.
        if let id = activeRun { closeRun(id, state: "cancelled") }
        transport?.stop(); transport = nil
        images.removeAll(); publishConnectionState(draining ? .stopping : .stopped)
    }
    func listenerFailed(_ reason: String) {
        listenerFailure = reason
        stop()
    }
    /// Explicit revocation also fences an already authenticated in-flight call.
    /// The UI must revoke/remove the key in its store before invoking this hook.
    func revoke(clientID: String) {
        if let id = activeRun, journal.runs[id]?.clientID == clientID { closeRun(id, state: "cancelled") }
    }
    private func loadJournal(directory: URL?) throws {
        let base = try directory ?? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true).appendingPathComponent("PhoneAgent/Remote", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        var excluded = base; var values = URLResourceValues(); values.isExcludedFromBackup = true
        try excluded.setResourceValues(values)
        let url = base.appendingPathComponent("accepted-tools-v1.json")
        let exists = FileManager.default.fileExists(atPath: url.path)
        let loaded = exists ? try JSONDecoder().decode(Journal.self, from: Data(contentsOf: url)) : Journal()
        guard loaded.version == 1, loaded.runs.count <= 10_000, loaded.calls.count <= 10_000 else { throw RemoteRPCError("journal_invalid", "Journal requires local reconciliation") }
        journal = loaded; journalURL = url
        for id in Array(journal.runs.keys) where journal.runs[id]?.state == "open" { journal.runs[id]?.state = "cancelled" }
        for id in Array(journal.calls.keys) where ["queued", "running", "pending_approval"].contains(journal.calls[id]?.state ?? "") {
            journal.calls[id]?.state = "unknown"
            journal.calls[id]?.error = "App restarted before a confirmed terminal result; never replay this action"
        }
        healthy = true
        try persist() // Fail closed on corrupt, unreadable or unwritable journals.
    }
    private func persist() throws {
        guard healthy, let url = journalURL else { throw RemoteRPCError("journal_unavailable", "Durable journal is unavailable") }
        do { try JSONEncoder().encode(journal).write(to: url, options: [.atomic, .completeFileProtection]) }
        catch {
            healthy = false
            // In-memory close is immediate even if protected storage has vanished.
            if let id = activeRun { journal.runs[id]?.state = "cancelled" }
            execution?.cancel(); worker?.stop(message: String(localized: "Remote task records could not be saved. The task stopped. Check the device."), interrupted: true)
            throw RemoteRPCError("journal_unavailable", "Durable journal failed; execution fenced", underlying: error)
        }
    }
    private func nowMS() -> Int64 { Int64(Date().timeIntervalSince1970 * 1000) }
    private func identifier(_ value: Any?) throws -> String {
        guard let s = value as? String, (1...128).contains(s.utf8.count), s.utf8.allSatisfy({ (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 95 }) else {
            throw RemoteRPCError("bad_request", "Invalid identifier")
        }
        return s
    }
    private func integer(_ value: Any?) throws -> Int64 {
        guard let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(), n.doubleValue.isFinite,
              n.doubleValue.rounded() == n.doubleValue, abs(n.doubleValue) < 9_007_199_254_740_991 else { throw RemoteRPCError("bad_request", "Integer required") }
        return n.int64Value
    }
    private func ownedRun(_ p: [String: Any], client: String) throws -> Run {
        let id = try identifier(p["run_id"])
        guard let run = journal.runs[id] else { throw RemoteRPCError("not_found", "Run not found") }
        guard run.clientID == client else { throw RemoteRPCError("forbidden", "Run belongs to another client") }
        if run.state == "open", nowMS() >= run.deadline { closeRun(id, state: "expired") }
        return journal.runs[id]!
    }
    private func callKey(client: String, run: String, call: String) -> String { client + "/" + run + "/" + call }
    private func json(_ object: Any) throws -> Data { try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .fragmentsAllowed]) }
    private func reply(_ id: String, result: [String: Any]) throws -> RemoteHTTPResponse {
        RemoteHTTPResponse(body: try json(["v": 1, "request_id": id, "ok": true, "result": result]))
    }
    private func failure(_ id: String, _ error: RemoteRPCError, status: Int = 200) -> RemoteHTTPResponse {
        let data = (try? json(["v": 1, "request_id": id, "ok": false, "error": ["code": error.code, "message": error.message, "retryable": false]])) ?? Data()
        return RemoteHTTPResponse(status: status, body: data)
    }
    private var diagnosticSnapshot: [String: String] {
        model.remoteAdmissionSnapshot.merging([
            "service_background": String(background), "service_active": String(activated),
            "journal_healthy": String(healthy), "active_run": String(activeRun != nil),
            "draining": String(draining), "active_call": String(activeCall != nil)
        ], uniquingKeysWith: { _, new in new })
    }
    func handle(body: Data, headers: [String: String]) async -> RemoteHTTPResponse {
        guard activated else { return failure("", RemoteRPCError("unauthorized", "Service is disabled"), status: 401) }
        var requestID = ""
        var authenticated = false
        var admissionClient: String?
        var admissionRun: String?
        var traceOperation: String?
        var traceCall: String?
        var unverifiedClient: String?
        func trace(_ stage: String, code: String? = nil, extra: [String: String] = [:]) {
            guard let traceOperation else { return }
            var state = diagnosticSnapshot.merging(extra, uniquingKeysWith: { _, new in new })
            state["connection"] = RemoteHTTPTrace.connectionID
            state["call"] = traceCall.map(MuseDiagnosticsLog.tag)
            diagnostics?.record(traceOperation + "." + stage, request: requestID, client: admissionClient,
                                run: admissionRun, code: code, state: state)
        }
        do {
            try RemoteStrictJSON.validate(body)
            guard let envelope = try JSONSerialization.jsonObject(with: body) as? [String: Any],
                  Set(envelope.keys) == Set(["v", "client_id", "request_id", "op", "params"]),
                  try integer(envelope["v"]) == 1,
                  let op = envelope["op"] as? String, let params = envelope["params"] as? [String: Any] else { throw RemoteRPCError("bad_request", "Invalid RPC envelope") }
            let client = try identifier(envelope["client_id"])
            unverifiedClient = client
            requestID = try identifier(envelope["request_id"])
            guard let authenticator else { throw RemoteRPCError("unauthorized", "Service is disabled") }
            try authenticator.verify(clientID: client, requestID: requestID, headers: headers, body: body)
            guard activated else { throw RemoteRPCError("unauthorized", "Service stopped during authentication") }
            authenticated = true
            let traced = ["companion.hello", "capabilities", "runs.open", "runs.get", "runs.cancel", "calls.get", "tools.call", "images.get"]
            traceOperation = traced.contains(op) ? op : "unknown"
            admissionClient = client
            admissionRun = try? identifier(params["run_id"])
            traceCall = try? identifier(params["call_id"])
            trace("received")
            if op == "companion.hello" {
                guard Set(params.keys) == Set(["device_name", "protocol"]),
                      let name = params["device_name"] as? String, (1...64).contains(name.utf8.count),
                      !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      try integer(params["protocol"]) == 1, let companionHello else {
                    throw RemoteRPCError("bad_request", "Invalid companion hello")
                }
                let result = try companionHello(client, name)
                trace("result", code: result["state"] as? String)
                return try reply(requestID, result: result)
            }
            guard authorizeRequest?(client, op, params) ?? false else { throw RemoteRPCError("forbidden", "Client scope does not permit this operation") }
            authenticatedRequest?(client)
            if op == "images.get" {
                let response = try imageResponse(params, client: client, requestID: requestID)
                trace("result")
                return response
            }
            let result = try operation(op, params, client: client)
            trace("result", code: result["state"] as? String)
            return try reply(requestID, result: result)
        } catch let error as RemoteRPCError {
            if admissionClient != nil {
                var fields: [String: String] = [:]
                fields["underlying_domain"] = error.underlyingDomain
                fields["underlying_code"] = error.underlyingCode.map(String.init)
                trace("rejected", code: error.code, extra: fields)
                return failure(requestID, RemoteRPCError(error.code, String(localized: "\(error.message) (Diagnostic ID: \(MuseDiagnosticsLog.tag(requestID)))")))
            }
            return failure(requestID, error, status: authenticated ? 200 : (error.code == "unauthorized" ? 401 : 400))
        }
        catch let error as RemoteRequestAuthenticator.Failure {
            let reason = authenticator?.rejectionReason
            var state = diagnosticSnapshot
            state["authenticated"] = "false"
            state["connection"] = RemoteHTTPTrace.connectionID
            if reason == .key_unavailable, let unverifiedClient {
                state["key_state"] = keyLookupDiagnostic?(unverifiedClient) ?? "not_reported"
            }
            // Unverified input is never recorded as an authenticated RPC/hello.
            // Correlation IDs are hashed by the logger; no headers/body are retained.
            diagnostics?.record("rpc.authentication.rejected", request: requestID, client: unverifiedClient,
                                code: reason?.rawValue ?? "unknown", state: state)
            return failure(requestID, RemoteRPCError(error == .replayed ? "replay" : "unauthorized", "Authentication failed"), status: 401)
        }
        catch {
            if admissionClient != nil {
                let native = error as NSError
                trace("failed", code: "internal_error", extra: ["underlying_domain": native.domain, "underlying_code": String(native.code)])
            }
            return failure(requestID, RemoteRPCError(authenticated ? "internal_error" : "bad_request", authenticated ? "Request failed safely; query status before any further action" + (admissionClient == nil ? "" : " (Diagnostic ID: " + MuseDiagnosticsLog.tag(requestID) + ")") : "Invalid JSON envelope"), status: authenticated ? 200 : 400) }
    }
    private func operation(_ op: String, _ p: [String: Any], client: String) throws -> [String: Any] {
        guard healthy else { throw RemoteRPCError("journal_unavailable", "Writes disabled; local reconciliation required") }
        switch op {
        case "capabilities":
            guard p.isEmpty else { throw RemoteRPCError("bad_request", "Unexpected capability parameters") }
            // DeviceTool schemas do not depend on its coordinator. Avoid constructing
            // a dummy bridge/coordinator by exposing the exact shared schema below.
            return ["tools": RemoteToolSchema.capabilities, "transport": "https", "approval": "paired-device-scopes", "image_encoding": "binary", "routes": ["ncmDeveloper", "localDevVPN"], "background": "existing-delivered-lease-required", "input_approval": "not-required", "max_image_bytes": 8 * 1024 * 1024, "image_contracts": ["original-v1", RemoteImageGeometry.contract], "thumbnail_max_dimension": RemoteImageGeometry.maxDimension, "thumbnail_max_bytes": RemoteImageGeometry.maxBytes]
        case "runs.open":
            guard Set(p.keys).isSubset(of: Set(["run_id", "deadline_ms", "image_contract"])) else { throw RemoteRPCError("bad_request", "Invalid run parameters") }
            let id = try identifier(p["run_id"]), deadline = try integer(p["deadline_ms"])
            let contract = p["image_contract"] as? String ?? "original-v1"
            guard ["original-v1", RemoteImageGeometry.contract].contains(contract),
                  p["image_contract"] == nil || p["image_contract"] is String else { throw RemoteRPCError("bad_request", "Unsupported image contract") }
            if let existing = journal.runs[id] {
                guard existing.clientID == client else { throw RemoteRPCError("forbidden", "Run belongs to another client") }
                guard existing.deadline == deadline, (existing.imageContract ?? "original-v1") == contract else { throw RemoteRPCError("idempotency_conflict", "Run ID has a different deadline") }
                return try ownedRun(p, client: client).wire
            }
            guard deadline > nowMS(), deadline <= nowMS() + 3_600_000 else { throw RemoteRPCError("deadline_exceeded", "Run deadline must be future and within one hour") }
            guard activeRun == nil, !draining else { throw RemoteRPCError("device_busy", "Another run is active or draining") }
            guard journal.runs.count < 10_000 else { throw RemoteRPCError("journal_full", "Accepted IDs are retained; local archive procedure required") }
            journal.runs[id] = Run(clientID: client, runID: id, deadline: deadline, state: "open", imageContract: contract)
            try persist()
            activeRun = id; generation = 0; images.removeAll()
            do {
                worker = try model.acquireRemoteRun(id, onImage: { [weak self] frame in self?.captured(frame) }, onStop: { [weak self] in self?.externallyStopped() })
            } catch {
                journal.runs[id]?.state = "cancelled"; activeRun = nil; try persist()
                if let failure = error as? RemoteRPCError { throw failure }
                throw RemoteRPCError("device_unavailable", error.localizedDescription)
            }
            publishConnectionState(.running)
            expiry = Task { [weak self] in
                let delay = max(1, deadline - (self?.nowMS() ?? deadline))
                do { try await Task.sleep(nanoseconds: UInt64(delay) * 1_000_000) } catch { return }
                self?.closeRun(id, state: "expired")
            }
            return journal.runs[id]!.wire
        case "runs.get": return try ownedRun(p, client: client).wire
        case "runs.cancel":
            let run = try ownedRun(p, client: client)
            if run.state == "open" { closeRun(run.runID, state: "cancelled") }
            return journal.runs[run.runID]!.wire
        case "calls.get":
            let run = try ownedRun(p, client: client), id = try identifier(p["call_id"])
            guard let call = journal.calls[callKey(client: client, run: run.runID, call: id)] else { throw RemoteRPCError("not_found", "Call not found; absence is not proof of nonexecution") }
            guard call.clientID == client, call.runID == run.runID else { throw RemoteRPCError("forbidden", "Call ownership mismatch") }
            guard authorizeRequest?(client, "tools.call", ["tool": call.tool ?? "unknown"]) ?? true else { throw RemoteRPCError("forbidden", "Client scope no longer permits this result") }
            return call.wire
        case "tools.call": return try acceptCall(p, client: client)
        default: throw RemoteRPCError("bad_request", "Unknown operation")
        }
    }
    private func acceptCall(_ p: [String: Any], client: String) throws -> [String: Any] {
        let allowed = Set(["run_id", "call_id", "deadline_ms", "tool", "arguments", "observation"])
        guard Set(p.keys).isSubset(of: allowed), let name = p["tool"] as? String,
              Self.toolNames.contains(name), let args = p["arguments"] as? [String: Any] else { throw RemoteRPCError("tool_not_allowed", "Invalid or unavailable tool") }
        let schema = DeviceTool.parameters(for: name)
        guard Set(args.keys).isSubset(of: Set(schema.properties.keys)), Set(schema.required).isSubset(of: Set(args.keys)) else {
            throw RemoteRPCError("bad_request", "Tool arguments do not match the advertised schema")
        }
        let run = try ownedRun(p, client: client), id = try identifier(p["call_id"])
        let key = callKey(client: client, run: run.runID, call: id)
        let digest = SHA256.hash(data: try json(p)).map { String(format: "%02x", $0) }.joined()
        if let existing = journal.calls[key] {
            guard existing.clientID == client, existing.runID == run.runID else { throw RemoteRPCError("forbidden", "Call ownership mismatch") }
            guard existing.digest == digest else { throw RemoteRPCError("idempotency_conflict", "Call ID has different arguments") }
            return existing.wire
        }
        guard run.state == "open", activeRun == run.runID, !draining else { throw RemoteRPCError("run_closed", "Run is closed") }
        guard activeCall == nil else { throw RemoteRPCError("device_busy", "One call is already executing; poll it first") }
        let deadline = try integer(p["deadline_ms"])
        guard deadline > nowMS(), deadline <= run.deadline else { throw RemoteRPCError("deadline_exceeded", "Call deadline is invalid") }
        var imageID: String?
        var executionArguments = args
        if name == "tap" || name == "drag" {
            guard let observation = p["observation"] as? [String: Any], Set(observation.keys) == Set(run.imageContract == RemoteImageGeometry.contract ? ["image_id", "generation", "geometry_revision"] : ["image_id", "generation"]) else { throw RemoteRPCError("stale_observation", "Coordinate tool requires an observation") }
            imageID = try identifier(observation["image_id"])
            let imageGeneration = try integer(observation["generation"])
            guard let image = images[imageID!], image.clientID == client, image.runID == run.runID,
                  image.generation == generation, Int64(image.generation) == imageGeneration else { throw RemoteRPCError("stale_observation", "Screenshot is no longer the current observation") }
            if run.imageContract == RemoteImageGeometry.contract {
                guard Date().timeIntervalSince(image.frame.capturedAt) < RemoteImageGeometry.maxAge,
                      let geometry = image.thumbnail?.geometry,
                      observation["geometry_revision"] as? String == geometry.revision else {
                    throw RemoteRPCError("stale_observation", "Geometry revision does not match this image")
                }
                let pairs = name == "tap" ? [("x", "y")] : [("from_x", "from_y"), ("to_x", "to_y")]
                for (xKey, yKey) in pairs {
                    let point = try geometry.originalPoint(x: Int(integer(args[xKey])), y: Int(integer(args[yKey])))
                    executionArguments[xKey] = point.x; executionArguments[yKey] = point.y
                }
                // Bound into both the app approval digest and lifecycle argument digest.
                executionArguments["_remote_geometry"] = geometry.wire
                executionArguments["_remote_image_id"] = image.frame.id
            }
        }
        guard journal.calls.count < 10_000 else { throw RemoteRPCError("journal_full", "Accepted IDs cannot be discarded automatically") }
        journal.calls[key] = Call(clientID: client, runID: run.runID, callID: id, digest: digest, state: "queued", tool: name, executionDigest: SHA256.hash(data: try json(executionArguments)).map { String(format: "%02x", $0) }.joined())
        try persist() // Accepted identity and payload hash are durable BEFORE enqueue.
        activeCall = key
        execution = Task { [weak self] in
            guard let self else { return }
            await self.execute(id: key, name: name, arguments: executionArguments, imageID: imageID, deadline: deadline)
        }
        callExpiry = Task { [weak self] in
            let delay = max(1, deadline - (self?.nowMS() ?? deadline))
            do { try await Task.sleep(nanoseconds: UInt64(delay) * 1_000_000) } catch { return }
            guard let self, self.activeCall == key else { return }
            // Resolves the existing app approval continuation as false and blocks
            // new calls BEFORE stopping transport; no approved late dispatch.
            self.closeRun(run.runID, state: "expired")
        }
        return journal.calls[key]!.wire
    }
    private func execute(id: String, name: String, arguments: [String: Any], imageID: String?, deadline: Int64) async {
        guard let worker, let run = activeRun, journal.runs[run]?.state == "open", !Task.isCancelled else { return }
        guard let callID = journal.calls[id]?.callID else { return }
        journal.calls[id]?.state = "running"
        var stopped = false
        do {
            try persist()
            let finalDigest = SHA256.hash(data: try json(arguments)).map { String(format: "%02x", $0) }.joined()
            guard journal.calls[id]?.executionDigest == finalDigest else { throw RemoteRPCError("idempotency_conflict", "Resolved action changed before execution") }
            if let imageID {
                guard let image = images[imageID], image.generation == generation, image.runID == run,
                      image.clientID == journal.calls[id]?.clientID else { throw RemoteRPCError("stale_observation", "Observation expired before execution") }
            }
            let result = try await worker.executeRemoteTool(name: name, arguments: arguments, callID: callID,
                imageID: imageID, deadline: Date(timeIntervalSince1970: Double(deadline) / 1000))
            let delivery = worker.remoteDelivery(callID)
            // Closing a run already froze a conservative terminal result. Never
            // upgrade unknown/cancelled from late callbacks or resurrect a run.
            if journal.calls[id]?.state == "running" {
                if delivery == .outcomeUnknown || delivery == .dispatching { journal.calls[id]?.state = "unknown" }
                else { journal.calls[id]?.state = result.isError ? "failed" : "succeeded" }
                if name == "screenshot", !result.isError {
                    let metadata = (try? JSONSerialization.jsonObject(with: Data(result.result.utf8))) as? [String: Any]
                    if let imageID = metadata?["image_id"] as? String, let image = images[imageID],
                       image.generation == generation, image.runID == run {
                        var receipt: [String: Any] = ["image_id": image.frame.id, "generation": image.generation, "width": image.frame.width, "height": image.frame.height]
                        if let thumbnail = image.thumbnail {
                            receipt["width"] = thumbnail.geometry.deliveredWidth; receipt["height"] = thumbnail.geometry.deliveredHeight
                            receipt["geometry"] = thumbnail.geometry.wire
                            receipt["image_contract"] = RemoteImageGeometry.contract
                            receipt["expires_at_ms"] = Int64(image.frame.capturedAt.addingTimeInterval(RemoteImageGeometry.maxAge).timeIntervalSince1970 * 1000)
                            receipt["mime_type"] = "image/jpeg"; receipt["byte_count"] = thumbnail.data.count
                        }
                        journal.calls[id]?.result = try json(receipt)
                    } else {
                        journal.calls[id]?.state = "failed"
                        journal.calls[id]?.error = "The captured image was unavailable; obtain a new screenshot"
                    }
                } else { journal.calls[id]?.result = try json(["text": result.result]) }
                if result.isError { journal.calls[id]?.error = result.result }
            }
        } catch {
            stopped = true
            if journal.calls[id]?.state == "running" {
                let delivery = worker.remoteDelivery(callID)
                journal.calls[id]?.state = (delivery == .dispatching || delivery == .outcomeUnknown) ? "unknown" : (nowMS() >= deadline ? "expired" : "cancelled")
                journal.calls[id]?.error = "Call stopped; inspect lifecycle before planning any further action"
            }
        }
        if ["tap", "drag", "home", "launch_app", "type_text"].contains(name) {
            generation += 1 // Conservative invalidation even on denial or uncertain result.
        }
        if healthy { try? persist() }
        if activeCall == id { callExpiry?.cancel(); callExpiry = nil; activeCall = nil; execution = nil }
        if stopped, activeRun == run, !draining { closeRun(run, state: "cancelled") }
    }
    private func captured(_ frame: FrameImage) {
        images.removeAll() // Never associate a new capture with an older image.
        guard let runID = activeRun, journal.runs[runID]?.state == "open", let client = journal.runs[runID]?.clientID,
              frame.png.count <= 8 * 1024 * 1024, ["image/png", "image/jpeg"].contains(frame.mimeType) else { return }
        let thumbnail: RemoteThumbnail?
        if journal.runs[runID]?.imageContract == RemoteImageGeometry.contract {
            guard let encoded = try? RemoteThumbnail.make(frame: frame) else { return }
            thumbnail = encoded
        } else { thumbnail = nil }
        generation += 1
        images.removeAll() // Single retained in-memory image bounds memory and disclosure.
        images[frame.id] = Image(clientID: client, runID: runID, generation: generation, frame: frame, thumbnail: thumbnail)
    }
    private func imageResponse(_ p: [String: Any], client: String, requestID: String) throws -> RemoteHTTPResponse {
        let run = try ownedRun(p, client: client), id = try identifier(p["image_id"])
        let gen = try integer(p["generation"])
        guard run.state == "open", let image = images[id], image.generation == generation, image.clientID == client, image.runID == run.runID, Int64(image.generation) == gen else { throw RemoteRPCError("not_found", "Image unavailable or expired") }
        let frame = image.frame
        guard image.thumbnail == nil || Date().timeIntervalSince(frame.capturedAt) < RemoteImageGeometry.maxAge else { throw RemoteRPCError("stale_observation", "Screenshot expired; capture another image") }
        let data = image.thumbnail?.data ?? frame.png
        var headers = ["Content-Type": image.thumbnail == nil ? frame.mimeType : "image/jpeg", "X-Actell-Image-Id": id,
            "X-Actell-Generation": String(gen), "X-Actell-Width": String(image.thumbnail?.geometry.deliveredWidth ?? frame.width), "X-Actell-Height": String(image.thumbnail?.geometry.deliveredHeight ?? frame.height),
            "X-Actell-Request-Id": requestID, "X-Actell-SHA256": SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()]
        if let geometry = image.thumbnail?.geometry {
            headers["X-Actell-Geometry-Revision"] = geometry.revision
            headers["X-Actell-Image-Contract"] = RemoteImageGeometry.contract
        }
        return RemoteHTTPResponse(headers: headers, body: data)
    }
    private func externallyStopped() {
        guard let id = activeRun, !draining else { return }
        closeRun(id, state: "cancelled", stopWorker: false)
    }
    private func closeRun(_ id: String, state: String, stopWorker: Bool = true) {
        guard activeRun == id, !draining else { return }
        draining = true; journal.runs[id]?.state = state
        if let callID = activeCall, ["queued", "running", "pending_approval"].contains(journal.calls[callID]?.state ?? "") {
            let delivery = journal.calls[callID].flatMap { worker?.remoteDelivery($0.callID) }
            journal.calls[callID]?.state = (delivery.map { [RunCheckpoint.Delivery.dispatching, .outcomeUnknown, .acknowledged, .observedResult].contains($0) } ?? false) ? "unknown" : (state == "expired" ? "expired" : "cancelled")
            journal.calls[callID]?.error = "Run closed; dispatched actions cannot be rolled back"
        }
        if healthy { try? persist() }
        expiry?.cancel(); expiry = nil; callExpiry?.cancel(); callExpiry = nil
        execution?.cancel()
        let oldWorker = worker, oldExecution = execution
        if stopWorker { oldWorker?.stop(message: String(localized: "Muse task stopped. Check the device for actions already sent.")) }
        images.removeAll()
        Task { [weak self] in
            await oldExecution?.value
            await oldWorker?.waitForRemoteRelease()
            guard let self else { return }
            self.model.releaseRemoteRun(id)
            self.worker = nil; self.activeRun = nil; self.activeCall = nil; self.execution = nil; self.draining = false
            self.publishConnectionState(self.activated ? .listening : .stopped)
        }
    }
}
