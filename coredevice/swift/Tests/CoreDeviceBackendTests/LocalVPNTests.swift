import XCTest
import Darwin
@testable import CoreDeviceBackend

@MainActor final class LocalVPNTests: XCTestCase {
    func testOnlyActiveDefaultVPNInterfaceIsAccepted() throws {
        func row(name: String = "utun77", address: String = "10.7.1.1", flags: UInt32 = UInt32(IFF_UP | IFF_RUNNING | IFF_POINTOPOINT)) -> NetworkInterfaces.Row {
            .init(name: name, index: 77, address: address, mask: "255.255.255.255", flags: flags, linkType: nil)
        }
        XCTAssertEqual(try LocalVPNDiscovery.selectInterface([row()]).index, 77)
        for rows in [[], [row(), row()], [row(name: "en0")], [row(address: "192.168.7.2")], [row(flags: UInt32(IFF_UP))]] {
            XCTAssertThrowsError(try LocalVPNDiscovery.selectInterface(rows))
        }
        XCTAssertThrowsError(try NCMInterfaceBinding.select([row()]))
    }
    func testCustomAddressesAreValidatedAndSelectOnlyMatchingVPN() throws {
        let config = try VPNLoopbackConfiguration(localAddress: " 10.8.1.1 ", peerAddress: "10.8.0.1")
        XCTAssertEqual(config.localAddress, "10.8.1.1")
        XCTAssertEqual(config.localIPv4, 0x0a080101)
        XCTAssertEqual(config.peerIPv4, 0x0a080001)
        let row = NetworkInterfaces.Row(name: "utun77", index: 77, address: "10.8.1.1", mask: "255.255.255.255", flags: UInt32(IFF_UP | IFF_RUNNING | IFF_POINTOPOINT), linkType: nil)
        XCTAssertThrowsError(try LocalVPNDiscovery.selectInterface([row]))
        XCTAssertEqual(try LocalVPNDiscovery.selectInterface([row], configuration: config), row)
        for address in ["", "10.8.1.256", "10.8.1", "10.8.1.1/32", "010.8.1.1", "127.0.0.1", "0.0.0.0", "224.0.0.1", "::1", "example.com", "10.8.0.1"] {
            XCTAssertThrowsError(try VPNLoopbackConfiguration(localAddress: address, peerAddress: "10.8.0.1"))
        }
    }
    func testNoGuessedPortAndAmbiguousDiscoveryFailsClosed() throws {
        XCTAssertThrowsError(try LocalVPNDiscovery.selectPort([]))
        XCTAssertThrowsError(try LocalVPNDiscovery.selectPort([0]))
        XCTAssertThrowsError(try LocalVPNDiscovery.selectPort([1234, 5678]))
        XCTAssertEqual(try LocalVPNDiscovery.selectPort([1234, 1234]), 1234)
    }
    func testVPNRequiresExplicitExistingIdentityAuthorizationBeforeNetwork() async throws {
        let identity = try AuthorizedRemoteIdentity(signingSeed: Data(repeating: 1, count: 32), controllerID: "test-controller", peerID: "test-peer",
            peerPublicKey: Data(repeating: 2, count: 32), alternateIRK: Data(repeating: 3, count: 16), peerUDID: "test-udid", peerModel: "test-model")
        do {
            try await NativeDeveloperServices().connectLocalVPN(identity: identity, authorization: .init(verifyExistingIdentity: false), pairingPort: 1234)
            XCTFail("authorization required")
        } catch { XCTAssertEqual(error as? NativeBackendError, .authorizationRequired) }
    }
}
