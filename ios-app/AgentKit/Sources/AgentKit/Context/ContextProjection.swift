import Foundation
import ProviderCore

public enum ContextProjection {
    /// Rebuild public facts from authoritative transaction history when encrypted replay material cannot cross scope.
    public static func portableItems(from transactions: [SessionTransaction]) -> [ModelInputItem] {
        transactions.flatMap(\.contextItems).compactMap(portableItem)
    }
    public static func portableItem(_ item: ModelInputItem) -> ModelInputItem? {
        switch item {
        case .message, .functionResult: return item
        case .compacted, .chatReplayState: return nil
        case .replay(let output):
            switch output {
            case .message(let value):
                let text = value.content.map { part in switch part { case .text(let text, _), .refusal(let text): return text } }.joined()
                return .message(role: .assistant, content: [.text(text)])
            case .functionCall(let call):
                return .replay(.functionCall(.init(id: call.id, itemID: call.itemID, name: call.name, arguments: call.arguments)))
            case .reasoning, .compaction, .providerOwned, .unknown: return nil
            }
        }
    }
    public static func validateClosedTools(_ items: [ModelInputItem]) throws {
        var pending = Set<String>(), seen = Set<String>()
        for item in items {
            switch item {
            case .replay(.functionCall(let call)):
                guard !call.id.isEmpty, seen.insert(call.id).inserted, pending.insert(call.id).inserted else { throw AgentRuntimeError.invalidTerminal("duplicate context tool call") }
            case .functionResult(let id, _):
                guard pending.remove(id) != nil else { throw AgentRuntimeError.invalidTerminal("orphan context tool result") }
            case .compacted(let value) where value.type == "function_call_output":
                guard case .object(let payload) = value.payload, case .string(let id) = payload["call_id"], pending.remove(id) != nil else { throw AgentRuntimeError.invalidTerminal("orphan compacted tool result") }
            default: break
            }
        }
        guard pending.isEmpty else { throw AgentRuntimeError.invalidTerminal("unclosed context tool group") }
    }
    static func completeGroups(_ items: [ModelInputItem]) -> [[ModelInputItem]] {
        var groups: [[ModelInputItem]] = [], group: [ModelInputItem] = [], pending = Set<String>()
        for item in items {
            if case .chatReplayState = item, group.isEmpty, !groups.isEmpty { groups[groups.count - 1].append(item); continue }
            group.append(item)
            if case .replay(.reasoning) = item { continue }
            switch item { case .replay(.functionCall(let call)): pending.insert(call.id); case .functionResult(let id, _): pending.remove(id); case .compacted(let value) where value.type == "function_call_output": if case .object(let payload) = value.payload, case .string(let id) = payload["call_id"] { pending.remove(id) }; default: break }
            if pending.isEmpty { groups.append(group); group = [] }
        }
        if !group.isEmpty { groups.append(group) }
        return groups
    }
    static func readable(_ item: ModelInputItem) -> String {
        switch item {
        case .message(let role, let parts): return "\(role.rawValue): " + parts.map { part in switch part { case .text(let text): return text; case .image: return "[image retained separately]" } }.joined(separator: "\n")
        case .functionResult(let id, let output): return "tool result \(id): \(output)"
        case .compacted: return "[native item requires public source reconstruction]"
        case .chatReplayState: return "[signed reasoning is not portable historical data]"
        case .replay(let output):
            switch output {
            case .message(let value): return "assistant: " + value.content.map { part in switch part { case .text(let text, _), .refusal(let text): return text } }.joined()
            case .functionCall(let call): return "tool call \(call.id) \(call.name): \(call.arguments)"
            case .reasoning: return "[reasoning replay omitted from portable memory]"
            case .compaction: return "[native compaction requires public source reconstruction]"
            case .providerOwned, .unknown: return "[provider-specific item omitted from portable memory]"
            }
        }
    }
}
