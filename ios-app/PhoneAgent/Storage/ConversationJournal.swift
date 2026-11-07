import Foundation
import AgentKit

/// App presentation adapter over the authoritative AgentKit session journal.
/// Legacy records are read only during conversion; all new writes use AgentKit.
final class ConversationJournal {
    static let directoryName = SessionStorageLayout.directoryName
    static let maximumBytes = 64 * 1_024 * 1_024
    private struct Saved {
        var conversation: AgentConversation
        var committedBytes: UInt64
        var modifiedAt: Date
    }
    enum Failure: Error { case invalidFormat, tooLarge, unreadableConversation }
    let directory: URL
    private var saved: [UUID: Saved] = [:]
    private var stores: [UUID: JSONLSessionStore] = [:]
    private var listEntries: [UUID: SessionListIndex.Entry]?
    private var knownFolders: [UUID: URL] = [:]
    private var committedIDs: Set<UUID> = []
    private var uncertainHistoryIDs: Set<UUID> = []
    private(set) var unreadableIDs: Set<UUID> = []
    private(set) var recoveredTail = false

    init(directory: URL) { self.directory = directory }

    private var layout: SessionStorageLayout { SessionStorageLayout(sessions: directory) }
    private struct HistoryAttributes {
        var size: UInt64
        var modified: Date
    }
    private static func historyAttributes(_ file: URL) throws -> HistoryAttributes {
        try SessionStorageLayout.requireRegularFile(file)
        // Fetch fresh filesystem attributes. URL resource values may be cached
        // across an append and otherwise publish a stale derived summary.
        let values = try FileManager.default.attributesOfItem(atPath: file.path)
        guard let size = values[.size] as? NSNumber, let modified = values[.modificationDate] as? Date else { throw Failure.invalidFormat }
        return HistoryAttributes(size: size.uint64Value, modified: modified)
    }
    func isLoaded(_ id: UUID) -> Bool { saved[id] != nil }
    func reload(_ id: UUID) throws -> AgentConversation {
        let value = try read(id); saved[id] = value
        return value.conversation
    }
    func adoptCommittedSession(_ id: UUID) throws {
        let value = try read(id); saved[id] = value
        let root = try folder(id); knownFolders[id] = root
        committedIDs.insert(id)
        updateListEntry(value.conversation, folder: root); try? writeIndex()
    }

    static func install(_ conversations: [AgentConversation], in root: URL) throws {
        _ = try SessionStorageMigration.install(conversations, in: root)
    }

    /// Called while constructing an isolated migration tree. The source
    /// archive is never written as an intermediate per-session journal.
    func importLegacyConversation(_ conversation: AgentConversation) throws {
        if listEntries == nil { _ = try loadSummaries() }
        let folder = try layout.ensureDirectory(for: conversation.id, createdAt: conversation.createdAt)
        let history = folder.appendingPathComponent("history.jsonl")
        guard !FileManager.default.fileExists(atPath: history.path) else { throw Failure.invalidFormat }
        knownFolders[conversation.id] = folder
        let store = JSONLSessionStore(root: folder, sessionID: conversation.id)
        var revision = 0
        for transaction in try AgentSessionPersistence.importConversation(conversation) {
            revision = try store.appendSync(transaction, expecting: revision).revision
        }
        stores[conversation.id] = store
        try adoptCommittedSession(conversation.id)
    }

