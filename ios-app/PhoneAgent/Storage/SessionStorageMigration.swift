import Foundation
import CryptoKit

/// The only product migration: legacy archive, attachments and execution journals
/// directly into the final session directories. Development-only layouts are excluded.
enum SessionStorageMigration {
    static let checkpointNames = ["run-checkpoint-v1.json", "usb-run-checkpoint-v1.json", "run-recovery-v1.json"]
    struct Result: Sendable { var unavailableAttachments = false }

    static func hasLegacyResources(in root: URL) throws -> Bool {
        let layout = SessionStorageLayout(root: root)
        return try layout.legacySessionsDirectory() != nil
            || FileManager.default.fileExists(atPath: root.appendingPathComponent("Attachments").path)
            || checkpointNames.contains { FileManager.default.fileExists(atPath: root.appendingPathComponent($0).path) }
    }

    static func install(_ conversations: [AgentConversation], in root: URL, legacyRoot: URL? = nil) throws -> Result {
        let manager = FileManager.default, layout = SessionStorageLayout(root: root)
        let sourceRoot = legacyRoot ?? root
        let sourceLayout = SessionStorageLayout(root: sourceRoot)
        guard Set(conversations.map(\.id)).count == conversations.count else { throw ConversationJournal.Failure.invalidFormat }
        if layout.isInstalled {
            let journal = ConversationJournal(directory: layout.sessions)
            let loaded = try journal.load()
            guard journal.unreadableIDs.isEmpty, !journal.recoveredTail,
                  Dictionary(uniqueKeysWithValues: loaded.map { ($0.id, $0) })
                    == Dictionary(uniqueKeysWithValues: conversations.map { ($0.id, $0) }) else { throw ConversationJournal.Failure.invalidFormat }
            return Result()
        }
        let legacySessions = try sourceLayout.legacySessionsDirectory()
        // Never reinterpret an unknown lowercase directory as a legacy source.
        let children = try manager.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
        guard !children.contains(where: { $0.lastPathComponent == SessionStorageLayout.directoryName }) else {
            throw SessionStorageLayout.Failure.invalidLayout
        }
        let staging = root.appendingPathComponent(".sessions-migration", isDirectory: true)
        if manager.fileExists(atPath: staging.path) { try SessionStorageLayout.requireDirectory(staging); try manager.removeItem(at: staging) }
        try SessionStorageLayout.createProtectedDirectory(staging)
        do {
            let staged = SessionStorageLayout(root: staging)
            try SessionStorageLayout.createProtectedDirectory(staged.sessions)
            try JSONEncoder().encode(SessionStorageLayout.Format()).write(to: staged.formatFile, options: [.atomic, .completeFileProtection])
            let journal = ConversationJournal(directory: staged.sessions)
            for conversation in conversations { try journal.importLegacyConversation(conversation) }
            let copied = try journal.load()
            guard journal.unreadableIDs.isEmpty,
                  Dictionary(uniqueKeysWithValues: copied.map { ($0.id, $0) })
                    == Dictionary(uniqueKeysWithValues: conversations.map { ($0.id, $0) }) else { throw ConversationJournal.Failure.invalidFormat }
            let dates = Dictionary(uniqueKeysWithValues: conversations.map { ($0.id, $0.createdAt) })
            try copyCheckpoints(from: sourceRoot, legacySessions: legacySessions, dates: dates, into: staged)
            let attachments = sourceRoot.appendingPathComponent("Attachments", isDirectory: true)
            if manager.fileExists(atPath: attachments.path) {
                try SessionStorageLayout.requireDirectory(attachments)
                for source in try manager.contentsOfDirectory(at: attachments, includingPropertiesForKeys: nil) {
                    guard let id = UUID(uuidString: source.lastPathComponent) else { throw SessionStorageLayout.Failure.invalidLayout }
                    try SessionStorageLayout.requireDirectory(source)
                    let folder = try staged.ensureDirectory(for: id, createdAt: dates[id] ?? sourceDate(source))
                    try copyVerifiedDirectory(source, to: folder.appendingPathComponent("attachments", isDirectory: true))
                }
            }
            var result = Result()
            for conversation in conversations {
                let references = (conversation.draftAttachments ?? []) + conversation.messages.flatMap { $0.attachments ?? [] }
                let folder = try staged.directory(for: conversation.id)
                for attachment in references {
                    guard attachment.conversationID == conversation.id else { throw SessionStorageLayout.Failure.invalidLayout }
                    let file = folder.appendingPathComponent("attachments/\(attachment.id.uuidString)/original")
                    if !manager.fileExists(atPath: file.path) { result.unavailableAttachments = true; continue }
                    try SessionStorageLayout.requireRegularFile(file)
                    let data = try Data(contentsOf: file)
                    if data.count != attachment.byteCount || digest(data) != attachment.digest { result.unavailableAttachments = true }
                }
            }
            // On a case-insensitive volume Sessions and sessions address the same
            // directory. Preserve the old directory under an unambiguous backup
            // name first. If interrupted here, the next attempt reads that backup.
            if sourceRoot.standardizedFileURL == root.standardizedFileURL,
               let legacySessions, legacySessions.lastPathComponent == "Sessions" {
                guard !manager.fileExists(atPath: layout.legacyBackup.path) else { throw SessionStorageLayout.Failure.invalidLayout }
                try manager.moveItem(at: legacySessions, to: layout.legacyBackup)
            }
            try manager.moveItem(at: staged.sessions, to: layout.sessions)
            // The session tree is authoritative. If publishing the derived state
            // fails or the process exits here, startup rebuilds it from that tree.
            if let state = try? Data(contentsOf: staged.stateFile) {
                try? state.write(to: layout.stateFile, options: [.atomic, .completeFileProtection])
            }
            try? manager.removeItem(at: staging)
            return result
        } catch {
            try? manager.removeItem(at: staging)
            throw error
        }
    }

