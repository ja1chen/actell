import Foundation

struct RunIdentity: Hashable, Sendable {
    let conversationID: UUID
    let runID: UUID
}

struct StepIdentity: Hashable, Sendable {
    let run: RunIdentity
    let stepID: String
}

struct PresentedFrame: Sendable {
    let step: StepIdentity
    let image: FrameImage
}

enum ChatRole: String, Codable, Sendable { case user, assistant, tool, notice }
enum MessageState: String, Codable, Sendable { case complete, streaming, interrupted, failed }
enum ToolStepState: String, Codable, Sendable {
    case requested, running, awaitingApproval, approved, executing, succeeded, failed, denied, cancelled, interrupted, outcomeUnknown
    var isTerminal: Bool { [.succeeded, .failed, .denied, .cancelled, .interrupted, .outcomeUnknown].contains(self) }
    var label: String {
        switch self {
        case .requested: return String(localized: "Requested")
        case .running, .executing: return String(localized: "Running")
        case .awaitingApproval: return String(localized: "Waiting for confirmation")
        case .approved: return String(localized: "Approved")
        case .succeeded: return String(localized: "Returned")
        case .failed: return String(localized: "Failed")
        case .denied: return String(localized: "Denied")
        case .cancelled: return String(localized: "Canceled")
        case .interrupted: return String(localized: "Interrupted")
        case .outcomeUnknown: return String(localized: "Result unknown")
        }
    }
}
struct ToolStep: Codable, Sendable, Equatable {
    var callID: String
    var name: String
    var state: ToolStepState
    var detail: String
    var result: String = ""
    // Optional keeps version-1 archives without parameter previews readable.
    // Only bounded public fields from our five registered tools are stored.
    var arguments: String?
    var skillName: String?
    var displayArguments: String? { Self.nonemptyArguments(arguments) }
    var displayResult: String {
        if !result.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return result }
        switch state {
        case .cancelled: return String(localized: "This call was canceled. Its result was not saved.")
        case .interrupted: return String(localized: "Execution was interrupted. Its result was not saved.")
        case .outcomeUnknown: return String(localized: "Delivery was not confirmed. The result is unknown and was not resent automatically.")
        default: return ""
        }
    }
    static func nonemptyArguments(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let json = try? JSONSerialization.jsonObject(with: Data(trimmed.utf8), options: [.fragmentsAllowed]) {
            if json is NSNull { return nil }
            if let object = json as? [String: Any], object.isEmpty { return nil }
            if let array = json as? [Any], array.isEmpty { return nil }
            if let string = json as? String, string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return nil }
        }
        return value
    }
    var symbol: String {
        let operation = AgentActivityAttributes.Operation.tool(name)
        return operation == .processing ? "wrench.and.screwdriver" : operation.symbol
    }
    var title: String {
        switch name {
        case "screenshot": return String(localized: "View screen")
        case "tap": return String(localized: "Tap")
        case "drag": return String(localized: "Drag")
        case "home": return String(localized: "Go to Home Screen")
        case "list_apps": return String(localized: "Find apps")
        case "launch_app": return String(localized: "Launch app")
        case "type_text": return String(localized: "Type text")
        case "wait": return String(localized: "Wait")
        case "finish": return String(localized: "Finish run")
        case "load_skill": return String(localized: "Load skill") + (skillName.map { " · " + $0 } ?? "")
        default: return name
        }
    }
}
struct ReasoningMessage: Codable, Sendable, Equatable {
    var text: String
    var state: MessageState = .streaming
}
struct ChatMessage: Identifiable, Codable, Sendable, Equatable {
    var id = UUID()
    var runID: UUID?
    var role: ChatRole
    var text: String
    var date = Date()
    var state: MessageState = .complete
    var tool: ToolStep?
    var attachments: [StoredAttachment]?
    var reasoning: ReasoningMessage?
}
struct AgentConversation: Identifiable, Codable, Sendable {
    var id = UUID()
    var title = String(localized: "New conversation")
    var mode: RunMode
    var createdAt = Date()
    var updatedAt = Date()
    var entry: SessionEntry?
    var draft = ""
    var draftAttachments: [StoredAttachment]?
    var providerID: UUID?
    var modelID: String?
    var recoveryNotices: [String: String]?
    var phase: RunPhase = .idle
    var messages: [ChatMessage] = []
    var preview: String {
        if entry?.state == .pendingConfirmation { return String(localized: "Siri · Awaiting confirmation: \(draft)") }
        return messages.last(where: { $0.role == .user || $0.role == .assistant })?.text ?? String(localized: "Start a new task or question")
    }
}

/// Presentation-only grouping; archives and model replay keep their original messages.
struct ConversationTurn: Identifiable {
    var messages: [ChatMessage]
    var id: UUID { messages[0].id }
    var runID: UUID? { messages.compactMap(\.runID).first }
    var tools: [ChatMessage] { messages.filter { $0.role == .tool && $0.tool != nil } }
    var thoughts: [ChatMessage] {
        messages.filter { $0.role == .assistant && $0.reasoning?.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false }
    }
    private func hasActivity(_ message: ChatMessage) -> Bool {
        message.tool != nil || (message.role == .assistant && message.reasoning?.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false)
    }
    var firstActivityID: UUID? { messages.first(where: hasActivity)?.id }
    var foldedMessages: [ChatMessage] {
        guard let first = messages.firstIndex(where: hasActivity), let last = messages.lastIndex(where: hasActivity) else { return [] }
        // Preserve interleaved replies and notices as well as tools and thoughts.
        return Array(messages[first...last])
    }
    var summaryLabel: String {
        var counts: [String] = []
        if !tools.isEmpty { counts.append(String(localized: "\(tools.count) tool calls")) }
        if !thoughts.isEmpty { counts.append(String(localized: "\(thoughts.count) reasoning notes")) }
        return counts.joined(separator: " · ")
    }
    static func group(_ messages: [ChatMessage]) -> [ConversationTurn] {
        var turns: [ConversationTurn] = []
        for message in messages {
            let differentRun = message.runID.map { run in turns.last?.runID.map { $0 != run } ?? false } ?? false
            if turns.isEmpty || message.role == .user || differentRun {
                turns.append(ConversationTurn(messages: [message]))
            } else { turns[turns.count - 1].messages.append(message) }
        }
        return turns
    }
}
extension RunPhase {
    var label: String {
        switch self {
        case .idle: return String(localized: "Ready")
        case .running: return String(localized: "Running")
        case .awaitingApproval: return String(localized: "Waiting for confirmation")
        case .stopped: return String(localized: "Stopped")
        case .interrupted: return String(localized: "Interrupted")
        case .completed: return String(localized: "Finished")
        case .blocked: return String(localized: "Needs attention")
        }
    }
}
