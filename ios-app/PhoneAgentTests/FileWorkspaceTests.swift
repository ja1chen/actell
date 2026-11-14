import XCTest
@testable import PhoneAgent

final class FileWorkspaceTests: XCTestCase {
    @MainActor func testWorkspaceUsesExistingSessionFolderNameAndPersists() throws {
        let root = try workspace().root
        let store = ConversationStore(directory: root)
        let id = store.create(mode: .live)
        let session = try store.sessionDirectory(id)
        let dated = session.deletingLastPathComponent().appendingPathComponent("2001-02-03_" + id.uuidString)
        try FileManager.default.moveItem(at: session, to: dated)
        let actual = try store.workspaceDirectory(id)
        XCTAssertEqual(actual.path, root.appendingPathComponent("workspaces").appendingPathComponent(dated.lastPathComponent).path)
        try Data("kept".utf8).write(to: actual.appendingPathComponent("note.txt"))
        let reloaded = ConversationStore(directory: root)
        let reopened = try reloaded.workspaceDirectory(id)
        XCTAssertEqual(reopened, actual)
        XCTAssertEqual(try String(contentsOf: reopened.appendingPathComponent("note.txt"), encoding: .utf8), "kept")
        let other = reloaded.create(mode: .live)
        XCTAssertNotEqual(try reloaded.workspaceDirectory(other), actual)
    }

    func testOldWorkspaceMovesWithoutLosingFiles() throws {
        let root = try workspace().root, id = UUID()
        let legacy = root.appendingPathComponent("legacy")
        let old = legacy.appendingPathComponent(id.uuidString)
        try FileManager.default.createDirectory(at: old, withIntermediateDirectories: true)
        try Data("original".utf8).write(to: old.appendingPathComponent("note.txt"))
        let session = root.appendingPathComponent("sessions/2001-02-03_" + id.uuidString)
        let target = try FileWorkspace.conversationRoot(sessionDirectory: session, legacyRoot: legacy)
        XCTAssertEqual(target.path, root.appendingPathComponent("workspaces/2001-02-03_" + id.uuidString).path)
        XCTAssertEqual(try String(contentsOf: target.appendingPathComponent("note.txt"), encoding: .utf8), "original")
        XCTAssertFalse(FileManager.default.fileExists(atPath: old.path))
        XCTAssertEqual(try FileWorkspace.conversationRoot(sessionDirectory: session, legacyRoot: legacy), target)
    }

    func testConflictingWorkspacesArePreservedWithoutMerging() throws {
        let root = try workspace().root, id = UUID()
        let session = root.appendingPathComponent("sessions/2001-02-03_" + id.uuidString)
        let target = try FileWorkspace.conversationRoot(sessionDirectory: session)
        let legacy = root.appendingPathComponent("legacy")
        let old = legacy.appendingPathComponent(id.uuidString)
        try FileManager.default.createDirectory(at: old, withIntermediateDirectories: true)
        try Data("old".utf8).write(to: old.appendingPathComponent("note.txt"))
        try Data("new".utf8).write(to: target.appendingPathComponent("note.txt"))
        XCTAssertThrowsError(try FileWorkspace.conversationRoot(sessionDirectory: session, legacyRoot: legacy))
        XCTAssertEqual(try String(contentsOf: old.appendingPathComponent("note.txt"), encoding: .utf8), "old")
        XCTAssertEqual(try String(contentsOf: target.appendingPathComponent("note.txt"), encoding: .utf8), "new")
    }

