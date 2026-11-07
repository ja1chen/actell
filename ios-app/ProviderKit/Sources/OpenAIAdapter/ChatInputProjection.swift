import Foundation
import ProviderCore

extension OpenAIWireCodec {
    /// Converts canonical complete context at the wire boundary, without owning or trimming it.
    func chatMessages(_ items: [ModelInputItem], instructions: String?) throws -> [ModelMessage] {
        var messages: [ModelMessage] = instructions.map { [.system($0)] } ?? []
        var assistant: ModelMessage?
        func flush() { if let value = assistant { messages.append(value); assistant = nil } }
        for item in items {
            switch item {
            case .message(let role, let content):
                flush()
                let text = content.compactMap { if case .text(let value) = $0 { return value }; return nil }.joined()
                let images = content.compactMap { if case .image(let value) = $0 { return value }; return nil }
                if role == .tool, let last = messages.indices.last, messages[last].role == .tool {
                    messages[last].images += images
                } else { messages.append(.init(role: role == .tool ? .user : role, content: text, images: images)) }
            case .functionResult(let id, let output): flush(); messages.append(.tool(output, toolCallId: id))
            case .chatReplayState(let state):
                _ = try state.reasoningDetailsForReplay(scope: scope)
                if var value = assistant { value.replayState = state; assistant = value }
                else if let index = messages.lastIndex(where: { $0.role == .assistant }) { messages[index].replayState = state }
                else { throw ModelError.protocolViolation("Chat replay state has no assistant output") }
            case .compacted: throw ModelError.unsupportedCapability("Native compacted context cannot enter Chat Completions")
            case .replay(let output):
                _ = try output.asReplayInput(scope: scope)
                switch output {
                case .message(let value):
                    let text = value.content.map { switch $0 { case .text(let text, _): return text; case .refusal(let text): return text } }.joined()
                    let previous = assistant
                    assistant = .init(role: .assistant, content: (previous?.content ?? "") + text, toolCalls: previous?.toolCalls, replayState: previous?.replayState)
                case .functionCall(let call):
                    let previous = assistant
                    assistant = .init(role: .assistant, content: previous?.content ?? "", toolCalls: (previous?.toolCalls ?? []) + [call], replayState: previous?.replayState)
                case .reasoning: break // Readable reasoning is presentation, never a fabricated user message.
                case .compaction, .unknown, .providerOwned: throw ModelError.unsupportedCapability("Unsupported Chat replay item")
                }
            }
        }
        flush()
        return messages
    }
}
