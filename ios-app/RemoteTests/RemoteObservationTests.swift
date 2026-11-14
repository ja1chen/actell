import XCTest
@testable import PhoneAgent

private actor RemoteObservationSpy: DeviceBridge {
    private(set) var accessibilityReads = 0
    func accessibilityObservation() async throws -> Data? { accessibilityReads += 1; return nil }
    func screenshot() async throws -> FrameImage { FrameImage(id: "fresh", png: Data(), width: 390, height: 844, capturedAt: Date(), isDemo: true) }
    func tap(x: Int, y: Int, imageID: String) async throws {}
    func drag(fromX: Int, fromY: Int, toX: Int, toY: Int, durationMS: Int, imageID: String) async throws {}
    func stop() async {}
}

@MainActor final class RemoteObservationTests: XCTestCase {
    func testRemoteScreenshotsKeepImageContractRegardlessOfLocalMode() async throws {
        for mode in ScreenInformationMode.allCases {
            let bridge = RemoteObservationSpy()
            let coordinator = ActionCoordinator(bridge: bridge, limits: AgentLimits(), approve: { _ in true }, onImage: { _, _ in }, onReceipt: { _ in }, screenInformationMode: mode)
            let result = try await coordinator.executeRemote(name: "screenshot", parameters: [:], callID: "remote", expectedImageID: nil, deadline: Date().addingTimeInterval(10))
            XCTAssertEqual(result.kind, .returned); XCTAssertEqual(result.images.count, 1)
            let reads = await bridge.accessibilityReads; XCTAssertEqual(reads, 0)
        }
    }
}
