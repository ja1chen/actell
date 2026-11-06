import Foundation

/// One newline-committed transaction per save, in one file per conversation.
/// Messages are upserted by ID; reading this journal never executes agent tools.
final class ConversationJournal {
    static let directoryName = SessionStorageLayout.directoryName
    static let maximumBytes = 64 * 1_024 * 1_024
    private struct Record: Codable {
        var version = 1
        var metadata: AgentConversation // messages is always empty
        var messages: [ChatMessage]
        var removedMessageIDs: [UUID]
    }
    private struct Saved {
        var conversation: AgentConversation
        var committedBytes: UInt64
    }
    enum Failure: Error { case invalidFormat, tooLarge, unreadableConversation }
    let directory: URL
    private var saved: [UUID: Saved] = [:]
    private var listEntries: [UUID: SessionListIndex.Entry]?
    private var knownFolders: [UUID: URL] = [:]
    private(set) var unreadableIDs: Set<UUID> = []
    private(set) var recoveredTail = false

    init(directory: URL) { self.directory = directory }

    private var layout: SessionStorageLayout { SessionStorageLayout(sessions: directory) }
    private struct Summary: Codable {
        var version = 1
        var conversation: AgentConversation
        var preview: String?
        var journalBytes: UInt64
        var modifiedAt: Date
    }
    func isLoaded(_ id: UUID) -> Bool { saved[id] != nil }

    static func install(_ conversations: [AgentConversation], in root: URL) throws {
        _ = try SessionStorageMigration.install(conversations, in: root)
    }

    func load() throws -> [AgentConversation] { try load(useSummaries: false) }
    func loadSummaries() throws -> [AgentConversation] { try load(useSummaries: true) }
    private func load(useSummaries: Bool) throws -> [AgentConversation] {
        try layout.validate()
        saved.removeAll(); unreadableIDs.removeAll(); recoveredTail = false
        if useSummaries, let index = try? SessionListIndex.read(from: layout.stateFile) {
            listEntries = Dictionary(uniqueKeysWithValues: index.sessions.map { ($0.id, $0) })
            knownFolders = Dictionary(uniqueKeysWithValues: index.sessions.map { ($0.id, directory.appendingPathComponent($0.directory, isDirectory: true)) })
            return index.sessions.map(\.conversation).sorted { $0.updatedAt > $1.updatedAt }
        }
        // A missing/invalid index is a cache rebuild, not a data migration.
        try invalidateIndex()
        listEntries = [:]
        var conversations: [AgentConversation] = []
        knownFolders = try layout.directories()
        for (id, folder) in knownFolders {
            let file = folder.appendingPathComponent("history.jsonl")
            // Draft attachments and orphaned execution records do not create a
            // visible conversation without a committed history file.
            guard FileManager.default.fileExists(atPath: file.path) else { continue }
            do {
                try SessionStorageLayout.requireRegularFile(file)
                let attributes = try file.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
                if useSummaries,
                   let data = try? Data(contentsOf: folder.appendingPathComponent("metadata.json")),
                   let summary = try? JSONDecoder().decode(Summary.self, from: data),
                   summary.version == 1, summary.conversation.id == id, summary.conversation.messages.isEmpty,
                   summary.journalBytes == UInt64(attributes.fileSize ?? 0), summary.modifiedAt == attributes.contentModificationDate {
                    let entry = SessionListIndex.Entry(summary.conversation, directory: folder.lastPathComponent, preview: summary.preview)
                    listEntries?[id] = entry
                    conversations.append(entry.conversation)
                } else {
                    let value = try read(id); saved[id] = value
                    conversations.append(value.conversation)
                    try? writeSummary(value)
                    updateListEntry(value.conversation, folder: folder)
                }
            } catch { unreadableIDs.insert(id) }
        }
        try? writeIndex()
        return conversations.sorted { $0.updatedAt > $1.updatedAt }
    }

    func conversation(_ id: UUID) throws -> AgentConversation {
        if let value = saved[id] { return value.conversation }
        do {
            let value = try read(id); saved[id] = value
            try? writeSummary(value)
            if recoveredTail { try? invalidateIndex() }
            return value.conversation
        } catch {
            unreadableIDs.insert(id)
            try? invalidateIndex()
            throw error
        }
    }

    private func folder(_ id: UUID) throws -> URL {
        if let folder = knownFolders[id] {
            try SessionStorageLayout.requireDirectory(folder)
            return folder
        }
        return try layout.directory(for: id)
    }
    private func file(_ id: UUID) throws -> URL { try folder(id).appendingPathComponent("history.jsonl") }

    private func writeSummary(_ value: Saved) throws {
        let file = try file(value.conversation.id)
        var metadata = value.conversation; metadata.messages = []; metadata.cachedPreview = nil
        guard let modifiedAt = try file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate else { return }
        // Cache only message content. App-provided empty/Siri labels are
        // localized when displayed, including after a language change.
        let preview = value.conversation.messages.last(where: { $0.role == .user || $0.role == .assistant })?.text
        let summary = Summary(conversation: metadata, preview: preview,
            journalBytes: value.committedBytes, modifiedAt: modifiedAt)
        try JSONEncoder().encode(summary).write(to: file.deletingLastPathComponent().appendingPathComponent("metadata.json"), options: [.atomic, .completeFileProtection])
    }