    @MainActor func testInMemoryWorkspaceUsesSeparateTemporaryStorage() throws {
        let first = ConversationStore(inMemory: true), second = ConversationStore(inMemory: true)
        let firstID = first.create(mode: .live), secondID = second.create(mode: .live)
        let a = try first.workspaceDirectory(firstID), b = try second.workspaceDirectory(secondID)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: a.deletingLastPathComponent().deletingLastPathComponent())
            try? FileManager.default.removeItem(at: b.deletingLastPathComponent().deletingLastPathComponent())
        }
        XCTAssertNotEqual(a.deletingLastPathComponent(), b.deletingLastPathComponent())
        XCTAssertEqual(a, try first.workspaceDirectory(firstID))
        XCTAssertTrue(a.path.hasPrefix(FileManager.default.temporaryDirectory.path))
    }

    private func workspace() throws -> FileWorkspace {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("local-tools-\(UUID())")
        let result = try FileWorkspace(root: root)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return result
    }
    private func object(_ text: String) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
    }
    private func assertFailure(_ operation: () async throws -> String, code: String, file: StaticString = #filePath, line: UInt = #line) async {
        do { _ = try await operation(); XCTFail("Expected \(code)", file: file, line: line) }
        catch let error as FileWorkspace.Failure { XCTAssertEqual(error.code, code, file: file, line: line) }
        catch { XCTFail("Unexpected \(error)", file: file, line: line) }
    }
    func testReadWriteUTF8AndPagination() async throws {
        let w = try workspace()
        _ = try await w.write(filePath: "notes/a.txt", content: "一\n二\n三\n")
        let r = try object(await w.read(filePath: "notes/a.txt", offset: 2, limit: 1))
        XCTAssertEqual(r["content"] as? String, "2: 二")
        XCTAssertEqual(r["next_offset"] as? Int, 3)
        XCTAssertEqual(r["total_lines"] as? Int, 3)
    }
    func testReadEmptyAndPastEnd() async throws {
        let w = try workspace()
        _ = try await w.write(filePath: "empty", content: "")
        let r = try object(await w.read(filePath: "empty", offset: Int.max))
        XCTAssertEqual(r["content"] as? String, "")
        XCTAssertEqual(r["total_lines"] as? Int, 0)
        XCTAssertTrue(r["next_offset"] is NSNull)
    }
    func testUniqueEditAndReplaceAll() async throws {
        let w = try workspace()
        _ = try await w.write(filePath: "a", content: "abc abc\n")
        await assertFailure({ try await w.edit(filePath: "a", oldString: "abc", newString: "X") }, code: "ambiguous_match")
        let before = try object(await w.read(filePath: "a"))
        XCTAssertEqual(before["content"] as? String, "1: abc abc")
        let r = try object(await w.edit(filePath: "a", oldString: "abc", newString: "X", replaceAll: true))
        XCTAssertEqual(r["replacements"] as? Int, 2)
        let after = try object(await w.read(filePath: "a"))
        XCTAssertEqual(after["content"] as? String, "1: X X")
    }
    func testMissingAndEmptyEditsDoNotChangeFile() async throws {
        let w = try workspace()
        _ = try await w.write(filePath: "a", content: "hello")
        await assertFailure({ try await w.edit(filePath: "a", oldString: "none", newString: "x") }, code: "match_not_found")
        await assertFailure({ try await w.edit(filePath: "a", oldString: "", newString: "x") }, code: "empty_match")
        await assertFailure({ try await w.edit(filePath: "a", oldString: "hello", newString: "hello") }, code: "unchanged_edit")
        XCTAssertEqual(try String(contentsOf: w.root.appendingPathComponent("a"), encoding: .utf8), "hello")
    }
    func testTraversalAndRootDenied() async throws {
        let w = try workspace()
        for path in ["../outside", "a/../../outside", "~/private", "a\\b", "nul\0name"] {
            await assertFailure({ try await w.write(filePath: path, content: "x") }, code: "invalid_path")
        }
        for path in ["/outside", ".", w.root.path, w.root.path + "-sibling/a"] {
            await assertFailure({ try await w.write(filePath: path, content: "x") }, code: "outside_workspace")
        }
    }
    func testAbsolutePathInsideWorkspaceAllowed() async throws {
        let w = try workspace()
        _ = try await w.write(filePath: w.root.appendingPathComponent("a").path, content: "allowed")
        XCTAssertEqual(try String(contentsOf: w.root.appendingPathComponent("a"), encoding: .utf8), "allowed")
    }
    func testSymlinkAndDanglingSymlinkDenied() async throws {
        let w = try workspace()
        try FileManager.default.createSymbolicLink(atPath: w.root.appendingPathComponent("link").path, withDestinationPath: "/tmp")
        await assertFailure({ try await w.write(filePath: "link/escape", content: "x") }, code: "symlink_denied")
        try FileManager.default.createSymbolicLink(atPath: w.root.appendingPathComponent("dangling").path, withDestinationPath: "/does-not-exist")
        await assertFailure({ try await w.write(filePath: "dangling", content: "x") }, code: "symlink_denied")
    }
    func testDirectoryCannotBeReadOrReplaced() async throws {
        let w = try workspace()
        try FileManager.default.createDirectory(at: w.root.appendingPathComponent("d"), withIntermediateDirectories: true)
        await assertFailure({ try await w.read(filePath: "d") }, code: "not_regular_file")
        await assertFailure({ try await w.write(filePath: "d", content: "x") }, code: "not_regular_file")
    }
    func testHardlinkDenied() async throws {
        let w = try workspace()
        let source = w.root.appendingPathComponent("a"), link = w.root.appendingPathComponent("b")
        try Data("text".utf8).write(to: source)
        try FileManager.default.linkItem(at: source, to: link)
        await assertFailure({ try await w.read(filePath: "b") }, code: "hardlink_denied")
    }
    func testBinaryAndOversizeDenied() async throws {
        let w = try workspace()
        try Data([0xff, 0xfe]).write(to: w.root.appendingPathComponent("binary"))
        await assertFailure({ try await w.read(filePath: "binary") }, code: "not_utf8_text")
        await assertFailure({ try await w.write(filePath: "nul", content: "a\0b") }, code: "not_utf8_text")
        await assertFailure({ try await w.write(filePath: "large", content: String(repeating: "x", count: FileWorkspace.maximumFileBytes + 1)) }, code: "file_too_large")
    }
    func testLongLineFailsWithoutSkippingSuffix() async throws {
        let w = try workspace()
        _ = try await w.write(filePath: "a", content: "first\n" + String(repeating: "🙂", count: 20_000) + "\nlast")
        await assertFailure({ try await w.read(filePath: "a") }, code: "oversized_line")
        await assertFailure({ try await w.read(filePath: "a", offset: 2) }, code: "oversized_line")
        let first = try object(await w.read(filePath: "a", limit: 1))
        XCTAssertEqual(first["content"] as? String, "1: first")
        XCTAssertEqual(first["next_offset"] as? Int, 2)
    }
    func testNumberingCountsTowardBudgetAndPaginationPreservesLines() async throws {
        let w = try workspace()
        let line = String(repeating: "x", count: FileWorkspace.maximumOutputBytes - 3)
        _ = try await w.write(filePath: "a", content: line + "\nnext")
        let first = try object(await w.read(filePath: "a"))
        XCTAssertEqual((first["content"] as? String)?.utf8.count, FileWorkspace.maximumOutputBytes)
        XCTAssertEqual(first["returned_lines"] as? Int, 1)
        XCTAssertEqual(first["next_offset"] as? Int, 2)
        let second = try object(await w.read(filePath: "a", offset: 2))
        XCTAssertEqual(second["content"] as? String, "2: next")
        XCTAssertTrue(second["next_offset"] is NSNull)
        _ = try await w.write(filePath: "b", content: line + "x")
        await assertFailure({ try await w.read(filePath: "b") }, code: "oversized_line")
    }
    func testCommitAuthorizationDenialLeavesFileUnchanged() async throws {
        let w = try workspace()
        _ = try await w.write(filePath: "a", content: "before")
        do {
            _ = try await w.write(filePath: "a", content: "after", commitCheck: { throw CancellationError() })
            XCTFail("Expected cancellation")
        } catch is CancellationError { }
        XCTAssertEqual(try String(contentsOf: w.root.appendingPathComponent("a"), encoding: .utf8), "before")
    }
    func testConversationIsolation() async throws {
        let a = try workspace(), b = try workspace()
        _ = try await a.write(filePath: "a", content: "private")
        await assertFailure({ try await b.read(filePath: a.root.appendingPathComponent("a").path) }, code: "outside_workspace")
    }
    func testWorkspaceQuota() async throws {
        let w = try workspace()
        let data = String(repeating: "x", count: FileWorkspace.maximumFileBytes)
        for n in 0..<10 { _ = try await w.write(filePath: "file-\(n)", content: data) }
        await assertFailure({ try await w.write(filePath: "overflow", content: "x") }, code: "workspace_full")
        // Replacing an existing file deducts its previous bytes.
        _ = try await w.write(filePath: "file-0", content: "small")
    }
    func testInvalidLineRange() async throws {
        let w = try workspace()
        await assertFailure({ try await w.read(filePath: "a", offset: 0) }, code: "invalid_range")
        await assertFailure({ try await w.read(filePath: "a", limit: 2001) }, code: "invalid_range")
    }
    func testDirectoryResolution() async throws {
        let w = try workspace()
        _ = try await w.write(filePath: "nested/a", content: "x")
        let root = try await w.directory()
        let nested = try await w.directory(filePath: "nested")
        XCTAssertEqual(root, w.root)
        XCTAssertEqual(nested.path, w.root.appendingPathComponent("nested").path)
        do { _ = try await w.directory(filePath: "../outside"); XCTFail("Expected denial") }
        catch let error as FileWorkspace.Failure { XCTAssertEqual(error.code, "invalid_path") }
    }
    func testLiteralUnicodeEditDoesNotMatchCanonicalEquivalent() async throws {
        let w = try workspace()
        _ = try await w.write(filePath: "a", content: "e\u{301}")
        await assertFailure({ try await w.edit(filePath: "a", oldString: "é", newString: "x") }, code: "match_not_found")
    }
    func testEditPreservesPermissionsAndExactNewlines() async throws {
        let w = try workspace()
        _ = try await w.write(filePath: "a", content: "old\r\nlast\n")
        let url = w.root.appendingPathComponent("a")
        try FileManager.default.setAttributes([.posixPermissions: 0o640], ofItemAtPath: url.path)
        _ = try await w.edit(filePath: "a", oldString: "old", newString: "new")
        XCTAssertEqual(try Data(contentsOf: url), Data("new\r\nlast\n".utf8))
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o640)
    }

}
