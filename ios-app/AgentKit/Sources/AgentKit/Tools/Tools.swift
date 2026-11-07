import Foundation
import CryptoKit
import ProviderCore

public enum ToolEffect: String, Codable, Sendable { case readOnly, localMutation, deviceMutation }

public struct ToolDescriptor: Sendable {
    public let name: String
    public let description: String
    public let parameters: JSONValue
    public let effect: ToolEffect
    public init(name: String, description: String, parameters: JSONValue, effect: ToolEffect = .readOnly) {
        self.name = name; self.description = description; self.parameters = parameters; self.effect = effect
    }
    public var modelDefinition: ModelToolDefinition { .init(name: name, description: description, schema: parameters) }
}

public struct ToolInvocation: Sendable, Equatable {
    public let sessionID: UUID
    public let turnID: UUID
    public let call: ModelToolCall
    public var callID: String { call.id }
    public var displayItemID: UUID {
        let digest = SHA256.hash(data: Data("\(sessionID.uuidString)/\(turnID.uuidString)/\(callID)".utf8))
        let bytes = Array(digest.prefix(16))
        return UUID(uuid: (bytes[0],bytes[1],bytes[2],bytes[3],bytes[4],bytes[5],bytes[6],bytes[7],bytes[8],bytes[9],bytes[10],bytes[11],bytes[12],bytes[13],bytes[14],bytes[15]))
    }
    public var name: String { call.name }
    public var rawArguments: String { call.arguments }
    public var arguments: JSONValue { (try? JSONDecoder().decode(JSONValue.self, from: Data(call.arguments.utf8))) ?? .null }
    public init(sessionID: UUID, turnID: UUID, call: ModelToolCall) { self.sessionID = sessionID; self.turnID = turnID; self.call = call }
}

public enum ToolOutcomeKind: String, Codable, Sendable {
    case returned, validationFailed, denied, cancelledBeforeDispatch, outcomeUnknown, infrastructureFailure
}
public struct ToolOutcome: Codable, Sendable, Equatable {
    public let kind: ToolOutcomeKind
    public let content: String
    public let images: [ModelImage]
    /// Set only by a trusted host tool; closes remaining calls without dispatch and completes the turn.
    public let finishTurn: Bool
    public init(kind: ToolOutcomeKind = .returned, content: String, images: [ModelImage] = [], finishTurn: Bool = false) {
        self.kind = kind; self.content = content; self.images = images; self.finishTurn = finishTurn
    }
    public var stopsBatch: Bool { kind == .denied || kind == .cancelledBeforeDispatch }
    /// Successful tool text stays byte-for-byte stable. Failures carry an explicit machine-readable classification.
    public var modelContent: String {
        guard kind != .returned else { return content }
        let value = JSONValue.object(["outcome": .string(kind.rawValue), "message": .string(content)])
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return (try? String(decoding: encoder.encode(value), as: UTF8.self)) ?? kind.rawValue
    }
}

public actor ExecutionFence {
    private var valid = true
    public init() {}
    public func invalidate() { valid = false }
    public func check() throws { guard valid else { throw CancellationError() } }
    public var isValid: Bool { valid }
}
public struct ToolExecutionContext: Sendable {
    public let sessionID: UUID
    public let turnID: UUID
    public let generation: UUID
    public let fence: ExecutionFence
    public init(sessionID: UUID, turnID: UUID, generation: UUID, fence: ExecutionFence) {
        self.sessionID = sessionID; self.turnID = turnID; self.generation = generation; self.fence = fence
    }
    /// Host tools must call this immediately before committing their own dispatch checkpoint and sending an effect.
    public func checkCancellation() async throws { try Task.checkCancellation(); try await fence.check() }
}
public protocol AgentTool: Sendable {
    var descriptor: ToolDescriptor { get }
    func execute(_ invocation: ToolInvocation, context: ToolExecutionContext) async throws -> ToolOutcome
}
public struct ClosureTool: AgentTool {
    public let descriptor: ToolDescriptor
    private let body: @Sendable (ToolInvocation, ToolExecutionContext) async throws -> ToolOutcome
    public init(descriptor: ToolDescriptor, execute: @escaping @Sendable (ToolInvocation, ToolExecutionContext) async throws -> ToolOutcome) {
        self.descriptor = descriptor; self.body = execute
    }
    public func execute(_ invocation: ToolInvocation, context: ToolExecutionContext) async throws -> ToolOutcome { try await body(invocation, context) }
}
