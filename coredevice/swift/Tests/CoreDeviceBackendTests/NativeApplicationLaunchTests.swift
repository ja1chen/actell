// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import CoreDeviceBackend

final class NativeApplicationLaunchTests: XCTestCase {
    func testLaunchReceiptRequiresPositivePIDAndMatchingBundleAndDropsPrivateFields() throws {
        let data = Data(#"{"bundle_id":"example.fixture","pid":7001,"auditToken":[1,2],"executableURL":"PRIVATE_PATH"}"#.utf8)
        let receipt = try NativeApplicationLaunch.decode(data, expectedBundleID: "example.fixture")
        XCTAssertEqual(receipt.pid, 7001)
        let encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(receipt)) as! [String: Any]
        XCTAssertEqual(Set(encoded.keys), ["pid", "bundle_id"])
        for json in [#"{"bundle_id":"example.other","pid":7001}"#, #"{"bundle_id":"example.fixture","pid":0}"#,
                     #"{"bundle_id":"example.fixture","pid":2147483648}"#, #"{"bundle_id":"example.fixture"}"#, "invalid"] {
            XCTAssertThrowsError(try NativeApplicationLaunch.decode(Data(json.utf8), expectedBundleID: "example.fixture"))
        }
    }

    #if COREDEVICE_OFFLINE_FIXTURES
    @MainActor func testLaunchReceiptCrossesNativeABIOnRepeatedLaunches() async throws {
        let client = NativeDeveloperServices()
        try await client.connectMediaFailureFixture()
        defer { client.close() }
        let first = try await client.launchApplication(bundleID: "example.fixture", arguments: [])
        let again = try await client.launchApplication(bundleID: "example.fixture", arguments: ["--fixture"])
        XCTAssertEqual(first, NativeApplicationLaunch(bundleID: "example.fixture", pid: 7001))
        XCTAssertEqual(again, first)
        try await client.checkDeveloperReadiness()
    }
    #endif
}
