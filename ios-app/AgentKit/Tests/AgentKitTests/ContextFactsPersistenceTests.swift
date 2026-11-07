import XCTest
import Foundation
import ProviderCore
@testable import AgentKit

@MainActor final class ContextFactsPersistenceTests: XCTestCase {
    private func directory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }
    func testMissingPureCompactionAllowsOrderedFactsButNotFullAudit() async throws {
        let root = try directory(), id = UUID()
        let first = ModelInputItem.message(role: .user, content: [.text("original")])
        let summary = ModelInputItem.message(role: .assistant, content: [.text("summary")])
        let tail = ModelInputItem.message(role: .assistant, content: [.text("later")])
        let transactions: [SessionTransaction] = [
            .init(sessionID: id, kind: .turnStarted, contextItems: [first]),
            .init(sessionID: id, kind: .contextCompacted, snapshot: .init(items: [summary])),
            .init(sessionID: id, kind: .modelOutput, contextItems: [tail])]
        try LegacySessionFixtures.write(root: root, sessionID: id, transactions: transactions, missing: [1])
        let reopened = JSONLSessionStore(root: root, sessionID: id)
        try reopened.migrateLegacySync { _ in XCTFail("Unexpected UI conversion"); return [] }
        let abstractStore: any SessionStore = reopened
        let facts = try await abstractStore.readContextFacts(id)
        XCTAssertEqual(facts.flatMap(\.contextItems), [first, tail])
        do { _ = try await abstractStore.readTransactions(id); XCTFail("Full audit must report missing compaction") }
        catch StoreError.missingBlob { }
        catch { XCTFail("Unexpected error: \(error)") }
    }
    func testMissingAuthoritativeFactsAreNotSkipped() throws {
        let root = try directory(), id = UUID()
        let transactions: [SessionTransaction] = [.init(sessionID: id, kind: .turnStarted,
            contextItems: [.message(role: .user, content: [.text("must remain")])])]
        try LegacySessionFixtures.write(root: root, sessionID: id, transactions: transactions, missing: [0])
        let history = root.appendingPathComponent("history.jsonl")
        let original = try Data(contentsOf: history)
        let store = JSONLSessionStore(root: root, sessionID: id)
        XCTAssertThrowsError(try store.migrateLegacySync { _ in [] }) { XCTAssertEqual($0 as? StoreError, .missingBlob) }
        XCTAssertEqual(try Data(contentsOf: history), original)
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("manifest.json").path))
    }
}
