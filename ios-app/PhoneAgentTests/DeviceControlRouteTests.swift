import XCTest
@testable import PhoneAgent

@MainActor final class DeviceControlRouteTests: XCTestCase {
    func testRouteSwitchPersistsAndRevokesConnectionButPreservesPairingRecord() throws {
        let suite = "LocalVPNTests.\(UUID().uuidString)", root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appending(path: "identity.plist")
        // Opaque sentinel: selecting a route must neither parse nor rewrite secrets.
        let bytes = Data("pairing-identity-sentinel".utf8); try bytes.write(to: url)
        defaults.set(DeviceControlRoute.ncmDeveloper.rawValue, forKey: DeviceControlRoute.defaultsKey)
        let store = RemotePairRecordStore(url: url), flow = PairingFlow(store: store, defaults: defaults)
        XCTAssertEqual(flow.route, .ncmDeveloper)
        let session = flow.controlSessionID, stop = flow.connectionStopID
        flow.ready = true
        XCTAssertTrue(flow.selectRoute(.vpnLoopback))
        XCTAssertFalse(flow.ready)
        XCTAssertNotEqual(flow.controlSessionID, session)
        XCTAssertNotEqual(flow.connectionStopID, stop)
        XCTAssertEqual(try Data(contentsOf: url), bytes)
        XCTAssertEqual(DeviceControlRoute.load(from: defaults), .vpnLoopback)
        XCTAssertEqual(PairingFlow(store: store, defaults: defaults).route, .vpnLoopback)
        XCTAssertTrue(flow.selectRoute(.ncmDeveloper))
        XCTAssertEqual(try Data(contentsOf: url), bytes)
    }
    func testRetainedRunAndPairingPreventSwitchEvenBeforeFirstDeviceTool() async throws {
        let suite = "LocalVPNTests.\(UUID().uuidString)", defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(DeviceControlRoute.ncmDeveloper.rawValue, forKey: DeviceControlRoute.defaultsKey)
        let flow = PairingFlow(store: RemotePairRecordStore(url: FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)), defaults: defaults)
        let bridge = try CoreDeviceBridge(flow: flow)
        XCTAssertFalse(flow.selectRoute(.vpnLoopback))
        XCTAssertEqual(flow.route, .ncmDeveloper)
        await bridge.stop()
        flow.running = true; flow.pairingActive = true
        XCTAssertFalse(flow.selectRoute(.vpnLoopback))
        flow.running = false; flow.pairingActive = false
        XCTAssertTrue(flow.selectRoute(.vpnLoopback))
        XCTAssertFalse(flow.selectRoute(.localCaptureUSB))
    }
    func testVPNAddressSaveIsAtomicRevokesSessionAndRetainsIdentity() async throws {
        let suite = "VPNConfigTests.\(UUID().uuidString)", defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appending(path: "identity.plist"), bytes = Data("identity-sentinel".utf8)
        try bytes.write(to: url)
        defaults.set("localDevVPN", forKey: DeviceControlRoute.defaultsKey)
        let store = RemotePairRecordStore(url: url), flow = PairingFlow(store: store, defaults: defaults)
        XCTAssertEqual(flow.route, .vpnLoopback) // Existing preference survives the display-name change.
        XCTAssertEqual(flow.vpnConfiguration, .defaults)
        let session = flow.controlSessionID
        XCTAssertThrowsError(try flow.saveVPNConfiguration(localAddress: "invalid", peerAddress: "10.8.0.1"))
        XCTAssertEqual(flow.controlSessionID, session)
        XCTAssertEqual(flow.vpnConfiguration, .defaults)
        flow.ready = true
        try flow.saveVPNConfiguration(localAddress: "10.8.1.1", peerAddress: "10.8.0.1")
        XCTAssertFalse(flow.ready); XCTAssertNotEqual(flow.controlSessionID, session)
        XCTAssertEqual(try Data(contentsOf: url), bytes)
        XCTAssertEqual(PairingFlow(store: store, defaults: defaults).vpnConfiguration, flow.vpnConfiguration)
        let bridge = try CoreDeviceBridge(flow: flow)
        XCTAssertThrowsError(try flow.saveVPNConfiguration(localAddress: "10.9.1.1", peerAddress: "10.9.0.1"))
        XCTAssertEqual(flow.vpnConfiguration.localAddress, "10.8.1.1")
        await bridge.stop()
    }
    func testMissingOrUnknownPreferenceDefaultsToVPNAndExplicitESP32IsPreserved() throws {
        let suite = "LocalVPNTests.\(UUID().uuidString)", defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertEqual(DeviceControlRoute.load(from: defaults), .vpnLoopback)
        defaults.set("unknown", forKey: DeviceControlRoute.defaultsKey)
        XCTAssertEqual(DeviceControlRoute.load(from: defaults), .vpnLoopback)
        defaults.set(DeviceControlRoute.ncmDeveloper.rawValue, forKey: DeviceControlRoute.defaultsKey)
        XCTAssertEqual(DeviceControlRoute.load(from: defaults), .ncmDeveloper)
    }
}
