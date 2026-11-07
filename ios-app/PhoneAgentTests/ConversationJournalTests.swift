import XCTest
import AgentKit
@testable import PhoneAgent

@MainActor final class ConversationJournalTests: XCTestCase {
    private struct Archive: Codable { var version = 1; var conversations: [AgentConversation] }
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
    private func file(_ id: UUID, in directory: URL) -> URL {
        directory.appendingPathComponent("sessions").appendingPathComponent(SessionStorageLayout.folderName(id: id, createdAt: Date())).appendingPathComponent("history.jsonl")
    }
    private func seed(_ conversations: [AgentConversation], in directory: URL) throws -> Data {
        let data = try JSONEncoder().encode(Archive(conversations: conversations))
        try data.write(to: directory.appendingPathComponent("conversations-v1.json"))
        return data
    }
    private func append(_ data: Data, to file: URL) throws {
        // A changed history fingerprint invalidates only this cached entry.
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        try handle.seekToEnd(); try handle.write(contentsOf: data)
    }

    func testAppendsOnlyChangedConversationAndMessages() throws {
        let directory = try directory(), store = ConversationStore(directory: directory)
        let first = store.create(mode: .live), second = store.create(mode: .demo)
        let run = try XCTUnwrap(store.begin(in: first, query: "question\nwith newline"))
        store.beginAssistantTurn(run); store.appendText("partial", identity: run); store.saveNow()
        let original = try Data(contentsOf: file(first, in: directory))
        let untouched = try Data(contentsOf: file(second, in: directory))
        let modified = try file(second, in: directory).resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        store.completeAssistantTurn("answer\n你好", reasoning: "public reasoning", identity: run)
        store.finish(run, phase: .completed, summary: "")
        let updated = try Data(contentsOf: file(first, in: directory))
        XCTAssertTrue(updated.starts(with: original))
        XCTAssertEqual(try Data(contentsOf: file(second, in: directory)), untouched)
        XCTAssertEqual(try file(second, in: directory).resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate, modified)
        let lines = updated.split(separator: 0x0A)
        for line in lines { XCTAssertNoThrow(try JSONSerialization.jsonObject(with: Data(line))) }
        let session = JSONLSessionStore(root: urlFolder(file(first, in: directory)), sessionID: first)
        let userMessages = try session.readTransactionsSync(first).flatMap(\.displayItems).filter { $0.role == "user" }
        XCTAssertEqual(userMessages.count, 1, "Unchanged messages are not appended again")
        let restored = try XCTUnwrap(ConversationStore(directory: directory).conversation(first))
        XCTAssertEqual(restored.messages.map(\.text), ["question\nwith newline", "answer\n你好"])
        XCTAssertEqual(restored.messages.last?.reasoning?.text, "public reasoning")
        store.saveNow()
        XCTAssertEqual(try Data(contentsOf: file(first, in: directory)), updated, "No-op saves do not append")
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("conversations-v1.json").path))
    }

    func testMigrationWaitsForUserPreservesReferencesAndDoesNotReimportDeletedHistory() async throws {
        let directory = try directory()
        var conversation = AgentConversation(mode: .live)
        conversation.title = "Saved history"; conversation.draft = "draft"; conversation.modelID = "model"
        conversation.providerID = UUID(); conversation.recoveryNotices = ["existing": "notice"]
        let attachment = StoredAttachment(id: UUID(), conversationID: conversation.id, name: "fixture.txt",
            kind: .text, mimeType: "text/plain", byteCount: 3, digest: "synthetic")
        conversation.draftAttachments = [attachment]
        conversation.messages = [ChatMessage(role: .assistant, text: "answer", attachments: [attachment],
            reasoning: ReasoningMessage(text: "thought", state: .complete))]
        let original = try seed([conversation], in: directory)
        let store = ConversationStore(directory: directory)
        XCTAssertTrue(store.migrationRequired); XCTAssertFalse(store.canCleanAttachments)
        XCTAssertNil(store.begin(in: conversation.id, query: "blocked before migration"))
        XCTAssertThrowsError(try store.prepare(SessionCommand(.prepare("new")), task: "new"))
        store.delete(conversation.id); store.clear(); store.saveNow()
        XCTAssertEqual(store.conversation(conversation.id), conversation)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file(conversation.id, in: directory).path))
        await store.migrateLegacyHistory()
        XCTAssertFalse(store.migrationRequired); XCTAssertNil(store.migrationError)
        XCTAssertEqual(ConversationStore(directory: directory).conversation(conversation.id), conversation)
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("conversations-v1.json")), original)
        store.delete(conversation.id)
        let restored = ConversationStore(directory: directory, legacy: [TaskRecord(goal: "older task", mode: .demo)])
        XCTAssertTrue(restored.conversations.isEmpty); XCTAssertFalse(restored.migrationRequired)
    }

    func testMigrationFailureAndAbandonedStagingCanBeRetried() async throws {
        let directory = try directory(), conversation = AgentConversation(mode: .demo)
        let original = try seed([conversation], in: directory)
        let store = ConversationStore(directory: directory)
        let staging = directory.appendingPathComponent(".sessions-migration")
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false)
        try Data("incomplete migration".utf8).write(to: staging.appendingPathComponent("partial.jsonl"))
        let destination = directory.appendingPathComponent("sessions")
        try Data("blocked destination".utf8).write(to: destination)
        await store.migrateLegacyHistory()
        XCTAssertTrue(store.migrationRequired); XCTAssertNotNil(store.migrationError)
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("conversations-v1.json")), original)
        XCTAssertEqual(store.conversation(conversation.id), conversation)
        try FileManager.default.removeItem(at: destination)
        await store.migrateLegacyHistory()
        XCTAssertFalse(store.migrationRequired); XCTAssertNil(store.migrationError)
        XCTAssertEqual(ConversationStore(directory: directory).conversation(conversation.id), conversation)
    }

    func testMigratedPendingToolsNeverResumeAndKeepUnknownDelivery() async throws {
        let directory = try directory()
        var conversation = AgentConversation(mode: .live)
        conversation.phase = .running
        conversation.messages = [ChatMessage(role: .assistant, text: "partial", state: .streaming,
            reasoning: ReasoningMessage(text: "partial thought")),
            ChatMessage(role: .tool, text: "", tool: ToolStep(callID: "tap", name: "tap", state: .executing, detail: ""))]
        _ = try seed([conversation], in: directory)
        let store = ConversationStore(directory: directory)
        await store.migrateLegacyHistory()
        let restored = ConversationStore(directory: directory)
        XCTAssertNil(restored.activeRun)
        XCTAssertEqual(restored.conversation(conversation.id)?.phase, .interrupted)
        XCTAssertEqual(restored.conversation(conversation.id)?.messages.first?.state, .interrupted)
        XCTAssertEqual(restored.conversation(conversation.id)?.messages.first?.reasoning?.state, .interrupted)
        XCTAssertEqual(restored.conversation(conversation.id)?.messages.last?.tool?.state, .outcomeUnknown)
    }

    func testMigrationRetryAdoptsAlreadyPublishedIdenticalDirectory() async throws {
        let directory = try directory(), conversation = AgentConversation(mode: .demo)
        _ = try seed([conversation], in: directory)
        let store = ConversationStore(directory: directory)
        try ConversationJournal.install(store.conversations, in: directory)
        await store.migrateLegacyHistory()
        XCTAssertFalse(store.migrationRequired); XCTAssertNil(store.migrationError)
        XCTAssertEqual(ConversationStore(directory: directory).conversation(conversation.id), conversation)
    }

    func testTornTailRecoversLastCommitAndNextSaveRepairsOnlyTail() throws {
        let directory = try directory(), store = ConversationStore(directory: directory)
        let id = store.create(mode: .demo)
        store.setDraft("saved draft", in: id); store.saveNow()
        let url = file(id, in: directory), original = try Data(contentsOf: url)
        try append(Data("{\"version\":1,\"metadata\":".utf8), to: url)
        let restored = ConversationStore(directory: directory)
        XCTAssertNotNil(restored.warning)
        XCTAssertEqual(restored.conversation(id)?.draft, "saved draft")
        restored.setDraft("new draft", in: id); restored.saveNow()
        let repaired = try Data(contentsOf: url)
        XCTAssertTrue(repaired.starts(with: original))
        XCTAssertEqual(ConversationStore(directory: directory).conversation(id)?.draft, "new draft")
        for line in repaired.split(separator: 0x0A) { XCTAssertNoThrow(try JSONSerialization.jsonObject(with: Data(line))) }
    }

    func testCorruptOrFutureConversationIsPreservedWithoutBlockingHealthyFiles() throws {
        for invalid in ["broken\n", "{\"version\":999}\n"] {
            let directory = try directory(), store = ConversationStore(directory: directory)
            let broken = store.create(mode: .demo), healthy = store.create(mode: .demo)
            try append(Data(invalid.utf8), to: file(broken, in: directory))
            let original = try Data(contentsOf: file(broken, in: directory))
            let restored = ConversationStore(directory: directory)
            XCTAssertNotNil(restored.warning); XCTAssertFalse(restored.canCleanAttachments)
            XCTAssertNotNil(restored.conversation(broken), "The verified prefix remains readable")
            XCTAssertNotNil(restored.conversation(healthy))
            restored.setDraft("must not overwrite damaged history", in: broken); restored.saveNow()
            restored.setDraft("still writable", in: healthy); restored.saveNow()
            let fresh = try restored.prepare(SessionCommand(.prepare("fresh")), task: "fresh")
            restored.delete(broken)
            XCTAssertEqual(try Data(contentsOf: file(broken, in: directory)), original)
            let again = ConversationStore(directory: directory)
            XCTAssertEqual(again.conversation(healthy)?.draft, "still writable")
            XCTAssertNotNil(again.conversation(fresh))
        }
    }

    func testEmptyLegacyArchiveMigratesOnceAndFutureArchiveIsNotOverwritten() async throws {
        let emptyDirectory = try directory()
        _ = try seed([], in: emptyDirectory)
        let emptyStore = ConversationStore(directory: emptyDirectory)
        XCTAssertTrue(emptyStore.migrationRequired)
        await emptyStore.migrateLegacyHistory()
        let reopened = ConversationStore(directory: emptyDirectory, legacy: [TaskRecord(goal: "not imported", mode: .demo)])
        XCTAssertFalse(reopened.migrationRequired); XCTAssertTrue(reopened.conversations.isEmpty)

        let futureDirectory = try directory()
        let original = try JSONEncoder().encode(Archive(version: 999, conversations: [AgentConversation(mode: .demo)]))
        let legacyFile = futureDirectory.appendingPathComponent("conversations-v1.json")
        try original.write(to: legacyFile)
        let futureStore = ConversationStore(directory: futureDirectory)
        XCTAssertNotNil(futureStore.warning); XCTAssertFalse(futureStore.migrationRequired)
        XCTAssertThrowsError(try futureStore.prepare(SessionCommand(.prepare("blocked")), task: "blocked"))
        await futureStore.migrateLegacyHistory()
        XCTAssertEqual(try Data(contentsOf: legacyFile), original)
    }

    func testFutureDirectoryFormatDoesNotFallBackToLegacyArchive() throws {
        let directory = try directory(), conversation = AgentConversation(mode: .demo)
        let original = try seed([conversation], in: directory)
        try ConversationJournal.install([], in: directory)
        let format = directory.appendingPathComponent("sessions/format.json")
        let future = Data("{\"version\":999}".utf8)
        try future.write(to: format)
        let store = ConversationStore(directory: directory)
        XCTAssertNotNil(store.warning); XCTAssertFalse(store.migrationRequired)
        XCTAssertTrue(store.conversations.isEmpty)
        XCTAssertThrowsError(try store.prepare(SessionCommand(.prepare("blocked")), task: "blocked"))
        XCTAssertEqual(try Data(contentsOf: format), future)
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("conversations-v1.json")), original)
    }

    func testFailedAppendKeepsDirtyConversationForRetry() throws {
        let directory = try directory(), store = ConversationStore(directory: directory)
        let id = store.create(mode: .demo), url = file(id, in: directory)
        let moved = url.appendingPathExtension("held")
        try FileManager.default.moveItem(at: url, to: moved)
        store.setDraft("retry me", in: id); store.saveNow()
        XCTAssertNotNil(store.warning); XCTAssertFalse(store.canCleanAttachments)
        try FileManager.default.moveItem(at: moved, to: url)
        store.saveNow()
        XCTAssertEqual(ConversationStore(directory: directory).conversation(id)?.draft, "retry me")
    }

    func testAppendOnlyHistoryAndMessageRemovalPreserveLatestState() throws {
        let directory = try directory()
        try ConversationJournal.install([], in: directory)
        let journal = ConversationJournal(directory: directory.appendingPathComponent("sessions"))
        var conversation = AgentConversation(mode: .demo)
        let removed = ChatMessage(role: .notice, text: "removed")
        conversation.messages = [removed, ChatMessage(role: .assistant, text: "", state: .streaming)]
        try journal.save(conversation)
        let initial = try Data(contentsOf: file(conversation.id, in: directory))
        for index in 0..<40 {
            conversation.messages[1].text = "\(index)" + String(repeating: "a", count: 80_000)
            try journal.save(conversation)
        }
        conversation.messages.removeFirst()
        conversation.messages[0].state = .complete
        try journal.save(conversation)
        let data = try Data(contentsOf: file(conversation.id, in: directory))
        XCTAssertTrue(data.starts(with: initial), "Committed history is never rewritten by presentation updates")
        let restored = ConversationJournal(directory: directory.appendingPathComponent("sessions"))
        XCTAssertEqual(try restored.load(), [conversation])
        XCTAssertFalse(String(decoding: data, as: UTF8.self).isEmpty)
    }

    private func urlFolder(_ file: URL) -> URL { file.deletingLastPathComponent() }

    func testDeletingOneConversationAndClearingDoNotRestoreFilesOnRelaunch() throws {
        let directory = try directory(), store = ConversationStore(directory: directory)
        let first = store.create(mode: .demo), second = store.create(mode: .demo)
        store.setDraft("pending", in: first)
        let original = try Data(contentsOf: file(second, in: directory))
        store.delete(first); store.saveNow()
        XCTAssertFalse(FileManager.default.fileExists(atPath: file(first, in: directory).path))
        XCTAssertEqual(try Data(contentsOf: file(second, in: directory)), original)
        XCTAssertEqual(ConversationStore(directory: directory).conversations.map(\.id), [second])
        store.clear()
        XCTAssertTrue(ConversationStore(directory: directory).conversations.isEmpty)
    }
}
