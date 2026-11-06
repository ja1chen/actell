import Foundation

/// Rebuildable list projection. Full drafts, attachments, recoveries and messages
/// belong to the session journal and are loaded before any session mutation.
struct SessionListIndex: Codable {
    static let previewLimit = 200
    var version = 1
    var sessions: [Entry]

    struct Entry: Codable {
        var id: UUID
        var directory: String
        var title: String
        var mode: RunMode
        var createdAt: Date
        var updatedAt: Date
        var phase: RunPhase
        var providerID: UUID?
        var modelID: String?
        var entry: SessionEntry?
        var draftPreview: String?
        var preview: String?

        init(_ conversation: AgentConversation, directory: String, preview: String?) {
            id = conversation.id; self.directory = directory
            title = conversation.title; mode = conversation.mode
            createdAt = conversation.createdAt; updatedAt = conversation.updatedAt
            phase = conversation.phase; providerID = conversation.providerID; modelID = conversation.modelID
            entry = conversation.entry
            draftPreview = conversation.entry?.state == .pendingConfirmation
                ? String(conversation.draft.prefix(SessionListIndex.previewLimit)) : nil
            self.preview = preview.map { String($0.prefix(SessionListIndex.previewLimit)) }
        }

        var conversation: AgentConversation {
            var value = AgentConversation(mode: mode)
            value.id = id; value.title = title; value.createdAt = createdAt; value.updatedAt = updatedAt
            value.phase = phase; value.providerID = providerID; value.modelID = modelID
            value.entry = entry; value.draft = draftPreview ?? ""; value.cachedPreview = preview
            return value
        }
    }

    static func read(from file: URL) throws -> SessionListIndex {
        try SessionStorageLayout.requireRegularFile(file)
        let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= ConversationJournal.maximumBytes else { throw ConversationJournal.Failure.tooLarge }
        let value = try JSONDecoder().decode(Self.self, from: Data(contentsOf: file))
        guard value.version == 1, Set(value.sessions.map(\.id)).count == value.sessions.count,
              value.sessions.allSatisfy({ SessionStorageLayout.conversationID(in: $0.directory) == $0.id
                  && ($0.preview?.count ?? 0) <= previewLimit && ($0.draftPreview?.count ?? 0) <= previewLimit }) else {
            throw ConversationJournal.Failure.invalidFormat
        }
        return value
    }

    func write(to file: URL) throws {
        let data = try JSONEncoder().encode(self)
        guard data.count <= ConversationJournal.maximumBytes else { throw ConversationJournal.Failure.tooLarge }
        try data.write(to: file, options: [.atomic, .completeFileProtection])
    }
}
