import Foundation
import AgentKit
import ProviderCore

/// App DTO conversion only. Execution and context are owned by the same AgentKit journal.
enum AgentSessionPersistence {
    private struct LegacyRecord: Decodable {
        var version: Int
        var metadata: AgentConversation
        var messages: [ChatMessage]
        var removedMessageIDs: [UUID]
    }

    static func metadata(_ conversation: AgentConversation) throws -> ProviderCore.JSONValue {
        var value = conversation
        value.messages = []; value.cachedPreview = nil
        return .object(["appConversation": try json(value)])
    }

    static func display(_ message: ChatMessage, legacy: Bool = false) throws -> DisplayItem {
        .init(id: message.id, turnID: message.runID, role: message.role.rawValue, text: message.text,
              state: message.state.rawValue, metadata: .object([
                "appMessage": try json(message), "origin": .string(legacy ? "legacy" : "app")
              ]))
    }

    static func migrate(_ data: Data, sessionID: UUID) throws -> [SessionTransaction] {
        var value: AgentConversation?
        var messages: [ChatMessage] = []
        var start = data.startIndex
        for end in data.indices where data[end] == 0x0A {
            let record = try JSONDecoder().decode(LegacyRecord.self, from: data[start..<end])
            guard record.version == 1, record.metadata.id == sessionID, record.metadata.messages.isEmpty,
                  Set(record.messages.map(\.id)).count == record.messages.count,
                  (record.metadata.draftAttachments ?? []).allSatisfy({ $0.conversationID == sessionID }) else { throw ConversationJournal.Failure.invalidFormat }
            let removed = Set(record.removedMessageIDs)
            messages.removeAll { removed.contains($0.id) }
            for message in record.messages {
                guard (message.attachments ?? []).allSatisfy({ $0.conversationID == sessionID }) else { throw ConversationJournal.Failure.invalidFormat }
                if let index = messages.firstIndex(where: { $0.id == message.id }) { messages[index] = message }
                else { messages.append(message) }
            }
            value = record.metadata
            start = end + 1
        }
        guard var value else { throw ConversationJournal.Failure.invalidFormat }
        value.messages = messages
        return try importConversation(value)
    }

    /// Convert the App-owned archive directly to the final session transaction.
    /// Historical attachments remain presentation-only and tools are facts.
    static func importConversation(_ value: AgentConversation) throws -> [SessionTransaction] {
        guard (value.draftAttachments ?? []).allSatisfy({ $0.conversationID == value.id }),
              value.messages.allSatisfy({ ($0.attachments ?? []).allSatisfy { $0.conversationID == value.id } }),
              Set(value.messages.map(\.id)).count == value.messages.count else { throw ConversationJournal.Failure.invalidFormat }
        // Legacy UI records cannot supply missing native calls, opaque items or attachment consent.
        var transactions = [SessionTransaction(sessionID: value.id, kind: .legacyImported, metadata: try metadata(value))]
        var context: [ModelInputItem] = [], displayItems: [DisplayItem] = []
        var seenCalls: Set<String> = [], batchBytes = 0
        func flush() {
            guard !displayItems.isEmpty else { return }
            transactions.append(SessionTransaction(sessionID: value.id, kind: .legacyImported, contextItems: context, displayItems: displayItems))
            context = []; displayItems = []; batchBytes = 0
        }
        for message in value.messages {
            let rawBytes = message.text.utf8.count + (message.reasoning?.text.utf8.count ?? 0)
                + (message.tool?.result.utf8.count ?? 0) + (message.tool?.arguments?.utf8.count ?? 0)
            if !displayItems.isEmpty, batchBytes + rawBytes > 1_024 * 1_024 { flush() }
            batchBytes += rawBytes
            displayItems.append(try display(message, legacy: true))
            switch message.role {
            case .user, .assistant:
                if message.state == .complete, !message.text.isEmpty {
                    context.append(.message(role: message.role == .user ? .user : .assistant, content: [.text(message.text)]))
                }
            case .tool:
                guard let tool = message.tool else { break }
                let arguments = tool.arguments ?? ""
                let call = ModelToolCall(id: tool.callID, name: tool.name, arguments: arguments)
                let complete = tool.state.isTerminal && !tool.callID.isEmpty && !tool.name.isEmpty && !tool.result.isEmpty
                    && call.decodedArguments() != nil && seenCalls.insert(tool.callID).inserted
                if complete {
                    let kind: ToolOutcomeKind
                    switch tool.state {
                    case .succeeded: kind = .returned
                    case .denied: kind = .denied
                    case .cancelled, .outcomeUnknown, .interrupted: kind = .outcomeUnknown
                    default: kind = tool.result.isEmpty ? .outcomeUnknown : .infrastructureFailure
                    }
                    let result = ToolOutcome(kind: kind, content: tool.result).modelContent
                    context.append(.replay(.functionCall(call)))
                    context.append(.functionResult(callID: tool.callID, output: result))
                } else {
                    // Preserve only known facts as portable text; this does not
                    // create a pending invocation or an executable call.
                    let text = "Historical tool record: name=\(tool.name), call_id=\(tool.callID), state=\(tool.state.rawValue). The complete call and result are unavailable; no action was replayed."
                    context.append(.message(role: .assistant, content: [.text(text)]))
                }
            case .notice: break
            }
            if displayItems.count == 16 { flush() }
        }
        flush()
        return transactions
    }

