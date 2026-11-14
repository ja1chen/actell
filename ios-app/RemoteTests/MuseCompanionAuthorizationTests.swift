import XCTest
@testable import PhoneAgent

@MainActor final class MuseCompanionAuthorizationTests: XCTestCase {
    func testEveryCapabilityDefaultsOffAndUnknownOperationsFailClosed() {
        for op in ["capabilities", "runs.open", "images.get", "tools.call", "calls.get"] {
            XCTAssertFalse(MuseCompanionAuthorization.permits(op: op, params: ["tool": "screenshot"], scopes: []))
        }
        XCTAssertFalse(MuseCompanionAuthorization.permits(op: "official.setup", params: [:], scopes: Set(MuseCompanionScope.allCases)))
        XCTAssertFalse(MuseCompanionAuthorization.permits(op: "tools.call", params: ["tool": "unknown"], scopes: Set(MuseCompanionScope.allCases)))
    }
    func testDisclosureAndControlScopesAreIndependent() {
        XCTAssertTrue(MuseCompanionAuthorization.permits(op: "tools.call", params: ["tool": "screenshot"], scopes: [.screenshot]))
        XCTAssertTrue(MuseCompanionAuthorization.permits(op: "images.get", params: [:], scopes: [.screenshot]))
        XCTAssertFalse(MuseCompanionAuthorization.permits(op: "tools.call", params: ["tool": "tap"], scopes: [.screenshot]))
        XCTAssertFalse(MuseCompanionAuthorization.permits(op: "images.get", params: [:], scopes: [.control]))
        XCTAssertFalse(MuseCompanionAuthorization.permits(op: "tools.call", params: ["tool": "list_apps"], scopes: [.control]))
        XCTAssertTrue(MuseCompanionAuthorization.permits(op: "tools.call", params: ["tool": "list_apps"], scopes: [.listApps]))
        XCTAssertTrue(MuseCompanionAuthorization.permits(op: "tools.call", params: ["tool": "tap"], scopes: [.control]))
    }
    func testEnrollmentCannotEmitAnUntrustedOrEmptyTLSIdentity() throws {
        let store = RemoteConnectionStore(vault: RemoteMemoryVault(), defaults: nil)
        try store.configure(host: "untrusted.invalid", port: "8765", sources: "127.0.0.1")
        XCTAssertThrowsError(try store.addClient(name: "Cannot pair without TLS"))
        XCTAssertTrue(store.settings.clients.isEmpty)
    }
    func testLegacyCredentialDoesNotAcquireScopesOrFreshBootstrap() throws {
        let old = Data("{\"id\":\"old\",\"name\":\"Legacy\",\"pairedAt\":0}".utf8)
        let decoded = try JSONDecoder().decode(RemoteClientRegistration.self, from: old)
        XCTAssertTrue(decoded.scopes.isEmpty)
        XCTAssertFalse(decoded.identityConfirmed)
        XCTAssertEqual(decoded.bootstrapExpiresAt, .distantPast)
    }
    func testPendingCredentialCannotExecuteAndHelloCannotGrantOrRenameIdentity() throws {
        let store = RemoteConnectionStore(vault: RemoteMemoryVault(), defaults: nil)
        try store.configure(host: "actell-test.invalid", port: "8765", sources: "127.0.0.1")
        let certificate = try XCTUnwrap(Data(base64Encoded: RemoteConnectionStoreTests.fixture, options: .ignoreUnknownCharacters))
        try store.importIdentity(data: certificate, password: "TEST_ONLY_NOT_A_REAL_PASSWORD")
        let invitation = try store.addClient(name: "Physical Muse")
        let id = invitation.client.id
        XCTAssertNotNil(store.key(for: id))
        XCTAssertFalse(store.permits(clientID: id, op: "capabilities", params: [:]))
        XCTAssertThrowsError(try store.setAuthorization(clientID: id, scopes: [.control], identityConfirmed: true))
        try store.recordHello(clientID: id, name: "First physical device")
        try store.recordHello(clientID: id, name: "Later remote label")
        XCTAssertEqual(store.settings.clients.first?.requestedDeviceName, "First physical device")
        XCTAssertFalse(store.permits(clientID: id, op: "capabilities", params: [:]))
        XCTAssertThrowsError(try store.setAuthorization(clientID: id, scopes: [.control], identityConfirmed: false))
        try store.setAuthorization(clientID: id, scopes: [.screenshot], identityConfirmed: true)
        XCTAssertNil(store.settings.clients.first?.bootstrapExpiresAt)
        XCTAssertTrue(store.permits(clientID: id, op: "images.get", params: [:]))
        XCTAssertFalse(store.permits(clientID: id, op: "tools.call", params: ["tool": "tap"]))
        try store.recordHello(clientID: id, name: "Rename attempt after binding")
        XCTAssertEqual(store.settings.clients.first?.requestedDeviceName, "First physical device")
        try store.setAuthorization(clientID: id, scopes: [], identityConfirmed: true)
        XCTAssertFalse(store.permits(clientID: id, op: "images.get", params: [:]))
        XCTAssertFalse(store.permits(clientID: id, op: "capabilities", params: [:]))
    }
    func testExpiredBootstrapIsNotAnAuthenticationKey() throws {
        let suite = "actell-expired-companion-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let vault = RemoteMemoryVault()
        var settings = RemoteConnectionSettings()
        var expired = RemoteClientRegistration(id: "expired", name: "Expired", pairedAt: .distantPast)
        expired.requestedDeviceName = "Untrusted label"
        settings.clients = [expired]
        defaults.set(try JSONEncoder().encode(settings), forKey: "actell.muse.connection.v1")
        try vault.write(Data(repeating: 1, count: 32), account: "client-expired")
        let store = RemoteConnectionStore(vault: vault, defaults: defaults)
        XCTAssertNil(store.key(for: "expired"))
        XCTAssertThrowsError(try store.recordHello(clientID: "expired", name: "Device"))
        XCTAssertThrowsError(try store.setAuthorization(clientID: "expired", scopes: [.control], identityConfirmed: true))
    }
    func testLANFilterIsNotPublicOrLoopbackAuthorization() throws {
        for literal in ["10.0.0.1", "172.16.0.1", "172.31.255.255", "192.168.1.1", "169.254.1.1", "fd00::1", "fe80::1"] {
            XCTAssertTrue(try XCTUnwrap(RemoteSourceAddress(literal: literal)).isPrivateLAN, literal)
        }
        for literal in ["8.8.8.8", "127.0.0.1", "172.32.0.1", "::1", "2001:4860:4860::8888", "::ffff:192.168.1.1"] {
            XCTAssertFalse(try XCTUnwrap(RemoteSourceAddress(literal: literal)).isPrivateLAN, literal)
        }
    }
    func testListenerOrAuthorizationAloneNeverMeansOnline() throws {
        let store = RemoteConnectionStore(vault: RemoteMemoryVault(), defaults: nil)
        let controller = RemoteConnectionController(service: RemoteToolsService(model: AgentViewModel(loadPersistentState: false)), store: store)
        var client = RemoteClientRegistration(id: "offline", name: "Muse", pairedAt: Date())
        XCTAssertEqual(controller.peerStatus(client), String(localized: "Waiting for the device after USB setup"))
        client.requestedDeviceName = "Muse"
        XCTAssertEqual(controller.peerStatus(client), String(localized: "Waiting for device approval"))
        client.identityConfirmed = true; client.scopes = [.screenshot]
        XCTAssertEqual(controller.peerStatus(client), String(localized: "Authorized, not connected"))
    }
}
