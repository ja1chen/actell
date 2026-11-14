import XCTest
@testable import PhoneAgent

@MainActor final class MuseConversationTests: XCTestCase {
    func testMuseOwnershipDisablesOnlyPhoneToolsForLocalChat() async throws {
        let store = ConversationStore(inMemory: true), provider = AdmissionInspectionProvider()
        let model = AgentViewModel(sessions: store, loadPersistentState: false,
            runServices: .init(provider: provider, bridge: UnavailableBridge()), makeRemoteBridge: { UnavailableBridge() })
        _ = try model.acquireRemoteRun("fixture-owner", onImage: { _ in }, onStop: {})
        defer { model.releaseRemoteRun("fixture-owner") }
        let id = model.createConversation(mode: .live)
        XCTAssertTrue(model.send("chat during Muse control", in: id, cloudConsent: true))
        try await waitUntil { !model.running }
        XCTAssertEqual(store.conversation(id)?.phase, .completed)
        let request = try XCTUnwrap(provider.requests.first)
        XCTAssertTrue(request.tools.contains { $0.name == "bash" })
        XCTAssertFalse(request.tools.contains { ["screenshot", "tap", "home", "launch_app", "type_text"].contains($0.name) })
        XCTAssertTrue(model.remoteAdmissionSnapshot["remote_lease"] == "true")
        XCTAssertNotNil(model.errorMessage)
        XCTAssertTrue(model.send("cancel only local chat", in: id, cloudConsent: true))
        let localRun = try XCTUnwrap(model.currentRun)
        XCTAssertTrue(model.stop(run: localRun))
        try await waitUntil { !model.stopping }
        XCTAssertTrue(model.remoteAdmissionSnapshot["remote_lease"] == "true")
    }
    private func waitUntil(_ condition: @escaping () -> Bool) async throws {
        for _ in 0..<150 {
            if condition() { return }
            try await Task.sleep(nanoseconds: 40_000_000)
        }
        XCTFail("Timed out waiting for deterministic offline runtime")
        throw AppError.timeout
    }
}
