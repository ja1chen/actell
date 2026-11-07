import Foundation
import ProviderCore
typealias DurableBlobWriter = (Data) throws -> String
typealias DurableBlobReader = (String, Int) throws -> Data
private let durableInlineLimit = 64 * 1024

struct DurableBlobReference: Codable {
    var digest: String
    var size: Int
    init(_ bytes: Data, writeBlob: DurableBlobWriter) throws { digest = try writeBlob(bytes); size = bytes.count }
    func bytes(readBlob: DurableBlobReader) throws -> Data { try readBlob(digest, size) }
}
private func durableText(_ text: String, inline: Bool, writeBlob: DurableBlobWriter) throws -> (String?, DurableBlobReference?) {
    guard !inline && text.utf8.count > durableInlineLimit else { return (text, nil) }
    return (nil, try DurableBlobReference(Data(text.utf8), writeBlob: writeBlob))
}
private func resolvedText(_ inline: String?, _ reference: DurableBlobReference?, readBlob: DurableBlobReader) throws -> String {
    switch (inline, reference) {
    case (.some(let value), .none): return value
    case (.none, .some(let reference)):
        let bytes = try reference.bytes(readBlob: readBlob)
        guard let value = String(data: bytes, encoding: .utf8) else { throw StoreError.corruptHistory }
        return value
    default: throw StoreError.invalidRecord
    }
}
private func durableMetadata(_ value: JSONValue?, inline: Bool, writeBlob: DurableBlobWriter) throws -> (JSONValue?, DurableBlobReference?) {
    guard let value else { return (nil, nil) }
    if inline { return (value, nil) }
    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    let bytes = try encoder.encode(value)
    guard bytes.count > durableInlineLimit else { return (value, nil) }
    return (nil, try DurableBlobReference(bytes, writeBlob: writeBlob))
}
private func resolvedMetadata(_ inline: JSONValue?, _ reference: DurableBlobReference?, readBlob: DurableBlobReader) throws -> JSONValue? {
    switch (inline, reference) {
    case (.some(let value), .none): return value
    case (.none, .some(let reference)):
        do { return try JSONDecoder().decode(JSONValue.self, from: reference.bytes(readBlob: readBlob)) }
        catch let error as StoreError { throw error }
        catch { throw StoreError.corruptHistory }
    case (.none, .none): return nil
    case (.some, .some): throw StoreError.invalidRecord
    }
}

