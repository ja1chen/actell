import Foundation

/// All durable resources for a conversation share one stable, dated directory.
struct SessionStorageLayout: Sendable {
    static let directoryName = "sessions"
    static var defaultRoot: URL { URL.documentsDirectory }
    static var defaultLegacyRoot: URL { URL.applicationSupportDirectory.appendingPathComponent("PhoneAgent", isDirectory: true) }
    let root: URL
    let sessions: URL
    init(root: URL) { self.root = root; sessions = root.appendingPathComponent(Self.directoryName, isDirectory: true) }
    init(sessions: URL) { self.sessions = sessions; root = sessions.deletingLastPathComponent() }
    var formatFile: URL { sessions.appendingPathComponent("format.json") }
    var stateFile: URL { root.appendingPathComponent("state.json") }
    var legacyBackup: URL { root.appendingPathComponent("legacy-sessions", isDirectory: true) }
    struct Format: Codable { var version = 1 }
    enum Failure: Error { case invalidLayout, missingSession, migrationRequired }

    static func folderName(id: UUID, createdAt: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: createdAt) + "_" + id.uuidString
    }

    static func conversationID(in name: String) -> UUID? {
        guard name.count == 47, name.dropFirst(10).first == "_",
              name.prefix(10).range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil else { return nil }
        return UUID(uuidString: String(name.suffix(36)))
    }

    var isInstalled: Bool { FileManager.default.fileExists(atPath: formatFile.path) }

    func validate() throws {
        try Self.requireDirectory(sessions)
        try Self.requireRegularFile(formatFile)
        let format = try JSONDecoder().decode(Format.self, from: Data(contentsOf: formatFile))
        guard format.version == 1 else { throw Failure.invalidLayout }
    }

    func directories() throws -> [UUID: URL] {
        guard FileManager.default.fileExists(atPath: sessions.path) else { return [:] }
        try Self.requireDirectory(sessions)
        var result: [UUID: URL] = [:]
        for folder in try FileManager.default.contentsOfDirectory(at: sessions, includingPropertiesForKeys: nil) {
            if folder.lastPathComponent == "format.json" { continue }
            guard let id = Self.conversationID(in: folder.lastPathComponent), result[id] == nil else { throw Failure.invalidLayout }
            try Self.requireDirectory(folder)
            result[id] = folder
        }
        return result
    }

    func directory(for id: UUID) throws -> URL {
        guard let folder = try directories()[id] else { throw Failure.missingSession }
        return folder
    }

    @discardableResult func ensureDirectory(for id: UUID, createdAt: Date) throws -> URL {
        try validate()
        if let folder = try directories()[id] { return folder }
        let folder = sessions.appendingPathComponent(Self.folderName(id: id, createdAt: createdAt), isDirectory: true)
        try Self.createProtectedDirectory(folder)
        return folder
    }

    /// Exact spelling matters on both case-sensitive and case-insensitive volumes.
    func legacySessionsDirectory() throws -> URL? {
        guard FileManager.default.fileExists(atPath: root.path) else { return nil }
        let children = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
        if let folder = children.first(where: { $0.lastPathComponent == "Sessions" }) { return folder }
        if FileManager.default.fileExists(atPath: legacyBackup.path) { return legacyBackup }
        return nil
    }

    static func createProtectedDirectory(_ folder: URL) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.protectionKey: FileProtectionType.complete])
        try requireDirectory(folder)
        var folder = folder, values = URLResourceValues(); values.isExcludedFromBackup = false
        try folder.setResourceValues(values)
    }

    static func requireDirectory(_ url: URL) throws {
        let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else { throw Failure.invalidLayout }
    }

    static func requireRegularFile(_ url: URL) throws {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else { throw Failure.invalidLayout }
    }
}
