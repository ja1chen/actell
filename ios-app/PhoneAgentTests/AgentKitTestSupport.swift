import Foundation
import AgentKit
import ProviderCore

/// Public facts used by App-owned model fixtures; the runtime owns canonical context.
func fixtureMessages(_ request: ModelRequest) -> [ModelMessage] {
    guard let input = request.input else { return request.messages }
    var result = request.instructions.map { [ModelMessage.system($0)] } ?? []
    for item in input {
        switch item {
        case .message(let role, let parts):
            let text = parts.compactMap { if case .text(let text) = $0 { return text }; return nil }.joined()
            let images = parts.compactMap { if case .image(let image) = $0 { return image }; return nil }
            result.append(.init(role: role, content: text, images: images))
        case .functionResult(let id, let output): result.append(.tool(output, toolCallId: id))
        case .replay(.functionCall(let call)):
            if result.last?.role == .assistant { result[result.count - 1].toolCalls = (result.last?.toolCalls ?? []) + [call] }
            else { result.append(.assistant(toolCalls: [call])) }
        case .replay(.message(let value)):
            result.append(.assistant(value.content.map { part in switch part { case .text(let text, _), .refusal(let text): return text } }.joined()))
        case .chatReplayState(let state):
            if let index = result.lastIndex(where: { $0.role == .assistant }) { result[index].replayState = state }
        case .replay(.reasoning), .replay(.compaction), .replay(.providerOwned), .replay(.unknown), .compacted: break
        }
    }
    return result
}
struct AgentKitAppTestRun: Sendable {
    let runtime: AgentRuntime
    let store: JSONLSessionStore
    let sessionID: UUID
    let stopHost: @Sendable () async -> Void
    init(provider: any ModelProvider, tools: [any AgentTool], directory: URL, sessionID: UUID = UUID(), stopHost: @escaping @Sendable () async -> Void = {}) {
        self.stopHost = stopHost
        self.sessionID = sessionID; self.store = JSONLSessionStore(root: directory, sessionID: sessionID)
        self.runtime = AgentRuntime(store: store, provider: provider, configuration: .init(model: "fixture"), tools: tools)
    }
    func start(_ text: String) async throws -> TurnHandle {
        _ = try await runtime.createSession(id: sessionID)
        return try await runtime.startTurn(in: sessionID, input: .init(text: text))
    }
    func run(_ text: String) async throws -> String {
        let handle = try await start(text), result = await handle.result()
        guard result.status != .failed else { throw ModelError.invalidResponse(result.error ?? "Fixture turn failed") }
        return result.text
    }
    func cancel(_ turn: UUID) async { await runtime.cancelTurn(turn); await stopHost() }
    func results() async throws -> [ToolResultRecord] { try await store.readTransactions(sessionID).flatMap(\.toolResults) }
}
