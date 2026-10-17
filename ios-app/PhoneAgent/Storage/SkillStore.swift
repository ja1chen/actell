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
    var displayVersion: String { version == "未标注" ? String(localized: "Unspecified") : version }
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
    private let file: URL?
    private var writable = true
    private struct Archive: Codable { var version = 1; let packages: [SkillPackage] }
    init(directory: URL? = nil, inMemory: Bool = false) {
        if inMemory { file = nil; return }
        let root = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("PhoneAgent/Skills")
        file = root.appendingPathComponent("skills-v1.json")
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.protectionKey: FileProtectionType.complete])
            var url = root, values = URLResourceValues(); values.isExcludedFromBackup = true; try url.setResourceValues(values)
            if let file, FileManager.default.fileExists(atPath: file.path) {
                let info = try file.resourceValues(forKeys: [.fileSizeKey, .isSymbolicLinkKey])
                guard info.isSymbolicLink != true, (info.fileSize ?? Int.max) <= 16 * 1_024 * 1_024 else { throw AppError.invalid(String(localized: "Invalid skill archive")) }
                let archive = try JSONDecoder().decode(Archive.self, from: Data(contentsOf: file))
                guard archive.version == 1, Set(archive.packages.map(\.id)).count == archive.packages.count else { throw AppError.invalid(String(localized: "Unsupported skill archive version")) }
                for package in archive.packages {
                    let checked = try SkillPackage.make(documents: package.documents)
                    guard checked.revision == package.revision, checked.name == package.name, checked.summary == package.summary, checked.version == package.version else { throw AppError.invalid(String(localized: "Skill content verification failed")) }
                }
                packages = archive.packages
            }
        } catch { writable = false; warning = String(localized: "Skills could not be read. The original archive was kept and cannot be edited for now.") }
    }
    // Shipped references are immutable and never written into user archives.
    static let builtinID = UUID(uuidString: "8098422E-79C6-49BF-9205-E58F166F42D5")!
    var builtinPackages: [SkillPackage] {
        guard let url = Bundle.main.url(forResource: "SKILL", withExtension: "md", subdirectory: "BuiltinSkills/ios-operation"),
              let text = try? String(contentsOf: url, encoding: .utf8),
              let checked = try? SkillPackage.make(documents: ["SKILL.md": text]) else { return [] }
        return [SkillPackage(id: Self.builtinID, name: checked.name, summary: checked.summary, version: checked.version, revision: checked.revision, documents: checked.documents, enabled: true)]
    }
    var enabledSnapshot: [SkillPackage] { builtinPackages + packages.filter(\.enabled) }
    @discardableResult func add(documents: [String: String]) throws -> SkillPackage {
        try Task.checkCancellation()
        let candidate = try SkillPackage.make(documents: documents)
        if let existing = packages.first(where: { $0.revision == candidate.revision }) { return existing }
        try save(packages + [candidate]); return candidate
    }
    @discardableResult func importPackage(_ url: URL) throws -> SkillPackage {
        try Task.checkCancellation()
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
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
        return try add(documents: documents)
    }
    func setEnabled(_ enabled: Bool, id: UUID) throws {
        var next = packages
        guard let index = next.firstIndex(where: { $0.id == id }) else { throw AppError.invalid(String(localized: "Skill not found")) }
        next[index].enabled = enabled; try save(next)
    }
    func remove(_ id: UUID) throws {
        guard id != Self.builtinID else { throw AppError.invalid(String(localized: "Built-in skills cannot be deleted")) }
        try save(packages.filter { $0.id != id })
    }
    private func save(_ next: [SkillPackage]) throws {
        guard writable else { throw AppError.unavailable(warning ?? String(localized: "Skills are read-only")) }
        try Task.checkCancellation()
        let data = try JSONEncoder().encode(Archive(packages: next))
        guard data.count <= 16 * 1_024 * 1_024 else { throw AppError.invalid(String(localized: "Skill storage is full. Delete unwanted versions first.")) }
        if let file { try data.write(to: file, options: [.atomic, .completeFileProtection]) }
        packages = next
    }
}
