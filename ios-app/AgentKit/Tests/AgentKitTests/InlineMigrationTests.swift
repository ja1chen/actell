import XCTest
import Foundation
import ProviderCore
@testable import AgentKit

final class InlineMigrationTests: XCTestCase {
    private func directory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }
    func testEnvelopeMigrationRehydratesAllFieldsAndOnlyCleansObsoleteSessionFiles() throws {
        let root = try directory(), id = UUID(), turn = UUID()
        let text = String(repeating: "old record ", count: 9_000)
        let image = ModelImage(data: Data([1, 2, 3]), mimeType: "image/png")
        let original = SessionTransaction(sessionID: id, turnID: turn, kind: .turnStarted,
            contextItems: [.message(role: .user, content: [.text(text), .image(image)])],
            displayItems: [.init(role: "user", text: text, metadata: .object(["fact": .string(text)]))])
        try LegacySessionFixtures.write(root: root, sessionID: id, transactions: [original])
        try Data("old index".utf8).write(to: root.appendingPathComponent("history.index"))
        try Data("old summary".utf8).write(to: root.appendingPathComponent("metadata.json"))
        let appAttachment = root.appendingPathComponent("attachments").appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: appAttachment, withIntermediateDirectories: true)
        try Data("keep".utf8).write(to: appAttachment.appendingPathComponent("metadata.json"))
        let store = JSONLSessionStore(root: root, sessionID: id)
        try store.migrateLegacySync { _ in XCTFail("No UI converter for envelope history"); return [] }
        let history = try Data(contentsOf: root.appendingPathComponent("history.jsonl"))
        XCTAssertTrue(String(decoding: history, as: UTF8.self).contains(text))
        for file in ["manifest.json", "history.index", "metadata.json", "blobs", ".inline-migration.json"] {
            XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(file).path), file)
        }
        XCTAssertEqual(try Data(contentsOf: appAttachment.appendingPathComponent("metadata.json")), Data("keep".utf8))
        XCTAssertEqual(try store.loadContextSync(id).items, original.contextItems)
        XCTAssertEqual(try store.readTransactionsSync(id).first, original)
        XCTAssertEqual(try store.appendSync(original, expecting: 0).sequence, 1)
        XCTAssertEqual(try store.readTransactionsSync(id).count, 1)
    }
    func testMigrationFailuresAreRetryableBeforeAndAfterAtomicPublish() throws {
        final class Fault: @unchecked Sendable {
            let lock = NSLock(); var target: StoreFaultPoint?
            init(_ target: StoreFaultPoint) { self.target = target }
            func inject(_ point: StoreFaultPoint) throws { try lock.withLock {
                if point == target { target = nil; throw StoreError.io("injected") }
            } }
        }
        for point in [StoreFaultPoint.migrationSource, .migrationHistory, .migrationManifest, .migrationCleanup] {
            let root = try directory(), id = UUID(), fault = Fault(point)
            let transaction = SessionTransaction(sessionID: id, kind: .turnStarted,
                contextItems: [.message(role: .user, content: [.text("durable")])])
            try LegacySessionFixtures.write(root: root, sessionID: id, transactions: [transaction])
            let historyURL = root.appendingPathComponent("history.jsonl"), old = try Data(contentsOf: historyURL)
            let store = JSONLSessionStore(root: root, sessionID: id, faultInjector: { try fault.inject($0) })
            if point == .migrationCleanup { try store.migrateLegacySync { _ in [] } }
            else { XCTAssertThrowsError(try store.migrateLegacySync { _ in [] }) }
            if point == .migrationSource || point == .migrationHistory { XCTAssertEqual(try Data(contentsOf: historyURL), old) }
            try store.migrateLegacySync { _ in XCTFail("No UI converter"); return [] }
            XCTAssertEqual(try store.loadContextSync(id).items, transaction.contextItems)
            XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(".inline-migration.json").path))
            XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("blobs").path))
        }
    }
    func testOldInterruptedUIMigrationUsesOriginalTemporarySource() throws {
        let root = try directory(), id = UUID(), migrationID = UUID(), source = Data("old app-owned source".utf8)
        let oldName = ".migration-\(migrationID.uuidString).source"
        try source.write(to: root.appendingPathComponent(oldName))
        let oldState = try JSONSerialization.data(withJSONObject: ["schemaVersion": 1, "id": migrationID.uuidString,
            "source": oldName, "digest": LegacySessionFixtures.digest(source)])
        try oldState.write(to: root.appendingPathComponent(".migration.json"))
        try Data("uncommitted replacement".utf8).write(to: root.appendingPathComponent("history.jsonl"))
        let store = JSONLSessionStore(root: root, sessionID: id)
        try store.migrateLegacySync { bytes in
            XCTAssertEqual(bytes, source)
            return [.init(sessionID: id, kind: .legacyImported, displayItems: [.init(role: "user", text: "retained")])]
        }
        XCTAssertEqual(try store.presentationSync().items.map(\.text), ["retained"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(oldName).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(".migration.json").path))
    }
    func testEmptyAndMissingExpectedSessionBehavior() throws {
        let root = try directory(), id = UUID()
        let fresh = JSONLSessionStore(root: root, sessionID: id)
        try fresh.migrateLegacySync { _ in XCTFail("Empty store is not legacy"); return [] }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("history.jsonl").path))
        let expected = JSONLSessionStore(root: root, sessionID: id, requireExistingHistory: true)
        XCTAssertThrowsError(try expected.migrateLegacySync { _ in [] }) { XCTAssertEqual($0 as? StoreError, .corruptHistory) }
        XCTAssertThrowsError(try expected.loadContextSync(id)) { XCTAssertEqual($0 as? StoreError, .corruptHistory) }
    }
    func testDamagedNewHistoryRemainsReadableThroughMigrationEntry() throws {
        let root = try directory(), id = UUID(), store = JSONLSessionStore(root: root, sessionID: id)
        _ = try store.appendSync(.init(sessionID: id, kind: .presentationUpdated, displayItems: [.init(role: "user", text: "valid")]), expecting: 0)
        let history = root.appendingPathComponent("history.jsonl")
        let handle = try FileHandle(forWritingTo: history); try handle.seekToEnd(); try handle.write(contentsOf: Data("{broken}\n".utf8)); try handle.close()
        let reopened = JSONLSessionStore(root: root, sessionID: id, requireExistingHistory: true)
        try reopened.migrateLegacySync { _ in XCTFail("New format must not be reimported"); return [] }
        let page = try reopened.readPageSync(.init(sessionID: id))
        XCTAssertEqual(page.items.map(\.text), ["valid"]); XCTAssertTrue(page.integrityGap)
        XCTAssertThrowsError(try reopened.appendSync(.init(sessionID: id, kind: .presentationUpdated), expecting: 0))
    }
    func testTwentyFourMegabytesOfLegacyTextMigratesBeyondOldAggregateLimit() throws {
        let root = try directory(), id = UUID()
        let body = String(repeating: "x", count: 2_000_000)
        let texts = (0..<12).map { "\($0):" + body }
        let transactions = texts.map { text in
            SessionTransaction(sessionID: id, kind: .legacyImported,
                contextItems: [.message(role: .user, content: [.text(text)])],
                displayItems: [.init(role: "user", text: text, metadata: .object(["originalMessage": .string(text)]))])
        }
        try LegacySessionFixtures.write(root: root, sessionID: id, transactions: transactions)
        let store = JSONLSessionStore(root: root, sessionID: id)
        try store.migrateLegacySync { _ in XCTFail("Unexpected UI conversion"); return [] }
        let file = root.appendingPathComponent("history.jsonl")
        let size = try XCTUnwrap(try file.resourceValues(forKeys: [.fileSizeKey]).fileSize)
        XCTAssertGreaterThan(size, 64 * 1024 * 1024, "The complete journal has no old aggregate limit")
        let restored = try JSONLSessionStore(root: root, sessionID: id, requireExistingHistory: true).loadContextSync(id)
        let actual = restored.items.compactMap { item -> String? in
            if case .message(.user, let parts) = item, case .text(let text)? = parts.first { return text }
            return nil
        }
        XCTAssertEqual(actual, texts)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("blobs").path))
    }
    func testDeclaredRecoveryGapCannotDisappearIntoTornTail() throws {
        let root = try directory(), id = UUID()
        let transactions: [SessionTransaction] = [
            .init(sessionID: id, kind: .turnStarted, contextItems: [.message(role: .user, content: [.text("original")])],
                  displayItems: [.init(role: "user", text: "original")]),
            .init(sessionID: id, kind: .contextCompacted, snapshot: .init(items: [.message(role: .assistant, content: [.text("lost")])]))]
        try LegacySessionFixtures.write(root: root, sessionID: id, transactions: transactions, missing: [1])
        let store = JSONLSessionStore(root: root, sessionID: id)
        try store.migrateLegacySync { _ in XCTFail("Unexpected UI conversion"); return [] }
        let history = root.appendingPathComponent("history.jsonl")
        let lines = try Data(contentsOf: history).split(separator: 10)
        XCTAssertEqual(lines.count, 3)
        var torn = Data(lines[0]); torn.append(10); torn.append(contentsOf: lines[1]); torn.append(10); torn.append(contentsOf: lines[2].prefix(12))
        try torn.write(to: history)
        let reopened = JSONLSessionStore(root: root, sessionID: id)
        let prefix = try reopened.readPageSync(.init(sessionID: id))
        XCTAssertEqual(prefix.items.map(\.text), ["original"]); XCTAssertTrue(prefix.integrityGap)
        XCTAssertThrowsError(try reopened.loadContextSync(id)) { XCTAssertEqual($0 as? StoreError, .corruptHistory) }
        XCTAssertThrowsError(try reopened.appendSync(.init(sessionID: id, kind: .turnStarted), expecting: 1))
    }
    func testCleanupRevalidatesImagesEvenWhenSameStoreHasCachedScan() throws {
        final class Fault: @unchecked Sendable {
            let lock = NSLock(); var fail = true
            func inject(_ point: StoreFaultPoint) throws { try lock.withLock {
                if point == .migrationCleanup && fail { fail = false; throw StoreError.io("cleanup") }
            } }
        }
        let root = try directory(), id = UUID(), bytes = Data([1, 2, 3]), fault = Fault()
        let image = ModelImage(data: bytes, mimeType: "image/png")
        let transaction = SessionTransaction(sessionID: id, kind: .turnStarted,
            contextItems: [.message(role: .user, content: [.image(image)])])
        try LegacySessionFixtures.write(root: root, sessionID: id, transactions: [transaction])
        let store = JSONLSessionStore(root: root, sessionID: id, faultInjector: { try fault.inject($0) })
        try store.migrateLegacySync { _ in XCTFail("Unexpected UI converter"); return [] }
        let marker = root.appendingPathComponent(".inline-migration.json"), oldBlobs = root.appendingPathComponent("blobs")
        XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path)); XCTAssertTrue(FileManager.default.fileExists(atPath: oldBlobs.path))
        let name = LegacySessionFixtures.digest(bytes), imageFile = root.appendingPathComponent("attachments").appendingPathComponent(name)
        try FileManager.default.removeItem(at: imageFile)
        try store.migrateLegacySync { _ in XCTFail("New format should not reimport"); return [] }
        XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path), "Old recovery source is still required")
        XCTAssertTrue(FileManager.default.fileExists(atPath: oldBlobs.path))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: root.path).contains { $0.hasPrefix(".inline-") && $0.hasSuffix(".source") })
        XCTAssertThrowsError(try store.loadContextSync(id)) { XCTAssertEqual($0 as? StoreError, .missingBlob) }
        try bytes.write(to: imageFile)
        try store.migrateLegacySync { _ in XCTFail("New format should not reimport"); return [] }
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path)); XCTAssertFalse(FileManager.default.fileExists(atPath: oldBlobs.path))
        XCTAssertEqual(try store.loadContextSync(id).items, transaction.contextItems)
    }
    func testSameInodeAndLengthMutationInvalidatesCachedScan() throws {
        let root = try directory(), id = UUID(), store = JSONLSessionStore(root: root, sessionID: id)
        _ = try store.appendSync(.init(sessionID: id, kind: .turnStarted,
            contextItems: [.message(role: .user, content: [.text("first")])], displayItems: [.init(role: "user", text: "first")]), expecting: 0)
        _ = try store.appendSync(.init(sessionID: id, kind: .turnStarted,
            contextItems: [.message(role: .user, content: [.text("second-fact")])]), expecting: 1)
        _ = try store.loadContextSync(id) // cache the valid scan on the same instance
        let file = root.appendingPathComponent("history.jsonl"), original = try Data(contentsOf: file)
        let range = try XCTUnwrap(original.range(of: Data("second-fact".utf8)))
        let handle = try FileHandle(forUpdating: file); try handle.seek(toOffset: UInt64(range.lowerBound))
        try handle.write(contentsOf: Data("second-faux".utf8)); try handle.synchronize(); try handle.close()
        XCTAssertEqual(try Data(contentsOf: file).count, original.count)
        let page = try store.readPageSync(.init(sessionID: id))
        XCTAssertEqual(page.items.map(\.text), ["first"]); XCTAssertTrue(page.integrityGap)
        XCTAssertThrowsError(try store.loadContextSync(id)) { XCTAssertEqual($0 as? StoreError, .corruptHistory) }
        XCTAssertThrowsError(try store.appendSync(.init(sessionID: id, kind: .turnStarted), expecting: 2))
    }
}
