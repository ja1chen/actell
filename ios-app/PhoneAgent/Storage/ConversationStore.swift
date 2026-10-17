import Foundation
import Combine

/// UI history contains public text, resource references, tool results
/// and explicit readable provider reasoning; no image bytes, opaque reasoning,
/// credentials or resumable tool queues.
@MainActor final class ConversationStore: ObservableObject {
    // Execution and persistence continue in background, but a hidden chat must
    // not rebuild its entire SwiftUI tree for every streamed reasoning fragment.
    private var records: [AgentConversation] = [] {
        willSet { if presentationActive { objectWillChange.send() } }
    }
    private var draftIDs: Set<UUID> = []
    /// Temporary composer drafts stay out of history and durable archives.
    var conversations: [AgentConversation] { records.filter { !draftIDs.contains($0.id) } }
    func isDraft(_ id: UUID) -> Bool { draftIDs.contains(id) }
    private var presentationActive = true
    @Published private(set) var activeRuns: [UUID: RunIdentity] = [:]
    var activeRun: RunIdentity? { activeRuns.values.first }
    @Published private(set) var warning: String?
    private let file: URL?
    private var canWrite = true
    private var saveTask: Task<Void, Never>?
    private struct Archive: Codable { var version = 1; var conversations: [AgentConversation] }

    init(directory: URL? = nil, inMemory: Bool = false, legacy: [TaskRecord] = []) {
        if inMemory { file = nil; return }
        do {
            let folder = try directory ?? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true).appendingPathComponent("PhoneAgent", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            var folderURL = folder
            var values = URLResourceValues(); values.isExcludedFromBackup = true
            try folderURL.setResourceValues(values)
            file = folder.appendingPathComponent("conversations-v1.json")
        } catch { file = nil; canWrite = false; warning = String(localized: "Conversations can only be kept in memory for now"); return }
        do {
            if let file, FileManager.default.fileExists(atPath: file.path) {
                let data = try Data(contentsOf: file)
                guard data.count <= 64 * 1_024 * 1_024 else { throw AppError.invalid(String(localized: "Conversation file is too large")) }
                let archive = try JSONDecoder().decode(Archive.self, from: data)
                guard archive.version == 1 else { throw AppError.invalid(String(localized: "Conversation file version is incompatible")) }
                records = archive.conversations
                for index in records.indices {
                    if [.running, .awaitingApproval].contains(records[index].phase) {
                        records[index].phase = .interrupted
                    }
                    closePendingMessages(at: index)
                }
            } else {
                records = legacy.map { record in
                    var conversation = AgentConversation(mode: record.mode)
                    conversation.id = record.id; conversation.title = String(record.goal.prefix(48))
                    conversation.updatedAt = record.updatedAt
                    conversation.phase = [.running, .awaitingApproval].contains(record.phase) ? .interrupted : record.phase
                    conversation.messages = [ChatMessage(role: .user, text: record.goal)]
                    conversation.messages += record.receipts.map { ChatMessage(role: .notice, text: $0.message, date: $0.date) }
                    if !record.result.isEmpty { conversation.messages.append(ChatMessage(role: .notice, text: String(localized: "Previous run result:\n\(record.result)"))) }
                    return conversation
                }
            }
            saveNow()
        } catch {
            canWrite = false // Preserve an unreadable original; never replace it with [].
            warning = String(localized: "Conversation history could not be read. The original file was kept. This conversation will not be saved to disk for now.")
        }
    }

