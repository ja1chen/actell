import XCTest
import AgentKit
import ProviderCore
@testable import PhoneAgent

private final class ArchiveMigrationCaptureProvider: ModelProvider, @unchecked Sendable {
    static let name = "archive-migration-fixture"
    let configuration = ProviderConfiguration(name: name, baseURL: URL(string: "https://invalid.invalid")!, defaultModel: "fixture")
    private let lock = NSLock()
    private var recorded: [ModelInputItem] = []
    var input: [ModelInputItem] { lock.withLock { recorded } }
    func complete(_ request: ModelRequest) async throws -> ModelResponse { throw ModelError.interrupted }
    func stream(_ request: ModelRequest) -> AsyncThrowingStream<ModelEvent, Error> {
        lock.withLock { recorded = request.input ?? [] }
        return AsyncThrowingStream { continuation in
            continuation.yield(.terminal(.init(id: "fixture-response", model: "fixture", status: .completed,
                output: [.message(.init(id: "fixture-message", content: [.text("continued", annotations: [])]))],
                request: request, providerName: Self.name)))
            continuation.finish()
        }
    }
}
private actor ArchiveMigrationEffects {
    private(set) var calls = 0
    func record() { calls += 1 }
}

@MainActor final class AgentSessionPersistenceTests: XCTestCase {
    private struct LegacyArchive: Encodable { var version = 1; var conversations: [AgentConversation] }
    private struct LegacyRecord: Encodable {
        var version = 1
        var metadata: AgentConversation
        var messages: [ChatMessage]
        var removedMessageIDs: [UUID] = []
    }
    private func directory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try ConversationJournal.install([], in: root)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }
    func testLegacyKnownToolsAreFactsIncompleteToolsArePortableAndNeverPending() throws {
        let root = try directory(), layout = SessionStorageLayout(root: root)
        let journal = ConversationJournal(directory: layout.sessions)
        var conversation = AgentConversation(mode: .demo)
        let call = ToolStep(callID: "call-1", name: "tap", state: .succeeded, detail: "", result: "done", arguments: "{\"x\":1}")
        let incomplete = ToolStep(callID: "call-2", name: "tap", state: .executing, detail: "", arguments: nil)
        let messages = [ChatMessage(role: .user, text: "question"), ChatMessage(role: .tool, text: "", tool: call),
                        ChatMessage(role: .tool, text: "", tool: incomplete), ChatMessage(role: .assistant, text: "answer")]
        let folder = try layout.ensureDirectory(for: conversation.id, createdAt: conversation.createdAt)
        conversation.messages = []
        var data = try JSONEncoder().encode(LegacyRecord(metadata: conversation, messages: messages)); data.append(10)
        data.append(Data("{incomplete".utf8))
        try data.write(to: folder.appendingPathComponent("history.jsonl"))
        let loaded = try journal.load()
        XCTAssertEqual(loaded.first?.messages.map(\.id), messages.map(\.id)); XCTAssertTrue(journal.recoveredTail)
        let context = try journal.engineStore(conversation.id).loadContextSync(conversation.id)
        XCTAssertTrue(context.pendingCalls.isEmpty)
        XCTAssertTrue(context.items.contains { if case .replay(.functionCall(let call)) = $0 { return call.id == "call-1" }; return false })
        XCTAssertTrue(context.items.contains { if case .functionResult(let id, let output) = $0 { return id == "call-1" && output == "done" }; return false })
        XCTAssertFalse(context.items.contains { if case .replay(.functionCall(let call)) = $0 { return call.id == "call-2" }; return false })
        XCTAssertTrue(context.items.contains { if case .message(.assistant, let parts) = $0, case .text(let text)? = parts.first { return text.contains("call-2") && text.contains("unavailable") }; return false })
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: folder.path).contains { $0.hasPrefix(".migration") })
    }
    func testStaleAppSaveCannotEraseCoreOutputAndReloadFindsNewOutput() throws {
        let root = try directory(), layout = SessionStorageLayout(root: root)
        let journal = ConversationJournal(directory: layout.sessions)
        var stale = AgentConversation(mode: .demo)
        stale.messages = [ChatMessage(role: .user, text: "question")]
        try journal.save(stale)
        let store = try journal.engineStore(stale.id), outputID = UUID()
        _ = try store.appendSync(.init(sessionID: stale.id, kind: .modelOutput,
            displayItems: [.init(id: outputID, role: "assistant", text: "answer")]), expecting: 0)
        stale.title = "updated"
        try journal.save(stale)
        let reopened = ConversationJournal(directory: layout.sessions)
        let restored = try XCTUnwrap(try reopened.load().first)
        XCTAssertEqual(restored.messages.map(\.id), [stale.messages[0].id, outputID])
        XCTAssertEqual(restored.messages.last?.text, "answer")
    }
    func testExistingToolImagesRestorePreviewWithoutAppAttachmentMetadata() async throws {
        let root = try directory(), sessions = ConversationStore(directory: root)
        let id = sessions.create(mode: .demo), turn = UUID()
        let frame = try await DemoBridge().screenshot()
        var image = ModelImage(data: frame.png, mimeType: frame.mimeType)
        image.width = frame.width; image.height = frame.height
        let call = ToolInvocation(sessionID: id, turnID: turn, call: .init(id: "screen", name: "screenshot", arguments: "{}"))
        let engine = try sessions.engineStore(for: id)
        _ = try engine.appendSync(.init(sessionID: id, turnID: turn, kind: .toolResult,
            displayItems: [.init(id: call.displayItemID, turnID: turn, role: "tool", text: "screen captured",
                metadata: .object(["callID": .string(call.callID), "name": .string(call.name), "outcome": .string("returned")]))],
            toolResults: [.init(turnID: turn, callID: call.callID, outcome: .init(content: "screen captured", images: [image]))]), expecting: 0)
        let before = try Data(contentsOf: sessions.sessionDirectory(id).appendingPathComponent("history.jsonl"))
        let restored = ConversationStore(directory: root)
        let message = try XCTUnwrap(restored.conversation(id)?.messages.first { $0.id == call.displayItemID })
        let attachment = try XCTUnwrap(message.attachments?.first)
        let original = try await AttachmentStore(directory: root).read(attachment, conversationID: id)
        XCTAssertEqual(original, frame.png)
        XCTAssertEqual(try Data(contentsOf: sessions.sessionDirectory(id).appendingPathComponent("history.jsonl")), before)
        XCTAssertTrue(try engine.loadContextSync(id).pendingCalls.isEmpty)
    }
    func testCorruptCommittedSuffixStillShowsVerifiedPrefix() throws {
        let root = try directory(), layout = SessionStorageLayout(root: root)
        let journal = ConversationJournal(directory: layout.sessions)
        var conversation = AgentConversation(mode: .demo)
        conversation.messages = [ChatMessage(role: .user, text: "readable")]
        try journal.save(conversation)
        let folder = try layout.directory(for: conversation.id)
        let handle = try FileHandle(forWritingTo: folder.appendingPathComponent("history.jsonl"))
        try handle.seekToEnd(); try handle.write(contentsOf: Data("{bad}\n".utf8)); try handle.close()
        let reopened = ConversationJournal(directory: layout.sessions)
        XCTAssertEqual(try reopened.load().first?.messages.first?.text, "readable")
        XCTAssertTrue(reopened.unreadableIDs.contains(conversation.id))
        conversation.title = "change"
        XCTAssertThrowsError(try reopened.save(conversation))
    }
    func testUserRecoveryCreatesSeparateSafeSessionAndPreservesOldFiles() async throws {
        let root = try directory(), layout = SessionStorageLayout(root: root)
        let journal = ConversationJournal(directory: layout.sessions)
        var source = AgentConversation(mode: .demo)
        source.providerID = UUID(); source.modelID = "old-model"; source.draft = "unsent"
        source.messages = [ChatMessage(role: .user, text: "question"),
            ChatMessage(role: .tool, text: "", tool: ToolStep(callID: "old-call", name: "tap", state: .executing, detail: ""))]
        try journal.save(source)
        let attachments = AttachmentStore(directory: root)
        let attachment = try await attachments.store(Data("hello".utf8), name: "note.txt", conversationID: source.id)
        source.messages[0].attachments = [attachment]; try journal.save(source)
        let folder = try layout.directory(for: source.id), history = folder.appendingPathComponent("history.jsonl")
        let handle = try FileHandle(forWritingTo: history)
        try handle.seekToEnd(); try handle.write(contentsOf: Data("{broken}\n".utf8)); try handle.close()
        let original = try Data(contentsOf: history)
        let store = ConversationStore(directory: root)
        XCTAssertTrue(store.hasRecoverableHistory(source.id))
        let newID = try await store.recoverReadableHistory(source.id)
        XCTAssertNotEqual(newID, source.id); XCTAssertEqual(try Data(contentsOf: history), original)
        let recovered = try XCTUnwrap(store.conversation(newID))
        XCTAssertNil(recovered.providerID); XCTAssertNil(recovered.modelID); XCTAssertTrue(recovered.draft.isEmpty); XCTAssertNil(recovered.entry)
        XCTAssertTrue(recovered.messages.allSatisfy { $0.runID == nil })
        XCTAssertEqual(recovered.messages.last?.tool?.state, .outcomeUnknown)
        let copied = try XCTUnwrap(recovered.messages.first?.attachments?.first)
        XCTAssertEqual(copied.conversationID, newID)
        let copiedBytes = try await attachments.read(copied, conversationID: newID)
        XCTAssertEqual(copiedBytes, Data("hello".utf8))
        let context = try store.engineStore(for: newID).loadContextSync(newID)
        XCTAssertTrue(context.pendingCalls.isEmpty)
        XCTAssertFalse(context.items.contains { if case .replay(.functionCall) = $0 { return true }; return false })
        XCTAssertTrue(context.items.contains { if case .message(.assistant, let parts) = $0, case .text(let value)? = parts.first { return value.contains("history has a gap") }; return false })
    }
    func testInvalidOptionalAppMetadataUsesVerifiedIdentityAndReadableDisplay() throws {
        let root = try directory(), layout = SessionStorageLayout(root: root), id = UUID()
        let folder = try layout.ensureDirectory(for: id, createdAt: Date())
        let store = JSONLSessionStore(root: folder, sessionID: id)
        _ = try store.appendPresentationSync(.init(sessionID: id, kind: .presentationUpdated,
            displayItems: [.init(role: "user", text: "verified text", metadata: .object(["appMessage": .string("invalid")]))],
            metadata: .object(["appConversation": .string("invalid")])))
        let journal = ConversationJournal(directory: layout.sessions)
        let conversation = try XCTUnwrap(try journal.load().first)
        XCTAssertEqual(conversation.id, id); XCTAssertEqual(conversation.title, "verified text")
        XCTAssertEqual(conversation.messages.first?.text, "verified text")
        XCTAssertNil(conversation.providerID); XCTAssertNil(conversation.entry); XCTAssertTrue(conversation.draft.isEmpty)
    }

    func testOriginalArchiveMigratesDirectlyIntoRuntimeContextWithoutReplayingTools() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let legacy = root.appendingPathComponent("legacy", isDirectory: true)
        let documents = root.appendingPathComponent("documents", isDirectory: true)
        try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        var source = AgentConversation(mode: .demo)
        source.createdAt = Date(timeIntervalSince1970: 1_700_000_000)
        source.title = "Original history"
        source.messages = (0..<24).map { ChatMessage(role: .user, text: "archive-message-\($0)") }
        let oversizedInline = String(repeating: "large preserved message ", count: 8_000)
        source.messages.insert(ChatMessage(role: .user, text: oversizedInline), at: 8)
        source.messages.insert(ChatMessage(role: .tool, text: "", tool: ToolStep(callID: "historical-call", name: "tap", state: .succeeded,
            detail: "", result: "historical result", arguments: "{}")), at: 12)
        let archive = try JSONEncoder().encode(LegacyArchive(conversations: [source]))
        let archiveURL = legacy.appendingPathComponent("conversations-v1.json")
        try archive.write(to: archiveURL)
        let sessions = ConversationStore(directory: documents, legacyDirectory: legacy)
        XCTAssertTrue(sessions.migrationRequired)
        await sessions.migrateLegacyHistory()
        XCTAssertFalse(sessions.migrationRequired); XCTAssertNil(sessions.migrationError)
        XCTAssertEqual(try Data(contentsOf: archiveURL), archive)
        let folder = try sessions.sessionDirectory(source.id)
        XCTAssertEqual(folder.lastPathComponent, SessionStorageLayout.folderName(id: source.id, createdAt: source.createdAt))
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent("manifest.json").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent("metadata.json").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent("history.index").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent("blobs").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent("history.jsonl").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent("history.legacy-v1.jsonl").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent("agent").path))
        let store = try sessions.engineStore(for: source.id)
        let transactions = try store.readTransactionsSync(source.id)
        XCTAssertEqual(transactions.first?.kind, .legacyImported)
        XCTAssertGreaterThan(transactions.count, 2, "Archive imports must be batched rather than one duplicated payload")
        XCTAssertEqual(transactions.flatMap(\.displayItems).count, source.messages.count)
        let provider = ArchiveMigrationCaptureProvider(), effects = ArchiveMigrationEffects()
        let tool = ClosureTool(descriptor: .init(name: "tap", description: "fixture", parameters: .object(["type": .string("object")]), effect: .deviceMutation)) { _, _ in
            await effects.record(); return .init(content: "unexpected")
        }
        let runtime = AgentRuntime(store: store, provider: provider, configuration: .init(model: "fixture", budget: .init(planningTokens: 1_000_000)), tools: [tool])
        let turn = try await runtime.startTurn(in: source.id, input: .init(text: "new user message"))
        let result = await turn.result()
        XCTAssertEqual(result.status, .completed); XCTAssertEqual(result.text, "continued")
        let sent = provider.input
        let texts = sent.flatMap { item -> [String] in
            guard case .message(_, let parts) = item else { return [] }
            return parts.compactMap { if case .text(let text) = $0 { return text }; return nil }
        }
        XCTAssertEqual(texts.filter { $0 == "archive-message-0" }.count, 1)
        XCTAssertEqual(texts.filter { $0 == "archive-message-23" }.count, 1)
        XCTAssertEqual(texts.filter { $0 == oversizedInline }.count, 1)
        XCTAssertEqual(texts.filter { $0 == "new user message" }.count, 1)
        XCTAssertTrue(sent.contains { if case .functionResult(let callID, let output) = $0 { return callID == "historical-call" && output == "historical result" }; return false })
        let count = await effects.calls
        XCTAssertEqual(count, 0, "Loading historical tool facts must never execute them")
    }

    func testInlineJournalKeepsFullDraftAndTextWithoutSessionSidecars() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ConversationStore(directory: root), id = store.create(mode: .demo)
        let draft = "INLINE_DRAFT_MARKER " + String(repeating: "长草稿", count: 500)
        store.setDraft(draft, in: id); store.addNotice("INLINE_FULL_TEXT_MARKER", in: id); store.saveNow()
        let folder = try store.sessionDirectory(id)
        let files = try FileManager.default.contentsOfDirectory(atPath: folder.path).filter { !$0.hasPrefix(".") }
        XCTAssertEqual(Set(files), ["history.jsonl"])
        let data = try Data(contentsOf: folder.appendingPathComponent("history.jsonl"))
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(text.contains("INLINE_DRAFT_MARKER")); XCTAssertTrue(text.contains("INLINE_FULL_TEXT_MARKER"))
        let restored = try XCTUnwrap(ConversationStore(directory: root).conversation(id))
        XCTAssertEqual(restored.draft, draft); XCTAssertEqual(restored.messages.last?.text, "INLINE_FULL_TEXT_MARKER")
    }

    func testArchiveMigrationRejectsForeignAttachmentBeforePublishingSessionTree() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let legacy = root.appendingPathComponent("legacy", isDirectory: true)
        let documents = root.appendingPathComponent("documents", isDirectory: true)
        try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        var source = AgentConversation(mode: .demo)
        let foreign = StoredAttachment(id: UUID(), conversationID: UUID(), name: "foreign.txt", kind: .text,
            mimeType: "text/plain", byteCount: 1, digest: "fixture")
        source.messages = [ChatMessage(role: .user, text: "kept", attachments: [foreign])]
        let archive = try JSONEncoder().encode(LegacyArchive(conversations: [source]))
        let archiveURL = legacy.appendingPathComponent("conversations-v1.json")
        try archive.write(to: archiveURL)
        let sessions = ConversationStore(directory: documents, legacyDirectory: legacy)
        await sessions.migrateLegacyHistory()
        XCTAssertTrue(sessions.migrationRequired); XCTAssertNotNil(sessions.migrationError)
        XCTAssertEqual(try Data(contentsOf: archiveURL), archive)
        XCTAssertFalse(SessionStorageLayout(root: documents).isInstalled)
        XCTAssertFalse(FileManager.default.fileExists(atPath: documents.appendingPathComponent("sessions").path))
    }

    func testLargeOriginalArchiveUsesBoundedTransactionsAndPreservesEveryMessage() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let legacy = root.appendingPathComponent("legacy", isDirectory: true)
        let documents = root.appendingPathComponent("documents", isDirectory: true)
        try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        var source = AgentConversation(mode: .demo)
        let body = String(repeating: "x", count: 2_000_000)
        source.messages = (0..<12).map { ChatMessage(role: .user, text: "\($0):" + body) }
        let archive = try JSONEncoder().encode(LegacyArchive(conversations: [source]))
        XCTAssertLessThan(archive.count, ConversationJournal.maximumBytes)
        var oldProjectionBytes = 0
        for message in source.messages {
            oldProjectionBytes += try JSONEncoder().encode(AgentSessionPersistence.display(message, legacy: true)).count
            oldProjectionBytes += try JSONEncoder().encode(message.text).count
        }
        XCTAssertGreaterThan(oldProjectionBytes, ConversationJournal.maximumBytes,
            "The former single payload would exceed the durable limit")
        let archiveURL = legacy.appendingPathComponent("conversations-v1.json")
        try archive.write(to: archiveURL)
        let sessions = ConversationStore(directory: documents, legacyDirectory: legacy)
        await sessions.migrateLegacyHistory()
        XCTAssertFalse(sessions.migrationRequired); XCTAssertNil(sessions.migrationError)
        let restored = try XCTUnwrap(sessions.conversation(source.id))
        XCTAssertEqual(restored.messages.map(\.text), source.messages.map(\.text))
        let store = try sessions.engineStore(for: source.id)
        let restoredContext = try store.loadContextSync(source.id)
        let texts = restoredContext.items.compactMap { item -> String? in
            guard case .message(.user, let parts) = item, case .text(let text)? = parts.first else { return nil }
            return text
        }
        XCTAssertEqual(texts, source.messages.map(\.text))
        let history = try Data(contentsOf: sessions.sessionDirectory(source.id).appendingPathComponent("history.jsonl"))
        for line in history.split(separator: 10) {
            XCTAssertNoThrow(try JSONSerialization.jsonObject(with: Data(line)))
            XCTAssertLessThan(line.count, 8 * 1_024 * 1_024, "Each oversized source message is isolated rather than combining the archive into one inline line")
        }
        let imported = try store.readTransactionsSync(source.id).filter { !$0.displayItems.isEmpty }
        XCTAssertEqual(imported.count, source.messages.count)
        XCTAssertTrue(imported.allSatisfy { $0.displayItems.count == 1 })
        XCTAssertEqual(try Data(contentsOf: archiveURL), archive)
    }
}
