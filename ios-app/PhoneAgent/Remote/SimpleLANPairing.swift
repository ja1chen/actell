import CryptoKit
import Foundation
import Observation

/// SLAN/1: MainActor serializes approval, ACK, stop, revoke and deadlines without suspension.
/// Tokens live only as RAM hashes. No secrets exist until the local user approves.
@MainActor @Observable final class SimpleLANPairing {
    struct Pending: Identifiable { let id: String; let name: String; var approved = false }
    private struct Context {
        let id: String
        let name: String
        let tokenHash: Data
        let bodyHash: Data
        var clientID: String?
        var deadline: TimeInterval?
        var lastClaim: TimeInterval?
    }
    private struct Retired { let tokenHash: Data; let rejected: Bool }
    private let store: RemoteConnectionStore
    private let now: () -> TimeInterval
    private let fence: (String) -> Void
    private var context: Context?
    private var retired: [String: Retired] = [:]
    private var attempts = 0
    private var badTokens: [TimeInterval] = []
    private(set) var available = false
    private(set) var windowDeadline: TimeInterval?
    private(set) var pending: Pending?
    private(set) var error: String?
    private(set) var completedName: String?
    var changed: (() -> Void)?
    var diagnostic: ((String, String?, String?, String?) -> Void)?

    init(store: RemoteConnectionStore, now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }, fence: @escaping (String) -> Void = { _ in }) {
        self.store = store; self.now = now; self.fence = fence
    }
    var windowRemaining: Int { max(0, Int(ceil((windowDeadline ?? now()) - now()))) }
    var acceptingRequests: Bool { available && windowRemaining > 0 && attempts < 3 }
    func setAvailable(_ value: Bool) {
        if value && available { return }
        if !value { stop() }
        else { available = true; changed?() }
    }
    func openWindow() throws {
        tick()
        guard available else { throw RemoteSetupError("请先开启 Muse 连接，等待服务运行后重试") }
        guard context?.clientID == nil, retired.count < 256 else { throw RemoteSetupError("请等待当前配对完成，或移除未完成的设备后重试") }
        retire(rejected: false)
        attempts = 0; windowDeadline = now() + 120; error = nil; completedName = nil
        changed?()
    }
    func closeWindow() {
        windowDeadline = nil
        if context?.clientID == nil { retire(rejected: false) }
        changed?()
    }
    func cancelCurrent() {
        do { try store.cancelLANPending(cancel: fence) }
        catch { available = false; self.error = "未完成配对无法清理，请解锁后重新打开执言" }
        retire(rejected: false); closeWindow()
    }
    func stop() {
        if let c = context { diagnostic?("pairing.stopped", c.id, c.clientID, "service_stopped") }
        // Stop admission before touching storage, including on lifecycle-driven stops.
        available = false; windowDeadline = nil
        retire(rejected: false)
        do { try store.cancelLANPending(cancel: fence) }
        catch { self.error = "未完成配对无法清理，请解锁后重新打开执言" }
        changed?()
    }
    func tick() {
        if let deadline = context?.deadline, now() >= deadline {
            diagnostic?("pairing.expired", context?.id, context?.clientID, "ack_timeout")
            do { try store.cancelLANPending(cancel: fence) }
            catch { available = false; self.error = "配对已停止，请解锁后重新打开执言" }
            retire(rejected: false); changed?()
        }
        if let deadline = windowDeadline, now() >= deadline {
            windowDeadline = nil
            if context?.clientID == nil { retire(rejected: false) }
            changed?()
        }
    }
    func approve() throws {
        tick()
        guard available, windowRemaining > 0, var c = context, c.clientID == nil else { throw RemoteSetupError("申请已过期，请重新添加 Muse") }
        let deadline = now() + 300
        do {
            let client = try store.createLANPending(name: c.name, requestID: c.id)
            c.clientID = client.id; c.deadline = deadline; c.lastClaim = nil
            context = c; pending?.approved = true; changed?()
            diagnostic?("pairing.approved", c.id, client.id, nil)
        } catch { available = false; self.error = "无法保存配对，请解锁后重新打开执言"; changed?(); throw error }
    }
    func reject() {
        guard context?.clientID == nil else { return }
        retire(rejected: true); changed?()
    }
    func forget(clientID: String) {
        if context?.clientID == clientID { retire(rejected: false); changed?() }
    }
    private func retire(rejected: Bool) {
        if let c = context { retired[c.id] = Retired(tokenHash: c.tokenHash, rejected: rejected) }
        context = nil; pending = nil
    }
    /// Invoked only after ACTELL1 authentication by the existing RPC service.
    func acknowledge(clientID: String, name: String) throws {
        tick()
        guard available, let client = store.settings.clients.first(where: { $0.id == clientID }) else {
            diagnostic?("pairing.ack.rejected", context?.id, clientID, available ? "client_missing" : "unavailable")
            throw RemoteRPCError("unauthorized", "Pairing is unavailable")
        }
        if client.lanPairingState == .active {
            diagnostic?("pairing.ack.active", nil, clientID, nil)
            return // Lost ACK responses use fresh nonce/request IDs.
        }
        guard client.lanPairingState == .pendingAck, let c = context, c.clientID == clientID,
              let deadline = c.deadline, now() < deadline, c.name == name else {
            let reason = client.lanPairingState != .pendingAck ? "not_pending" :
                context?.clientID != clientID ? "context_missing" :
                context?.name != name ? "name_mismatch" : "expired"
            diagnostic?("pairing.ack.rejected", context?.id, clientID, reason)
            throw RemoteRPCError("unauthorized", "Pairing expired")
        }
        // No await: once admitted before the deadline, finish the atomic Keychain update.
        do { try store.activateLANClient(clientID, name: name) }
        catch {
            diagnostic?("pairing.ack.rejected", c.id, clientID, "storage_failed")
            available = false; self.error = "配对无法保存，请解锁后重新打开执言"; changed?(); throw error
        }
        diagnostic?("pairing.ack.completed", c.id, clientID, nil)
        completedName = name
        retire(rejected: false); changed?()
    }
    static func validName(_ name: String) -> Bool {
        (1...64).contains(name.utf8.count) && !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !name.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
    }
    static func token(_ value: String) -> Data? {
        guard value.utf8.count == 43, value.utf8.allSatisfy({ (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 95 }),
              let data = Data(base64Encoded: value.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/") + "="), data.count == 32,
              base64url(data) == value else { return nil }
        return data
    }
    static func base64url(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
    private static func equal(_ a: Data, _ b: Data) -> Bool {
        guard a.count == 32, b.count == 32 else { return false }
        var delta: UInt8 = 0
        for (x, y) in zip(a, b) { delta |= x ^ y }
        return delta == 0
    }
    private func invalidToken(status: Int = 401) -> RemoteHTTPResponse {
        badTokens.removeAll { now() - $0 >= 2 }
        guard badTokens.count < 8 else { return response(429, error: "rate_limited") }
        badTokens.append(now())
        return response(status, error: status == 409 ? "conflict" : "unauthorized")
    }
    private func response(_ status: Int, error: String) -> RemoteHTTPResponse { response(status, ["v": 1, "error": error]) }
    private func response(_ status: Int, _ object: [String: Any]) -> RemoteHTTPResponse {
        RemoteHTTPResponse(status: status, headers: ["Cache-Control": "no-store"], body: (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data())
    }
    private func waiting(_ id: String, approved: Bool = false) -> RemoteHTTPResponse {
        response(202, ["v": 1, "request_id": id, "state": approved ? "approved" : "pending", "retry_after_s": 2])
    }
    /// Called only for actual RFC1918 Wi-Fi peers by the shared listener.
    func handle(path: String, body: Data, headers: [String: String]) -> RemoteHTTPResponse {
        tick()
        guard available else { return response(503, error: "time_unavailable") }
        guard path == "/v1/pair/request" || path == "/v1/pair/claim", body.count <= 512,
              !body.starts(with: [0xef, 0xbb, 0xbf]),
              headers["content-type"] == "application/json",
              !["cookie", "forwarded", "x-forwarded-for", "via"].contains(where: { headers[$0] != nil }) else { return response(400, error: "invalid_request") }
        let obj: [String: Any]
        do {
            try RemoteStrictJSON.validate(body, maximumDepth: 2, unsignedIntegersOnly: true)
            guard let decoded = try JSONSerialization.jsonObject(with: body) as? [String: Any] else { throw RemoteHTTPFailure.badRequest }
            obj = decoded
        } catch { return response(400, error: "invalid_request") }
        let isRequest = path == "/v1/pair/request"
        guard Set(obj.keys) == (isRequest ? Set(["v", "request_id", "device_name"]) : Set(["v", "request_id"])), obj["v"] as? UInt32 == 1,
              let id = obj["request_id"] as? String, UUID(uuidString: id)?.uuidString.lowercased() == id,
              id[id.index(id.startIndex, offsetBy: 14)] == "4", "89ab".contains(id[id.index(id.startIndex, offsetBy: 19)]) else { return response(400, error: "invalid_request") }
        if isRequest { guard let name = obj["device_name"] as? String, Self.validName(name) else { return response(400, error: "invalid_request") } }
        guard let auth = headers["authorization"], auth.hasPrefix("Bearer "), let token = Self.token(String(auth.dropFirst(7))) else { return invalidToken() }
        let hash = Data(SHA256.hash(data: token)), bodyHash = Data(SHA256.hash(data: body))
        if let old = retired[id] {
            guard Self.equal(hash, old.tokenHash) else { return invalidToken(status: isRequest ? 409 : 401) }
            return response(!isRequest && old.rejected ? 403 : 410, error: !isRequest && old.rejected ? "rejected" : "expired")
        }
        if let c = context, c.id == id {
            guard Self.equal(hash, c.tokenHash) else { return invalidToken(status: isRequest ? 409 : 401) }
            if isRequest {
                guard Self.equal(bodyHash, c.bodyHash) else { return response(409, error: "conflict") }
                return waiting(id, approved: c.clientID != nil)
            }
            if let last = c.lastClaim, now() - last < 2 { return response(429, error: "rate_limited") }
            context?.lastClaim = now()
            guard let clientID = c.clientID else { return waiting(id) }
            guard let secret = store.key(for: clientID), secret.count == 32, let certificate = store.settings.certificate,
                  let deadline = c.deadline else { return response(503, error: "storage_failed") }
            if c.lastClaim == nil { diagnostic?("pairing.claim.prepared", id, clientID, nil) }
            return response(200, ["v": 1, "request_id": id, "state": "approved", "client_id": clientID,
                                  "secret": Self.base64url(secret), "host": store.settings.host, "port": Int(store.settings.port),
                                  "certificate_sha256": certificate.fingerprint, "claim_remaining_s": max(0, Int(ceil(deadline - now())))])
        }
        guard isRequest else { return invalidToken() }
        guard !store.hasLANRequest(id) else { return response(410, error: "expired") }
        guard windowRemaining > 0 else { return response(410, error: "expired") }
        guard context == nil else { return response(409, error: "busy") }
        guard attempts < 3, retired.count < 256 else { return response(429, error: "rate_limited") }
        attempts += 1
        context = Context(id: id, name: obj["device_name"] as! String, tokenHash: hash, bodyHash: bodyHash)
        pending = Pending(id: id, name: obj["device_name"] as! String); changed?()
        diagnostic?("pairing.request.accepted", id, nil, nil)
        return waiting(id)
    }
}
