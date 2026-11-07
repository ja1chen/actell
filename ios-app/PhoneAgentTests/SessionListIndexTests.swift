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

    func testValidIndexLoadsLazilyAndDetectsEngineHistoryChanges() throws {
        let root = try root(), store = ConversationStore(directory: root), id = store.create(mode: .demo)
        let journal = ConversationJournal(directory: SessionStorageLayout(root: root).sessions)
        XCTAssertEqual(try journal.loadSummaries().map(\.id), [id])
        XCTAssertFalse(journal.isLoaded(id))
        let engine = try store.engineStore(for: id)
        _ = try engine.appendSync(.init(sessionID: id, kind: .modelOutput,
            displayItems: [.init(role: "assistant", text: "new runtime output")]), expecting: 0)
        let refreshed = ConversationJournal(directory: SessionStorageLayout(root: root).sessions)
        XCTAssertEqual(try refreshed.loadSummaries().first?.preview, "new runtime output")
        XCTAssertEqual(try refreshed.conversation(id).messages.last?.text, "new runtime output")
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
        let run = try XCTUnwrap(store.begin(in: first, query: "new preview"))
        store.finish(run, phase: .completed, summary: "")
        let updated = try SessionListIndex.read(from: index(root))
        XCTAssertEqual(updated.sessions.first?.id, first)
        XCTAssertEqual(updated.sessions.first?.preview, "new preview")
        XCTAssertEqual(updated.sessions.first?.phase, .completed)
        XCTAssertEqual(try Data(contentsOf: otherFile), otherData)
        XCTAssertFalse(FileManager.default.fileExists(atPath: otherFile.deletingLastPathComponent().appendingPathComponent("metadata.json").path))
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

    func testFailedIndexPublicationDoesNotBlockAuthoritativeChanges() throws {
        let root = try root(), store = ConversationStore(directory: root), id = store.create(mode: .demo)
        let file = try history(id, in: store), original = try Data(contentsOf: file)
        try FileManager.default.removeItem(at: index(root))
        try FileManager.default.createDirectory(at: index(root), withIntermediateDirectories: false)
        store.setDraft("retry", in: id); store.saveNow()
        let updated = try Data(contentsOf: file)
        XCTAssertTrue(updated.starts(with: original)); XCTAssertGreaterThan(updated.count, original.count)
        try FileManager.default.removeItem(at: index(root))
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
        XCTAssertEqual(reopened.conversations.map(\.id), [healthy])
        XCTAssertNil(reopened.conversation(broken)); XCTAssertNotNil(reopened.warning)
        XCTAssertFalse(reopened.canCleanAttachments)
        reopened.setDraft("healthy", in: healthy); reopened.saveNow(); reopened.delete(broken)
        XCTAssertEqual(try Data(contentsOf: file), damaged)
        XCTAssertTrue(FileManager.default.fileExists(atPath: index(root).path))
        XCTAssertEqual(ConversationStore(directory: root).conversation(healthy)?.draft, "healthy")
    }

    func testCorruptionAfterLazyConstructionReturnsPrefixAndDisablesAttachmentCleanup() throws {
        let root = try root(), original = ConversationStore(directory: root)
        let id = original.create(mode: .demo)
        let run = try XCTUnwrap(original.begin(in: id, query: "verified prefix"))
        original.finish(run, phase: .completed, summary: "")
        let file = try history(id, in: original)
        let reopened = ConversationStore(directory: root)
        XCTAssertNil(reopened.warning); XCTAssertTrue(reopened.canCleanAttachments)
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd(); try handle.write(contentsOf: Data("{unknown committed suffix}\n".utf8)); try handle.close()
        let damaged = try Data(contentsOf: file)

        XCTAssertEqual(reopened.conversation(id)?.messages.first?.text, "verified prefix")
        XCTAssertNotNil(reopened.warning)
        XCTAssertFalse(reopened.canCleanAttachments, "A readable prefix cannot prove the unknown suffix has no attachment references")
        _ = reopened.referencedAttachments
        reopened.delete(id)
        XCTAssertNotNil(reopened.conversation(id))
        XCTAssertEqual(try Data(contentsOf: file), damaged)
    }

    func testDeleteRechecksLazyAndPreviouslyLoadedHistoryBeforeRemovingSession() throws {
        for loaded in [false, true] {
            let root = try root(), store = ConversationStore(directory: root)
            let id = store.create(mode: .demo)
            let run = try XCTUnwrap(store.begin(in: id, query: "preserved"))
            store.finish(run, phase: .completed, summary: "")
            let file = try history(id, in: store), folder = file.deletingLastPathComponent()
            let journal = ConversationJournal(directory: SessionStorageLayout(root: root).sessions)
            XCTAssertEqual(try journal.loadSummaries().map(\.id), [id])
            XCTAssertFalse(journal.isLoaded(id))
            if loaded { _ = try journal.conversation(id) }
            let unknownAsset = folder.appendingPathComponent("attachments").appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: unknownAsset, withIntermediateDirectories: true)
            let originalAsset = Data("only the unreadable suffix may reference this resource".utf8)
            try originalAsset.write(to: unknownAsset.appendingPathComponent("original"))
            let handle = try FileHandle(forWritingTo: file)
            try handle.seekToEnd(); try handle.write(contentsOf: Data("{unreadable committed suffix}\n".utf8)); try handle.close()
            let damaged = try Data(contentsOf: file)

            XCTAssertThrowsError(try journal.delete(id)) { error in
                guard case ConversationJournal.Failure.unreadableConversation = error else { return XCTFail("Unexpected error: \(error)") }
            }
            XCTAssertTrue(journal.unreadableIDs.contains(id))
            XCTAssertEqual(try journal.conversation(id).messages.first?.text, "preserved")
            XCTAssertEqual(try Data(contentsOf: file), damaged)
            XCTAssertEqual(try Data(contentsOf: unknownAsset.appendingPathComponent("original")), originalAsset)
        }
    }

    func testDeleteDiscoveryAlsoDisablesAttachmentCleanupInConversationStore() throws {
        let root = try root(), store = ConversationStore(directory: root), id = store.create(mode: .demo)
        let file = try history(id, in: store)
        let reopened = ConversationStore(directory: root)
        XCTAssertTrue(reopened.canCleanAttachments)
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd(); try handle.write(contentsOf: Data("{unreadable committed suffix}\n".utf8)); try handle.close()
        let damaged = try Data(contentsOf: file)
        reopened.delete(id)
        XCTAssertNotNil(reopened.warning); XCTAssertFalse(reopened.canCleanAttachments)
        XCTAssertNotNil(reopened.conversation(id))
        XCTAssertEqual(try Data(contentsOf: file), damaged)
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
    func testOneStaleOrMalformedEntryRebuildsOnlyThatConversation() throws {
        for malformed in [false, true] {
            let root = try root(), store = ConversationStore(directory: root)
            let changed = store.create(mode: .demo), untouched = store.create(mode: .demo)
            if malformed {
                var object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: index(root))) as? [String: Any])
                var rows = try XCTUnwrap(object["sessions"] as? [[String: Any]])
                let position = try XCTUnwrap(rows.firstIndex { $0["id"] as? String == changed.uuidString })
                rows[position]["directory"] = "../invalid-cache-path"
                object["sessions"] = rows
                try JSONSerialization.data(withJSONObject: object).write(to: index(root))
            } else {
                let engine = try store.engineStore(for: changed)
                _ = try engine.appendSync(.init(sessionID: changed, kind: .modelOutput, displayItems: [.init(role: "assistant", text: "changed runtime fact")]), expecting: 0)
            }
            let journal = ConversationJournal(directory: SessionStorageLayout(root: root).sessions)
            XCTAssertEqual(Set(try journal.loadSummaries().map(\.id)), [changed, untouched])
            XCTAssertTrue(journal.isLoaded(changed)); XCTAssertFalse(journal.isLoaded(untouched))
            XCTAssertFalse(FileManager.default.fileExists(atPath: try store.sessionDirectory(changed).appendingPathComponent("metadata.json").path))
        }
    }

    func testScalarNullAndMalformedCacheRowsCannotInvalidateHealthyLazyEntries() throws {
        let root = try root(), store = ConversationStore(directory: root)
        let changed = store.create(mode: .demo), untouched = store.create(mode: .demo)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: index(root))) as? [String: Any])
        var rows = try XCTUnwrap(object["sessions"] as? [[String: Any]])
        let position = try XCTUnwrap(rows.firstIndex { $0["id"] as? String == changed.uuidString })
        rows[position]["mode"] = ["invalid": true]
        object["sessions"] = rows.map { $0 as Any } + [NSNull(), "invalid scalar", 42, false]
        try JSONSerialization.data(withJSONObject: object).write(to: index(root))
        let journal = ConversationJournal(directory: SessionStorageLayout(root: root).sessions)
        XCTAssertEqual(Set(try journal.loadSummaries().map(\.id)), [changed, untouched])
        XCTAssertTrue(journal.isLoaded(changed)); XCTAssertFalse(journal.isLoaded(untouched))
    }

    func testStaleExistingStateDetectsCommittedCreateAndDeleteWithoutScanningUnchangedHistory() throws {
        let root = try root(), store = ConversationStore(directory: root)
        let removed = store.create(mode: .demo), untouched = store.create(mode: .demo)
        let stale = try Data(contentsOf: index(root))
        let added = store.create(mode: .demo)
        try FileManager.default.removeItem(at: store.sessionDirectory(removed))
        try stale.write(to: index(root))
        let journal = ConversationJournal(directory: SessionStorageLayout(root: root).sessions)
        XCTAssertEqual(Set(try journal.loadSummaries().map(\.id)), [untouched, added])
        XCTAssertFalse(journal.isLoaded(untouched)); XCTAssertTrue(journal.isLoaded(added))
        XCTAssertEqual(Set(try SessionListIndex.read(from: index(root)).sessions.map(\.id)), [untouched, added])
    }

    func testMissingCommittedHistoryNeverBecomesEmptyOnReopenOrOldStateUpgrade() throws {
        for version in [1, SessionListIndex.currentVersion] {
            let root = try root(), store = ConversationStore(directory: root)
            let missing = store.create(mode: .demo), healthy = store.create(mode: .demo)
            var cached = try SessionListIndex.read(from: index(root)); cached.version = version; try cached.write(to: index(root))
            let missingHistory = try history(missing, in: store)
            try FileManager.default.removeItem(at: missingHistory)
            let journal = ConversationJournal(directory: SessionStorageLayout(root: root).sessions)
            XCTAssertEqual(try journal.loadSummaries().map(\.id), [healthy])
            XCTAssertTrue(journal.unreadableIDs.contains(missing))
            XCTAssertThrowsError(try journal.engineStore(missing))
            XCTAssertThrowsError(try journal.save(AgentConversation(id: missing, mode: .demo)))
            XCTAssertFalse(FileManager.default.fileExists(atPath: missingHistory.path))
            let again = ConversationJournal(directory: SessionStorageLayout(root: root).sessions)
            _ = try again.loadSummaries()
            XCTAssertThrowsError(try again.engineStore(missing))
            XCTAssertFalse(FileManager.default.fileExists(atPath: missingHistory.path))
        }
    }

    func testOldDerivedStateRebuildsOnceAndRetiresOnlySessionSummary() throws {
        let root = try root(), store = ConversationStore(directory: root), id = store.create(mode: .demo)
        store.setDraft(String(repeating: "完整草稿", count: 400), in: id); store.saveNow()
        let folder = try store.sessionDirectory(id), retired = folder.appendingPathComponent("metadata.json")
        try Data("obsolete derived summary".utf8).write(to: retired)
        var cached = try SessionListIndex.read(from: index(root)); cached.version = 1; try cached.write(to: index(root))
        let journal = ConversationJournal(directory: SessionStorageLayout(root: root).sessions)
        _ = try journal.loadSummaries()
        XCTAssertTrue(journal.isLoaded(id)); XCTAssertFalse(FileManager.default.fileExists(atPath: retired.path))
        XCTAssertEqual(try journal.conversation(id).draft, String(repeating: "完整草稿", count: 400))
        XCTAssertEqual(try SessionListIndex.read(from: index(root)).version, SessionListIndex.currentVersion)
        let next = ConversationJournal(directory: SessionStorageLayout(root: root).sessions)
        _ = try next.loadSummaries(); XCTAssertFalse(next.isLoaded(id))
    }

    func testUpdatingLazySiriMetadataPreservesFullDraftAndAttachmentReferences() throws {
        let root = try root(), store = ConversationStore(directory: root)
        let text = String(repeating: "长任务", count: 600), command = SessionCommand(.prepare(text))
        let id = try store.prepare(command, task: text)
        let attachment = StoredAttachment(id: UUID(), conversationID: id, name: "local.txt", kind: .text, mimeType: "text/plain", byteCount: 1, digest: "synthetic")
        store.addDraftAttachment(attachment, in: id)
        let reopened = ConversationStore(directory: root)
        let provider = UUID(); reopened.selectProvider(provider, model: "preserved-model", in: id); reopened.saveNow()
        let restored = try XCTUnwrap(ConversationStore(directory: root).conversation(id))
        XCTAssertEqual(restored.draft, text); XCTAssertEqual(restored.draftAttachments, [attachment])
        XCTAssertEqual(restored.entry?.commandID, command.commandID); XCTAssertEqual(restored.providerID, provider)
        let state = String(decoding: try Data(contentsOf: index(root)), as: UTF8.self)
        XCTAssertFalse(state.contains(text)); XCTAssertFalse(state.contains(attachment.name))
    }

}
