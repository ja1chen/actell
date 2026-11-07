import Foundation

/// Rebuildable list projection. Full drafts, attachments, recoveries and messages
/// belong to the session journal and are loaded before any session mutation.
struct SessionListIndex: Codable {
    static let previewLimit = 200
    static let currentVersion = 2
    var version = currentVersion
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
        var historySize: UInt64?
        var historyModifiedAt: Date?

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
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any]
        guard let version = object?["version"] as? Int, [1, currentVersion].contains(version),
              let rows = object?["sessions"] as? [Any] else {
            throw ConversationJournal.Failure.invalidFormat
        }
        var entries: [UUID: Entry] = [:], duplicates = Set<UUID>(), order: [UUID] = []
        for row in rows {
            guard let row = row as? [String: Any],
                  let data = try? JSONSerialization.data(withJSONObject: row),
                  let entry = try? JSONDecoder().decode(Entry.self, from: data),
                  SessionStorageLayout.conversationID(in: entry.directory) == entry.id,
                  (entry.preview?.count ?? 0) <= previewLimit, (entry.draftPreview?.count ?? 0) <= previewLimit else { continue }
            if entries[entry.id] != nil { duplicates.insert(entry.id) } else { order.append(entry.id) }
            entries[entry.id] = entry
        }
        return SessionListIndex(version: version, sessions: order.compactMap { duplicates.contains($0) ? nil : entries[$0] })
    }

    func write(to file: URL) throws {
        let data = try JSONEncoder().encode(self)
        guard data.count <= ConversationJournal.maximumBytes else { throw ConversationJournal.Failure.tooLarge }
        try data.write(to: file, options: [.atomic, .completeFileProtection])
    }
}
