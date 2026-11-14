import Foundation

/// Text operations with a conversation working directory. Filesystem access follows
/// platform permissions; absolute paths, parent paths, and links are supported.
actor FileWorkspace {
    struct Failure: Error, LocalizedError, Sendable {
        let code: String
        let message: String
        var errorDescription: String? { "\(code): \(message)" }
    }

    nonisolated let root: URL
    static let maximumFileBytes = 2 * 1024 * 1024
    static let maximumOutputBytes = 64 * 1024
    private let files = FileManager.default

    static func conversationRoot(sessionDirectory: URL, legacyRoot: URL? = nil) throws -> URL {
        guard let id = SessionStorageLayout.conversationID(in: sessionDirectory.lastPathComponent) else {
            throw Failure(code: "invalid_session", message: "A dated conversation directory is required.")
        }
        let parent = sessionDirectory.deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("workspaces", isDirectory: true)
        try SessionStorageLayout.createProtectedDirectory(parent)
        let destination = parent.appendingPathComponent(sessionDirectory.lastPathComponent, isDirectory: true)
        if let legacyRoot {
            let source = legacyRoot.appendingPathComponent(id.uuidString, isDirectory: true)
            if let attributes = try? FileManager.default.attributesOfItem(atPath: source.path) {
                try SessionStorageLayout.requireDirectory(legacyRoot)
                guard attributes[.type] as? FileAttributeType == .typeDirectory else {
                    throw Failure(code: "invalid_root", message: "The old workspace must be a real directory.")
                }
                guard (try? FileManager.default.attributesOfItem(atPath: destination.path)) == nil else {
                    throw Failure(code: "workspace_conflict", message: "Both old and new workspaces exist; their files have been kept without merging.")
                }
                try FileManager.default.moveItem(at: source, to: destination)
            }
        }
        try SessionStorageLayout.createProtectedDirectory(destination)
        return destination
    }

    init(root: URL) throws {
        guard root.isFileURL else { throw Failure(code: "invalid_root", message: "A local workspace is required.") }
        let candidate = root.standardizedFileURL
        let resolved = candidate.resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: resolved, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        self.root = resolved
    }

    func read(filePath: String, offset: Int = 1, limit: Int = 2_000) throws -> String {
        try Task.checkCancellation()
        guard offset >= 1, (1...2_000).contains(limit) else {
            throw fail("invalid_range", "offset is 1-based and limit must be between 1 and 2000.")
        }
        let url = try resolve(filePath)
        let text = try loadText(url)
        var lines = text.components(separatedBy: "\n")
        if text.isEmpty { lines = [] }
        else if text.hasSuffix("\n") { lines.removeLast() }
        let start = min(offset - 1, lines.count)
        let end = min(start + limit, lines.count)
        var selected: [String] = [], bytes = 0, next = start
        for index in start..<end {
            let line = "\(index + 1): \(lines[index])"
            // Never consume only a prefix of a line: line-based pagination cannot
            // recover its omitted suffix. Include numbering in the content budget.
            guard line.utf8.count <= Self.maximumOutputBytes else {
                throw fail("oversized_line", "Line \(index + 1) exceeds the output limit including its line number; no partial line was returned.")
            }
            let size = line.utf8.count + (selected.isEmpty ? 0 : 1)
            if bytes + size > Self.maximumOutputBytes { break }
            selected.append(line); bytes += size; next = index + 1
        }
        try Task.checkCancellation()
        return try json(["file_path": relative(url), "content": selected.joined(separator: "\n"),
                         "offset": offset, "total_lines": lines.count, "returned_lines": selected.count,
                         "next_offset": next < lines.count ? (next + 1) as Any : NSNull(),
                         "truncated": next < lines.count, "line_truncated": false])
    }

    func write(filePath: String, content: String, commitCheck: @Sendable () async throws -> Void = {}) async throws -> String {
        try Task.checkCancellation()
        let url = try resolve(filePath)
        let data = try textData(content)
        try await commit(data, to: url, expectedText: nil, check: commitCheck)
        // No cancellation check after commit: a completed effect must remain a fact.
        return try json(["file_path": relative(url), "bytes_written": data.count, "written": true])
    }

    func edit(filePath: String, oldString: String, newString: String, replaceAll: Bool = false,
              commitCheck: @Sendable () async throws -> Void = {}) async throws -> String {
        try Task.checkCancellation()
        guard !oldString.isEmpty else { throw fail("empty_match", "old_string must not be empty.") }
        guard !oldString.utf8.elementsEqual(newString.utf8) else { throw fail("unchanged_edit", "old_string and new_string must differ.") }
        let url = try resolve(filePath)
        let original = try loadText(url)
        // Literal matching, with no regex or whitespace normalization.
        var matches = 0
        var searchStart = original.startIndex
        while searchStart < original.endIndex,
              let range = original.range(of: oldString, options: .literal, range: searchStart..<original.endIndex) {
            matches += 1; searchStart = range.upperBound
        }
        guard matches > 0 else { throw fail("match_not_found", "The exact old_string was not found; read the file again.") }
        guard replaceAll || matches == 1 else {
            throw fail("ambiguous_match", "old_string matches more than once; provide more context or replace_all.")
        }
        let updated = original.replacingOccurrences(of: oldString, with: newString, options: .literal)
        let data = try textData(updated)
        try await commit(data, to: url, expectedText: original, check: commitCheck)
        return try json(["file_path": relative(url), "bytes_written": data.count, "replacements": matches, "edited": true])
    }

    func directory(filePath: String = ".") throws -> URL {
        try Task.checkCancellation()
        let url = try resolve(filePath)
        let attributes = try files.attributesOfItem(atPath: url.path)
        guard attributes[.type] as? FileAttributeType == .typeDirectory else {
            throw fail("not_directory", "The workdir must be an existing directory.")
        }
        return url
    }

    private func fail(_ code: String, _ message: String) -> Failure { Failure(code: code, message: message) }
    private func relative(_ url: URL) -> String {
        url.path.hasPrefix(root.path + "/") ? String(url.path.dropFirst(root.path.count + 1)) : url.path
    }

    private func resolve(_ path: String) throws -> URL {
        guard !path.isEmpty, path.utf8.count <= 4096, !path.contains("\0") else {
            throw fail("invalid_path", "Provide a nonempty file path without NUL bytes.")
        }
        let expanded = (path as NSString).expandingTildeInPath
        return (expanded.hasPrefix("/") ? URL(fileURLWithPath: expanded) : root.appendingPathComponent(expanded))
            .standardizedFileURL.resolvingSymlinksInPath()
    }

    private func validateFile(_ url: URL) throws {
        guard files.fileExists(atPath: url.path) else { return }
        let attributes = try files.attributesOfItem(atPath: url.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular else {
            throw fail("not_regular_file", "Only regular text files are supported.")
        }
    }

    private func loadText(_ url: URL) throws -> String {
        try validateFile(url)
        let attributes = try files.attributesOfItem(atPath: url.path)
        guard ((attributes[.size] as? NSNumber)?.intValue ?? Int.max) <= Self.maximumFileBytes else {
            throw fail("file_too_large", "The file exceeds the 2 MiB text limit.")
        }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: Self.maximumFileBytes + 1) ?? Data()
        guard data.count <= Self.maximumFileBytes else { throw fail("file_too_large", "The file exceeds the 2 MiB text limit.") }
        guard !data.contains(0), let text = String(data: data, encoding: .utf8) else {
            throw fail("not_utf8_text", "Only UTF-8 text files without NUL bytes are supported.")
        }
        return text
    }

    private func textData(_ content: String) throws -> Data {
        guard !content.contains("\0") else { throw fail("not_utf8_text", "Text must not contain NUL bytes.") }
        guard content.utf8.count <= Self.maximumFileBytes else { throw fail("file_too_large", "Text exceeds the 2 MiB file limit.") }
        return Data(content.utf8)
    }

    private func commit(_ data: Data, to url: URL, expectedText: String?,
                        check: @Sendable () async throws -> Void) async throws {
        try await check()
        try Task.checkCancellation()
        // Revalidate after the suspension point: another actor call may have run.
        if let expectedText, !(try loadText(url)).utf8.elementsEqual(expectedText.utf8) {
            throw fail("concurrent_change", "The file changed while authorization was checked; read it again.")
        }
        try validateFile(url)
        let attributes = try? files.attributesOfItem(atPath: url.path)
        try Task.checkCancellation()
        try files.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                  attributes: [.posixPermissions: 0o700])
        try validateFile(url)
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".actell-write-\(UUID().uuidString)")
        defer { try? files.removeItem(at: temporary) }
        try data.write(to: temporary, options: .withoutOverwriting)
        try files.setAttributes([.posixPermissions: attributes?[.posixPermissions] ?? 0o600], ofItemAtPath: temporary.path)
        try Task.checkCancellation()
        try validateFile(url)
        if attributes != nil {
            _ = try files.replaceItemAt(url, withItemAt: temporary, backupItemName: nil, options: .usingNewMetadataOnly)
        } else {
            try files.moveItem(at: temporary, to: url)
        }
    }

    private func json(_ object: [String: Any]) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes]), as: UTF8.self)
    }
}
