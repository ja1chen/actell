import CryptoKit
import Network
import XCTest
@testable import PhoneAgent

@MainActor final class SimpleLANPairingTests: XCTestCase {
    private final class Vault: RemoteCredentialVault {
        var data: [String: Data] = [:]
        var failWrite = false
        var failRead = false
        func read(_ account: String) throws -> Data? { if failRead { throw RemoteSetupError("test storage failure") }; return data[account] }
        func write(_ value: Data, account: String) throws { if failWrite { throw RemoteSetupError("test storage failure") }; data[account] = value }
        func remove(_ account: String) throws { data.removeValue(forKey: account) }
    }
    private final class Clock { var value: TimeInterval = 100 }
    private let id = "11111111-1111-4111-8111-111111111111"
    private let token = String(repeating: "A", count: 43) // Public handoff dummy only.
    private var request: Data { Data(#"{"v":1,"request_id":"11111111-1111-4111-8111-111111111111","device_name":"Desk Muse"}"#.utf8) }
    private var claim: Data { Data(#"{"v":1,"request_id":"11111111-1111-4111-8111-111111111111"}"#.utf8) }
    private func settings(_ vault: Vault) throws -> RemoteConnectionStore {
        let suite = "slan.tests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        var s = RemoteConnectionSettings()
        s.host = "actell-test.local"; s.generatedHost = s.host; s.companionMode = true; s.identityKind = "generated"
        s.certificate = .init(name: "Public test identity summary", fingerprint: String(repeating: "0", count: 64), expiresAt: Date().addingTimeInterval(3600))
        defaults.set(try JSONEncoder().encode(s), forKey: "actell.muse.connection.v1")
        return RemoteConnectionStore(vault: vault, defaults: defaults)
    }
    private func headers(_ token: String? = nil) -> [String: String] { ["content-type": "application/json", "authorization": "Bearer " + (token ?? self.token)] }
    private func object(_ response: RemoteHTTPResponse) throws -> [String: Any] { try JSONSerialization.jsonObject(with: response.body) as! [String: Any] }
    private func engine(_ store: RemoteConnectionStore, _ clock: Clock) throws -> SimpleLANPairing {
        let e = SimpleLANPairing(store: store, now: { clock.value }); e.setAvailable(true); try e.openWindow(); return e
    }
    private func submit(_ e: SimpleLANPairing) -> RemoteHTTPResponse { e.handle(path: "/v1/pair/request", body: request, headers: headers()) }
    private func collect(_ e: SimpleLANPairing, token: String? = nil) -> RemoteHTTPResponse { e.handle(path: "/v1/pair/claim", body: claim, headers: headers(token)) }

    func testDiagnosticsDistinguishApprovalClaimAndAuthenticatedAckFailure() throws {
        let store = try settings(Vault()), clock = Clock()
        let pairing = try engine(store, clock)
        var events: [(String, String?, String?, String?)] = []
        pairing.diagnostic = { events.append(($0, $1, $2, $3)) }
        XCTAssertEqual(submit(pairing).status, 202)
        try pairing.approve()
        let client = try XCTUnwrap(store.settings.clients.first)
        XCTAssertEqual(collect(pairing).status, 200)
        XCTAssertFalse(client.identityConfirmed)
        XCTAssertThrowsError(try pairing.acknowledge(clientID: client.id, name: "Wrong name"))
        XCTAssertEqual(events.last?.0, "pairing.ack.rejected")
        XCTAssertEqual(events.last?.3, "name_mismatch")
        XCTAssertFalse(store.settings.clients.first!.identityConfirmed)
        try pairing.acknowledge(clientID: client.id, name: "Desk Muse")
        XCTAssertTrue(store.settings.clients.first!.identityConfirmed)
        XCTAssertEqual(events.map { $0.0 }, ["pairing.request.accepted", "pairing.approved", "pairing.claim.prepared", "pairing.ack.rejected", "pairing.ack.completed"])
        XCTAssertFalse(String(describing: events).contains(token))
        XCTAssertFalse(String(describing: events).contains("Desk Muse"))
    }

    func testActivePeerAcknowledgesWithEnrollmentClosedWithoutChangingAuthorization() throws {
        let store = try settings(Vault()), pairing = try engine(store, Clock())
        let client = try store.createLANPending(name: "Desk Muse", requestID: id)
        try store.activateLANClient(client.id, name: "Desk Muse")
        try store.setAuthorization(clientID: client.id, scopes: [.screenshot], identityConfirmed: true, name: "Living room")
        let registration = store.settings.clients.first, key = store.key(for: client.id)
        pairing.setAvailable(false)
        XCTAssertFalse(pairing.available)
        XCTAssertFalse(pairing.acceptingRequests)
        XCTAssertThrowsError(try pairing.openWindow())
        XCTAssertEqual(submit(pairing).status, 503)
        try pairing.acknowledge(clientID: client.id, name: "Desk Muse")
        XCTAssertEqual(store.settings.clients.first, registration)
        XCTAssertEqual(store.key(for: client.id), key)
        try store.setAuthorization(clientID: client.id, scopes: [], identityConfirmed: true)
        try pairing.acknowledge(clientID: client.id, name: "Desk Muse")
        XCTAssertEqual(store.settings.clients.first?.scopes, [])
        XCTAssertFalse(store.permits(clientID: client.id, op: "capabilities", params: [:]))
        try store.revokeClient(client.id, cancel: { _ in })
        XCTAssertThrowsError(try pairing.acknowledge(clientID: client.id, name: "Desk Muse"))
    }

    func testClosingEnrollmentCannotActivatePendingPeer() throws {
        let store = try settings(Vault()), pairing = try engine(store, Clock())
        XCTAssertEqual(submit(pairing).status, 202)
        try pairing.approve()
        let client = try XCTUnwrap(store.settings.clients.first)
        XCTAssertEqual(client.lanPairingState, .pendingAck)
        pairing.setAvailable(false)
        XCTAssertNil(store.key(for: client.id))
        XCTAssertTrue(store.settings.clients.isEmpty)
        XCTAssertThrowsError(try pairing.acknowledge(clientID: client.id, name: "Desk Muse"))
    }

    func testLocalNameAndScopesPersistTogetherWithoutChangingPairingIdentity() throws {
        let vault = Vault(), store = try settings(vault)
        let client = try store.createLANPending(name: "Desk Muse", requestID: id)
        XCTAssertThrowsError(try store.setAuthorization(clientID: client.id, scopes: [], identityConfirmed: true, name: "Pending"))
        try store.activateLANClient(client.id, name: "Desk Muse")
        let key = store.key(for: client.id)
        try store.setAuthorization(clientID: client.id, scopes: [.screenshot], identityConfirmed: true, name: "  客厅 Muse  ")
        let renamed = try XCTUnwrap(store.settings.clients.first)
        XCTAssertEqual(renamed.name, "客厅 Muse")
        XCTAssertEqual(renamed.requestedDeviceName, "Desk Muse")
        XCTAssertEqual(renamed.id, client.id)
        XCTAssertEqual(store.key(for: client.id), key)
        let pairing = try engine(store, Clock())
        try pairing.acknowledge(clientID: client.id, name: "Desk Muse")
        XCTAssertEqual(store.settings.clients.first?.name, "客厅 Muse")
        let persisted = vault.data
        vault.failWrite = true
        XCTAssertThrowsError(try store.setAuthorization(clientID: client.id, scopes: [.control], identityConfirmed: true, name: "Another name"))
        XCTAssertEqual(vault.data, persisted) // No partial name/scope update.
        vault.failWrite = false
        let restored = RemoteConnectionStore(vault: vault, defaults: nil)
        XCTAssertEqual(restored.settings.clients.first, renamed)
        XCTAssertEqual(restored.key(for: client.id), key)
        for invalid in ["", "  ", "Name\ninside", "Name\u{0000}inside", String(repeating: "名", count: 65)] {
            XCTAssertThrowsError(try restored.setAuthorization(clientID: client.id, scopes: [], identityConfirmed: true, name: invalid))
            XCTAssertEqual(restored.settings.clients.first, renamed)
        }
    }

    func testDummyHashStrictCodecNoSecretBeforeApprovalAndIdempotentClaim() throws {
        XCTAssertEqual(Data(SHA256.hash(data: request)).map { String(format: "%02x", $0) }.joined(), "10fb78b0779f29b6d17a37395de02c967943129bb45a997c053bce0beeb90e77")
        let vault = Vault(), clock = Clock(), store = try settings(vault), e = try engine(store, clock)
        XCTAssertEqual(submit(e).status, 202); XCTAssertTrue(store.settings.clients.isEmpty); XCTAssertTrue(vault.data.isEmpty)
        XCTAssertEqual(collect(e).status, 202)
        try e.approve()
        let approved = try object(collect(e)), client = try XCTUnwrap(approved["client_id"] as? String)
        let txt = RemoteHTTPTransport.companionTXT(identity: store.settings.certificate!.fingerprint, host: store.settings.host, pairing: true)
        XCTAssertEqual(approved["host"] as? String, txt["host"])
        XCTAssertEqual(approved["certificate_sha256"] as? String, txt["identity"])
        XCTAssertEqual(approved["state"] as? String, "approved"); XCTAssertEqual(approved["claim_remaining_s"] as? Int, 300)
        XCTAssertNotNil(SimpleLANPairing.token(approved["secret"] as! String)); XCTAssertNotEqual(approved["secret"] as? String, token)
        XCTAssertEqual(store.settings.clients.first?.lanPairingState, .pendingAck)
        XCTAssertFalse(store.permits(clientID: client, op: "capabilities", params: [:]))
        XCTAssertThrowsError(try store.setAuthorization(clientID: client, scopes: [.control], identityConfirmed: true))
        clock.value += 2
        let repeated = try object(collect(e))
        XCTAssertEqual(repeated["client_id"] as? String, client); XCTAssertEqual(repeated["secret"] as? String, approved["secret"] as? String)
        XCTAssertEqual(repeated["claim_remaining_s"] as? Int, 298)
        XCTAssertNil(try object(submit(e))["secret"])
        try e.acknowledge(clientID: client, name: "Desk Muse")
        XCTAssertTrue(store.settings.clients[0].identityConfirmed); XCTAssertEqual(store.settings.clients[0].scopes, Set(MuseCompanionScope.allCases))
        XCTAssertEqual(collect(e).status, 410); XCTAssertEqual(submit(e).status, 410)
        try e.acknowledge(clientID: client, name: "Desk Muse")
        XCTAssertEqual(store.settings.clients.count, 1)
        e.stop()
        XCTAssertNotNil(store.key(for: client)); XCTAssertTrue(store.settings.clients[0].identityConfirmed)
    }
    func testTokenBodyConflictRateLimitAndNoPendingReplacement() throws {
        let store = try settings(Vault()), clock = Clock(), e = try engine(store, clock)
        XCTAssertEqual(submit(e).status, 202)
        let wrong = SimpleLANPairing.base64url(Data(repeating: 7, count: 32))
        XCTAssertEqual(e.handle(path: "/v1/pair/request", body: request, headers: headers(wrong)).status, 409)
        XCTAssertEqual(collect(e, token: wrong).status, 401)
        let changed = Data(String(decoding: request, as: UTF8.self).replacingOccurrences(of: "Desk Muse", with: "Other Muse").utf8)
        XCTAssertEqual(e.handle(path: "/v1/pair/request", body: changed, headers: headers()).status, 409)
        XCTAssertEqual(e.pending?.name, "Desk Muse")
        for _ in 0..<10 { _ = collect(e, token: wrong) }
        XCTAssertEqual(collect(e, token: wrong).status, 429)
        XCTAssertEqual(e.pending?.id, id)
        XCTAssertEqual(collect(e).status, 202) // Invalid-token throttling does not discard the real request.
        XCTAssertEqual(collect(e).status, 429)
    }
    func testRejectionWindowExpiryAndThreeDistinctRequests() throws {
        let store = try settings(Vault()), clock = Clock(), e = try engine(store, clock)
        _ = submit(e); e.reject()
        XCTAssertEqual(collect(e).status, 403); XCTAssertEqual(submit(e).status, 410)
        for _ in 0..<2 {
            let raw = Data(String(decoding: request, as: UTF8.self).replacingOccurrences(of: id, with: UUID().uuidString.lowercased()).utf8)
            XCTAssertEqual(e.handle(path: "/v1/pair/request", body: raw, headers: headers()).status, 202); e.reject()
        }
        let fresh = Data(String(decoding: request, as: UTF8.self).replacingOccurrences(of: id, with: UUID().uuidString.lowercased()).utf8)
        XCTAssertEqual(e.handle(path: "/v1/pair/request", body: fresh, headers: headers()).status, 429)
        try e.openWindow()
        XCTAssertEqual(e.handle(path: "/v1/pair/request", body: fresh, headers: headers()).status, 202)
        clock.value += 120; e.tick()
        XCTAssertNil(e.pending); XCTAssertFalse(e.acceptingRequests); XCTAssertTrue(store.settings.clients.isEmpty)
    }
    func testApprovalOutlivesWindowButExpiresAt300AndStopRevokesPending() throws {
        let store = try settings(Vault()), clock = Clock(), e = try engine(store, clock)
        _ = submit(e); clock.value += 119; try e.approve()
        let client = try XCTUnwrap(store.settings.clients.first?.id)
        clock.value += 2; e.tick()
        XCTAssertFalse(e.acceptingRequests); XCTAssertEqual(collect(e).status, 200)
        clock.value += 298
        XCTAssertThrowsError(try e.acknowledge(clientID: client, name: "Desk Muse"))
        XCTAssertNil(store.key(for: client)); XCTAssertTrue(store.settings.clients.isEmpty)
        XCTAssertEqual(collect(e).status, 410)
        let other = SimpleLANPairing(store: store, now: { clock.value }); other.setAvailable(true); try other.openWindow()
        _ = submit(other); try other.approve()
        let pending = store.settings.clients[0].id
        other.stop()
        XCTAssertNil(store.key(for: pending)); XCTAssertTrue(store.settings.clients.isEmpty)
        XCTAssertThrowsError(try other.acknowledge(clientID: pending, name: "Desk Muse"))
    }
    func testRestartRevokesPendingButPreservesActiveAndScopesInAuthoritativeVault() throws {
        let vault = Vault(), clock = Clock(), store = try settings(vault), e = try engine(store, clock)
        _ = submit(e); try e.approve(); let client = store.settings.clients[0].id
        let reboot = RemoteConnectionStore(vault: vault, defaults: nil)
        XCTAssertNil(reboot.key(for: client)); XCTAssertTrue(reboot.settings.clients.isEmpty)
        // New process / fresh application IDs after pending cleanup.
        let activeStore = try settings(vault), active = try engine(activeStore, clock)
        _ = submit(active); try active.approve(); let id2 = activeStore.settings.clients[0].id
        try active.acknowledge(clientID: id2, name: "Desk Muse")
        try activeStore.setAuthorization(clientID: id2, scopes: [.screenshot], identityConfirmed: true)
        let reload = RemoteConnectionStore(vault: vault, defaults: nil)
        XCTAssertNotNil(reload.key(for: id2)); XCTAssertEqual(reload.settings.clients[0].scopes, [.screenshot])
        XCTAssertTrue(reload.permits(clientID: id2, op: "images.get", params: [:]))
        XCTAssertFalse(reload.permits(clientID: id2, op: "tools.call", params: ["tool": "tap"]))
        try reload.revokeClient(id2) { _ in }
        XCTAssertNil(RemoteConnectionStore(vault: vault, defaults: nil).key(for: id2))
    }
    func testStorageFailuresCannotDeliverOrActivateAndLegacyHelloCannotBypassPending() throws {
        let vault = Vault(), store = try settings(vault), clock = Clock(), e = try engine(store, clock)
        _ = submit(e); vault.failWrite = true
        XCTAssertThrowsError(try e.approve()); XCTAssertTrue(store.settings.clients.isEmpty)
        XCTAssertNil(try object(collect(e))["secret"])
        let v2 = Vault(), s2 = try settings(v2), e2 = try engine(s2, clock)
        _ = submit(e2); try e2.approve(); let client = s2.settings.clients[0].id
        XCTAssertThrowsError(try s2.recordHello(clientID: client, name: "Desk Muse"))
        v2.failWrite = true
        XCTAssertThrowsError(try e2.acknowledge(clientID: client, name: "Desk Muse"))
        XCTAssertFalse(s2.settings.clients[0].identityConfirmed); XCTAssertNil(s2.key(for: client))
        let locked = RemoteConnectionStore(vault: v2, defaults: nil)
        XCTAssertNotNil(locked.loadError); XCTAssertNil(locked.key(for: client))
    }
    func testStrictJSONTokenAndLANTransportRoutes() throws {
        let store = try settings(Vault()), clock = Clock(), e = try engine(store, clock)
        for raw in [String(decoding: request, as: UTF8.self).replacingOccurrences(of: "\"v\":1", with: "\"v\":1,\"v\":1"), String(decoding: request, as: UTF8.self).replacingOccurrences(of: "\"v\":1", with: "\"v\":1.0"), String(decoding: request, as: UTF8.self).replacingOccurrences(of: "\"v\":1", with: "\"v\":true"), String(decoding: request, as: UTF8.self).replacingOccurrences(of: "\"v\":1", with: "\"v\":1,\"extra\":0"), String(decoding: request, as: UTF8.self).replacingOccurrences(of: "Desk Muse", with: "Desk\\nMuse"), "\u{feff}" + String(decoding: request, as: UTF8.self)] {
            XCTAssertEqual(e.handle(path: "/v1/pair/request", body: Data(raw.utf8), headers: headers()).status, 400)
        }
        XCTAssertEqual(e.handle(path: "/v1/pair/request", body: Data(repeating: 32, count: 513), headers: headers()).status, 400)
        XCTAssertNil(SimpleLANPairing.token(token + "="))
        for ip in ["192.168.0.2", "10.0.0.1", "172.16.1.1"] { XCTAssertTrue(RemoteSourceAddress(literal: ip)!.isRFC1918) }
        for ip in ["127.0.0.1", "169.254.1.1", "8.8.8.8", "fd00::1", "::ffff:192.168.0.2"] { XCTAssertFalse(RemoteSourceAddress(literal: ip)!.isRFC1918) }
        for path in ["/v1/pair/request", "/v1/pair/claim"] {
            let body = path.hasSuffix("request") ? request : claim
            var parser = RemoteHTTPRequestParser()
            let raw = Data("POST \(path) HTTP/1.1\r\nHost: actell-test.local:8765\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\n\r\n".utf8) + body
            XCTAssertEqual(try parser.append(raw)?.path, path)
        }
        XCTAssertEqual(RemoteHTTPTransport.companionTXT(identity: "pin", host: "actell-test.local", pairing: true)["pair"], "1")
        XCTAssertNil(RemoteHTTPTransport.companionTXT(identity: "pin", host: "actell-test.local", pairing: false)["pair"])
        XCTAssertEqual(RemoteHTTPTransport.companionTXT(identity: "pin", host: "actell-test.local", pairing: true)["identity"], "pin")
        for pairing in [false, true] {
            let txt = RemoteHTTPTransport.companionTXT(identity: "pin", host: store.settings.host, pairing: pairing)
            XCTAssertEqual(txt["host"], "actell-test.local")
            XCTAssertEqual(txt["host"], store.settings.host) // Same value returned by claim; never the SRV hostname.
        }
    }
}
