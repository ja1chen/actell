import XCTest
@testable import PhoneAgent

@MainActor final class SessionListIndexTests: XCTestCase {
    private func root() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }
    private func index(_ root: URL) -> URL { SessionStorageLayout(root: root).stateFile }
    private func history(_ id: UUID, in store: ConversationStore) throws -> URL {
        try store.sessionDirectory(id).appendingPathComponent("history.jsonl")
    }

    func testIndexIsBoundedAndExcludesFullDraftsAttachmentsAndMessages() throws {
        let root = try root(), store = ConversationStore(directory: root), id = store.create(mode: .demo)
        let fullText = String(repeating: "消息", count: 500)
        let run = try XCTUnwrap(store.begin(in: id, query: fullText))
        store.finish(run, phase: .completed, summary: "")
        store.setDraft("private composer text", in: id)
        let asset = StoredAttachment(id: UUID(), conversationID: id, name: "private attachment name", kind: .text,
            mimeType: "text/plain", byteCount: 1, digest: "fixture")
        store.addDraftAttachment(asset, in: id); store.saveNow()
        let data = try Data(contentsOf: index(root)), text = String(decoding: data, as: UTF8.self)
        let entry = try XCTUnwrap(SessionListIndex.read(from: index(root)).sessions.first)
        XCTAssertEqual(entry.id, id); XCTAssertEqual(entry.preview?.count, 200)
        XCTAssertEqual(entry.directory, try store.sessionDirectory(id).lastPathComponent)
        XCTAssertNil(entry.draftPreview)
        for excluded in [fullText, "private composer text", asset.name, "\"messages\"", "\"draftAttachments\"", "\"recoveryNotices\""] {
            XCTAssertFalse(text.contains(excluded))
        }
        let restored = try XCTUnwrap(ConversationStore(directory: root).conversation(id))
        XCTAssertEqual(restored.messages.first?.text, fullText)
        XCTAssertEqual(restored.draft, "private composer text"); XCTAssertEqual(restored.draftAttachments, [asset])
    }

    func testValidIndexLoadsListWithoutEnumeratingOrReadingSessionDirectories() throws {
        let root = try root(), store = ConversationStore(directory: root), id = store.create(mode: .demo)
        let folder = try store.sessionDirectory(id), held = root.appendingPathComponent("held")
        try FileManager.default.moveItem(at: folder, to: held)
        // Enumeration would reject this entry. A valid index must not enumerate,
        // stat per-session paths, or read their metadata/history to show the list.
        let sentinel = SessionStorageLayout(root: root).sessions.appendingPathComponent("enumeration-sentinel")
        try Data().write(to: sentinel)
        let journal = ConversationJournal(directory: SessionStorageLayout(root: root).sessions)
        XCTAssertEqual(try journal.loadSummaries().map(\.id), [id])
        XCTAssertFalse(journal.isLoaded(id))
        try FileManager.default.moveItem(at: held, to: folder)
        XCTAssertEqual(try journal.conversation(id).id, id)
        XCTAssertTrue(journal.isLoaded(id))
    }

    func testMissingCorruptFutureDuplicateAndInvalidPathIndexesRebuildWithoutMigration() throws {
        for kind in ["missing", "corrupt", "future", "duplicate", "path"] {
            let root = try root(), store = ConversationStore(directory: root), id = store.create(mode: .demo)
            store.setDraft("keep full draft", in: id); store.saveNow()
            let file = try history(id, in: store), original = try Data(contentsOf: file)
            var cached = try SessionListIndex.read(from: index(root))
            switch kind {
            case "missing": try FileManager.default.removeItem(at: index(root))
            case "corrupt": try Data("incomplete json".utf8).write(to: index(root))
            case "future": cached.version = 999; try cached.write(to: index(root))
            case "duplicate": cached.sessions += cached.sessions; try cached.write(to: index(root))
            default: cached.sessions[0].directory = "../outside"; try cached.write(to: index(root))
            }
            let reopened = ConversationStore(directory: root)
            XCTAssertFalse(reopened.migrationRequired, kind)
            XCTAssertEqual(reopened.conversations.map(\.id), [id], kind)
            XCTAssertEqual(reopened.conversation(id)?.draft, "keep full draft", kind)
            XCTAssertEqual(try SessionListIndex.read(from: index(root)).sessions.map(\.id), [id], kind)
            XCTAssertEqual(try Data(contentsOf: file), original, kind)
        }
    }

    func testUpdatingAndDeletingRefreshIndexWithoutRewritingOtherSessions() throws {
        let root = try root(), store = ConversationStore(directory: root)
        let first = store.create(mode: .demo), second = store.create(mode: .demo)
        let otherFile = try history(second, in: store), otherData = try Data(contentsOf: otherFile)
        let otherSummary = otherFile.deletingLastPathComponent().appendingPathComponent("metadata.json")
        let otherSummaryData = try Data(contentsOf: otherSummary)
        let run = try XCTUnwrap(store.begin(in: first, query: "new preview"))
        store.finish(run, phase: .completed, summary: "")
        let updated = try SessionListIndex.read(from: index(root))
        XCTAssertEqual(updated.sessions.first?.id, first)
        XCTAssertEqual(updated.sessions.first?.preview, "new preview")
        XCTAssertEqual(updated.sessions.first?.phase, .completed)
        XCTAssertEqual(try Data(contentsOf: otherFile), otherData)
        XCTAssertEqual(try Data(contentsOf: otherSummary), otherSummaryData)
        store.delete(first)
        XCTAssertEqual(try SessionListIndex.read(from: index(root)).sessions.map(\.id), [second])
        store.clear()
        XCTAssertTrue(try SessionListIndex.read(from: index(root)).sessions.isEmpty)
        XCTAssertTrue(ConversationStore(directory: root).conversations.isEmpty)
    }

    func testInterruptedIndexPublicationRebuildsCommittedCreatesAndDeletes() throws {
        let root = try root(), store = ConversationStore(directory: root)
        let removed = store.create(mode: .demo), surviving = store.create(mode: .demo)
        // Simulate an exit after a directory deletion but before index publication.
        try FileManager.default.removeItem(at: index(root))
        try FileManager.default.removeItem(at: store.sessionDirectory(removed))
        let reopened = ConversationStore(directory: root)
        XCTAssertEqual(reopened.conversations.map(\.id), [surviving])
        let added = reopened.create(mode: .demo)
        // The authoritative new history exists, but publishing the cache failed.
        try FileManager.default.removeItem(at: index(root))
        let again = ConversationStore(directory: root)
        XCTAssertEqual(Set(again.conversations.map(\.id)), [surviving, added])
        XCTAssertEqual(Set(try SessionListIndex.read(from: index(root)).sessions.map(\.id)), [surviving, added])
    }

    func testFailedInvalidationDoesNotModifyOrDeleteAuthoritativeHistory() throws {
        let root = try root(), store = ConversationStore(directory: root), id = store.create(mode: .demo)
        let file = try history(id, in: store), original = try Data(contentsOf: file)
        try FileManager.default.removeItem(at: index(root))
        try FileManager.default.createDirectory(at: index(root), withIntermediateDirectories: false)
        store.setDraft("retry", in: id); store.saveNow()
        XCTAssertNotNil(store.warning)
        XCTAssertEqual(try Data(contentsOf: file), original)
        store.delete(id)
        XCTAssertNotNil(store.conversation(id)); XCTAssertEqual(try Data(contentsOf: file), original)
        try FileManager.default.removeItem(at: index(root))
        store.saveNow()
        XCTAssertEqual(ConversationStore(directory: root).conversation(id)?.draft, "retry")
        store.delete(id)
        XCTAssertTrue(try SessionListIndex.read(from: index(root)).sessions.isEmpty)
    }

    func testLazyCorruptionDiscoveryPreservesFileAndDisablesAttachmentCleanup() throws {
        let root = try root(), store = ConversationStore(directory: root)
        let broken = store.create(mode: .demo), healthy = store.create(mode: .demo)
        let file = try history(broken, in: store), damaged = Data("damaged committed history\n".utf8)
        try damaged.write(to: file) // Simulate storage corruption after a valid cache was published.
        let reopened = ConversationStore(directory: root)
        XCTAssertEqual(reopened.conversations.count, 2)
        XCTAssertNil(reopened.conversation(broken)); XCTAssertNotNil(reopened.warning)
        XCTAssertFalse(reopened.canCleanAttachments)
        reopened.setDraft("healthy", in: healthy); reopened.saveNow(); reopened.delete(broken)
        XCTAssertEqual(try Data(contentsOf: file), damaged)
        XCTAssertFalse(FileManager.default.fileExists(atPath: index(root).path))
        XCTAssertEqual(ConversationStore(directory: root).conversation(healthy)?.draft, "healthy")
    }

    func testSiriIndexRetainsCommandRoutingButLoadsFullDraftBeforeUse() throws {
        let root = try root(), store = ConversationStore(directory: root)
        let task = String(repeating: "任务", count: 700), command = SessionCommand(.prepare(task))
        let id = try store.prepare(command, task: task)
        let cached = try XCTUnwrap(SessionListIndex.read(from: index(root)).sessions.first)
        XCTAssertEqual(cached.draftPreview?.count, 200)
        XCTAssertEqual(cached.entry?.commandID, command.commandID)
        XCTAssertEqual(cached.entry?.state, .pendingConfirmation)
        let reopened = ConversationStore(directory: root)
        XCTAssertEqual(reopened.conversations.first?.entry?.routePending, true)
        XCTAssertEqual(try reopened.prepare(command, task: task), id)
        XCTAssertEqual(reopened.conversations.count, 1)
        XCTAssertEqual(reopened.conversation(id)?.draft, task)
        try reopened.dismissPreparedTask(in: id)
        XCTAssertEqual(try SessionListIndex.read(from: index(root)).sessions.first?.entry?.state, .dismissed)
    }
}
