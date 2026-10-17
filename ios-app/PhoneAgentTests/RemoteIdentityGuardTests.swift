import XCTest
@testable import PhoneAgent

@MainActor final class RemoteIdentityGuardTests: XCTestCase {
    func testPrepareCompanionCannotSilentlyReplacePreviouslySavedPin() throws {
        let store = RemoteConnectionStore(vault: RemoteMemoryVault(), defaults: nil)
        try store.prepareCompanion()
        let original = try XCTUnwrap(store.settings.certificate)
        let host = store.settings.host
        let provider = RemoteGeneratedIdentityProvider(namespace: "actell.muse.generated-tls.v1." + host)
        defer { try? provider.remove() }
        try provider.remove()
        XCTAssertNil(try provider.load(host: host))
        XCTAssertThrowsError(try store.prepareCompanion())
        XCTAssertEqual(store.settings.certificate?.fingerprint, original.fingerprint)
        XCTAssertNil(try provider.load(host: host))
    }
}