    func load() throws -> [AgentConversation] { try load(useSummaries: false) }
    func loadSummaries() throws -> [AgentConversation] { try load(useSummaries: true) }
    private func load(useSummaries: Bool) throws -> [AgentConversation] {
        try layout.validate()
        saved.removeAll(); stores.removeAll(); unreadableIDs.removeAll(); uncertainHistoryIDs.removeAll(); recoveredTail = false
        // Directory enumeration reconciles committed creates/deletes even when
        // the optional list publication was interrupted. Reuse each unchanged
        // entry independently; one stale history never forces all logs to load.
        knownFolders = try layout.directories()
        let index = try? SessionListIndex.read(from: layout.stateFile)
        let cached = index?.sessions ?? []
        let canReuse = useSummaries && index?.version == SessionListIndex.currentVersion
        listEntries = Dictionary(uniqueKeysWithValues: cached.filter {
            knownFolders[$0.id]?.lastPathComponent == $0.directory
        }.map { ($0.id, $0) })
        committedIDs = Set(listEntries?.keys.map { $0 } ?? [])
        var conversations: [AgentConversation] = []
        for (id, folder) in knownFolders {
            let history = folder.appendingPathComponent("history.jsonl")
            guard FileManager.default.fileExists(atPath: history.path) else {
                if committedIDs.contains(id) { unreadableIDs.insert(id); invalidateEntryFingerprint(id) }
                continue
            }
            do {
                let attributes = try Self.historyAttributes(history)
                guard attributes.size > 0 else {
                    if committedIDs.contains(id) { unreadableIDs.insert(id); invalidateEntryFingerprint(id) }
                    continue
                }
                committedIDs.insert(id)
                if canReuse, let entry = listEntries?[id],
                   entry.historySize == attributes.size, entry.historyModifiedAt == attributes.modified {
                    conversations.append(entry.conversation)
                } else {
                    let value = try read(id); saved[id] = value
                    conversations.append(value.conversation)
                    updateListEntry(value.conversation, folder: folder)
                }
            } catch { unreadableIDs.insert(id); invalidateEntryFingerprint(id) }
        }
        try? writeIndex()
        return conversations.sorted { $0.updatedAt > $1.updatedAt }
    }

