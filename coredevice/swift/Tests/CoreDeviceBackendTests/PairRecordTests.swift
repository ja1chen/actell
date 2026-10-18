// SPDX-License-Identifier: GPL-3.0-or-later
import XCTest
@testable import CoreDeviceBackend
final class PairRecordTests: XCTestCase {
    // Public synthetic bytes, never a real phone's identity.
    private func record(committed: Bool, peer: String = "TEST-PEER", version: Int = 1) throws -> RemotePairRecord {
        let object: [String: Any] = ["version": version, "seed": Array(repeating: 0x42, count: 32),
            "controllerID": "TEST-HOST", "peerID": peer, "peerPublicKey": Array(repeating: 0x44, count: 32),
            "alternateIRK": Array(repeating: 0x33, count: 16), "peerUDID": "TEST-UDID", "peerModel": "TEST-MODEL", "committed": committed]
        return try JSONDecoder().decode(RemotePairRecord.self, from: JSONSerialization.data(withJSONObject: object))
    }
    func testDurablePromotionPreservesBindingAndRejectsDowngradeOrReplacement() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = RemotePairRecordStore(url: directory.appendingPathComponent("identity.plist"))
        XCTAssertFalse(store.exists)
        try store.save(record(committed: false)); XCTAssertFalse(try store.load().committed)
        try store.save(record(committed: true)); XCTAssertTrue(try store.load().committed)
        XCTAssertThrowsError(try store.save(record(committed: false)))
        XCTAssertThrowsError(try store.save(record(committed: true, peer: "OTHER-PEER")))
        XCTAssertEqual(try store.load().peerID, "TEST-PEER")
        XCTAssertTrue(try store.load().committed)
    }
    func testMalformedOrUnknownVersionCannotReplaceRecord() throws {
        XCTAssertThrowsError(try record(committed: true, version: 2).identity())
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = RemotePairRecordStore(url: directory.appendingPathComponent("identity.plist"))
        try store.save(record(committed: true))
        XCTAssertThrowsError(try store.save(record(committed: true, version: 2)))
        XCTAssertEqual(try store.load().version, 1)
    }
    @MainActor func testPairSetupConsentBeforeListener() async {
        let session = RemotePairingSession()
        do { try await session.pair(authorized: false, persist: { _ in XCTFail("must not persist") }, update: { _ in XCTFail("must not advertise") }); XCTFail("consent required") }
        catch { XCTAssertEqual(error as? NativeBackendError, .authorizationRequired) }
        session.close(); session.close()
    }
}
