import Foundation
import Combine
import AgentKit
import ProviderCore

/// UI history contains public text, resource references, tool results
/// and explicit readable provider reasoning; no image bytes, opaque reasoning,
/// credentials or resumable tool queues.
@MainActor final class ConversationStore: ObservableObject {
    // Execution and persistence continue in background, but a hidden chat must
    // not rebuild its entire SwiftUI tree for every streamed reasoning fragment.
    private var records: [AgentConversation] = [] {
        willSet { if presentationActive && !loadingHistory { objectWillChange.send() } }
    }
    private var draftIDs: Set<UUID> = []
    private var unloadedIDs: Set<UUID> = []
    private var pendingRecoveries: [UUID: [RunCheckpoint]] = [:]
    private var loadingHistory = false
    /// Temporary composer drafts stay out of history and durable archives.
    var conversations: [AgentConversation] { records.filter { !draftIDs.contains($0.id) } }
    func isDraft(_ id: UUID) -> Bool { draftIDs.contains(id) }
    private var presentationActive = true
    @Published private(set) var activeRuns: [UUID: RunIdentity] = [:]
    var activeRun: RunIdentity? { activeRuns.values.first }
    @Published private(set) var warning: String?
    @Published private(set) var migrationRequired = false
    @Published private(set) var isMigrating = false
    @Published private(set) var migrationError: String?
    private let directory: URL?
    private let legacyDirectory: URL?
    var storageRoot: URL? { directory }
    var storageReady: Bool { canWrite && !migrationRequired }
    func sessionDirectory(_ id: UUID) throws -> URL {
        guard storageReady, let directory else { throw SessionCommandError.unavailableStorage }
        let layout = SessionStorageLayout(root: directory)
        if let record = records.first(where: { $0.id == id }) {
            return try layout.ensureDirectory(for: id, createdAt: record.createdAt)
        }
        return try layout.directory(for: id)
    }
    private var journal: ConversationJournal?
    private var ephemeralEngineStores: [UUID: JSONLSessionStore] = [:]
    private let ephemeralEngineRoot = FileManager.default.temporaryDirectory.appendingPathComponent("ActellAgent-" + UUID().uuidString)
    func engineStore(for id: UUID) throws -> JSONLSessionStore {
        saveNow()
        if let journal { return try journal.engineStore(id) }
        guard directory == nil, canWrite else { throw SessionCommandError.unavailableStorage }
        if let value = ephemeralEngineStores[id] { return value }
        let value = JSONLSessionStore(root: ephemeralEngineRoot.appendingPathComponent(id.uuidString), sessionID: id)
        if let conversation = conversation(id) {
            _ = try value.appendPresentationSync(SessionTransaction(sessionID: id, kind: .presentationUpdated,
                displayItems: try conversation.messages.map { try AgentSessionPersistence.display($0) },
                metadata: try AgentSessionPersistence.metadata(conversation)))
        }
        ephemeralEngineStores[id] = value
        return value
    }
    private var dirtyIDs: Set<UUID> = []
    private var historyFullyReadable = true
    var canCleanAttachments: Bool { historyFullyReadable && !migrationRequired && canWrite && dirtyIDs.isSubset(of: draftIDs) }
    private var canWrite = true
    private var saveTask: Task<Void, Never>?
    private struct Archive: Codable { var version = 1; var conversations: [AgentConversation] }

