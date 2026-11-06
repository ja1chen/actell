import Foundation

/// Application-owned boundary. A retry reuses commandID; a new utterance gets a
/// new ID even when its text is identical. No command can approve a tool.
struct SessionCommand: Sendable {
    enum Action: Sendable { case prepare(String), execute(String), open, status, cancel }
    enum Source: String, Codable, Sendable { case siri, app }
    let commandID: UUID
    let sessionID: UUID?
    let runID: UUID?
    let source: Source
    let createdAt: Date
    let action: Action

    init(_ action: Action, commandID: UUID = UUID(), sessionID: UUID? = nil,
         runID: UUID? = nil, source: Source = .siri, createdAt: Date = Date()) {
        self.action = action; self.commandID = commandID; self.sessionID = sessionID
        self.runID = runID; self.source = source; self.createdAt = createdAt
    }
}

/// Persisted in the same journal transaction as the conversation and draft.
struct SessionEntry: Codable, Sendable, Equatable {
    enum State: String, Codable, Sendable { case pendingConfirmation, submitted, dismissed }
    let commandID: UUID
    let sessionID: UUID
    let source: SessionCommand.Source
    let createdAt: Date
    var updatedAt: Date
    var state: State = .pendingConfirmation
    var routePending = true
    var runID: UUID?
}

enum SessionCommandError: LocalizedError {
    case invalidTask, unavailableStorage, missingSession, conflictingCommand, startFailed
    case executionFailed(String)
    var errorDescription: String? {
        switch self {
        case .executionFailed(let reason): return reason
        case .startFailed: return String(localized: "The task could not start. Open Zhiyan and check the task and provider settings.")
        case .invalidTask: return String(localized: "Enter a task of 1–2,000 characters.")
        case .unavailableStorage: return String(localized: "The draft could not be saved. Open Zhiyan and check storage.")
        case .missingSession: return String(localized: "This draft is no longer available.")
        case .conflictingCommand: return String(localized: "This request identifier has already been used.")
        }
    }
}

enum SessionPublicStatus: String, Sendable {
    case idle, pendingConfirmation, running, awaitingApproval, stopping
    var message: String {
        switch self {
        case .idle: return String(localized: "No task is currently running.")
        case .pendingConfirmation: return String(localized: "A task draft is waiting for your confirmation in Zhiyan. It has not started.")
        case .running: return String(localized: "A task is running.")
        case .awaitingApproval: return String(localized: "A task is waiting for your approval in Zhiyan.")
        case .stopping: return String(localized: "The current task is stopping.")
        }
    }
}

@MainActor protocol SessionCommandRunning: AnyObject {
    var currentRun: RunIdentity? { get }
    var commandCanStart: Bool { get }
    var commandStartError: String? { get }
    var commandBusy: Bool { get }
    var commandStatus: SessionPublicStatus { get }
    func cancelCommandRun(_ identity: RunIdentity) -> Bool
    func startCommandTask(_ task: String, in sessionID: UUID) -> Bool
}

@MainActor final class SessionCommandService {
    enum Result: Equatable {
        case prepared(UUID), started(UUID), open(UUID), deferred, status(SessionPublicStatus), cancelled, noMatchingRun
    }
    let sessions: ConversationStore
    private let runner: any SessionCommandRunning
    // Process-local handoff only: a relaunch must never auto-execute a saved draft.
    private var pendingExecutions: [UUID: SessionCommand] = [:]

    init(sessions: ConversationStore, runner: any SessionCommandRunning) {
        self.sessions = sessions; self.runner = runner
    }
    var pendingRoute: UUID? {
        sessions.conversations.filter { $0.entry?.state == .pendingConfirmation && $0.entry?.routePending == true }
            .max { $0.createdAt < $1.createdAt }?.id
    }
    func resumePendingExecutions() {
        guard runner.commandCanStart else { return }
        let commands = pendingExecutions.values.sorted { $0.createdAt < $1.createdAt }
        for command in commands {
            pendingExecutions.removeValue(forKey: command.commandID)
            do { _ = try perform(command) }
            catch {
                if let session = sessions.conversations.first(where: { $0.entry?.commandID == command.commandID }) {
                    sessions.addNotice(error.localizedDescription, in: session.id)
                }
            }
        }
    }
    /// Capture before any suspension. A later run must never inherit this stop.
    func cancelCurrentCommand() -> SessionCommand {
        SessionCommand(.cancel, sessionID: runner.currentRun?.conversationID, runID: runner.currentRun?.runID)
    }
    func perform(_ command: SessionCommand) throws -> Result {
        switch command.action {
        case .execute(let task):
            let id = try sessions.prepare(command, task: task)
            guard let session = sessions.conversation(id) else { throw SessionCommandError.missingSession }
            // A submitted or dismissed command must never execute again on retry.
            if session.entry?.state == .submitted { return .started(id) }
            guard session.entry?.state == .pendingConfirmation else { throw SessionCommandError.conflictingCommand }
            guard runner.commandCanStart else {
                pendingExecutions[command.commandID] = command
                return .deferred
            }
            pendingExecutions.removeValue(forKey: command.commandID)
            guard runner.startCommandTask(session.draft, in: id) else {
                if let reason = runner.commandStartError { throw SessionCommandError.executionFailed(reason) }
                throw SessionCommandError.startFailed
            }
            return .started(id)
        case .prepare(let task):
            return .prepared(try sessions.prepare(command, task: task))
        case .open:
            guard let id = command.sessionID, let session = sessions.conversation(id),
                  session.entry?.state == .pendingConfirmation else { throw SessionCommandError.missingSession }
            return .open(id)
        case .status:
            let status = runner.commandStatus
            return .status(status == .idle && sessions.conversations.contains { $0.entry?.state == .pendingConfirmation } ? .pendingConfirmation : status)
        case .cancel:
            guard let sessionID = command.sessionID, let runID = command.runID else { return .noMatchingRun }
            return runner.cancelCommandRun(RunIdentity(conversationID: sessionID, runID: runID)) ? .cancelled : .noMatchingRun
        }
    }
}

extension AgentViewModel: SessionCommandRunning {
    var commandStartError: String? {
        selectedConversationID.flatMap { existingExecutionModel(for: $0)?.errorMessage }
    }
    var commandBusy: Bool { hasBusySessions || isListening }
    var commandStatus: SessionPublicStatus {
        if let run = currentRun, let worker = existingExecutionModel(for: run.conversationID) {
            if worker.stopping { return .stopping }
            if worker.running { return worker.approval == nil ? .running : .awaitingApproval }
        }
        return .idle
    }
    func startCommandTask(_ task: String, in sessionID: UUID) -> Bool {
        selectConversation(sessionID) // Bind the default provider just as the conversation UI does.
        return send(task, in: sessionID, cloudConsent: true, allowBackgroundStart: true)
    }
    func cancelCommandRun(_ identity: RunIdentity) -> Bool {
        return stop(run: identity) // Existing runner/coordinator drain, never just UI state.
    }
}
