import Foundation

public struct StreamCheckpoint: Codable, Sendable {
    public var version = 1
    public var scope: ProviderScope?
    public let responseID: String?
    public let sequence: Int?
    public let terminal: ResponseStatus?
    public var itemIDs: [Int: String] = [:]
    public var completedItems: [Int: ModelOutputItem] = [:]
    public var contentPreviews: [String: String] = [:]
    public var argumentPreviews: [String: String] = [:]
    public var events: [ProviderStreamEvent]?
    public init(responseID: String?, sequence: Int?, terminal: ResponseStatus?) { self.responseID = responseID; self.sequence = sequence; self.terminal = terminal }
}

/// Pure format projection; retention and context ownership belong to AgentKit.
public enum ModelInputProjection {
    public static func input(messages: [ModelMessage]) throws -> [ModelInputItem] {
        var result: [ModelInputItem] = []
        for message in messages {
            if message.role == .system { continue }
            if message.role == .tool {
                guard let id = message.toolCallId, !id.isEmpty else { throw ModelError.invalidRequest("Tool result missing call ID") }
                result.append(.functionResult(callID: id, output: message.content))
                if !message.images.isEmpty { result.append(.message(role: .tool, content: message.images.map(ModelInputContent.image))) }
            } else {
                if !message.content.isEmpty || !message.images.isEmpty {
                    result.append(.message(role: message.role, content: [.text(message.content)] + message.images.map(ModelInputContent.image)))
                }
                for call in message.toolCalls ?? [] { result.append(.replay(.functionCall(call))) }
                if let state = message.replayState { result.append(.chatReplayState(state)) }
            }
        }
        return result
    }
}