// Stable, explicitly tagged representations. Provider enums' synthesized Codable layout
// is deliberately not part of the on-disk schema.
struct DurableInput: Codable {
    var type: String
    var role: ModelMessageRole?
    var content: [DurableContent]?
    var callID: String?
    var output: String?
    var outputRef: DurableBlobReference?
    var replay: DurableOutput?
    var compacted: ProviderOwnedItem?
    var chatReplayState: ScopedChatReplayState?
    init(_ value: ModelInputItem, inline: Bool = false, writeBlob: DurableBlobWriter) throws {
        switch value {
        case .message(let role, let content): self.type = "message"; self.role = role; self.content = try content.map { try DurableContent($0, inline: inline, writeBlob: writeBlob) }
        case .functionResult(let id, let output): self.type = "function_result"; self.callID = id; (self.output, self.outputRef) = try durableText(output, inline: inline, writeBlob: writeBlob)
        case .replay(let output): self.type = "replay"; self.replay = try DurableOutput(output)
        case .compacted(let item): self.type = "compacted"; self.compacted = item
        case .chatReplayState(let state): self.type = "chat_replay_state"; self.chatReplayState = state
        }
    }
    func value(readBlob: DurableBlobReader) throws -> ModelInputItem {
        switch type {
        case "message": guard let role, let content else { throw StoreError.invalidRecord }; return .message(role: role, content: try content.map { try $0.value(readBlob: readBlob) })
        case "function_result": guard let callID else { throw StoreError.invalidRecord }; return .functionResult(callID: callID, output: try resolvedText(output, outputRef, readBlob: readBlob))
        case "replay": guard let replay else { throw StoreError.invalidRecord }; return .replay(try replay.value())
        case "compacted": guard let compacted else { throw StoreError.invalidRecord }; return .compacted(compacted)
        case "chat_replay_state": guard let chatReplayState else { throw StoreError.invalidRecord }; return .chatReplayState(chatReplayState)
        default: throw StoreError.unsupportedSchema
        }
    }
}
struct DurableContent: Codable {
    var type: String
    var text: String?
    var textRef: DurableBlobReference?
    var image: DurableImage?
    init(_ value: ModelInputContent, inline: Bool = false, writeBlob: DurableBlobWriter) throws {
        switch value { case .text(let text): type = "text"; (self.text, self.textRef) = try durableText(text, inline: inline, writeBlob: writeBlob)
        case .image(let image): type = "image"; self.image = try DurableImage(image, writeBlob: writeBlob) }
    }
    func value(readBlob: DurableBlobReader) throws -> ModelInputContent {
        switch type { case "text": guard image == nil else { throw StoreError.invalidRecord }; return .text(try resolvedText(text, textRef, readBlob: readBlob))
        case "image": guard let image, text == nil, textRef == nil else { throw StoreError.invalidRecord }; return .image(try image.value(readBlob: readBlob))
        default: throw StoreError.unsupportedSchema }
    }
}
struct DurableDisplayItem: Codable {
    var id: UUID
    var turnID: UUID?
    var role: String
    var text: String?
    var textRef: DurableBlobReference?
    var state: String
    var createdAt: Date?
    var metadata: JSONValue?
    var metadataRef: DurableBlobReference?
    init(_ value: DisplayItem, inline: Bool = false, writeBlob: DurableBlobWriter) throws {
        id = value.id; turnID = value.turnID; role = value.role; state = value.state; createdAt = value.createdAt
        (text, textRef) = try durableText(value.text, inline: inline, writeBlob: writeBlob)
        (metadata, metadataRef) = try durableMetadata(value.metadata, inline: inline, writeBlob: writeBlob)
    }
    func value(readBlob: DurableBlobReader) throws -> DisplayItem {
        let restoredMetadata = try resolvedMetadata(metadata, metadataRef, readBlob: readBlob)
        return DisplayItem(id: id, turnID: turnID, role: role, text: try resolvedText(text, textRef, readBlob: readBlob), state: state, metadata: restoredMetadata, createdAt: createdAt)
    }
}
struct DurableImage: Codable {
    var digest: String
    var size: Int
    var mimeType: String
    var observationID: String?
    var width: Int?
    var height: Int?
    init(_ value: ModelImage, writeBlob: DurableBlobWriter) throws {
        guard value.fileURL == nil else { throw StoreError.invalidPath }
        digest = try writeBlob(value.data); size = value.data.count; mimeType = value.mimeType
        observationID = value.observationID; width = value.width; height = value.height
    }
    func value(readBlob: DurableBlobReader) throws -> ModelImage {
        var image = ModelImage(data: try readBlob(digest, size), mimeType: mimeType)
        image.observationID = observationID; image.width = width; image.height = height
        return image
    }
}
struct DurableOutput: Codable {
    var type: String
    var message: DurableMessage?
    var call: ModelToolCall?
    var reasoning: DurableReasoning?
    var owned: ProviderOwnedItem?
    var compaction: DurableCompaction?
    init(_ value: ModelOutputItem) throws {
        switch value {
        case .message(let value): type = "message"; message = DurableMessage(value)
        case .functionCall(let value): type = "function_call"; call = value
        case .reasoning(let value): type = "reasoning"; reasoning = DurableReasoning(value)
        case .providerOwned(let value): type = "provider_owned"; owned = value
        case .unknown(let value): type = "unknown"; owned = value
        case .compaction(let value): type = "compaction"; compaction = DurableCompaction(value)
        }
    }
    func value() throws -> ModelOutputItem {
        switch type {
        case "message": guard let message else { throw StoreError.invalidRecord }; return .message(try message.value())
        case "function_call": guard let call else { throw StoreError.invalidRecord }; return .functionCall(call)
        case "reasoning": guard let reasoning else { throw StoreError.invalidRecord }; return .reasoning(reasoning.value())
        case "provider_owned": guard let owned else { throw StoreError.invalidRecord }; return .providerOwned(owned)
        case "unknown": guard let owned else { throw StoreError.invalidRecord }; return .unknown(owned)
        case "compaction": guard let compaction else { throw StoreError.invalidRecord }; return .compaction(compaction.value())
        default: throw StoreError.unsupportedSchema
        }
    }
}
struct DurableReasoning: Codable {
    var id: String
    var summary: [String]
    var encryptedContent: String?
    var scope: ProviderScope?
    var extra: [String: JSONValue]
    init(_ value: ReasoningItem) { id = value.id; summary = value.summary; encryptedContent = value.encryptedContentForReplay; scope = value.scope; extra = value.extra }
    func value() -> ReasoningItem { .init(id: id, summary: summary, encryptedContent: encryptedContent, scope: scope, extra: extra) }
}
struct DurableCompaction: Codable {
    var id: String?
    var encryptedContent: String
    var scope: ProviderScope
    var extra: [String: JSONValue]
    init(_ value: CompactionItem) { id = value.id; encryptedContent = value.encryptedContentForReplay; scope = value.scope; extra = value.extra }
    func value() -> CompactionItem { .init(id: id, encryptedContent: encryptedContent, scope: scope, extra: extra) }
}
struct DurableMessage: Codable {
    struct Part: Codable {
        var type: String
        var text: String
        var annotations: [JSONValue]?
        init(_ content: ModelOutputContent) {
            switch content { case .text(let text, let annotations): type = "text"; self.text = text; self.annotations = annotations
            case .refusal(let text): type = "refusal"; self.text = text }
        }
        func value() throws -> ModelOutputContent {
            switch type { case "text": return .text(text, annotations: annotations ?? [])
            case "refusal": return .refusal(text)
            default: throw StoreError.unsupportedSchema }
        }
    }
    var id: String
    var content: [Part]
    var phase: String?
    var scope: ProviderScope?
    var status: ResponseStatus
    var extra: [String: JSONValue]
    init(_ value: OutputMessage) { id = value.id; content = value.content.map(Part.init); phase = value.phase; scope = value.scope; status = value.status; extra = value.extra }
    func value() throws -> OutputMessage { .init(id: id, content: try content.map { try $0.value() }, phase: phase, status: status, extra: extra, scope: scope) }
}
struct DurableSnapshot: Codable {
    var epoch: UUID
    var scope: ProviderScope?
    var items: [DurableInput]
    var head: String?
    var headCoveredItemCount: Int
    var preservedNativeItemCount: Int?
    init(_ value: ContextSnapshot, inline: Bool = false, writeBlob: DurableBlobWriter) throws { epoch = value.epoch; scope = value.scope; items = try value.items.map { try DurableInput($0, inline: inline, writeBlob: writeBlob) }; head = value.head; headCoveredItemCount = value.headCoveredItemCount; preservedNativeItemCount = value.preservedNativeItemCount }
    func value(readBlob: DurableBlobReader) throws -> ContextSnapshot { .init(epoch: epoch, scope: scope, items: try items.map { try $0.value(readBlob: readBlob) }, head: head, headCoveredItemCount: headCoveredItemCount, preservedNativeItemCount: preservedNativeItemCount ?? 0) }
}
struct DurableToolResult: Codable {
    var turnID: UUID
    var callID: String
    var kind: ToolOutcomeKind
    var content: String
    var images: [DurableImage]
    var finishTurn: Bool
    init(_ value: ToolResultRecord, writeBlob: DurableBlobWriter) throws {
        turnID = value.turnID; callID = value.callID; kind = value.outcome.kind; content = value.outcome.content
        images = try value.outcome.images.map { try DurableImage($0, writeBlob: writeBlob) }; finishTurn = value.outcome.finishTurn
    }
    func value(readBlob: DurableBlobReader) throws -> ToolResultRecord {
        .init(turnID: turnID, callID: callID, outcome: .init(kind: kind, content: content, images: try images.map { try $0.value(readBlob: readBlob) }, finishTurn: finishTurn))
    }
}
struct DurableTransaction: Codable {
    var id: UUID
    var sessionID: UUID
    var turnID: UUID?
    var kind: TransactionKind
    var createdAt: Date
    var contextItems: [DurableInput]
    var displayItems: [DurableDisplayItem]
    var usage: ModelUsage?
    var snapshot: DurableSnapshot?
    var contextHead: ContextHead?
    var toolClaims: [String]
    var toolResults: [DurableToolResult]
    var metadata: JSONValue?
    var metadataRef: DurableBlobReference?
    var removedDisplayItemIDs: [UUID]
    private enum CodingKeys: String, CodingKey {
        case id, sessionID, turnID, kind, createdAt, contextItems, displayItems, usage, snapshot, contextHead, toolClaims, toolResults, metadata, metadataRef, removedDisplayItemIDs
    }
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id); sessionID = try c.decode(UUID.self, forKey: .sessionID)
        turnID = try c.decodeIfPresent(UUID.self, forKey: .turnID); kind = try c.decode(TransactionKind.self, forKey: .kind)
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date(timeIntervalSince1970: 0)
        contextItems = try c.decode([DurableInput].self, forKey: .contextItems)
        displayItems = try c.decode([DurableDisplayItem].self, forKey: .displayItems)
        // Statistics are optional and cannot invalidate authoritative facts.
        usage = try? c.decode(ModelUsage.self, forKey: .usage)
        snapshot = try c.decodeIfPresent(DurableSnapshot.self, forKey: .snapshot)
        contextHead = try c.decodeIfPresent(ContextHead.self, forKey: .contextHead)
        toolClaims = try c.decode([String].self, forKey: .toolClaims)
        toolResults = try c.decode([DurableToolResult].self, forKey: .toolResults)
        metadata = try c.decodeIfPresent(JSONValue.self, forKey: .metadata)
        metadataRef = try c.decodeIfPresent(DurableBlobReference.self, forKey: .metadataRef)
        removedDisplayItemIDs = try c.decodeIfPresent([UUID].self, forKey: .removedDisplayItemIDs) ?? []
    }
    init(_ value: SessionTransaction, inline: Bool = false, writeBlob: DurableBlobWriter) throws {
        id = value.id; sessionID = value.sessionID; turnID = value.turnID; kind = value.kind; createdAt = value.createdAt
        contextItems = try value.contextItems.map { try DurableInput($0, inline: inline, writeBlob: writeBlob) }; displayItems = try value.displayItems.map { try DurableDisplayItem($0, inline: inline, writeBlob: writeBlob) }; usage = value.usage
        snapshot = try value.snapshot.map { try DurableSnapshot($0, inline: inline, writeBlob: writeBlob) }; contextHead = value.contextHead; toolClaims = value.toolClaims; toolResults = try value.toolResults.map { try DurableToolResult($0, writeBlob: writeBlob) }; (metadata, metadataRef) = try durableMetadata(value.metadata, inline: inline, writeBlob: writeBlob); removedDisplayItemIDs = value.removedDisplayItemIDs
    }
    func value(readBlob: DurableBlobReader) throws -> SessionTransaction {
        .init(id: id, sessionID: sessionID, turnID: turnID, kind: kind, createdAt: createdAt, contextItems: try contextItems.map { try $0.value(readBlob: readBlob) }, displayItems: try displayItems.map { try $0.value(readBlob: readBlob) }, usage: usage, snapshot: try snapshot?.value(readBlob: readBlob), contextHead: contextHead, toolClaims: toolClaims, toolResults: try toolResults.map { try $0.value(readBlob: readBlob) }, metadata: try resolvedMetadata(metadata, metadataRef, readBlob: readBlob), removedDisplayItemIDs: removedDisplayItemIDs)
    }
    /// New session records carry all textual and metadata facts inline;
    /// references are reserved for actual binary images only.
    func requireInlineFields() throws {
        func validate(_ items: [DurableInput]) throws {
            for item in items {
                guard item.outputRef == nil else { throw StoreError.invalidRecord }
                for content in item.content ?? [] { guard content.textRef == nil else { throw StoreError.invalidRecord } }
            }
        }
        guard metadataRef == nil, displayItems.allSatisfy({ $0.textRef == nil && $0.metadataRef == nil }) else { throw StoreError.invalidRecord }
        try validate(contextItems)
        if let snapshot { try validate(snapshot.items) }
    }
}