    init(directory: URL? = nil, legacyDirectory: URL? = nil, inMemory: Bool = false, legacy: [TaskRecord] = []) {
        self.legacyDirectory = legacyDirectory ?? directory ?? SessionStorageLayout.defaultLegacyRoot
        if inMemory { self.directory = nil; return }
        do {
            let folder = directory ?? SessionStorageLayout.defaultRoot
            try SessionStorageLayout.createProtectedDirectory(folder)
            self.directory = folder
        } catch { self.directory = nil; canWrite = false; warning = String(localized: "Conversations can only be kept in memory for now"); return }
        do {
            guard let directory = self.directory, let legacyDirectory = self.legacyDirectory else { return }
            let folder = directory.appendingPathComponent(ConversationJournal.directoryName, isDirectory: true)
            let legacyFile = legacyDirectory.appendingPathComponent("conversations-v1.json")
            if SessionStorageLayout(root: directory).isInstalled {
                let journal = ConversationJournal(directory: folder)
                records = try journal.loadSummaries(); self.journal = journal
                unloadedIDs = Set(records.filter { !journal.isLoaded($0.id) }.map(\.id))
                if !journal.unreadableIDs.isEmpty {
                    historyFullyReadable = false
                    warning = String(localized: "Some conversations could not be read. Their files have been kept. Other conversations can still be saved.")
                } else if journal.recoveredTail {
                    warning = String(localized: "An interrupted save was found. Conversations were restored through their last complete save.")
                }
            } else if FileManager.default.fileExists(atPath: legacyFile.path) {
                let size = try legacyFile.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                guard size <= ConversationJournal.maximumBytes else { throw ConversationJournal.Failure.tooLarge }
                let archive = try JSONDecoder().decode(Archive.self, from: Data(contentsOf: legacyFile))
                guard archive.version == 1, Set(archive.conversations.map(\.id)).count == archive.conversations.count else {
                    throw ConversationJournal.Failure.invalidFormat
                }
                records = archive.conversations
                migrationRequired = true; canWrite = false
            } else if !legacy.isEmpty {
                records = legacy.map { record in
                    var conversation = AgentConversation(mode: record.mode)
                    conversation.id = record.id; conversation.title = String(record.goal.prefix(48))
                    conversation.createdAt = record.receipts.first?.date ?? record.updatedAt
                    conversation.updatedAt = record.updatedAt
                    conversation.phase = record.phase
                    conversation.messages = [ChatMessage(role: .user, text: record.goal)]
                    conversation.messages += record.receipts.map { ChatMessage(role: .notice, text: $0.message, date: $0.date) }
                    if !record.result.isEmpty { conversation.messages.append(ChatMessage(role: .notice, text: String(localized: "Previous run result:\n\(record.result)"))) }
                    return conversation
                }
                migrationRequired = true; canWrite = false
            } else if try SessionStorageMigration.hasLegacyResources(in: legacyDirectory) {
                migrationRequired = true; canWrite = false
            } else {
                try ConversationJournal.install([], in: directory)
                journal = ConversationJournal(directory: folder)
            }
            for index in records.indices where !unloadedIDs.contains(records[index].id) {
                let previous = records[index]
                if [.running, .awaitingApproval].contains(records[index].phase) { records[index].phase = .interrupted }
                closePendingMessages(at: index)
                if previous != records[index] { dirtyIDs.insert(records[index].id) }
            }
            saveNow()
        } catch {
            canWrite = false; historyFullyReadable = false
            warning = String(localized: "Conversation history could not be read. The original file was kept. This conversation will not be saved to disk for now.")
        }
    }

    func migrateLegacyHistory() async {
        guard migrationRequired, !isMigrating, let directory, let legacyDirectory else { return }
        isMigrating = true; migrationError = nil
        defer { isMigrating = false }
        let snapshot = conversations
        do {
            let result = try await Task.detached(priority: .userInitiated) {
                try SessionStorageMigration.install(snapshot, in: directory, legacyRoot: legacyDirectory)
            }.value
            let journal = ConversationJournal(directory: directory.appendingPathComponent(ConversationJournal.directoryName))
            _ = try journal.loadSummaries()
            guard journal.unreadableIDs.isEmpty else { throw ConversationJournal.Failure.invalidFormat }
            let layout = SessionStorageLayout(root: directory)
            let recoveries = try conversations.flatMap {
                try SessionStorageMigration.readCheckpoints(in: layout.directory(for: $0.id))
            }
            self.journal = journal
            canWrite = true; migrationRequired = false
            if result.unavailableAttachments {
                warning = String(localized: "Some saved attachments are missing or damaged. Their references and any existing files were kept.")
            }
            for saved in recoveries { reconcileRecovery(saved.recovered()) }
            // Include any recovery reconciliation that arrived while migration ran.
            dirtyIDs.formUnion(conversations.map(\.id)); saveNow()
        } catch {
            migrationError = String(localized: "History could not be migrated. Your original data is unchanged. Check available storage and try again.")
        }
    }