    static func readCheckpoints(in folder: URL) throws -> [RunCheckpoint] {
        var records: [RunCheckpoint] = []
        for name in checkpointNames {
            let file = folder.appendingPathComponent(name)
            guard FileManager.default.fileExists(atPath: file.path) else { continue }
            try SessionStorageLayout.requireRegularFile(file)
            let data = try Data(contentsOf: file)
            if name == "run-recovery-v1.json" { records += try JSONDecoder().decode([RunCheckpoint].self, from: data) }
            else { records.append(try JSONDecoder().decode(RunCheckpoint.self, from: data)) }
        }
        return records
    }

    private static func copyCheckpoints(from root: URL, legacySessions: URL?, dates: [UUID: Date], into layout: SessionStorageLayout) throws {
        var sources: [(URL, UUID?)] = [(root, nil)]
        if let legacySessions {
            try SessionStorageLayout.requireDirectory(legacySessions)
            for folder in try FileManager.default.contentsOfDirectory(at: legacySessions, includingPropertiesForKeys: nil) {
                guard let id = UUID(uuidString: folder.lastPathComponent) else { throw SessionStorageLayout.Failure.invalidLayout }
                try SessionStorageLayout.requireDirectory(folder)
                sources.append((folder, id))
            }
        }
        var grouped: [UUID: [RunCheckpoint]] = [:], current: [UUID: RunCheckpoint] = [:], fallbackDates: [UUID: Date] = [:]
        for (source, owner) in sources {
            let checkpoints = try readCheckpoints(in: source)
            for checkpoint in checkpoints {
                if let owner, owner != checkpoint.conversationID { throw SessionStorageLayout.Failure.invalidLayout }
                grouped[checkpoint.conversationID, default: []].append(checkpoint)
                fallbackDates[checkpoint.conversationID] = try sourceDate(source)
            }
            // The scoped active checkpoint takes precedence over the old root's
            // active record; all runs remain in recovery, including unknown actions.
            for name in checkpointNames.prefix(2).reversed() {
                let file = source.appendingPathComponent(name)
                if FileManager.default.fileExists(atPath: file.path) {
                    let checkpoint = try JSONDecoder().decode(RunCheckpoint.self, from: Data(contentsOf: file))
                    current[checkpoint.conversationID] = checkpoint
                }
            }
        }
        for (id, checkpoints) in grouped {
            let folder = try layout.ensureDirectory(for: id, createdAt: dates[id] ?? fallbackDates[id] ?? Date(timeIntervalSince1970: 0))
            let recovery = RunCheckpoint.mergedRecoveries(checkpoints)
            let recoveryData = try JSONEncoder().encode(recovery)
            let recoveryFile = folder.appendingPathComponent("run-recovery-v1.json")
            try recoveryData.write(to: recoveryFile, options: [.atomic, .completeFileProtection])
            guard try JSONDecoder().decode([RunCheckpoint].self, from: Data(contentsOf: recoveryFile)) == recovery else { throw SessionStorageLayout.Failure.invalidLayout }
            if let active = current[id] ?? recovery.first {
                let file = folder.appendingPathComponent("run-checkpoint-v1.json")
                try JSONEncoder().encode(active).write(to: file, options: [.atomic, .completeFileProtection])
                guard try JSONDecoder().decode(RunCheckpoint.self, from: Data(contentsOf: file)) == active else { throw SessionStorageLayout.Failure.invalidLayout }
            }
        }
    }

    private static func copyVerifiedDirectory(_ source: URL, to destination: URL) throws {
        try SessionStorageLayout.requireDirectory(source)
        try SessionStorageLayout.createProtectedDirectory(destination)
        for file in try FileManager.default.contentsOfDirectory(at: source, includingPropertiesForKeys: [.isDirectoryKey]) {
            let target = destination.appendingPathComponent(file.lastPathComponent)
            if try file.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true {
                try copyVerifiedDirectory(file, to: target)
            } else {
                try SessionStorageLayout.requireRegularFile(file)
                let data = try Data(contentsOf: file)
                try data.write(to: target, options: [.atomic, .completeFileProtection])
                guard digest(try Data(contentsOf: target)) == digest(data) else { throw SessionStorageLayout.Failure.invalidLayout }
            }
        }
    }

    private static func sourceDate(_ url: URL) throws -> Date {
        let values = try url.resourceValues(forKeys: [.creationDateKey, .contentModificationDateKey])
        return values.creationDate ?? values.contentModificationDate ?? Date(timeIntervalSince1970: 0)
    }

    private static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
}
