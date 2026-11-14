import Foundation
import Combine
import CryptoKit

struct SkillPackage: Codable, Identifiable, Equatable, Sendable {
    let id: UUID
    let name: String
    let summary: String
    let version: String
    let revision: String
    let documents: [String: String]
    var enabled: Bool
    var displayVersion: String? {
        let value = version.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value != "未标注" else { return nil }
        return value.hasPrefix("v") ? value : "v" + value
    }
    var resources: [String] { documents.keys.sorted() }
    static func validResource(_ path: String) -> Bool {
        !path.isEmpty && path.utf8.count <= 240 && !path.hasPrefix("/") && !path.contains("\\") && !path.contains(":") &&
        path.split(separator: "/", omittingEmptySubsequences: false).allSatisfy { !$0.isEmpty && !$0.hasPrefix(".") } &&
        ["md", "txt", "markdown"].contains((path as NSString).pathExtension.lowercased())
    }
    static func make(documents: [String: String]) throws -> SkillPackage {
        guard !documents.isEmpty, documents.count <= 32, documents.keys.allSatisfy(validResource),
              documents.values.allSatisfy({ !$0.contains("\0") && $0.utf8.count <= 64 * 1_024 }),
              documents.values.reduce(0, { $0 + $1.utf8.count }) <= 512 * 1_024,
              let main = documents["SKILL.md"] else { throw AppError.invalid(String(localized: "A skill needs SKILL.md at its root. Supports up to 32 UTF-8 Markdown/TXT files, 64 KiB per file and 512 KiB total.")) }
        let lines = main.components(separatedBy: .newlines)
        guard lines.first == "---", let end = lines.dropFirst().firstIndex(of: "---") else { throw AppError.invalid(String(localized: "SKILL.md needs a metadata section between --- lines with name and description")) }
        var metadata: [String: String] = [:], index = 1
        while index < end {
            let line = lines[index]; index += 1
            if line.trimmingCharacters(in: .whitespaces).isEmpty || line.hasPrefix("#") { continue }
            guard !line.hasPrefix(" "), let colon = line.firstIndex(of: ":") else { throw AppError.invalid(String(localized: "Invalid skill metadata. Use simple text fields or indented | / > multiline text.")) }
            let key = String(line[..<colon]), raw = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            guard metadata[key] == nil else { throw AppError.invalid(String(localized: "Duplicate skill metadata field")) }
            var value = raw
            if ["|", ">", "|-", ">-"].contains(raw) {
                var parts: [String] = []
                while index < end && (lines[index].hasPrefix(" ") || lines[index].isEmpty) {
                    parts.append(lines[index].trimmingCharacters(in: .whitespaces)); index += 1
                }
                value = parts.joined(separator: raw.hasPrefix(">") ? " " : "\n")
            } else if value.count >= 2, (value.first == "\"" && value.last == "\"" || value.first == "'" && value.last == "'") {
                value = String(value.dropFirst().dropLast())
            }
            metadata[key] = value.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard let name = metadata["name"], !name.isEmpty, name.count <= 80,
              let summary = metadata["description"], !summary.isEmpty, summary.count <= 1_000 else {
            throw AppError.invalid(String(localized: "A skill name must contain 1–80 characters and its description 1–1000 characters"))
        }
        let version = metadata["version"] ?? "未标注"
        guard version.count <= 80 else { throw AppError.invalid(String(localized: "Skill version text is too long")) }
        let canonical = documents.keys.sorted().map { "\($0.utf8.count):\($0)\(documents[$0]!.utf8.count):\(documents[$0]!)" }.joined()
        let revision = SHA256.hash(data: Data(canonical.utf8)).map { String(format: "%02x", $0) }.joined()
        return SkillPackage(id: UUID(), name: name, summary: summary, version: version, revision: revision, documents: documents, enabled: true)
    }
}

@MainActor final class SkillStore: ObservableObject {
    @Published private(set) var packages: [SkillPackage] = []
    @Published private(set) var warning: String?
    let directory: URL?
    private var locations: [UUID: URL] = [:]
    private var writable = true
    static let disabledIDsKey = "disabledSkillIDs"
    private let defaults: UserDefaults?
    private var disabledIDs: Set<UUID> = []
    private struct Archive: Codable { let version: Int; let packages: [SkillPackage] }
    static var localDirectory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("skills", isDirectory: true)
    }
    init(directory: URL? = nil, inMemory: Bool = false, legacyDirectory: URL? = nil, defaults: UserDefaults? = .standard) {
        self.defaults = inMemory ? nil : defaults
        self.directory = inMemory ? nil : directory ?? Self.localDirectory
        reloadDisabledIDs()
        guard let root = self.directory else { return }
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.protectionKey: FileProtectionType.complete])
            let legacy = legacyDirectory ?? (directory == nil
                ? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("PhoneAgent/Skills") : root)
            try migrateArchive(at: legacy.appendingPathComponent("skills-v1.json"), to: root)
            try migrateDisabledMarkers(in: root)
            refresh()
        } catch {
            writable = false
            warning = String(localized: "Skills could not be read. Existing files were kept. Check the skills folder and try again.")
        }
    }
    // Shipped references are immutable and never written into user directories.
    static let builtinID = UUID(uuidString: "8098422E-79C6-49BF-9205-E58F166F42D5")!
    static let creatorID = UUID(uuidString: "E6C42B35-1664-47CE-8595-1E368668267B")!
    var builtinPackages: [SkillPackage] {
        [(Self.builtinID, "ios-operation"), (Self.creatorID, "skill-creator")].compactMap { id, folder in
            guard let url = Bundle.main.url(forResource: "SKILL", withExtension: "md", subdirectory: "BuiltinSkills/\(folder)"),
                  let text = try? String(contentsOf: url, encoding: .utf8),
                  let checked = try? SkillPackage.make(documents: ["SKILL.md": text]) else { return nil }
            return Self.identify(checked, id: id, enabled: true)
        }
    }
    var enabledSnapshot: [SkillPackage] {
        refresh()
        return builtinPackages + packages.filter(\.enabled)
    }
    /// Scan before each run and while viewing the library. Running catalogs remain immutable.
    func refresh() {
        guard let directory, writable else { return }
        reloadDisabledIDs()
        do {
            let folders = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]).sorted { $0.lastPathComponent < $1.lastPathComponent }
            var next: [SkillPackage] = [], paths: [UUID: URL] = [:], invalid = false
            for folder in folders {
                guard (try folder.resourceValues(forKeys: [.isDirectoryKey])).isDirectory == true else { continue }
                guard FileManager.default.fileExists(atPath: folder.appendingPathComponent("SKILL.md").path) else { continue }
                do {
                    let checked = try SkillPackage.make(documents: Self.readDocuments(folder))
                    let id = Self.directoryID(folder.lastPathComponent)
                    guard paths[id] == nil, ![Self.builtinID, Self.creatorID].contains(id) else { throw AppError.invalid(String(localized: "Skill content verification failed")) }
                    next.append(Self.identify(checked, id: id, enabled: !disabledIDs.contains(id)))
                    paths[id] = folder
                } catch { invalid = true }
            }
            if packages != next { packages = next }
            locations = paths
            warning = invalid ? String(localized: "Some skills could not be loaded. Check their SKILL.md and reference files.") : nil
        } catch {
            packages = []; locations = [:]
            warning = String(localized: "Skills could not be read. Existing files were kept. Check the skills folder and try again.")
        }
    }
    private static func identify(_ package: SkillPackage, id: UUID, enabled: Bool) -> SkillPackage {
        SkillPackage(id: id, name: package.name, summary: package.summary, version: package.version,
                     revision: package.revision, documents: package.documents, enabled: enabled)
    }
    private static func directoryID(_ name: String) -> UUID {
        if let id = UUID(uuidString: name) { return id }
        let hex = SHA256.hash(data: Data(name.utf8)).prefix(16).map { String(format: "%02x", $0) }
        return UUID(uuidString: hex[0..<4].joined() + "-" + hex[4..<6].joined() + "-" + hex[6..<8].joined() + "-" + hex[8..<10].joined() + "-" + hex[10..<16].joined())!
    }
    @discardableResult func add(documents: [String: String]) throws -> SkillPackage {
        try requireWritable()
        let candidate = try SkillPackage.make(documents: documents)
        refresh()
        if let existing = packages.first(where: { $0.revision == candidate.revision }) { return existing }
        if let directory {
            try Self.write(candidate, to: directory.appendingPathComponent(candidate.id.uuidString))
            refresh()
        } else { packages.append(candidate) }
        return candidate
    }
    @discardableResult func importPackage(_ url: URL) throws -> SkillPackage {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        return try add(documents: Self.readDocuments(url))
    }
    private static func readDocuments(_ url: URL) throws -> [String: String] {
        let rootInfo = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard rootInfo.isSymbolicLink != true else { throw AppError.invalid(String(localized: "Symbolic links are not supported for skills")) }
        var documents: [String: String] = [:]
        func read(_ file: URL, resource: String) throws {
            try Task.checkCancellation()
            guard SkillPackage.validResource(resource), documents.count < 32 else { throw AppError.invalid(String(localized: "Skill packages can contain Markdown/TXT documents only, without scripts, images, or archives")) }
            let info = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            guard info.isRegularFile == true, info.isSymbolicLink != true, (info.fileSize ?? Int.max) <= 64 * 1_024,
                  let text = String(data: try Data(contentsOf: file), encoding: .utf8) else { throw AppError.invalid(String(localized: "The skill document is not a regular UTF-8 file or is larger than 64 KiB")) }
            documents[resource] = text
        }
        if rootInfo.isDirectory == true {
            let root = url.standardizedFileURL.path + "/"
            guard let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles]) else { throw AppError.invalid(String(localized: "Could not read the skill folder")) }
            var visited = 0
            for case let file as URL in enumerator {
                try Task.checkCancellation(); visited += 1
                guard visited <= 128 else { throw AppError.invalid(String(localized: "The skill package has too many folders. Select a folder containing only skill text.")) }
                let info = try file.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                guard info.isSymbolicLink != true, file.standardizedFileURL.path.hasPrefix(root) else { throw AppError.invalid(String(localized: "The skill package contains an invalid path or symbolic link")) }
                if info.isDirectory == true { continue }
                try read(file, resource: String(file.standardizedFileURL.path.dropFirst(root.count)))
            }
        } else {
            guard url.lastPathComponent == "SKILL.md" else { throw AppError.invalid(String(localized: "Select SKILL.md or a text skill folder containing it")) }
            try read(url, resource: "SKILL.md")
        }
        return documents
    }
    func setEnabled(_ enabled: Bool, id: UUID) throws {
        try requireWritable(); refresh()
        guard let index = packages.firstIndex(where: { $0.id == id }) else { throw AppError.invalid(String(localized: "Skill not found")) }
        setDisabled(!enabled, id: id)
        packages[index].enabled = enabled
    }
    func remove(_ id: UUID) throws {
        try requireWritable(); refresh()
        guard ![Self.builtinID, Self.creatorID].contains(id) else { throw AppError.invalid(String(localized: "Built-in skills cannot be deleted")) }
        if let folder = locations[id] { try FileManager.default.removeItem(at: folder) }
        setDisabled(false, id: id)
        packages.removeAll { $0.id == id }; locations[id] = nil
    }
    private func reloadDisabledIDs() {
        if let defaults {
            disabledIDs = Set((defaults.stringArray(forKey: Self.disabledIDsKey) ?? []).compactMap(UUID.init(uuidString:)))
        }
    }
    private func setDisabled(_ disabled: Bool, id: UUID) {
        if disabled { disabledIDs.insert(id) } else { disabledIDs.remove(id) }
        guard let defaults else { return }
        if disabledIDs.isEmpty { defaults.removeObject(forKey: Self.disabledIDsKey) }
        else { defaults.set(disabledIDs.map(\.uuidString).sorted(), forKey: Self.disabledIDsKey) }
    }
    private func migrateDisabledMarkers(in root: URL) throws {
        let folders = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])
        for folder in folders {
            guard (try folder.resourceValues(forKeys: [.isDirectoryKey])).isDirectory == true else { continue }
            let marker = folder.appendingPathComponent(".disabled")
            guard FileManager.default.fileExists(atPath: marker.path) else { continue }
            setDisabled(true, id: Self.directoryID(folder.lastPathComponent))
            try FileManager.default.removeItem(at: marker)
        }
    }
    private func requireWritable() throws {
        try Task.checkCancellation()
        guard writable else { throw AppError.unavailable(warning ?? String(localized: "Skills are read-only")) }
    }
    private static func write(_ package: SkillPackage, to destination: URL) throws {
        let staging = destination.deletingLastPathComponent().appendingPathComponent(".import-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: staging) }
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true, attributes: [.protectionKey: FileProtectionType.complete])
        for (path, text) in package.documents {
            try Task.checkCancellation()
            let file = staging.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: file, options: .completeFileProtection)
        }
        try FileManager.default.moveItem(at: staging, to: destination)
    }
    private func migrateArchive(at archiveURL: URL, to root: URL) throws {
        guard FileManager.default.fileExists(atPath: archiveURL.path) else { return }
        let info = try archiveURL.resourceValues(forKeys: [.fileSizeKey, .isSymbolicLinkKey])
        guard info.isSymbolicLink != true, (info.fileSize ?? Int.max) <= 16 * 1_024 * 1_024 else { throw AppError.invalid(String(localized: "Invalid skill archive")) }
        let archive = try JSONDecoder().decode(Archive.self, from: Data(contentsOf: archiveURL))
        guard archive.version == 1, Set(archive.packages.map(\.id)).count == archive.packages.count else { throw AppError.invalid(String(localized: "Unsupported skill archive version")) }
        // Validate every package before changing storage. A failed migration keeps the archive.
        for package in archive.packages {
            let checked = try SkillPackage.make(documents: package.documents)
            guard checked.revision == package.revision, checked.name == package.name, checked.summary == package.summary, checked.version == package.version else { throw AppError.invalid(String(localized: "Skill content verification failed")) }
        }
        for package in archive.packages {
            let destination = root.appendingPathComponent(package.id.uuidString)
            if FileManager.default.fileExists(atPath: destination.path) {
                let existing = try SkillPackage.make(documents: Self.readDocuments(destination))
                guard existing.revision == package.revision else { throw AppError.invalid(String(localized: "Skill content verification failed")) }
            } else { try Self.write(package, to: destination) }
        }
        for package in archive.packages {
            setDisabled(!package.enabled, id: package.id)
            let marker = root.appendingPathComponent(package.id.uuidString).appendingPathComponent(".disabled")
            if FileManager.default.fileExists(atPath: marker.path) { try FileManager.default.removeItem(at: marker) }
        }
        try FileManager.default.removeItem(at: archiveURL)
    }
}
