import XCTest
import Foundation
import ProviderCore
import Darwin
@testable import AgentKit

final class SessionStoreTests: XCTestCase {
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
    func testRoundTripCompactionAndPendingCallsDoNotExecute() throws {
        let root = try directory(), id = UUID(), turn = UUID()
        let store = JSONLSessionStore(root: root, sessionID: id)
        let user = ModelInputItem.message(role: .user, content: [.text("hello")])
        let call = ModelToolCall(id: "one", name: "tap", arguments: "{}")
        let model = ModelInputItem.replay(.functionCall(call))
        _ = try store.appendSync(.init(sessionID: id, turnID: turn, kind: .turnStarted, contextItems: [user], displayItems: [.init(role: "user", text: "hello")]), expecting: 0)
        _ = try store.appendSync(.init(sessionID: id, turnID: turn, kind: .modelOutput, contextItems: [model], usage: .init(promptTokens: 3)), expecting: 1)
        _ = try store.appendSync(.init(sessionID: id, turnID: turn, kind: .toolClaimed, toolClaims: ["one"]), expecting: 2)
        let loaded = try JSONLSessionStore(root: root, sessionID: id).loadContextSync(id)
        XCTAssertEqual(loaded.items, [user, model]); XCTAssertEqual(loaded.pendingCalls.map(\.call.id), ["one"])
        XCTAssertTrue(loaded.pendingCalls[0].claimed); XCTAssertEqual(loaded.usage.first?.promptTokens, 3)
        let result = ToolResultRecord(turnID: turn, callID: "one", outcome: .init(kind: .outcomeUnknown, content: "unknown"))
        let output = ModelInputItem.functionResult(callID: "one", output: result.outcome.modelContent)
        _ = try store.appendSync(.init(sessionID: id, turnID: turn, kind: .recovery, contextItems: [output], toolResults: [result]), expecting: 2)
        let compact = ModelInputItem.message(role: .user, content: [.text("summary")])
        _ = try store.appendSync(.init(sessionID: id, kind: .contextCompacted, contextItems: [user], snapshot: .init(items: [compact])), expecting: 3)
        let tail = ModelInputItem.message(role: .user, content: [.text("next")])
        _ = try store.appendSync(.init(sessionID: id, kind: .turnStarted, contextItems: [tail]), expecting: 4)
        let restored = try JSONLSessionStore(root: root, sessionID: id).loadContextSync(id)
        XCTAssertEqual(restored.items, [compact, tail]); XCTAssertTrue(restored.pendingCalls.isEmpty)
        XCTAssertEqual(try store.readTransactionsSync(id).count, 6)
        XCTAssertEqual(restored.callIDsByTurn[turn], ["one"])
    }
    func testIdempotencyRevisionAndTornTail() throws {
        let root = try directory(), id = UUID(), store = JSONLSessionStore(root: root, sessionID: id)
        let tx = SessionTransaction(sessionID: id, kind: .turnStarted, contextItems: [.message(role: .user, content: [.text("x")])])
        let receipt = try store.appendSync(tx, expecting: 0)
        XCTAssertEqual(try store.appendSync(tx, expecting: 0), receipt)
        var conflicting = tx; conflicting.metadata = .string("different")
        XCTAssertThrowsError(try store.appendSync(conflicting, expecting: 1)) { XCTAssertEqual($0 as? StoreError, .transactionConflict) }
        let history = root.appendingPathComponent("history.jsonl")
        let h = try FileHandle(forWritingTo: history); try h.seekToEnd(); try h.write(contentsOf: Data("{torn".utf8)); try h.close()
        let next = SessionTransaction(sessionID: id, kind: .turnStarted, contextItems: [.message(role: .user, content: [.text("y")])])
        XCTAssertThrowsError(try store.appendSync(next, expecting: 0)) { XCTAssertEqual($0 as? StoreError, .revisionConflict) }
        _ = try store.appendSync(next, expecting: 1)
        let loaded = try JSONLSessionStore(root: root, sessionID: id).loadContextSync(id)
        XCTAssertEqual(loaded.items.count, 2); XCTAssertEqual(loaded.sequence, 2)
    }
    func testSynchronizationFaultPermitsFollowupWithoutIndex() throws {
        final class Fault: @unchecked Sendable {
            let lock = NSLock(); var failSync = true
            func inject(_ point: StoreFaultPoint) throws { try lock.withLock {
                if point == .synchronize && failSync { failSync = false; throw StoreError.io("injected") }
                if point == .index { throw StoreError.io("index") }
            } }
        }
        let root = try directory(), id = UUID(), fault = Fault()
        let store = JSONLSessionStore(root: root, sessionID: id, faultInjector: { try fault.inject($0) })
        let tx = SessionTransaction(sessionID: id, kind: .turnStarted, contextItems: [.message(role: .user, content: [.text("x")])])
        XCTAssertThrowsError(try store.appendSync(tx, expecting: 0))
        XCTAssertEqual(try store.appendSync(tx, expecting: 0).sequence, 1)
        _ = try store.appendSync(.init(sessionID: id, kind: .turnStarted, contextItems: [.message(role: .user, content: [.text("y")])]), expecting: 1)
        XCTAssertEqual(try store.loadContextSync(id).items.count, 2)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("history.index").path))
    }
    func testLegacyMigrationInterruptedAfterHistoryAndCleanup() throws {
        final class Fault: @unchecked Sendable {
            let lock = NSLock(); var fail = true
            func inject(_ point: StoreFaultPoint) throws { try lock.withLock {
                if point == .migrationManifest && fail { fail = false; throw StoreError.io("injected") }
            } }
        }
        let root = try directory(), id = UUID(), old = Data("legacy source".utf8), fault = Fault()
        try old.write(to: root.appendingPathComponent("history.jsonl"))
        let store = JSONLSessionStore(root: root, sessionID: id, faultInjector: { try fault.inject($0) })
        let item = DisplayItem(role: "user", text: "old")
        func convert(_ source: Data) throws -> [SessionTransaction] {
            XCTAssertEqual(source, old)
            return [.init(sessionID: id, kind: .legacyImported, displayItems: [item])]
        }
        XCTAssertThrowsError(try store.migrateLegacySync(convert))
        try store.migrateLegacySync(convert)
        try store.migrateLegacySync { _ in XCTFail("committed migration must not reimport"); return [] }
        XCTAssertEqual(try store.readPageSync(.init(sessionID: id)).items.map(\.text), [item.text])
        let files = try FileManager.default.contentsOfDirectory(atPath: root.path)
        XCTAssertFalse(files.contains { $0.hasPrefix(".migration") }); XCTAssertFalse(files.contains("history.legacy-v1.jsonl"))
    }
    func testPresentationUpsertsAndPagination() throws {
        let root = try directory(), id = UUID(), store = JSONLSessionStore(root: root, sessionID: id)
        let a = DisplayItem(role: "user", text: "a"), b = DisplayItem(role: "assistant", text: "b"), c = DisplayItem(role: "user", text: "c")
        _ = try store.appendSync(.init(sessionID: id, kind: .presentationUpdated, displayItems: [a]), expecting: 0)
        _ = try store.appendSync(.init(sessionID: id, kind: .presentationUpdated, displayItems: [b]), expecting: 0)
        _ = try store.appendSync(.init(sessionID: id, kind: .presentationUpdated, displayItems: [c]), expecting: 0)
        var changed = b; changed.text = "edited"
        _ = try store.appendSync(.init(sessionID: id, kind: .presentationUpdated, displayItems: [changed], removedDisplayItemIDs: [a.id]), expecting: 0)
        let page = try store.readPageSync(.init(sessionID: id, limit: 1))
        XCTAssertEqual(page.items.map(\.text), [c.text]); XCTAssertEqual(page.nextBeforeSequence, 3)
        XCTAssertEqual(try store.readPageSync(.init(sessionID: id, beforeSequence: page.nextBeforeSequence, limit: 1)).items.map(\.text), [changed.text])
        XCTAssertEqual(try store.loadContextSync(id).revision, 0)
    }
    func testCorruptMiddlePreservesVerifiedPrefixAndRejectsAppend() throws {
        let root = try directory(), id = UUID(), store = JSONLSessionStore(root: root, sessionID: id)
        let first = DisplayItem(role: "user", text: "good")
        _ = try store.appendSync(.init(sessionID: id, kind: .presentationUpdated, displayItems: [first]), expecting: 0)
        let history = root.appendingPathComponent("history.jsonl")
        let h = try FileHandle(forWritingTo: history); try h.seekToEnd(); try h.write(contentsOf: Data("{bad}\n".utf8)); try h.close()
        let reopened = JSONLSessionStore(root: root, sessionID: id)
        let page = try reopened.readPageSync(.init(sessionID: id))
        XCTAssertEqual(page.items.map(\.text), [first.text]); XCTAssertTrue(page.integrityGap)
        XCTAssertThrowsError(try reopened.loadContextSync(id))
        XCTAssertThrowsError(try reopened.appendSync(.init(sessionID: id, kind: .presentationUpdated), expecting: 0))
    }
    func testBusyAndBlobFailureAreRecoverable() throws {
        final class Fault: @unchecked Sendable {
            let lock = NSLock(); var fail = true
            func inject(_ point: StoreFaultPoint) throws { try lock.withLock {
                if point == .blob && fail { fail = false; throw StoreError.io("blob") }
            } }
        }
        let root = try directory(), id = UUID(), fault = Fault()
        let store = JSONLSessionStore(root: root, sessionID: id, faultInjector: { try fault.inject($0) })
        let tx = SessionTransaction(sessionID: id, kind: .turnStarted, contextItems: [.message(role: .user, content: [.image(.init(data: Data([1]), mimeType: "image/png"))])])
        XCTAssertThrowsError(try store.appendSync(tx, expecting: 0))
        let lock = open(root.appendingPathComponent(".writer.lock").path, O_RDWR)
        XCTAssertGreaterThanOrEqual(lock, 0); XCTAssertEqual(flock(lock, LOCK_EX | LOCK_NB), 0)
        XCTAssertThrowsError(try store.appendSync(tx, expecting: 0)) { XCTAssertEqual($0 as? StoreError, .busy) }
        flock(lock, LOCK_UN); close(lock)
        _ = try store.appendSync(tx, expecting: 0)
        XCTAssertEqual(try store.loadContextSync(id).items.count, 1)
    }
    func testPresentationMetadataAndOriginalItemTimeSurviveUpdates() throws {
        let root = try directory(), id = UUID(), store = JSONLSessionStore(root: root, sessionID: id)
        let item = DisplayItem(role: "user", text: "first")
        let time = Date(timeIntervalSince1970: 12345)
        _ = try store.appendSync(.init(sessionID: id, kind: .presentationUpdated, createdAt: time, displayItems: [item], metadata: .string("app")), expecting: 0)
        var edited = item; edited.text = "edited"
        _ = try store.appendSync(.init(sessionID: id, kind: .requestPrepared, displayItems: [edited], metadata: .string("inference")), expecting: 0)
        let presentation = try store.presentationSync()
        XCTAssertEqual(presentation.metadata, .string("app")); XCTAssertEqual(presentation.items.first?.createdAt, time)
        XCTAssertEqual(presentation.items.first?.text, "edited")
    }
    func testMigrationResumesBeforeSourceCopy() throws {
        final class Fault: @unchecked Sendable {
            let lock = NSLock(); var fail = true
            func inject(_ point: StoreFaultPoint) throws { try lock.withLock {
                if point == .migrationSource && fail { fail = false; throw StoreError.io("source") }
            } }
        }
        let root = try directory(), id = UUID(), old = Data("legacy".utf8), fault = Fault()
        try old.write(to: root.appendingPathComponent("history.jsonl"))
        let store = JSONLSessionStore(root: root, sessionID: id, faultInjector: { try fault.inject($0) })
        let convert: (Data) throws -> [SessionTransaction] = { bytes in
            XCTAssertEqual(bytes, old)
            return [.init(sessionID: id, kind: .legacyImported, displayItems: [.init(role: "user", text: "old")])]
        }
        XCTAssertThrowsError(try store.migrateLegacySync(convert))
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("history.jsonl")), old)
        try store.migrateLegacySync(convert)
        XCTAssertEqual(try store.presentationSync().items.map(\.text), ["old"])
    }
    func testCanonicalAssistantCannotBeDowngradedAndMetadataMerges() throws {
        let root = try directory(), id = UUID(), store = JSONLSessionStore(root: root, sessionID: id)
        let itemID = UUID()
        let preview = DisplayItem(id: itemID, role: "assistant", text: "partial", state: "streaming", metadata: .object(["appMessage": .string("attachment"), "version": .number(1)]))
        let final = DisplayItem(id: itemID, role: "assistant", text: "complete", metadata: .object(["callID": .string("c"), "version": .number(2)]))
        _ = try store.appendPresentationSync(.init(sessionID: id, kind: .presentationUpdated, displayItems: [preview]))
        _ = try store.appendSync(.init(sessionID: id, kind: .modelOutput, displayItems: [final]), expecting: 0)
        _ = try store.appendPresentationSync(.init(sessionID: id, kind: .presentationUpdated, displayItems: [preview]))
        let item = try JSONLSessionStore(root: root, sessionID: id).presentationSync().items[0]
        XCTAssertEqual(item.text, "complete"); XCTAssertEqual(item.state, "complete")
        XCTAssertEqual(item.metadata, .object(["appMessage": .string("attachment"), "callID": .string("c"), "version": .number(1)]))
    }
    func testChunkedScanAndStablePagesAcrossReopen() throws {
        let root = try directory(), id = UUID(), store = JSONLSessionStore(root: root, sessionID: id)
        for index in 0..<400 {
            _ = try store.appendPresentationSync(.init(sessionID: id, kind: .presentationUpdated, displayItems: [.init(role: "user", text: "message \(index)")]))
        }
        let reopened = JSONLSessionStore(root: root, sessionID: id)
        let page = try reopened.readPageSync(.init(sessionID: id, limit: 20))
        XCTAssertEqual(page.items.map(\.text), (380..<400).map { "message \($0)" })
        let earlier = try reopened.readPageSync(.init(sessionID: id, beforeSequence: page.nextBeforeSequence, limit: 20))
        XCTAssertEqual(earlier.items.map(\.text), (360..<380).map { "message \($0)" })
    }
    func testContextHeadPersistsDeltaWithoutReplacingFacts() throws {
        let root = try directory(), id = UUID(), store = JSONLSessionStore(root: root, sessionID: id)
        let scope = ProviderScope(provider: "provider", endpoint: "https://example.com", account: "account", model: "model", session: id)
        let user = ModelInputItem.message(role: .user, content: [.text("hello")])
        let output = ModelInputItem.replay(.message(.init(id: "item", content: [.text("reply", annotations: [])])))
        _ = try store.appendSync(.init(sessionID: id, kind: .turnStarted, contextItems: [user]), expecting: 0)
        let head = ContextHead(epoch: UUID(), scope: scope, responseID: "response", coveredItemCount: 2)
        _ = try store.appendSync(.init(sessionID: id, kind: .modelOutput, contextItems: [output], contextHead: head), expecting: 1)
        let loaded = try JSONLSessionStore(root: root, sessionID: id).loadContextSync(id)
        XCTAssertEqual(loaded.items, [user, output]); XCTAssertEqual(loaded.snapshot?.head, "response")
        XCTAssertEqual(loaded.snapshot?.headCoveredItemCount, 2); XCTAssertEqual(loaded.revision, 2)
        let bad = ContextHead(epoch: UUID(), scope: scope, responseID: nil, coveredItemCount: 100)
        XCTAssertThrowsError(try store.appendSync(.init(sessionID: id, kind: .modelOutput, contextHead: bad), expecting: 2))
        XCTAssertEqual(try store.loadContextSync(id).revision, 2)
    }
    func testMissingCompactionRebuildsPriorBaseAndLaterTailWithoutOldHead() throws {
        let root = try directory(), id = UUID()
        let scope = ProviderScope(provider: "provider", endpoint: "https://example.com", account: "account", model: "model", session: id)
        let original = ModelInputItem.message(role: .user, content: [.text("original")])
        let summary = ModelInputItem.message(role: .user, content: [.text("summary")])
        let tail = ModelInputItem.message(role: .user, content: [.text("tail")])
        let old: [SessionTransaction] = [
            .init(sessionID: id, kind: .turnStarted, contextItems: [original]),
            .init(sessionID: id, kind: .contextCompacted, snapshot: .init(scope: scope, items: [summary])),
            .init(sessionID: id, kind: .turnStarted, contextItems: [tail], contextHead: .init(epoch: UUID(), scope: scope, responseID: "must-not-reuse", coveredItemCount: 2))]
        try LegacySessionFixtures.write(root: root, sessionID: id, transactions: old, missing: [1])
        let reopened = JSONLSessionStore(root: root, sessionID: id)
        try reopened.migrateLegacySync { _ in XCTFail("Envelope migration must not use UI converter"); return [] }
        let recovered = try reopened.loadContextSync(id)
        XCTAssertEqual(recovered.items, [original, tail]); XCTAssertTrue(recovered.recoveredCompactionMissing)
        XCTAssertNil(recovered.snapshot?.head); XCTAssertEqual(recovered.revision, 3)
        XCTAssertThrowsError(try reopened.readTransactionsSync(id))
        _ = try reopened.appendSync(.init(sessionID: id, kind: .recovery, snapshot: .init(scope: scope, items: recovered.items)), expecting: 3)
        let next = try reopened.loadContextSync(id)
        XCTAssertEqual(next.items, [original, tail]); XCTAssertFalse(next.recoveredCompactionMissing)
        XCTAssertNil(next.snapshot?.head)
    }
    func testImageBytesAreStoredOnceAcrossSnapshots() throws {
        let root = try directory(), id = UUID(), store = JSONLSessionStore(root: root, sessionID: id)
        let image = ModelImage(data: Data(repeating: 7, count: 1024), mimeType: "image/png")
        let item = ModelInputItem.message(role: .user, content: [.image(image)])
        _ = try store.appendSync(.init(sessionID: id, kind: .turnStarted, contextItems: [item]), expecting: 0)
        _ = try store.appendSync(.init(sessionID: id, kind: .contextCompacted, snapshot: .init(items: [item])), expecting: 1)
        let images = try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("attachments").path)
        XCTAssertEqual(images.count, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("blobs").path))
        XCTAssertEqual(try JSONLSessionStore(root: root, sessionID: id).loadContextSync(id).items, [item])
        let external = ModelImage(fileURL: URL(fileURLWithPath: "/tmp/untrusted-image"), mimeType: "image/png")
        let invalid = SessionTransaction(sessionID: id, kind: .turnStarted, contextItems: [.message(role: .user, content: [.image(external)])])
        XCTAssertThrowsError(try store.appendSync(invalid, expecting: 2)) { XCTAssertEqual($0 as? StoreError, .invalidPath) }
    }
    func testUsageCalibrationRestoresAndResetsAcrossEpochs() throws {
        let root = try directory(), id = UUID(), store = JSONLSessionStore(root: root, sessionID: id), epoch = UUID()
        let scope = ProviderScope(provider: "provider", endpoint: "https://example.com", account: "account", model: "model", session: id)
        let head = ContextHead(epoch: epoch, scope: scope, responseID: nil, coveredItemCount: 0)
        _ = try store.appendSync(.init(sessionID: id, kind: .modelOutput, usage: .init(promptTokens: 95), contextHead: head,
            metadata: .object(["requestEstimateTokens": .number(100), "contextEpoch": .string(epoch.uuidString)])), expecting: 0)
        let restored = try JSONLSessionStore(root: root, sessionID: id).loadContextSync(id)
        XCTAssertEqual(restored.lastInputTokens, 95); XCTAssertEqual(restored.lastInputEstimate, 100); XCTAssertEqual(restored.calibrationEpoch, epoch)
        _ = try store.appendSync(.init(sessionID: id, kind: .contextCompacted, snapshot: .init(epoch: UUID(), scope: scope, items: [])), expecting: 1)
        XCTAssertNil(try store.loadContextSync(id).lastInputTokens)
    }
    func testStalePresentationRemovalCannotEraseCoreFact() throws {
        let root = try directory(), id = UUID(), store = JSONLSessionStore(root: root, sessionID: id)
        let item = DisplayItem(role: "assistant", text: "complete")
        _ = try store.appendSync(.init(sessionID: id, kind: .modelOutput, displayItems: [item]), expecting: 0)
        _ = try store.appendPresentationSync(.init(sessionID: id, kind: .presentationUpdated, removedDisplayItemIDs: [item.id]))
        XCTAssertEqual(try JSONLSessionStore(root: root, sessionID: id).presentationSync().items.map(\.id), [item.id])
    }
    func testMissingCommittedHistoryCannotBeRecreatedAndRetryKeepsFacts() throws {
        let root = try directory(), id = UUID(), store = JSONLSessionStore(root: root, sessionID: id)
        _ = try store.appendSync(.init(sessionID: id, kind: .turnStarted,
            contextItems: [.message(role: .user, content: [.text("original")])]), expecting: 0)
        let history = root.appendingPathComponent("history.jsonl"), held = root.appendingPathComponent("held")
        try FileManager.default.moveItem(at: history, to: held)
        let next = SessionTransaction(sessionID: id, kind: .turnStarted, contextItems: [.message(role: .user, content: [.text("next")])])
        XCTAssertThrowsError(try store.appendSync(next, expecting: 1))
        XCTAssertFalse(FileManager.default.fileExists(atPath: history.path))
        try FileManager.default.moveItem(at: held, to: history)
        _ = try store.appendSync(next, expecting: 1)
        XCTAssertEqual(try store.loadContextSync(id).items.count, 2)
    }
}
