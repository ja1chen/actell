import Foundation

public struct PromptCachePolicy: Sendable, Equatable, Codable {
    public let key: String?, retention: String?
    public init(key: String? = nil, retention: String? = nil) { self.key = key; self.retention = retention }
}
public struct ModelCompactionRequest: Sendable {
    public let model: String, input: [ModelInputItem], instructions: String?, id: UUID
    public init(model: String, input: [ModelInputItem], instructions: String? = nil, id: UUID = UUID()) { self.model = model; self.input = input; self.instructions = instructions; self.id = id }
}
public struct ModelCompactionResponse: Sendable {
    public let id: String, scope: ProviderScope, input: [ModelInputItem], usage: ModelUsage?
    public init(id: String, scope: ProviderScope, input: [ModelInputItem], usage: ModelUsage? = nil) { self.id = id; self.scope = scope; self.input = input; self.usage = usage }
}
public protocol ModelCompactingProvider: ModelProvider {
    func compact(_ request: ModelCompactionRequest) async throws -> ModelCompactionResponse
}