    private func read(_ id: UUID) throws -> Saved {
        let url = try file(id)
        try SessionStorageLayout.requireRegularFile(url)
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= Self.maximumBytes else { throw Failure.tooLarge }
        let data = try Data(contentsOf: url)
        var conversation: AgentConversation?
        var start = data.startIndex
        // Only a newline commits a record. A torn final write is never decoded
        // as a complete transaction or allowed to hide corruption in earlier lines.
        for end in data.indices where data[end] == 0x0A {
            let record = try JSONDecoder().decode(Record.self, from: data[start..<end])
            guard record.version == 1, record.metadata.id == id, record.metadata.messages.isEmpty,
                  Set(record.messages.map(\.id)).count == record.messages.count else { throw Failure.invalidFormat }
            var messages = conversation?.messages ?? []
            let removed = Set(record.removedMessageIDs)
            messages.removeAll { removed.contains($0.id) }
            var positions = Dictionary(uniqueKeysWithValues: messages.enumerated().map { ($0.element.id, $0.offset) })
            for message in record.messages {
                if let index = positions[message.id] { messages[index] = message }
                else { positions[message.id] = messages.count; messages.append(message) }
            }
            conversation = record.metadata; conversation?.messages = messages
            start = end + 1
        }
        guard let conversation else { throw Failure.invalidFormat }
        if start < data.endIndex { recoveredTail = true }
        return Saved(conversation: conversation, committedBytes: UInt64(start))
    }

    func save(_ conversation: AgentConversation) throws {
        if listEntries == nil { _ = try loadSummaries() }
        guard !unreadableIDs.contains(conversation.id) else { throw Failure.unreadableConversation }
        let folder = try knownFolders[conversation.id] != nil ? self.folder(conversation.id)
            : layout.ensureDirectory(for: conversation.id, createdAt: conversation.createdAt)
        knownFolders[conversation.id] = folder
        let destination = folder.appendingPathComponent("history.jsonl")
        if saved[conversation.id] == nil, FileManager.default.fileExists(atPath: destination.path) {
            saved[conversation.id] = try read(conversation.id)
        }
        let previous = saved[conversation.id]
        guard previous?.conversation != conversation else { return }
        guard Set(conversation.messages.map(\.id)).count == conversation.messages.count else { throw Failure.invalidFormat }
        var metadata = conversation; metadata.messages = []
        let snapshot = Record(metadata: metadata, messages: conversation.messages, removedMessageIDs: [])
        let snapshotData = try encode(snapshot)
        guard snapshotData.count <= Self.maximumBytes else { throw Failure.tooLarge }
        let oldMessages = Dictionary(uniqueKeysWithValues: (previous?.conversation.messages ?? []).map { ($0.id, $0) })
        let ids = Set(conversation.messages.map(\.id))
        let delta = Record(metadata: metadata,
            messages: conversation.messages.filter { oldMessages[$0.id] != $0 },
            removedMessageIDs: oldMessages.keys.filter { !ids.contains($0) })
        let data = try encode(delta)
        let offset = previous?.committedBytes ?? 0
        // Invalidate before touching authoritative data. If interrupted or the
        // cache cannot be saved, the next launch rebuilds instead of trusting
        // an old list that could omit a new session or resurrect a deletion.
        try invalidateIndex()
        let compact = offset + UInt64(data.count) > UInt64(min(Self.maximumBytes, max(1_024 * 1_024, snapshotData.count * 8)))
        if previous == nil || compact {
            try snapshotData.write(to: destination, options: [.atomic, .completeFileProtection])
            saved[conversation.id] = Saved(conversation: conversation, committedBytes: UInt64(snapshotData.count))
        } else {
            let handle = try FileHandle(forWritingTo: destination)
            defer { try? handle.close() }
            // Also removes an incomplete tail from a prior failed append.
            try handle.truncate(atOffset: offset)
            try handle.seek(toOffset: offset)
            do {
                try handle.write(contentsOf: data)
                try handle.synchronize()
            } catch {
                try? handle.truncate(atOffset: offset)
                throw error
            }
            saved[conversation.id] = Saved(conversation: conversation, committedBytes: offset + UInt64(data.count))
        }
        if let value = saved[conversation.id] { try? writeSummary(value) }
        updateListEntry(conversation, folder: folder)
        try? writeIndex()
    }

    private func updateListEntry(_ conversation: AgentConversation, folder: URL) {
        let preview = conversation.messages.last(where: { $0.role == .user || $0.role == .assistant })?.text
        listEntries?[conversation.id] = SessionListIndex.Entry(conversation, directory: folder.lastPathComponent, preview: preview)
    }

    private func invalidateIndex() throws {
        guard FileManager.default.fileExists(atPath: layout.stateFile.path) else { return }
        try SessionStorageLayout.requireRegularFile(layout.stateFile)
        try FileManager.default.removeItem(at: layout.stateFile)
    }

    private func writeIndex() throws {
        guard let listEntries, unreadableIDs.isEmpty, !recoveredTail else { return }
        let entries = listEntries.values.sorted { $0.updatedAt > $1.updatedAt }
        try SessionListIndex(sessions: entries).write(to: layout.stateFile)
    }

    func delete(_ id: UUID) throws {
        if listEntries == nil { _ = try loadSummaries() }
        guard !unreadableIDs.contains(id) else { throw Failure.unreadableConversation }
        if listEntries?[id] != nil, saved[id] == nil { _ = try conversation(id) }
        try invalidateIndex()
        if let folder = try knownFolders[id] ?? layout.directories()[id] { try FileManager.default.removeItem(at: folder) }
        saved.removeValue(forKey: id); listEntries?.removeValue(forKey: id); knownFolders.removeValue(forKey: id)
        try? writeIndex()
    }

    private func encode(_ record: Record) throws -> Data {
        var data = try JSONEncoder().encode(record)
        data.append(0x0A)
        return data
    }
}