    func conversation(_ id: UUID) throws -> AgentConversation {
        if let value = saved[id], let url = try? file(id),
           let attributes = try? Self.historyAttributes(url),
           attributes.size == value.committedBytes, attributes.modified == value.modifiedAt { return value.conversation }
        do {
            let value = try read(id); saved[id] = value
            if let root = knownFolders[id] { updateListEntry(value.conversation, folder: root) }
            try? writeIndex()
            return value.conversation
        } catch {
            unreadableIDs.insert(id); invalidateEntryFingerprint(id)
            try? writeIndex()
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

    func engineStore(_ id: UUID) throws -> JSONLSessionStore {
        if let value = stores[id] { return value }
        let root = try folder(id)
        let value = JSONLSessionStore(root: root, sessionID: id, requireExistingHistory: committedIDs.contains(id))
        // The storage layer recognizes its self-describing header and both
        // previous formats. App supplies only its own legacy UI converter.
        try value.migrateLegacySync {
            if !$0.isEmpty && $0.last != 0x0A { self.recoveredTail = true }
            return try AgentSessionPersistence.migrate($0, sessionID: id)
        }
        stores[id] = value
        return value
    }

    private func read(_ id: UUID) throws -> Saved {
        let store = try engineStore(id)
        var presentation = try store.presentationSync()
        if presentation.integrityGap { unreadableIDs.insert(id); uncertainHistoryIDs.insert(id) }
        if presentation.recoveredTail { recoveredTail = true; uncertainHistoryIDs.insert(id) }
        if presentation.integrityGap && presentation.metadata == nil && presentation.items.isEmpty { throw Failure.invalidFormat }
        let conversation: AgentConversation
        if let current = try? AgentSessionPersistence.conversation(from: presentation, sessionID: id) {
            conversation = current
        } else {
            // A malformed optional App metadata update does not invalidate an
            // earlier valid conversation descriptor or the durable facts.
            let transactions = (try? store.readTransactionsSync(id)) ?? []
            var recovered: AgentConversation?
            for transaction in transactions.reversed() where [.sessionUpdated, .presentationUpdated, .legacyImported].contains(transaction.kind) {
                guard let metadata = transaction.metadata else { continue }
                presentation.metadata = metadata
                if let candidate = try? AgentSessionPersistence.conversation(from: presentation, sessionID: id) { recovered = candidate; break }
            }
            if let recovered { conversation = recovered }
            else {
                // The session header supplies identity and display facts still carry
                // their own timestamps. Missing App metadata must not invent
                // a provider, draft, entry, or device authorization.
                var neutral = AgentConversation(id: id, mode: .live)
                if let first = presentation.items.first(where: { $0.role == "user" && !$0.text.isEmpty }) { neutral.title = String(first.text.prefix(48)) }
                if let date = presentation.items.first?.createdAt { neutral.createdAt = date; neutral.updatedAt = date }
                presentation.metadata = try AgentSessionPersistence.metadata(neutral)
                conversation = try AgentSessionPersistence.conversation(from: presentation, sessionID: id)
            }
        }
        let attributes = try Self.historyAttributes(file(id))
        return Saved(conversation: conversation, committedBytes: attributes.size, modifiedAt: attributes.modified)
    }

    func save(_ conversation: AgentConversation) throws {
        if listEntries == nil { _ = try loadSummaries() }
        if committedIDs.contains(conversation.id), knownFolders[conversation.id] == nil { throw Failure.unreadableConversation }
        let root = try knownFolders[conversation.id] != nil ? folder(conversation.id)
            : layout.ensureDirectory(for: conversation.id, createdAt: conversation.createdAt)
        knownFolders[conversation.id] = root
        let store = try engineStore(conversation.id)
        let history = root.appendingPathComponent("history.jsonl")
        var refreshed = false
        if FileManager.default.fileExists(atPath: history.path) {
            let attributes = try Self.historyAttributes(history)
            if saved[conversation.id] == nil || saved[conversation.id]?.committedBytes != attributes.size || saved[conversation.id]?.modifiedAt != attributes.modified {
                saved[conversation.id] = try read(conversation.id); refreshed = true
            }
        }
        let previous = saved[conversation.id]?.conversation
        guard previous != conversation else { return }
        guard Set(conversation.messages.map(\.id)).count == conversation.messages.count else { throw Failure.invalidFormat }
        let old = Dictionary(uniqueKeysWithValues: (previous?.messages ?? []).map { ($0.id, $0) })
        let ids = Set(conversation.messages.map(\.id))
        let changed = conversation.messages.filter { old[$0.id] != $0 }
        let transaction = try SessionTransaction(sessionID: conversation.id, kind: .presentationUpdated,
            displayItems: changed.map { try AgentSessionPersistence.display($0) },
            metadata: AgentSessionPersistence.metadata(conversation), removedDisplayItemIDs: old.keys.filter { !ids.contains($0) })
        _ = try store.appendPresentationSync(transaction)
        unreadableIDs.remove(conversation.id); uncertainHistoryIDs.remove(conversation.id)
        committedIDs.insert(conversation.id)
        let attributes = try Self.historyAttributes(history)
        if refreshed {
            if let presentation = try? store.presentationSync(),
               let actual = try? AgentSessionPersistence.conversation(from: presentation, sessionID: conversation.id) {
                saved[conversation.id] = Saved(conversation: actual, committedBytes: attributes.size, modifiedAt: attributes.modified)
            } else { saved.removeValue(forKey: conversation.id) }
        } else {
            saved[conversation.id] = Saved(conversation: conversation, committedBytes: attributes.size, modifiedAt: attributes.modified)
        }
        updateListEntry(saved[conversation.id]?.conversation ?? conversation, folder: root)
        try? writeIndex()
    }

    private func updateListEntry(_ conversation: AgentConversation, folder: URL) {
        let preview = conversation.messages.last(where: { $0.role == .user || $0.role == .assistant })?.text
        var entry = SessionListIndex.Entry(conversation, directory: folder.lastPathComponent, preview: preview)
        let history = folder.appendingPathComponent("history.jsonl")
        if !uncertainHistoryIDs.contains(conversation.id), let values = try? Self.historyAttributes(history) {
            entry.historySize = values.size; entry.historyModifiedAt = values.modified
        }
        listEntries?[conversation.id] = entry
    }

    private func invalidateEntryFingerprint(_ id: UUID) {
        uncertainHistoryIDs.insert(id)
        listEntries?[id]?.historySize = nil; listEntries?[id]?.historyModifiedAt = nil
    }

    private func writeIndex() throws {
        guard let listEntries else { return }
        let entries = listEntries.values.sorted { $0.updatedAt > $1.updatedAt }
        try SessionListIndex(sessions: entries).write(to: layout.stateFile)
    }

    func delete(_ id: UUID) throws {
        if listEntries == nil { _ = try loadSummaries() }
        guard !unreadableIDs.contains(id) else { throw Failure.unreadableConversation }
        if listEntries?[id] != nil || saved[id] != nil { _ = try conversation(id) }
        guard !unreadableIDs.contains(id) else { throw Failure.unreadableConversation }
        if let folder = try knownFolders[id] ?? layout.directories()[id] { try FileManager.default.removeItem(at: folder) }
        saved.removeValue(forKey: id); stores.removeValue(forKey: id); committedIDs.remove(id); uncertainHistoryIDs.remove(id); listEntries?.removeValue(forKey: id); knownFolders.removeValue(forKey: id)
        try? writeIndex()
    }

}
