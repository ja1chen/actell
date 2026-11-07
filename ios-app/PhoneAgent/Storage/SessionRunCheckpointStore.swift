import Foundation

/// Routes both the primary runtime and additional workers to the same session layout.
/// During migration initialization is read-only; new runs remain blocked by the store.
@MainActor final class SessionRunCheckpointStore: RunCheckpointStorage {
    private let sessions: ConversationStore
    private let conversationID: UUID?
    init(sessions: ConversationStore, conversationID: UUID? = nil) {
        self.sessions = sessions; self.conversationID = conversationID
    }
    func load() throws -> RunCheckpoint? { try loadRecoveries().first }
    func loadRecoveries() throws -> [RunCheckpoint] {
        guard sessions.storageReady, let root = sessions.storageRoot else { return [] }
        let folders = try SessionStorageLayout(root: root).directories()
        var result: [RunCheckpoint] = []
        for (id, folder) in folders where conversationID == nil || conversationID == id {
            let records = try SessionStorageMigration.readCheckpoints(in: folder)
            guard records.allSatisfy({ $0.conversationID == id }) else { throw SessionStorageLayout.Failure.invalidLayout }
            result += records
        }
        return result
    }
    func saveRecoveries(_ checkpoints: [RunCheckpoint]) throws {
        guard !checkpoints.isEmpty else { return }
        guard sessions.storageReady else { throw SessionCommandError.unavailableStorage }
        for (id, records) in Dictionary(grouping: checkpoints, by: \.conversationID) {
            if let conversationID, conversationID != id { throw SessionStorageLayout.Failure.invalidLayout }
            try RunCheckpointStore(directory: sessions.sessionDirectory(id)).saveRecoveries(records)
        }
    }
    func save(_ checkpoint: RunCheckpoint) throws {
        if let conversationID, conversationID != checkpoint.conversationID { throw SessionStorageLayout.Failure.invalidLayout }
        try RunCheckpointStore(directory: sessions.sessionDirectory(checkpoint.conversationID)).save(checkpoint)
    }
}