    static func conversation(from presentation: SessionPresentation, sessionID: UUID) throws -> AgentConversation {
        guard case .object(let metadata)? = presentation.metadata, let encoded = metadata["appConversation"] else {
            throw ConversationJournal.Failure.invalidFormat
        }
        var conversation: AgentConversation = try decode(encoded)
        guard conversation.id == sessionID, conversation.messages.isEmpty else { throw ConversationJournal.Failure.invalidFormat }
        conversation.messages = try presentation.items.map { item in
            let values = item.metadata?.foundation as? [String: Any] ?? [:]
            var message: ChatMessage
            if case .object(let object)? = item.metadata, let encoded = object["appMessage"],
               let decoded: ChatMessage = try? decode(encoded), decoded.id == item.id {
                message = decoded
            } else {
                message = ChatMessage(id: item.id, runID: item.turnID,
                    role: item.role == "reasoning" ? .assistant : (ChatRole(rawValue: item.role) ?? .notice),
                    text: item.text, date: item.createdAt ?? conversation.createdAt)
            }
            if item.role == "assistant" {
                message.text = item.text
                message.state = MessageState(rawValue: item.state) ?? .complete
                if let reasoning = values["reasoning"] as? String, !reasoning.isEmpty {
                    message.reasoning = .init(text: reasoning, state: message.state)
                }
            } else if item.role == "reasoning" {
                message.text = ""
                message.reasoning = .init(text: item.text, state: MessageState(rawValue: item.state) ?? .complete)
            } else if item.role == "tool", let callID = values["callID"] as? String, let name = values["name"] as? String {
                message.role = .tool; message.text = ""
                var tool = message.tool ?? ToolStep(callID: callID, name: name, state: .requested, detail: "")
                if let outcome = values["outcome"] as? String {
                    tool.result = item.text
                    switch outcome {
                    case "returned": tool.state = .succeeded
                    case "outcomeUnknown": tool.state = .outcomeUnknown
                    case "denied": tool.state = .denied
                    case "cancelledBeforeDispatch": tool.state = .cancelled
                    default: tool.state = .failed
                    }
                }
                if tool.arguments == nil { tool.arguments = ToolStep.nonemptyArguments(values["rawArguments"] as? String) }
                message.tool = tool
            }
            for image in presentation.toolImages[item.id] ?? [] {
                let attachment = StoredAttachment.sessionImage(image, conversationID: sessionID)
                if !(message.attachments ?? []).contains(where: { $0.digest == attachment.digest }) {
                    message.attachments = (message.attachments ?? []) + [attachment]
                }
            }
            return message
        }
        return conversation
    }

    private static func json<T: Encodable>(_ value: T) throws -> ProviderCore.JSONValue {
        try JSONDecoder().decode(ProviderCore.JSONValue.self, from: JSONEncoder().encode(value))
    }
    private static func decode<T: Decodable>(_ value: ProviderCore.JSONValue) throws -> T {
        try JSONDecoder().decode(T.self, from: JSONEncoder().encode(value))
    }
}