    func conversation(_ id: UUID) -> AgentConversation? { records.first { $0.id == id } }
    func setPresentationActive(_ active: Bool) {
        guard active != presentationActive else { return }
        presentationActive = active
        if active { objectWillChange.send() }
    }
    var referencedAttachments: [StoredAttachment] {
        records.flatMap { ($0.draftAttachments ?? []) + $0.messages.flatMap { $0.attachments ?? [] } }
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
        saveNow()
    }
    @discardableResult func attach(_ attachment: StoredAttachment, toTool callID: String, identity: RunIdentity) -> Bool {
        guard accepts(identity), let message = conversation(identity.conversationID)?.messages.last(where: { $0.runID == identity.runID && $0.tool?.callID == callID }) else { return false }
        attach(attachment, to: message.id, in: identity.conversationID); return true
    }
    @discardableResult func create(mode: RunMode) -> UUID {
        let conversation = AgentConversation(mode: mode)
        records.insert(conversation, at: 0); saveNow()
        return conversation.id
    }
    @discardableResult func createDraft(mode: RunMode) -> UUID {
        let draft = AgentConversation(mode: mode)
        draftIDs.insert(draft.id)
        records.insert(draft, at: 0)
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
        try commit([conversation] + records)
        return conversation.id
    }
    func dismissPreparedTask(in id: UUID) throws {
        guard let index = index(id), records[index].entry?.state == .pendingConfirmation else { return }
        var next = records
        next[index].entry?.state = .dismissed; next[index].entry?.routePending = false
        next[index].entry?.updatedAt = Date(); next[index].draft = ""
        try commit(next)
    }
    private func commit(_ next: [AgentConversation]) throws {
        guard canWrite else { throw SessionCommandError.unavailableStorage }
        do {
            if let file {
                let data = try JSONEncoder().encode(Archive(conversations: next.filter { !draftIDs.contains($0.id) }))
                guard data.count <= 64 * 1_024 * 1_024 else { throw SessionCommandError.unavailableStorage }
                try data.write(to: file, options: [.atomic, .completeFileProtection])
            }
            records = next
        } catch { throw SessionCommandError.unavailableStorage }
    }
    func setDraft(_ text: String, in id: UUID) {
        guard let index = index(id) else { return }
        records[index].draft = String(text.prefix(2_000)); scheduleSave()
    }
    func addDraftAttachment(_ attachment: StoredAttachment, in id: UUID) {
        guard attachment.conversationID == id, activeRuns[id] == nil, let index = index(id) else { return }
        var references = records[index].draftAttachments ?? []
        guard !references.contains(where: { $0.id == attachment.id }) else { return }
        references.append(attachment); records[index].draftAttachments = references; saveNow()
    }
    func removeDraftAttachment(_ attachmentID: UUID, in id: UUID) {
        guard activeRuns[id] == nil, let index = index(id) else { return }
        records[index].draftAttachments?.removeAll { $0.id == attachmentID }; saveNow()
    }
    func delete(_ id: UUID) {
        guard activeRuns[id] == nil else { return }
        records.removeAll { $0.id == id }; draftIDs.remove(id); saveNow()
    }
    func clear() {
        guard activeRuns.isEmpty else { return }
        records = []; draftIDs = []; saveNow()
    }
    func begin(in id: UUID, query: String, attachments: [StoredAttachment] = []) -> RunIdentity? {
        guard activeRuns[id] == nil, let index = index(id) else { return nil }
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
    func beginAssistantTurn(_ identity: RunIdentity) {
        guard accepts(identity), let index = index(identity.conversationID) else { return }
        records[index].messages.append(ChatMessage(runID: identity.runID, role: .assistant, text: "", state: .streaming))
        touch(index); scheduleSave()
    }
    func appendText(_ text: String, identity: RunIdentity) {
        guard accepts(identity), let index = index(identity.conversationID),
              let message = records[index].messages.lastIndex(where: { $0.runID == identity.runID && $0.role == .assistant && $0.state == .streaming }) else { return }
        records[index].messages[message].text = String((records[index].messages[message].text + text).prefix(16_000))
        touch(index); scheduleSave()
    }
    func appendReasoning(_ text: String, identity: RunIdentity) {
        guard !text.isEmpty, accepts(identity), let index = index(identity.conversationID),
              let message = records[index].messages.lastIndex(where: { $0.runID == identity.runID && $0.role == .assistant && $0.state == .streaming }) else { return }
        if records[index].messages[message].reasoning == nil {
            records[index].messages[message].reasoning = ReasoningMessage(text: "")
        }
        records[index].messages[message].reasoning?.text += text
        touch(index); scheduleSave()
    }
    func completeAssistantTurn(_ text: String, reasoning: String? = nil, identity: RunIdentity) {
        guard accepts(identity), let index = index(identity.conversationID),
              let message = records[index].messages.lastIndex(where: { $0.runID == identity.runID && $0.role == .assistant && $0.state == .streaming }) else { return }
        if let reasoning, !reasoning.isEmpty {
            records[index].messages[message].reasoning = ReasoningMessage(text: reasoning, state: .complete)
        }
        if text.isEmpty && records[index].messages[message].reasoning == nil { records[index].messages.remove(at: message) }
        else {
            records[index].messages[message].text = String(text.prefix(16_000))
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
            records[index].messages.append(ChatMessage(runID: identity.runID, role: .tool, text: "", tool: tool))
        }
        if state == .awaitingApproval { records[index].phase = .awaitingApproval }
        else if [.approved, .executing, .succeeded, .failed].contains(state) { records[index].phase = .running }
        touch(index); saveNow()
    }
    func reconcileRecovery(_ checkpoint: RunCheckpoint) {
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
    /// Only public text from this conversation is used as context. Historical
    /// tools/images are never re-enqueued or used to authorize new input.
    func history(in id: UUID) -> [ChatMessage] {
        Array((conversation(id)?.messages ?? []).filter { ($0.role == .user || $0.role == .assistant) && $0.state == .complete && !$0.text.isEmpty }.suffix(16)).map {
            var message = $0; message.reasoning = nil; return message
        }
    }
    private func index(_ id: UUID) -> Int? { records.firstIndex { $0.id == id } }
    private func touch(_ index: Int) {
        records[index].updatedAt = Date()
        // Keep durable image/file references until the user deletes their history.
        // The normal 200-message trim must not orphan historical originals.
        var excess = records[index].messages.count - 200
        if excess > 0 {
            records[index].messages.removeAll { message in
                guard excess > 0, message.attachments?.isEmpty != false else { return false }
                excess -= 1; return true
            }
        }
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
        if changed { saveNow() }
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
        guard let file, canWrite else { return }
        do {
            let data = try JSONEncoder().encode(Archive(conversations: conversations))
            guard data.count <= 64 * 1_024 * 1_024 else { throw AppError.invalid(String(localized: "Conversation storage is full. Delete old conversations.")) }
            try data.write(to: file, options: [.atomic, .completeFileProtection])
        } catch { warning = String(localized: "The conversation could not be saved. Check available storage. Your current content is still in memory.") }
    }
}
