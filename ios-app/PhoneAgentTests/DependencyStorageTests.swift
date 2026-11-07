import Foundation
import AgentKit
import ProviderCore
import XCTest

final class DependencyStorageTests: XCTestCase {
    func testSessionStoreWritesDirectlyToSuppliedRootAndReloadsOnIOS() throws {
        let base = try XCTUnwrap(FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first)
            .appendingPathComponent("agentkit-test-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: base) }
        let session = UUID(), item = UUID()
        let store = JSONLSessionStore(root: base, sessionID: session)
        _ = try store.appendSync(.init(sessionID: session, kind: .turnStarted,
            contextItems: [.message(role: .user, content: [.text("durable input")])],
            displayItems: [.init(id: item, role: "user", text: "durable input")]), expecting: 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: base.appendingPathComponent("history.jsonl").path))
        let files = try FileManager.default.contentsOfDirectory(atPath: base.path).filter { !$0.hasPrefix(".") }
        XCTAssertEqual(Set(files), ["history.jsonl"])
        // A text-only session remains independently recoverable when only its
        // JSONL is copied; no manifest, list cache or transaction blob is needed.
        let copied = base.appendingPathExtension("copy")
        defer { try? FileManager.default.removeItem(at: copied) }
        try FileManager.default.createDirectory(at: copied, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: base.appendingPathComponent("history.jsonl"),
                                        to: copied.appendingPathComponent("history.jsonl"))
        let restored = JSONLSessionStore(root: copied, sessionID: session)
        XCTAssertEqual(try restored.readPageSync(.init(sessionID: session)).items.map(\.id), [item])
        XCTAssertEqual(try restored.loadContextSync(session).items, [.message(role: .user, content: [.text("durable input")])])
    }
}
