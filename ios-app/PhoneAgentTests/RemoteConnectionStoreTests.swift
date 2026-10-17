import XCTest
import Security
@testable import PhoneAgent

// Synthetic CA and server test identity for .invalid, never shipped in the app target.
@MainActor final class RemoteConnectionStoreTests: XCTestCase {
    func testCredentialDiagnosticsRetainSystemCodeWithoutTechnicalUICopy() {
        let vault = RemoteVaultError(status: errSecMissingEntitlement, operation: "read")
        XCTAssertEqual((vault as NSError).domain, NSOSStatusErrorDomain)
        XCTAssertEqual((vault as NSError).code, Int(errSecMissingEntitlement))
        XCTAssertEqual((vault as NSError).localizedDescription, vault.errorDescription)
        let native = NSError(domain: NSOSStatusErrorDomain, code: Int(errSecInteractionNotAllowed))
        let setup = RemoteSetupError("Synthetic credential failure", underlying: native) as NSError
        XCTAssertEqual(setup.code, native.code)
        XCTAssertEqual((setup.userInfo[NSUnderlyingErrorKey] as? NSError)?.domain, NSOSStatusErrorDomain)
        XCTAssertEqual(setup.localizedDescription, "Synthetic credential failure")
    }
    static let fixture = """
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
"""
    private var certificate: Data { Data(base64Encoded: Self.fixture, options: .ignoreUnknownCharacters)! }
    private func configured(_ vault: RemoteMemoryVault = RemoteMemoryVault(), defaults: UserDefaults? = nil) throws -> RemoteConnectionStore {
        let store = RemoteConnectionStore(vault: vault, defaults: defaults)
        try store.configure(host: "actell-test.invalid", port: "8765", sources: "127.0.0.1")
        try store.importIdentity(data: certificate, password: "TEST_ONLY_NOT_A_REAL_PASSWORD")
        return store
    }
    func testConfigurationRejectsOriginsWildcardsDuplicatesAndInvalidPorts() throws {
        for host in ["https://host", "host/path", "user@host", "", "-bad.local"] {
            XCTAssertThrowsError(try RemoteConnectionSettings.validate(host: host, port: "8765", sources: "127.0.0.1"))
        }
        for source in ["*", "192.168.0.0/24", "client.local", "127.0.0.1,127.0.0.1", ""] {
            XCTAssertThrowsError(try RemoteConnectionSettings.validate(host: "actell-test.invalid", port: "8765", sources: source))
        }
        for port in ["0", "65536", "-1", "abc"] {
            XCTAssertThrowsError(try RemoteConnectionSettings.validate(host: "host.local", port: port, sources: "127.0.0.1"))
        }
        let result = try RemoteConnectionSettings.validate(host: "::1", port: "443", sources: "127.0.0.1\n::1")
        XCTAssertEqual(result.1, 443); XCTAssertEqual(result.2.count, 2)
    }
    func testCertificateImportReloadAndHostnameValidation() throws {
        let vault = RemoteMemoryVault(), store = try configured(vault)
        try store.importIdentity(data: certificate, password: "TEST_ONLY_NOT_A_REAL_PASSWORD")
        XCTAssertEqual(store.settings.certificate?.fingerprint.count, 64)
        XCTAssertNoThrow(try store.loadIdentity())
        try store.configure(host: "other.invalid", port: "8765", sources: "127.0.0.1")
        XCTAssertThrowsError(try store.loadIdentity())
        try store.removeIdentity(); XCTAssertNil(store.settings.certificate)
        XCTAssertNil(try vault.read(RemoteConnectionStore.identityAccount))
    }
    func testFailedReplacementRetainsOriginalCertificateAndKeychainItem() throws {
        let vault = RemoteMemoryVault(), store = try configured(vault)
        try store.importIdentity(data: certificate, password: "TEST_ONLY_NOT_A_REAL_PASSWORD")
        let before = try vault.read(RemoteConnectionStore.identityAccount), summary = store.settings.certificate
        XCTAssertThrowsError(try store.importIdentity(data: certificate, password: "wrong"))
        XCTAssertThrowsError(try store.importIdentity(data: Data("not a certificate".utf8), password: ""))
        XCTAssertEqual(try vault.read(RemoteConnectionStore.identityAccount), before)
        XCTAssertEqual(store.settings.certificate, summary)
        XCTAssertNoThrow(try store.loadIdentity())
    }
    func testClientSecretsAreIsolatedFromPersistedSettingsAndRevocationPrecedesFence() throws {
        let suite = "actell-muse-tests-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!; defer { defaults.removePersistentDomain(forName: suite) }
        let vault = RemoteMemoryVault(), store = try configured(vault, defaults: defaults)
        let invitation = try store.addClient(name: "Synthetic client")
        let key = try XCTUnwrap(store.key(for: invitation.client.id)); XCTAssertEqual(key.count, 32)
        let info = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(invitation.text.utf8)) as? [String: Any])
        XCTAssertEqual(info["secret_base64"] as? String, key.base64EncodedString())
        XCTAssertEqual(info["tls_verification_required"] as? Bool, true)
        let metadata = String(decoding: defaults.data(forKey: "actell.muse.connection.v1")!, as: UTF8.self)
        XCTAssertFalse(metadata.contains(key.base64EncodedString()))
        XCTAssertFalse(metadata.contains("secret_base64")); XCTAssertFalse(metadata.contains("password"))
        let reloaded = RemoteConnectionStore(vault: vault, defaults: defaults)
        XCTAssertEqual(reloaded.key(for: invitation.client.id), key)
        var fenced = false
        try reloaded.revokeClient(invitation.client.id) { id in
            XCTAssertNil(reloaded.key(for: id)); fenced = true
        }
        XCTAssertTrue(fenced); XCTAssertTrue(reloaded.settings.clients.isEmpty)
    }
    func testFailedKeychainDeletionCannotClaimClientRevoked() throws {
        final class Vault: RemoteCredentialVault {
            var values: [String: Data] = [:]
            func read(_ account: String) throws -> Data? { values[account] }
            func write(_ data: Data, account: String) throws { values[account] = data }
            func remove(_ account: String) throws { throw RemoteSetupError("synthetic locked keychain") }
        }
        let vault = Vault(), store = RemoteConnectionStore(vault: vault, defaults: nil)
        try store.configure(host: "actell-test.invalid", port: "8765", sources: "127.0.0.1")
        try store.importIdentity(data: certificate, password: "TEST_ONLY_NOT_A_REAL_PASSWORD")
        let invitation = try store.addClient(name: "client"); var fenced = false
        XCTAssertThrowsError(try store.revokeClient(invitation.client.id) { _ in fenced = true })
        XCTAssertFalse(fenced); XCTAssertNotNil(store.key(for: invitation.client.id))
        XCTAssertEqual(store.settings.clients.count, 1)
        let service = RemoteToolsService(model: AgentViewModel(loadPersistentState: false))
        let controller = RemoteConnectionController(service: service, store: store)
        var states: [RemoteToolsService.ConnectionState] = []
        service.connectionStateChanged = { states.append($0) }
        XCTAssertThrowsError(try controller.revoke(invitation.client))
        XCTAssertEqual(states.last, .stopped)
        XCTAssertEqual(controller.settings.clients.count, 1)
        XCTAssertNotNil(store.key(for: invitation.client.id))
    }
    func testClientLimitAndDefaultControllerRemainDormant() throws {
        let store = try configured()
        for i in 0..<16 { _ = try store.addClient(name: "client-\(i)") }
        XCTAssertThrowsError(try store.addClient(name: "overflow"))
        let service = RemoteToolsService(model: AgentViewModel(loadPersistentState: false))
        let controller = RemoteConnectionController(service: service, store: try configured())
        XCTAssertEqual(controller.status, .stopped)
        XCTAssertThrowsError(try controller.start()); XCTAssertEqual(service.connectionState, .stopped)
        controller.stop(); XCTAssertEqual(controller.status, .stopped)
    }
    func testKeychainVaultRoundTripForUniqueTestAccount() throws {
        let vault = RemoteKeychainVault(), account = "test-only-" + UUID().uuidString
        defer {
            // Cleanup must not replace XCTSkip on unsigned simulators.
            _ = SecItemDelete([kSecClass: kSecClassGenericPassword,
                               kSecAttrService: "com.ja1chen.Actell.MuseRemote.v1",
                               kSecAttrAccount: account] as CFDictionary)
        }
        do {
            try vault.write(Data([1,2,3]), account: account)
            XCTAssertEqual(try vault.read(account), Data([1,2,3]))
            try vault.write(Data([4,5]), account: account)
            XCTAssertEqual(try vault.read(account), Data([4,5]))
            try vault.remove(account)
            XCTAssertNil(try vault.read(account))
        }
        catch let error as RemoteVaultError {
            #if targetEnvironment(simulator)
            if error.status == errSecMissingEntitlement {
                throw XCTSkip("Unsigned simulator lacks Keychain entitlement; separately verified with local ad-hoc simulator signing")
            }
            #endif
            throw error
        }
    }
}
