import XCTest
import CryptoKit
@testable import PhoneAgent

@MainActor final class SessionStorageMigrationTests: XCTestCase {
    private struct Archive: Encodable { let version = 1; let conversations: [AgentConversation] }
    private func root() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }
    private func write<T: Encodable>(_ value: T, to file: URL) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(value).write(to: file)
    }
    private func checkpoint(_ id: UUID, call: String) -> RunCheckpoint {
        var checkpoint = RunCheckpoint(runID: UUID(), conversationID: id, generation: UUID())
        checkpoint.tools = [.init(callID: call, name: "tap", parameterSummary: "x=1", argumentDigest: "synthetic", delivery: .dispatching)]
        return checkpoint
    }
    private func attachment(_ data: Data, in id: UUID, root: URL) throws -> StoredAttachment {
        let attachment = StoredAttachment(id: UUID(), conversationID: id, name: "fixture.txt", kind: .text,
            mimeType: "text/plain", byteCount: data.count, digest: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined())
        let folder = root.appendingPathComponent("Attachments/\(id.uuidString)/\(attachment.id.uuidString)")
        try write(attachment, to: folder.appendingPathComponent("metadata.json"))
        try data.write(to: folder.appendingPathComponent("original"))
        return attachment
    }

    func testSeparateLegacyRootMigratesToDocumentsWithoutMovingOriginalsOrPromptingAgain() async throws {
        let sandbox = try root()
        let source = sandbox.appendingPathComponent("Library/Application Support/PhoneAgent")
        let documents = sandbox.appendingPathComponent("Documents")
        var conversation = AgentConversation(mode: .demo)
        let bytes = Data("original attachment".utf8)
        let asset = try attachment(bytes, in: conversation.id, root: source)
        conversation.messages = [ChatMessage(role: .user, text: "saved question", attachments: [asset])]
        let archive = source.appendingPathComponent("conversations-v1.json")
        try write(Archive(conversations: [conversation]), to: archive)
        let checkpoint = checkpoint(conversation.id, call: "unknown-delivery")
        let oldCheckpoint = source.appendingPathComponent("Sessions/\(conversation.id)/run-checkpoint-v1.json")
        try write(checkpoint, to: oldCheckpoint)
        let originalArchive = try Data(contentsOf: archive), originalCheckpoint = try Data(contentsOf: oldCheckpoint)

        let store = ConversationStore(directory: documents, legacyDirectory: source)
        XCTAssertTrue(store.migrationRequired)
        XCTAssertFalse(SessionStorageLayout(root: documents).isInstalled)
        await store.migrateLegacyHistory()
        XCTAssertNil(store.migrationError); XCTAssertFalse(store.migrationRequired)
        XCTAssertEqual(try Data(contentsOf: archive), originalArchive)
        XCTAssertEqual(try Data(contentsOf: oldCheckpoint), originalCheckpoint)
        let layout = SessionStorageLayout(root: documents)
        XCTAssertEqual(layout.stateFile, documents.appendingPathComponent("state.json"))
        XCTAssertEqual(try SessionListIndex.read(from: layout.stateFile).sessions.map(\.id), [conversation.id])
        let session = try store.sessionDirectory(conversation.id)
        XCTAssertEqual(session.deletingLastPathComponent(), layout.sessions)
        let restored = try await AttachmentStore(directory: documents).read(asset, conversationID: conversation.id)
        XCTAssertEqual(restored, bytes)
        try SessionRunCheckpointStore(sessions: store).save(checkpoint)
        for folder in [documents, layout.sessions, session, session.appendingPathComponent("attachments")] {
            XCTAssertNotEqual(try folder.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup, true)
        }

        try FileManager.default.removeItem(at: layout.stateFile)
        let reopened = ConversationStore(directory: documents, legacyDirectory: source)
        XCTAssertFalse(reopened.migrationRequired)
        XCTAssertEqual(reopened.conversation(conversation.id)?.messages.first?.attachments, [asset])
        XCTAssertTrue(FileManager.default.fileExists(atPath: layout.stateFile.path))
        reopened.clear()
        let empty = ConversationStore(directory: documents, legacyDirectory: source)
        XCTAssertFalse(empty.migrationRequired); XCTAssertTrue(empty.conversations.isEmpty)
        XCTAssertEqual(try Data(contentsOf: archive), originalArchive)
    }

    func testNewInstallDoesNotNeedLegacyDirectoryOrMigration() throws {
        let sandbox = try root(), documents = sandbox.appendingPathComponent("Documents")
        let source = sandbox.appendingPathComponent("absent-legacy")
        let store = ConversationStore(directory: documents, legacyDirectory: source)
        XCTAssertNil(store.warning); XCTAssertFalse(store.migrationRequired); XCTAssertTrue(store.storageReady)
        XCTAssertEqual(SessionStorageLayout.defaultRoot, URL.documentsDirectory)
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: documents.path)), ["sessions", "state.json"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
    }

    func testFailedCrossDirectoryMigrationDoesNotPublishStateBeforeRetry() async throws {
        let sandbox = try root(), source = sandbox.appendingPathComponent("legacy")
        let documents = sandbox.appendingPathComponent("Documents")
        let conversation = AgentConversation(mode: .demo)
        try write(Archive(conversations: [conversation]), to: source.appendingPathComponent("conversations-v1.json"))
        let damaged = source.appendingPathComponent("run-checkpoint-v1.json")
        try write(["broken": true], to: damaged)
        let store = ConversationStore(directory: documents, legacyDirectory: source)
        await store.migrateLegacyHistory()
        XCTAssertTrue(store.migrationRequired); XCTAssertNotNil(store.migrationError)
        let layout = SessionStorageLayout(root: documents)
        XCTAssertFalse(layout.isInstalled)
        XCTAssertFalse(FileManager.default.fileExists(atPath: layout.stateFile.path))
        try write(checkpoint(conversation.id, call: "restored"), to: damaged)
        await store.migrateLegacyHistory()
        XCTAssertFalse(store.migrationRequired); XCTAssertNil(store.migrationError)
        XCTAssertEqual(try SessionListIndex.read(from: layout.stateFile).sessions.map(\.id), [conversation.id])
    }

    func testOneMigrationGroupsRootAndScopedCheckpointsWithHistoryAndAttachments() async throws {
        let root = try root()
        var first = AgentConversation(mode: .live), second = AgentConversation(mode: .demo)
        first.createdAt = ISO8601DateFormatter().date(from: "2025-01-02T23:30:00Z")!
        second.createdAt = ISO8601DateFormatter().date(from: "2025-02-03T00:30:00Z")!
        let bytes = Data("saved original".utf8), asset = try attachment(bytes, in: first.id, root: root)
        first.messages = [ChatMessage(role: .user, text: "question", attachments: [asset])]
        let rootRun = checkpoint(first.id, call: "root-action"), scopedRun = checkpoint(second.id, call: "scoped-action")
        let previousSecond = checkpoint(second.id, call: "older-root-recovery")
        try write(Archive(conversations: [first, second]), to: root.appendingPathComponent("conversations-v1.json"))
        try write(rootRun, to: root.appendingPathComponent("run-checkpoint-v1.json"))
        try write([previousSecond], to: root.appendingPathComponent("run-recovery-v1.json"))
        let scoped = root.appendingPathComponent("Sessions/\(second.id.uuidString)")
        try write(scopedRun, to: scoped.appendingPathComponent("run-checkpoint-v1.json"))
        try write([scopedRun], to: scoped.appendingPathComponent("run-recovery-v1.json"))
        let originalArchive = try Data(contentsOf: root.appendingPathComponent("conversations-v1.json"))
        let originalRootRun = try Data(contentsOf: root.appendingPathComponent("run-checkpoint-v1.json"))
        let originalScopedRun = try Data(contentsOf: scoped.appendingPathComponent("run-checkpoint-v1.json"))

        let store = ConversationStore(directory: root)
        XCTAssertTrue(store.migrationRequired)
        let routed = SessionRunCheckpointStore(sessions: store)
        XCTAssertTrue(try routed.loadRecoveries().isEmpty)
        XCTAssertThrowsError(try routed.save(rootRun))
        await store.migrateLegacyHistory()
        XCTAssertNil(store.migrationError); XCTAssertFalse(store.migrationRequired)
        let firstDirectory = try store.sessionDirectory(first.id), secondDirectory = try store.sessionDirectory(second.id)
        XCTAssertEqual(firstDirectory.lastPathComponent, "2025-01-02_\(first.id.uuidString)")
        XCTAssertEqual(secondDirectory.lastPathComponent, "2025-02-03_\(second.id.uuidString)")
        for folder in [firstDirectory, secondDirectory] {
            for file in ["history.jsonl", "run-checkpoint-v1.json", "run-recovery-v1.json"] {
                XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent(file).path))
            }
        }
        let attachments = AttachmentStore(directory: root)
        let restoredBytes = try await attachments.read(asset, conversationID: first.id)
        XCTAssertEqual(restoredBytes, bytes)
        let firstRecoveries = try SessionStorageMigration.readCheckpoints(in: firstDirectory)
        let secondRecoveries = try SessionStorageMigration.readCheckpoints(in: secondDirectory)
        XCTAssertTrue(firstRecoveries.allSatisfy { $0.conversationID == first.id })
        XCTAssertTrue(secondRecoveries.allSatisfy { $0.conversationID == second.id })
        XCTAssertEqual(Set(secondRecoveries.map(\.runID)), [scopedRun.runID, previousSecond.runID])
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("conversations-v1.json")), originalArchive)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("run-checkpoint-v1.json")), originalRootRun)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("legacy-sessions/\(second.id.uuidString)/run-checkpoint-v1.json")), originalScopedRun)
        let names = try FileManager.default.contentsOfDirectory(atPath: root.path)
        XCTAssertTrue(names.contains("sessions")); XCTAssertFalse(names.contains("Sessions"))

        let reopened = ConversationStore(directory: root)
        XCTAssertFalse(reopened.migrationRequired)
        XCTAssertEqual(reopened.conversation(first.id)?.messages.first?.attachments, [asset])
        let recoveries = try SessionRunCheckpointStore(sessions: reopened).loadRecoveries().map { $0.recovered() }
        XCTAssertTrue(recoveries.allSatisfy { $0.tools.first?.delivery == .outcomeUnknown })
        XCTAssertTrue(recoveries.allSatisfy { $0.pendingApproval == nil && $0.segmentID == nil })
        XCTAssertNil(reopened.activeRun)
        let next = checkpoint(first.id, call: "new-run")
        try routed.save(next)
        XCTAssertEqual(try JSONDecoder().decode(RunCheckpoint.self, from: Data(contentsOf: firstDirectory.appendingPathComponent("run-checkpoint-v1.json"))).runID, next.runID)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("run-checkpoint-v1.json")), originalRootRun)
        XCTAssertEqual(try SessionRunCheckpointStore(sessions: reopened, conversationID: second.id).loadRecoveries().map(\.conversationID), secondRecoveries.map(\.conversationID))
        store.delete(first.id)
        XCTAssertFalse(FileManager.default.fileExists(atPath: firstDirectory.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: secondDirectory.path))
    }

    func testCheckpointOnlyMigrationAndInterruptedCaseRenamePreserveOrphanedRuns() async throws {
        let root = try root(), id = UUID(), checkpoint = checkpoint(id, call: "orphaned")
        try write(checkpoint, to: root.appendingPathComponent("Sessions/\(id.uuidString)/run-checkpoint-v1.json"))
        try FileManager.default.moveItem(at: root.appendingPathComponent("Sessions"), to: root.appendingPathComponent("legacy-sessions"))
        try write(["incomplete": true], to: root.appendingPathComponent(".sessions-migration/partial.json"))
        let store = ConversationStore(directory: root)
        XCTAssertTrue(store.migrationRequired)
        await store.migrateLegacyHistory()
        XCTAssertNil(store.migrationError); XCTAssertFalse(store.migrationRequired)
        XCTAssertTrue(store.conversations.isEmpty)
        let folder = try SessionStorageLayout(root: root).directory(for: id)
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent("history.jsonl").path))
        let recovered = try SessionRunCheckpointStore(sessions: store).loadRecoveries()
        XCTAssertTrue(recovered.contains { $0.runID == checkpoint.runID && $0.tools.first?.callID == "orphaned" })
        XCTAssertFalse(ConversationStore(directory: root).migrationRequired)
    }

    func testCorruptCheckpointBlocksPublishAndCanRetryWithoutChangingOriginals() async throws {
        let root = try root(), conversation = AgentConversation(mode: .demo)
        try write(Archive(conversations: [conversation]), to: root.appendingPathComponent("conversations-v1.json"))
        let file = root.appendingPathComponent("Sessions/\(conversation.id.uuidString)/run-checkpoint-v1.json")
        try write(["broken": true], to: file)
        let original = try Data(contentsOf: file), store = ConversationStore(directory: root)
        await store.migrateLegacyHistory()
        XCTAssertTrue(store.migrationRequired); XCTAssertNotNil(store.migrationError)
        XCTAssertEqual(try Data(contentsOf: file), original)
        XCTAssertFalse(SessionStorageLayout(root: root).isInstalled)
        try write(checkpoint(conversation.id, call: "fixed"), to: file)
        await store.migrateLegacyHistory()
        XCTAssertFalse(store.migrationRequired); XCTAssertNil(store.migrationError)
    }

    func testCheckpointConversationMismatchIsNeverAssignedToAnotherSession() async throws {
        let root = try root(), conversation = AgentConversation(mode: .demo)
        try write(Archive(conversations: [conversation]), to: root.appendingPathComponent("conversations-v1.json"))
        try write(checkpoint(UUID(), call: "wrong-owner"), to: root.appendingPathComponent("Sessions/\(conversation.id.uuidString)/run-checkpoint-v1.json"))
        let store = ConversationStore(directory: root)
        await store.migrateLegacyHistory()
        XCTAssertTrue(store.migrationRequired); XCTAssertNotNil(store.migrationError)
        XCTAssertFalse(SessionStorageLayout(root: root).isInstalled)
    }

    func testStateProjectionLoadsOnlyRequestedHistoryAndRebuildsChangedLog() throws {
        let root = try root(), store = ConversationStore(directory: root)
        let first = store.create(mode: .demo), second = store.create(mode: .demo)
        store.addNotice("durable history", in: first)
        let stateFile = SessionStorageLayout(root: root).stateFile
        let oldState = try Data(contentsOf: stateFile)
        let journal = ConversationJournal(directory: SessionStorageLayout(root: root).sessions)
        let summaries = try journal.loadSummaries()
        XCTAssertEqual(summaries.count, 2)
        XCTAssertNil(summaries.first(where: { $0.id == second })?.cachedPreview)
        XCTAssertFalse(journal.isLoaded(first)); XCTAssertFalse(journal.isLoaded(second))
        XCTAssertEqual(try journal.conversation(first).messages.last?.text, "durable history")
        XCTAssertTrue(journal.isLoaded(first)); XCTAssertFalse(journal.isLoaded(second))
        store.addNotice("newer history", in: first)
        try oldState.write(to: stateFile)
        let refreshed = ConversationJournal(directory: SessionStorageLayout(root: root).sessions)
        _ = try refreshed.loadSummaries()
        XCTAssertTrue(refreshed.isLoaded(first)); XCTAssertFalse(refreshed.isLoaded(second))
        XCTAssertEqual(try refreshed.conversation(first).messages.count, 2)
        try FileManager.default.removeItem(at: stateFile)
        let rebuilt = ConversationStore(directory: root)
        XCTAssertEqual(rebuilt.conversation(first)?.messages.count, 2)
        XCTAssertFalse(FileManager.default.fileExists(atPath: try rebuilt.sessionDirectory(first).appendingPathComponent("metadata.json").path))
        rebuilt.setDraft("loaded before saving", in: second); rebuilt.saveNow()
        XCTAssertEqual(ConversationStore(directory: root).conversation(first)?.messages.count, 2)
        XCTAssertEqual(ConversationStore(directory: root).conversation(second)?.draft, "loaded before saving")
    }

    func testDatedDirectoryDoesNotChangeAfterUpdatesAndDraftAttachmentsStayTogether() async throws {
        let root = try root(), store = ConversationStore(directory: root)
        let draft = store.createDraft(mode: .demo), folder = try store.sessionDirectory(draft)
        let attachmentStore = AttachmentStore(directory: root)
        let asset = try await attachmentStore.store(Data("draft".utf8), name: "draft.txt", conversationID: draft)
        store.addDraftAttachment(asset, in: draft)
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent("history.jsonl").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent("attachments/\(asset.id.uuidString)/original").path))
        let run = try XCTUnwrap(store.begin(in: draft, query: "first message", attachments: [asset]))
        store.finish(run, phase: .completed, summary: "")
        XCTAssertEqual(try store.sessionDirectory(draft), folder)
        let otherDate = Date(timeIntervalSince1970: 0)
        XCTAssertEqual(try SessionStorageLayout(root: root).ensureDirectory(for: draft, createdAt: otherDate), folder)
        XCTAssertEqual(ConversationStore(directory: root).conversation(draft)?.messages.first?.attachments, [asset])
        store.delete(draft)
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path))
    }
}