    func conversation(_ id: UUID) -> AgentConversation? {
        guard let index = index(id) else { return nil }
        return records[index]
    }
    private func loadHistory(_ id: UUID) {
        guard unloadedIDs.contains(id), let journal, let position = records.firstIndex(where: { $0.id == id }) else { return }
        loadingHistory = true
        defer { loadingHistory = false }
        do {
            records[position] = try journal.conversation(id)
            unloadedIDs.remove(id)
            if !journal.unreadableIDs.isEmpty {
                historyFullyReadable = false
                warning = String(localized: "Some conversations could not be read. Their files have been kept. Other conversations can still be saved.")
            } else if journal.recoveredTail {
                warning = String(localized: "An interrupted save was found. Conversations were restored through their last complete save.")
            }
            let previous = records[position]
            if [.running, .awaitingApproval].contains(records[position].phase) { records[position].phase = .interrupted }
            closePendingMessages(at: position)
            if previous != records[position] { dirtyIDs.insert(id) }
            for checkpoint in pendingRecoveries.removeValue(forKey: id) ?? [] { reconcileTools(checkpoint) }
            saveNow()
        } catch {
            historyFullyReadable = false
            warning = String(localized: "Some conversations could not be read. Their files have been kept. Other conversations can still be saved.")
        }
    }
    func setPresentationActive(_ active: Bool) {
        guard active != presentationActive else { return }
        presentationActive = active
        if active { objectWillChange.send() }
    }
    var referencedAttachments: [StoredAttachment] {
        for id in Array(unloadedIDs) { loadHistory(id) }
        return records.flatMap { ($0.draftAttachments ?? []) + $0.messages.flatMap { $0.attachments ?? [] } }
    }
    func attach(_ attachment: StoredAttachment, to messageID: UUID, in conversationID: UUID) {
        guard attachment.conversationID == conversationID, let index = index(conversationID),
              let message = records[index].messages.firstIndex(where: { $0.id == messageID }) else { return }
        var references = records[index].messages[message].attachments ?? []
        if let sourceURL = attachment.sourceURL {
            // A retry may return new bytes after the previous original was lost.
            // Keep one current binding per source so readers cannot pick a stale ID.
            references.removeAll { $0.sourceURL == sourceURL }
        } else if references.contains(where: { $0.id == attachment.id && $0.sourceURL == nil }) { return }
        references.append(attachment); records[index].messages[message].attachments = references
        dirtyIDs.insert(conversationID); saveNow()
    }
    @discardableResult func attach(_ attachment: StoredAttachment, toTool callID: String, identity: RunIdentity) -> Bool {
        guard accepts(identity), let message = conversation(identity.conversationID)?.messages.last(where: { $0.runID == identity.runID && $0.tool?.callID == callID }) else { return false }
        attach(attachment, to: message.id, in: identity.conversationID); return true
    }
    @discardableResult func create(mode: RunMode) -> UUID {
        let conversation = AgentConversation(mode: mode)
        records.insert(conversation, at: 0); dirtyIDs.insert(conversation.id); saveNow()
        return conversation.id
    }
    /// A damaged journal remains untouched; only its verified visible prefix
    /// can be used as the source for a separate, explicitly requested session.
    func hasRecoverableHistory(_ id: UUID) -> Bool {
        guard journal?.unreadableIDs.contains(id) == true,
              let conversation = records.first(where: { $0.id == id }) else { return false }
        return !conversation.messages.isEmpty
    }
    @discardableResult func recoverReadableHistory(_ id: UUID) async throws -> UUID {
        guard storageReady, activeRuns[id] == nil, let journal, let directory,
              journal.unreadableIDs.contains(id) else { throw SessionCommandError.unavailableStorage }
        let source = try journal.conversation(id)
        guard !source.messages.isEmpty else { throw SessionCommandError.unavailableStorage }
        var recovered = AgentConversation(mode: source.mode)
        recovered.title = source.title
        // Provider choice, pending entry, draft and execution authorization are
        // deliberately not transferred from a damaged execution history.
        let attachments = AttachmentStore(directory: directory)
        for sourceMessage in source.messages {
            var message = sourceMessage
            message.id = UUID(); message.runID = nil
            if message.state == .streaming { message.state = .interrupted }
            if message.reasoning?.state == .streaming { message.reasoning?.state = .interrupted }
            if var tool = message.tool, !tool.state.isTerminal { tool.state = .outcomeUnknown; message.tool = tool }
            var copied: [StoredAttachment] = []
            for original in sourceMessage.attachments ?? [] {
                if let data = try? await attachments.read(original, conversationID: id),
                   let stored = try? await attachments.store(data, name: original.name, conversationID: recovered.id) {
                    copied.append(stored)
                } else {
                    // Keep a missing placeholder owned by the new session; do
                    // not reopen an external URL or impersonate existing bytes.
                    var missing = original; missing.conversationID = recovered.id; missing.sourceURL = nil
                    copied.append(missing)
                }
            }
            message.attachments = copied.isEmpty ? nil : copied
            recovered.messages.append(message)
        }
        var context: [ModelInputItem] = [.message(role: .assistant, content: [.text(
            "This conversation was reconstructed from a verified readable prefix. The original history has a gap; later facts and tool outcomes may be missing. Historical actions were not replayed."
        )])]
        for message in recovered.messages {
            switch message.role {
            case .user, .assistant:
                guard message.state == .complete, !message.text.isEmpty else { continue }
                context.append(.message(role: message.role == .user ? .user : .assistant, content: [.text(message.text)]))
            case .tool:
                guard let tool = message.tool else { continue }
                let fact = "Historical tool record: name=\(tool.name), call_id=\(tool.callID), state=\(tool.state.rawValue), recorded_result=\(tool.result). This is a historical fact, not a pending call."
                context.append(.message(role: .assistant, content: [.text(fact)]))
            case .notice: break
            }
        }
        let newRoot = try SessionStorageLayout(root: directory).ensureDirectory(for: recovered.id, createdAt: recovered.createdAt)
        let store = JSONLSessionStore(root: newRoot, sessionID: recovered.id)
        let transaction = try SessionTransaction(sessionID: recovered.id, kind: .legacyImported,
            contextItems: context, displayItems: recovered.messages.map { try AgentSessionPersistence.display($0, legacy: true) },
            metadata: AgentSessionPersistence.metadata(recovered))
        _ = try store.appendSync(transaction, expecting: 0)
        // Install in the normal registry only after the durable transaction.
        _ = try journal.engineStore(recovered.id)
        try? journal.adoptCommittedSession(recovered.id)
        records.insert(recovered, at: 0)
        return recovered.id
    }
    @discardableResult func createDraft(mode: RunMode) -> UUID {
        let draft = AgentConversation(mode: mode)
        draftIDs.insert(draft.id)
        records.insert(draft, at: 0)
        if directory != nil, storageReady {
            do { _ = try sessionDirectory(draft.id) } catch { reportSaveFailure() }
        }
        return draft.id
    }
    func discardDraft(_ id: UUID) {
        guard isDraft(id), activeRuns[id] == nil else { return }
        delete(id)
    }
    /// Prepare and route are one durable record. Commit first so Siri never
    /// reports a saved task when the archive is locked, corrupt, or full.
    func prepare(_ command: SessionCommand, task: String) throws -> UUID {
        let text = task.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.count <= 2_000 else { throw SessionCommandError.invalidTask }
        if let previous = records.first(where: { $0.entry?.commandID == command.commandID }) {
            guard previous.entry?.source == command.source else { throw SessionCommandError.conflictingCommand }
            return previous.id
        }
        var conversation = AgentConversation(mode: .live)
        conversation.createdAt = command.createdAt; conversation.updatedAt = command.createdAt
        conversation.title = String(text.prefix(48)); conversation.draft = text
        conversation.entry = SessionEntry(commandID: command.commandID, sessionID: conversation.id,
            source: command.source, createdAt: command.createdAt, updatedAt: command.createdAt)
        try commit(conversation)
        records.insert(conversation, at: 0)
        return conversation.id
    }
    func dismissPreparedTask(in id: UUID) throws {
        guard let index = index(id), records[index].entry?.state == .pendingConfirmation else { return }
        var next = records[index]
        next.entry?.state = .dismissed; next.entry?.routePending = false
        next.entry?.updatedAt = Date(); next.draft = ""
        try commit(next)
        records[index] = next
    }
    private func commit(_ conversation: AgentConversation) throws {
        guard canWrite else { throw SessionCommandError.unavailableStorage }
        do {
            try journal?.save(conversation)
            dirtyIDs.remove(conversation.id)
        } catch { throw SessionCommandError.unavailableStorage }
    }
    func setDraft(_ text: String, in id: UUID) {
        guard let index = index(id) else { return }
        records[index].draft = String(text.prefix(2_000)); dirtyIDs.insert(id); scheduleSave()
    }
    func addDraftAttachment(_ attachment: StoredAttachment, in id: UUID) {
        guard attachment.conversationID == id, activeRuns[id] == nil, let index = index(id) else { return }
        var references = records[index].draftAttachments ?? []
        guard !references.contains(where: { $0.id == attachment.id }) else { return }
        references.append(attachment); records[index].draftAttachments = references; dirtyIDs.insert(id); saveNow()
    }
    func removeDraftAttachment(_ attachmentID: UUID, in id: UUID) {
        guard activeRuns[id] == nil, let index = index(id) else { return }
        records[index].draftAttachments?.removeAll { $0.id == attachmentID }; dirtyIDs.insert(id); saveNow()
    }
    func delete(_ id: UUID) {
        guard activeRuns[id] == nil, !migrationRequired else { return }
        do {
            guard canWrite || isDraft(id) else { throw SessionCommandError.unavailableStorage }
            if canWrite { try journal?.delete(id) }
            records.removeAll { $0.id == id }; draftIDs.remove(id); dirtyIDs.remove(id); unloadedIDs.remove(id); pendingRecoveries.removeValue(forKey: id)
        } catch {
            if journal?.unreadableIDs.isEmpty == false {
                historyFullyReadable = false
                warning = String(localized: "Some conversations could not be read. Their files have been kept. Other conversations can still be saved.")
            } else { reportSaveFailure() }
        }
    }
    func clear() {
        guard activeRuns.isEmpty, !migrationRequired else { return }
        for id in records.map(\.id) { delete(id) }
    }
    func begin(in id: UUID, query: String, attachments: [StoredAttachment] = []) -> RunIdentity? {
        guard !migrationRequired, activeRuns[id] == nil, let index = index(id) else { return nil }
        draftIDs.remove(id)
        let identity = RunIdentity(conversationID: id, runID: UUID())
        activeRuns[id] = identity
        if records[index].messages.isEmpty { records[index].title = String(query.prefix(48)) }
        records[index].phase = .running; records[index].draft = ""
        if records[index].entry?.state == .pendingConfirmation {
            records[index].entry?.state = .submitted
            records[index].entry?.routePending = false
            records[index].entry?.runID = identity.runID
            records[index].entry?.updatedAt = Date()
        }
        records[index].messages.append(ChatMessage(runID: identity.runID, role: .user, text: query, attachments: attachments.isEmpty ? nil : attachments))
        records[index].draftAttachments = nil
        touch(index); saveNow()
        return identity
    }
    func accepts(_ identity: RunIdentity) -> Bool { activeRuns[identity.conversationID] == identity }
    func reloadPresentation(_ id: UUID) {
        guard let journal, let index = records.firstIndex(where: { $0.id == id }) else { return }
        do { records[index] = try journal.reload(id) }
        catch { reportSaveFailure() }
    }
    func beginAssistantTurn(_ identity: RunIdentity, itemID: UUID = UUID()) {
        guard accepts(identity), let index = index(identity.conversationID) else { return }
        guard !records[index].messages.contains(where: { $0.id == itemID }) else { return }
        records[index].messages.append(ChatMessage(id: itemID, runID: identity.runID, role: .assistant, text: "", state: .streaming))
        touch(index); scheduleSave()
    }
    func appendText(_ text: String, identity: RunIdentity, itemID: UUID? = nil) {
        guard accepts(identity), let index = index(identity.conversationID),
              let message = records[index].messages.lastIndex(where: { $0.runID == identity.runID && $0.role == .assistant && $0.state == .streaming && (itemID == nil || $0.id == itemID) }) else { return }
        records[index].messages[message].text += text
        touch(index); scheduleSave()
    }
    func appendReasoning(_ text: String, identity: RunIdentity, itemID: UUID? = nil) {
        guard !text.isEmpty, accepts(identity), let index = index(identity.conversationID),
              let message = records[index].messages.lastIndex(where: { $0.runID == identity.runID && $0.role == .assistant && $0.state == .streaming && (itemID == nil || $0.id == itemID) }) else { return }
        if records[index].messages[message].reasoning == nil {
            records[index].messages[message].reasoning = ReasoningMessage(text: "")
        }
        records[index].messages[message].reasoning?.text += text
        touch(index); scheduleSave()
    }
    func completeAssistantTurn(_ text: String, reasoning: String? = nil, identity: RunIdentity, itemID: UUID? = nil) {
        guard accepts(identity), let index = index(identity.conversationID),
              let message = records[index].messages.lastIndex(where: { $0.runID == identity.runID && $0.role == .assistant && $0.state == .streaming && (itemID == nil || $0.id == itemID) }) else { return }
        if let reasoning, !reasoning.isEmpty {
            records[index].messages[message].reasoning = ReasoningMessage(text: reasoning, state: .complete)
        }
        if text.isEmpty && records[index].messages[message].reasoning == nil { records[index].messages.remove(at: message) }
        else {
            records[index].messages[message].text = text
            records[index].messages[message].state = .complete
            records[index].messages[message].reasoning?.state = .complete
        }
        touch(index); saveNow()
    }
    func updateTool(callID: String, name: String, state: ToolStepState, detail: String = "", result: String = "", arguments: String? = nil, skillName: String? = nil, identity: RunIdentity) {
        guard accepts(identity), let index = index(identity.conversationID) else { return }
        if let message = records[index].messages.firstIndex(where: { $0.runID == identity.runID && $0.tool?.callID == callID }) {
            let previous = records[index].messages[message].tool?.state
            guard previous?.isTerminal != true else { return }
            // Approval callbacks can arrive before queued observer events. Keep
            // their state, and never revive a terminal (especially denied) step.
            let regresses = state == .requested || (state == .running && [.awaitingApproval, .approved, .executing].contains(previous))
            if previous?.isTerminal != true && !regresses {
                records[index].messages[message].tool?.state = state
            }
            if !detail.isEmpty { records[index].messages[message].tool?.detail = String(detail.prefix(500)) }
            if !result.isEmpty { records[index].messages[message].tool?.result = result }
            if let arguments { records[index].messages[message].tool?.arguments = String(arguments.prefix(4_000)) }
            if let skillName { records[index].messages[message].tool?.skillName = String(skillName.prefix(80)) }
        } else {
            let tool = ToolStep(callID: callID, name: name, state: state, detail: String(detail.prefix(500)), result: result, arguments: arguments.map { String($0.prefix(4_000)) }, skillName: skillName.map { String($0.prefix(80)) })
            let itemID = ToolInvocation(sessionID: identity.conversationID, turnID: identity.runID,
                call: ModelToolCall(id: callID, name: name, arguments: "{}")).displayItemID
            records[index].messages.append(ChatMessage(id: itemID, runID: identity.runID, role: .tool, text: "", tool: tool))
        }
        if state == .awaitingApproval { records[index].phase = .awaitingApproval }
        else if [.approved, .executing, .succeeded, .failed].contains(state) { records[index].phase = .running }
        touch(index); saveNow()
    }
    func reconcileRecovery(_ checkpoint: RunCheckpoint) {
        if unloadedIDs.contains(checkpoint.conversationID) {
            pendingRecoveries[checkpoint.conversationID, default: []].append(checkpoint)
            return
        }
        reconcileTools(checkpoint)
    }
    func selectProvider(_ providerID: UUID?, model: String?, in id: UUID) {
        guard let index = index(id), activeRuns[id] == nil else { return }
        records[index].providerID = providerID
        records[index].modelID = model
        touch(index); saveNow()
    }
    func addNotice(_ text: String, in id: UUID) {
        guard let index = index(id) else { return }
        records[index].messages.append(ChatMessage(role: .notice, text: String(text.prefix(1_000))))
        touch(index); saveNow()
    }
    func finish(_ identity: RunIdentity, phase: RunPhase, summary: String) {
        guard accepts(identity), let index = index(identity.conversationID) else { return }
        records[index].phase = phase
        closePendingMessages(at: index, state: phase == .blocked ? .failed : .interrupted, cancelled: phase == .stopped)
        if !summary.isEmpty {
            records[index].messages.append(ChatMessage(runID: identity.runID, role: .notice, text: String(summary.prefix(1_000)), state: phase == .blocked ? .failed : .complete))
        }
        activeRuns.removeValue(forKey: identity.conversationID); touch(index); saveNow()
    }
    /// Presentation query only. AgentKit builds model context from committed session facts.
    func history(in id: UUID) -> [ChatMessage] {
        (conversation(id)?.messages ?? []).filter { ($0.role == .user || $0.role == .assistant) && $0.state == .complete && !$0.text.isEmpty }.map {
            var message = $0; message.reasoning = nil; return message
        }
    }
    private func index(_ id: UUID) -> Int? {
        loadHistory(id)
        guard !unloadedIDs.contains(id) else { return nil }
        return records.firstIndex { $0.id == id }
    }
    private func touch(_ index: Int) {
        dirtyIDs.insert(records[index].id)
        records[index].updatedAt = Date()
        // Durable history is independent of the bounded context sent to a model.
    }
    private func closePendingMessages(at index: Int, state terminalState: MessageState = .interrupted, cancelled: Bool = false) {
        for message in records[index].messages.indices {
            if records[index].messages[message].state == .streaming { records[index].messages[message].state = terminalState }
            if records[index].messages[message].reasoning?.state == .streaming { records[index].messages[message].reasoning?.state = terminalState }
            if let state = records[index].messages[message].tool?.state, !state.isTerminal {
                let uncertain = state == .executing
                records[index].messages[message].tool?.state = uncertain ? .outcomeUnknown : (cancelled ? .cancelled : .interrupted)
                records[index].messages[message].tool?.result = uncertain
                    ? String(localized: "Execution was interrupted without delivery confirmation. The result is unknown and was not resent automatically.")
                    : (cancelled ? String(localized: "This call was canceled.") : String(localized: "Execution was interrupted. Its result was not saved."))
            }
        }
    }
    private func reconcileTools(_ checkpoint: RunCheckpoint) {
        guard let index = index(checkpoint.conversationID), activeRuns[checkpoint.conversationID] == nil else { return }
        var changed = false
        for message in records[index].messages.indices {
            guard records[index].messages[message].runID == checkpoint.runID,
                  let tool = records[index].messages[message].tool,
                  let saved = checkpoint.tools.first(where: { $0.callID == tool.callID && $0.name == tool.name }),
                  ![.succeeded, .failed, .denied].contains(tool.state) else { continue }
            let input = ["tap", "drag", "home", "launch_app", "type_text"].contains(tool.name)
            var recovered = tool
            switch saved.delivery {
            case .acknowledged, .observedResult:
                recovered.state = input ? .succeeded : .interrupted
                recovered.result = input ? "Command delivery acknowledged." : String(localized: "The call finished, but its result could not be saved.")
            case .dispatching, .outcomeUnknown:
                recovered.state = input ? .outcomeUnknown : .interrupted
                recovered.result = input ? String(localized: "The action was sent without acknowledgment. The result is unknown and was not resent automatically.") : String(localized: "The call was interrupted. Its result was not saved.")
            case .prepared:
                recovered.state = .cancelled; recovered.result = String(localized: "Execution was interrupted. This call was not sent.")
            case .failed:
                recovered.state = .failed; recovered.result = String(localized: "The call failed and its detailed result could not be saved.")
            }
            if recovered.arguments == nil { recovered.arguments = ToolStep.nonemptyArguments(saved.parameterSummary) }
            if recovered != tool {
                records[index].messages[message].tool = recovered; changed = true
            }
        }
        if changed { dirtyIDs.insert(checkpoint.conversationID); saveNow() }
    }
    private func scheduleSave() {
        guard saveTask == nil else { return }
        saveTask = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: 300_000_000) } catch { return }
            self?.saveNow()
        }
    }
    func saveNow() {
        saveTask?.cancel(); saveTask = nil
        guard canWrite else { return }
        for id in dirtyIDs {
            guard !draftIDs.contains(id), let conversation = records.first(where: { $0.id == id }), !unloadedIDs.contains(id) else { continue }
            do { try journal?.save(conversation); dirtyIDs.remove(id) }
            catch { reportSaveFailure() }
        }
    }
    private func reportSaveFailure() {
        warning = String(localized: "The conversation could not be saved. Check available storage. Your current content is still in memory.")
    }
}
