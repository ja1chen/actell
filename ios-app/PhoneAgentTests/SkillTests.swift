import XCTest
import AgentKit
import ProviderCore
@testable import PhoneAgent

@MainActor final class SkillTests: XCTestCase {
    private let document = "---\nname: Synthetic Guide\ndescription: Read synthetic fixtures\nversion: 1\n---\nBODY_NOT_A_SUMMARY\nSee [reference](references/guide.md)."
    private lazy var defaults: UserDefaults = {
        let suite = "skill-tests-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return defaults
    }()
    private func directory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("skills-test-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }; return root
    }
    func testBuiltinIsAvailableByNameWithoutPersistingIt() throws {
        let store = SkillStore(inMemory: true)
        let builtin = try XCTUnwrap(store.builtinPackages.first)
        XCTAssertEqual(builtin.id, SkillStore.builtinID)
        XCTAssertEqual(builtin.name, "ios-operation")
        let creator = try XCTUnwrap(store.builtinPackages.first { $0.id == SkillStore.creatorID })
        XCTAssertEqual(creator.name, "skill-creator")
        XCTAssertEqual(creator.version, try SkillPackage.make(documents: creator.documents).version)
        XCTAssertThrowsError(try store.remove(creator.id))
        XCTAssertTrue(store.packages.isEmpty)
        let catalog = SkillCatalog(store: store)
        let metadata = AgentViewModel.systemPrompt(skills: store.enabledSnapshot, language: "en")
        XCTAssertTrue(metadata.contains("ios-operation"))
        let body = try catalog.load(named: builtin.name)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any])
        XCTAssertEqual(object["content"] as? String, builtin.documents["SKILL.md"])
        XCTAssertNil(object["next_offset"])
        XCTAssertThrowsError(try store.remove(builtin.id))
    }
    func testVersionComesFromEntrypointMetadataAndRemainsOptional() throws {
        let versioned = try SkillPackage.make(documents: ["SKILL.md": document.replacingOccurrences(of: "version: 1", with: "version: 2.3.4")])
        XCTAssertEqual(versioned.version, "2.3.4")
        XCTAssertEqual(versioned.displayVersion, "v2.3.4")
        let unversioned = try SkillPackage.make(documents: ["SKILL.md": document.replacingOccurrences(of: "version: 1\n", with: "")])
        XCTAssertEqual(unversioned.version, "未标注")
        XCTAssertNil(unversioned.displayVersion)
        let emptyVersion = try SkillPackage.make(documents: ["SKILL.md": document.replacingOccurrences(of: "version: 1", with: "version: ''")])
        XCTAssertNil(emptyVersion.displayVersion)
        let prefixed = try SkillPackage.make(documents: ["SKILL.md": document.replacingOccurrences(of: "version: 1", with: "version: v2.0.0")])
        XCTAssertEqual(prefixed.displayVersion, "v2.0.0")
    }
    func testImportVersionsDuplicateDisableDeleteAndRestart() throws {
        let root = try directory(), store = SkillStore(directory: root, defaults: defaults)
        let first = try store.add(documents: ["SKILL.md": document])
        XCTAssertEqual(try store.add(documents: ["SKILL.md": document]).id, first.id)
        let next = try store.add(documents: ["SKILL.md": document + "\nUpdated"])
        XCTAssertNotEqual(first.id, next.id); XCTAssertNotEqual(first.revision, next.revision)
        try store.setEnabled(false, id: first.id)
        XCTAssertEqual(store.enabledSnapshot.filter { ![SkillStore.builtinID, SkillStore.creatorID].contains($0.id) }.map(\.id), [next.id])
        XCTAssertTrue(try SkillCatalog(store: store).load(named: first.name).contains("Updated"))
        let restored = SkillStore(directory: root, defaults: defaults)
        XCTAssertEqual(restored.packages, store.packages)
        try restored.remove(next.id); XCTAssertEqual(restored.packages.count, 1)
        XCTAssertTrue(restored.enabledSnapshot.filter { ![SkillStore.builtinID, SkillStore.creatorID].contains($0.id) }.isEmpty)
        XCTAssertTrue(try SkillCatalog(store: restored).load(named: first.name).contains("BODY_NOT_A_SUMMARY"))
    }
    func testDirectoryScanLoadsNewAndEditedSkillsByNameIncludingDisabledSkills() async throws {
        let root = try directory(), store = SkillStore(directory: root, defaults: defaults)
        let catalog = SkillCatalog(store: store)
        let work = try FileWorkspace(root: root.appendingPathComponent("../work-" + UUID().uuidString))
        addTeardownBlock { try? FileManager.default.removeItem(at: work.root) }
        let folder = root.appendingPathComponent("conversation-guide")
        _ = try await work.write(filePath: folder.appendingPathComponent("SKILL.md").path, content: document)
        let first = try XCTUnwrap(store.enabledSnapshot.first { $0.name == "Synthetic Guide" })
        XCTAssertEqual(store.packages.count, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("skills-v1.json").path))
        XCTAssertTrue(try catalog.load(named: first.name).contains("BODY_NOT_A_SUMMARY"))
        _ = try await work.edit(filePath: folder.appendingPathComponent("SKILL.md").path, oldString: "BODY_NOT_A_SUMMARY", newString: "EDITED_BODY")
        let next = try XCTUnwrap(store.enabledSnapshot.first { $0.id == first.id })
        XCTAssertNotEqual(next.revision, first.revision)
        XCTAssertEqual(next.id, first.id)
        XCTAssertEqual(SkillStore(directory: root, defaults: defaults).packages.first?.id, first.id)
        XCTAssertTrue(try catalog.load(named: first.name).contains("EDITED_BODY"))
        try store.setEnabled(false, id: first.id)
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent(".disabled").path))
        XCTAssertEqual(defaults.stringArray(forKey: SkillStore.disabledIDsKey), [first.id.uuidString])
        XCTAssertFalse(store.enabledSnapshot.contains { $0.id == first.id })
        XCTAssertTrue(try catalog.load(named: first.name).contains("EDITED_BODY"))
        try store.setEnabled(true, id: first.id)
        XCTAssertNil(defaults.object(forKey: SkillStore.disabledIDsKey))
        XCTAssertTrue(store.enabledSnapshot.contains { $0.id == first.id })
        try FileManager.default.removeItem(at: folder)
        XCTAssertThrowsError(try catalog.load(named: first.name))
        XCTAssertTrue(store.packages.isEmpty)
    }
    func testDisabledMarkerMigratesToDefaultsAndIsRemoved() throws {
        let root = try directory(), store = SkillStore(directory: root, defaults: defaults)
        let item = try store.add(documents: ["SKILL.md": document])
        let marker = root.appendingPathComponent(item.id.uuidString).appendingPathComponent(".disabled")
        XCTAssertNil(defaults.object(forKey: SkillStore.disabledIDsKey))
        try Data().write(to: marker)
        let restored = SkillStore(directory: root, defaults: defaults)
        XCTAssertFalse(try XCTUnwrap(restored.packages.first).enabled)
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
        XCTAssertEqual(defaults.stringArray(forKey: SkillStore.disabledIDsKey), [item.id.uuidString])
        try restored.setEnabled(true, id: item.id)
        XCTAssertNil(defaults.object(forKey: SkillStore.disabledIDsKey))
        XCTAssertTrue(try XCTUnwrap(SkillStore(directory: root, defaults: defaults).packages.first).enabled)
    }
    func testDeletingDisabledSkillClearsPreferenceAndReimportDefaultsToEnabled() throws {
        let root = try directory(), store = SkillStore(directory: root, defaults: defaults)
        let item = try store.add(documents: ["SKILL.md": document])
        try store.setEnabled(false, id: item.id)
        XCTAssertEqual(defaults.stringArray(forKey: SkillStore.disabledIDsKey), [item.id.uuidString])
        try store.remove(item.id)
        XCTAssertNil(defaults.object(forKey: SkillStore.disabledIDsKey))
        XCTAssertTrue(try store.add(documents: ["SKILL.md": document]).enabled)
    }
    func testLegacyArchiveMigratesDocumentsIDsAndEnabledState() throws {
        let root = try directory(), legacy = try directory()
        var package = try SkillPackage.make(documents: ["SKILL.md": document, "references/guide.md": "REFERENCE"])
        package.enabled = false
        struct Archive: Encodable { let version = 1; let packages: [SkillPackage] }
        let archive = legacy.appendingPathComponent("skills-v1.json")
        try JSONEncoder().encode(Archive(packages: [package])).write(to: archive)
        let store = SkillStore(directory: root, legacyDirectory: legacy, defaults: defaults)
        XCTAssertNil(store.warning)
        XCTAssertEqual(store.packages, [package])
        XCTAssertEqual(defaults.stringArray(forKey: SkillStore.disabledIDsKey), [package.id.uuidString])
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(package.id.uuidString + "/.disabled").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: archive.path))
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent(package.id.uuidString + "/references/guide.md"), encoding: .utf8), "REFERENCE")
        XCTAssertEqual(SkillStore(directory: root, defaults: defaults).packages, [package])
    }
    func testMigrationConflictPreservesArchiveAndDirectoryContents() throws {
        let root = try directory(), legacy = try directory()
        let package = try SkillPackage.make(documents: ["SKILL.md": document])
        struct Archive: Encodable { let version = 1; let packages: [SkillPackage] }
        let bytes = try JSONEncoder().encode(Archive(packages: [package]))
        let archive = legacy.appendingPathComponent("skills-v1.json")
        try bytes.write(to: archive)
        let folder = root.appendingPathComponent(package.id.uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let edited = document + "\nUser edits"
        try Data(edited.utf8).write(to: folder.appendingPathComponent("SKILL.md"))
        let store = SkillStore(directory: root, legacyDirectory: legacy, defaults: defaults)
        XCTAssertNotNil(store.warning)
        XCTAssertEqual(try Data(contentsOf: archive), bytes)
        XCTAssertEqual(try String(contentsOf: folder.appendingPathComponent("SKILL.md"), encoding: .utf8), edited)
    }
    func testDirectoryIDsCannotCollideWithBuiltinCatalog() throws {
        let root = try directory(), store = SkillStore(directory: root, defaults: defaults)
        for id in [SkillStore.builtinID, SkillStore.creatorID] {
            let folder = root.appendingPathComponent(id.uuidString)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data(document.utf8).write(to: folder.appendingPathComponent("SKILL.md"))
        }
        let snapshot = store.enabledSnapshot
        XCTAssertEqual(Set(snapshot.map(\.id)).count, snapshot.count)
        XCTAssertTrue(store.packages.isEmpty)
        XCTAssertNotNil(store.warning)
    }
    func testInvalidDirectoryDoesNotHideValidSkillsAndRecoversAfterCorrection() throws {
        let root = try directory(), store = SkillStore(directory: root, defaults: defaults)
        let package = try store.add(documents: ["SKILL.md": document])
        let folder = root.appendingPathComponent("invalid")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("No metadata".utf8).write(to: folder.appendingPathComponent("SKILL.md"))
        store.refresh()
        XCTAssertNotNil(store.warning)
        XCTAssertEqual(store.packages.map(\.id), [package.id])
        try Data(document.utf8).write(to: folder.appendingPathComponent("SKILL.md"))
        store.refresh()
        XCTAssertNil(store.warning)
        XCTAssertEqual(store.packages.count, 2)
    }
    func testFolderImportPreservesExtraFilesAndLoadsTextWithoutPackageLimits() throws {
        let root = try directory(), bundle = root.appendingPathComponent("bundle")
        try FileManager.default.createDirectory(at: bundle.appendingPathComponent("references"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: bundle.appendingPathComponent("scripts"), withIntermediateDirectories: true)
        let body = document + String(repeating: "a", count: 64 * 1024)
        try Data(body.utf8).write(to: bundle.appendingPathComponent("SKILL.md"))
        let reference = "REFERENCE\0" + String(repeating: "a", count: 16 * 1024)
        for index in 0..<33 {
            try Data(reference.utf8).write(to: bundle.appendingPathComponent("references/\(index).md"))
        }
        let scriptPath = "scripts/run.sh"
        let script = Data("echo sample".utf8)
        try script.write(to: bundle.appendingPathComponent(scriptPath))
        let invalidUTF8 = Data([0xff])
        try invalidUTF8.write(to: bundle.appendingPathComponent("binary.md"))
        let privateFile = root.appendingPathComponent("private.md")
        try Data("Outside the skill".utf8).write(to: privateFile)
        try FileManager.default.createSymbolicLink(at: bundle.appendingPathComponent("outside.md"), withDestinationURL: privateFile)
        let store = SkillStore(directory: root.appendingPathComponent("library"), defaults: defaults)
        let imported = try store.importPackage(bundle)
        XCTAssertEqual(try store.importPackage(bundle).id, imported.id)
        XCTAssertEqual(store.enabledSnapshot.first(where: { $0.id == imported.id }), imported)
        XCTAssertNil(store.warning)
        XCTAssertEqual(imported.documents["references/32.md"], reference)
        XCTAssertEqual(imported.documents.count, 34)
        XCTAssertNil(imported.documents[scriptPath])
        XCTAssertNil(imported.documents["binary.md"])
        XCTAssertNil(imported.documents["outside.md"])
        let copied = try XCTUnwrap(store.directory).appendingPathComponent(imported.id.uuidString)
        XCTAssertEqual(try Data(contentsOf: copied.appendingPathComponent(scriptPath)), script)
        XCTAssertEqual(try Data(contentsOf: copied.appendingPathComponent("binary.md")), invalidUTF8)
        try assertWholeDocument(imported, expected: body)

        try Data("echo updated".utf8).write(to: bundle.appendingPathComponent(scriptPath))
        XCTAssertNotEqual(try store.importPackage(bundle).id, imported.id)

        for path in ["../escape.md", "/tmp/private.md", "refs/../../secret.md", "refs\\private.md", "https://x/file.md", "refs//x.md"] {
            XCTAssertThrowsError(try store.add(documents: ["SKILL.md": document, path: "invalid"]))
        }
        XCTAssertEqual(store.packages.count, 2)
    }
    func testMetadataFormatLimitsAndCorruptArchivePreserveOriginal() throws {
        let store = SkillStore(inMemory: true)
        for body in ["# No metadata", "---\nname: x\n---\nmissing description", "---\nname: x\nname: y\ndescription: d\n---"] {
            XCTAssertThrowsError(try store.add(documents: ["SKILL.md": body]))
        }
        let multi = try store.add(documents: ["SKILL.md": "---\nname: 'multi'\ndescription: >\n  first line\n  second line\n---\nBody"])
        XCTAssertEqual(multi.summary, "first line second line")
        let root = try directory(), file = root.appendingPathComponent("skills-v1.json"), bytes = Data("unreadable".utf8)
        try bytes.write(to: file)
        let broken = SkillStore(directory: root, defaults: defaults)
        XCTAssertNotNil(broken.warning); XCTAssertThrowsError(try broken.add(documents: ["SKILL.md": document]))
        XCTAssertEqual(try Data(contentsOf: file), bytes)
    }
    func testCatalogLoadsByNameAndExposesReferencePathsWithoutDumpingBodyInListing() async throws {
        let root = try directory(), store = SkillStore(directory: root, defaults: defaults)
        let item = try store.add(documents: ["SKILL.md": document, "references/guide.md": "REFERENCE_BODY"])
        let catalog = SkillCatalog(store: store)
        let metadata = AgentViewModel.systemPrompt(skills: store.enabledSnapshot, language: "en")
        XCTAssertTrue(metadata.contains(item.name))
        XCTAssertFalse(metadata.contains("BODY_NOT_A_SUMMARY"))
        XCTAssertFalse(metadata.contains("REFERENCE_BODY"))
        let result = try catalog.load(named: item.name)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(result.utf8)) as? [String: Any])
        XCTAssertEqual(object["content"] as? String, document)
        XCTAssertFalse(result.contains("REFERENCE_BODY"))
        let directory = try XCTUnwrap(object["directory"] as? String)
        XCTAssertEqual(object["file_path"] as? String, directory + "/SKILL.md")
        let workspace = try FileWorkspace(root: root)
        let reference = try await workspace.read(filePath: directory + "/references/guide.md", offset: 1, limit: 20)
        XCTAssertTrue(reference.contains("REFERENCE_BODY"))
        XCTAssertThrowsError(try catalog.load(named: "Missing Guide"))
        let tool = SkillTool(name: "load_skill", catalog: catalog, canRead: { true })
        let schema = try XCTUnwrap(tool.descriptor.parameters.foundation as? [String: Any])
        XCTAssertEqual(schema["required"] as? [String], ["name"])
        XCTAssertEqual(Set((schema["properties"] as? [String: Any] ?? [:]).keys), ["name"])
    }
    func testPromptOnlyIncludesEnabledNamesAndDescriptions() throws {
        let store = SkillStore(inMemory: true)
        let item = try store.add(documents: ["SKILL.md": document])
        var disabled = item
        disabled.enabled = false
        let prompt = AgentViewModel.systemPrompt(skills: [disabled], language: "zh-Hans")
        XCTAssertFalse(prompt.contains(item.name))
        XCTAssertFalse(prompt.contains(item.summary))
        XCTAssertEqual(prompt, AgentViewModel.systemPrompt(skills: [], language: "zh-Hans"))
        XCTAssertTrue(prompt.hasSuffix("\nDefault response language: zh-Hans."))
        let enabledPrompt = AgentViewModel.systemPrompt(skills: [item], language: "en")
        XCTAssertFalse(enabledPrompt.contains(item.id.uuidString))
        XCTAssertFalse(enabledPrompt.contains(item.revision))
        let catalogLine = try XCTUnwrap(enabledPrompt.components(separatedBy: "\n").first { $0.hasPrefix("[{") })
        let metadata = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(catalogLine.utf8)) as? [[String: String]])
        XCTAssertEqual(metadata, [["name": item.name, "description": item.summary]])
        XCTAssertFalse(enabledPrompt.contains("BODY_NOT_A_SUMMARY"))
        let chinesePrompt = AgentViewModel.systemPrompt(skills: [item], language: "zh-Hans")
        XCTAssertTrue(enabledPrompt.contains("\n" + AgentViewModel.systemPrompt))
        XCTAssertEqual(enabledPrompt.split(separator: "\n").dropFirst().dropLast(),
                       chinesePrompt.split(separator: "\n").dropFirst().dropLast())
        for (language, name) in [("en", "Actell"), ("en-US", "Actell"), ("zh-Hans", "执言"), ("zh-Hans-CN", "执言")] {
            let localized = AgentViewModel.systemPrompt(skills: [item], language: language)
            XCTAssertTrue(try XCTUnwrap(localized.components(separatedBy: "\n").first).contains(name))
            XCTAssertTrue(localized.hasSuffix("\nDefault response language: \(language)."))
        }
        let catalogEnd = try XCTUnwrap(enabledPrompt.range(of: "}]", options: .backwards)).upperBound
        let languageStart = try XCTUnwrap(enabledPrompt.range(of: "Follow the user's explicit language preference")).lowerBound
        XCTAssertLessThan(catalogEnd, languageStart)
        let other = try store.add(documents: ["SKILL.md": document.replacingOccurrences(of: "Synthetic Guide", with: "Another Guide")])
        XCTAssertEqual(AgentViewModel.systemPrompt(skills: [item, other], language: "en"),
                       AgentViewModel.systemPrompt(skills: [other, item], language: "en"))
    }
    func testCancelledImportAndStaleToolContextNeverRead() async throws {
        let store = SkillStore(inMemory: true), body = document
        let task = Task { try store.add(documents: ["SKILL.md": body]) }; task.cancel()
        do { _ = try await task.value; XCTFail() } catch {}
        XCTAssertTrue(store.packages.isEmpty)
        let item = try store.add(documents: ["SKILL.md": body])
        let tool = SkillTool(name: "load_skill", catalog: SkillCatalog(store: store), canRead: { false })
        let sessionID = UUID(), turnID = UUID()
        let arguments = String(decoding: try JSONEncoder().encode(["name": item.name]), as: UTF8.self)
        let invocation = ToolInvocation(sessionID: sessionID, turnID: turnID, call: .init(id: "stale", name: "load_skill", arguments: arguments))
        let context = ToolExecutionContext(sessionID: sessionID, turnID: turnID, generation: UUID(), fence: ExecutionFence())
        do { _ = try await tool.execute(invocation, context: context); XCTFail() } catch { XCTAssertTrue(error is CancellationError) }
    }
    func testLargeSkillLoadsWholeDocumentByName() throws {
        let body = document + String(repeating: "a", count: 49_999 - document.unicodeScalars.count)
            + "🙂" + String(repeating: "b", count: 10_000)
        let store = SkillStore(inMemory: true)
        let item = try store.add(documents: ["SKILL.md": body])
        let response = try SkillCatalog(store: store).load(named: item.name)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(response.utf8)) as? [String: Any])
        XCTAssertEqual(object["content"] as? String, body)
        XCTAssertEqual((object["content"] as? String)?.unicodeScalars.count, 60_000)
    }
    func testFullSkillAndMaximumResourceMetadataReachModelUnchanged() async throws {
        let body = document + String(repeating: "\u{0001}", count: 50_001 - document.unicodeScalars.count)
        var documents = ["SKILL.md": body]
        for index in 0..<31 {
            documents[String(repeating: "r", count: 228) + "/\(index).md"] = "reference"
        }
        let store = SkillStore(inMemory: true)
        let item = try store.add(documents: documents)
        let tool = SkillTool(name: "load_skill", catalog: SkillCatalog(store: store), canRead: { true })
        let sessionID = UUID(), turnID = UUID()
        let arguments = String(decoding: try JSONEncoder().encode(["name": item.name]), as: UTF8.self)
        let invocation = ToolInvocation(sessionID: sessionID, turnID: turnID, call: .init(id: "page", name: "load_skill", arguments: arguments))
        let context = ToolExecutionContext(sessionID: sessionID, turnID: turnID, generation: UUID(), fence: ExecutionFence())
        let result = try await tool.execute(invocation, context: context)
        XCTAssertEqual(result.kind, .returned)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(result.modelContent.utf8)) as? [String: Any])
        XCTAssertEqual(object["content"] as? String, body)
        XCTAssertNil(object["next_offset"])
        XCTAssertEqual((object["available_resources"] as? [String])?.count, 32)
        XCTAssertNil(object["artifactReference"])
    }
    func testWholeDocumentsPreserveUnicodeAndResourceCatalogue() throws {
        let samples = [
            document + "\n" + String(repeating: "a", count: 49_000) + "b" + String(repeating: "\u{0301}", count: 2_000),
            document + "\n" + String(repeating: "中文🙂👩‍👩‍👦‍👦\"\\\n\t\u{0001}", count: 500)
        ]
        for body in samples {
            let package = try SkillPackage.make(documents: ["SKILL.md": body])
            try assertWholeDocument(package, expected: body)
        }
        let name = "a" + String(repeating: "\u{0301}", count: 10_000)
        let body = "---\nname: \(name)\ndescription: Unicode fixture\n---\n" + String(repeating: "资料🙂\"\\\n", count: 500)
        var documents = ["SKILL.md": body]
        for index in 0..<31 { documents[String(repeating: "\u{0001}", count: 200) + "/\(index).md"] = "reference" }
        let package = try SkillPackage.make(documents: documents)
        try assertWholeDocument(package, expected: body)
    }
    private func assertWholeDocument(_ package: SkillPackage, expected: String) throws {
        let store = SkillStore(inMemory: true)
        _ = try store.add(documents: package.documents)
        let response = try SkillCatalog(store: store).load(named: package.name)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(response.utf8)) as? [String: Any])
        let content = try XCTUnwrap(object["content"] as? String)
        XCTAssertEqual(object["skill_name"] as? String, package.name)
        XCTAssertEqual(object["available_resources"] as? [String], package.resources)
        XCTAssertNil(object["next_offset"])
        XCTAssertEqual(Array(content.utf8), Array(expected.utf8))
    }
    func testActualAgentLoadsReferencesAndReloadsEditedAndNewSkillsByName() async throws {
        let root = try directory(), store = SkillStore(directory: root, defaults: defaults)
        let ending = "\nEND_OF_COMPLETE_SKILL"
        let body = document + String(repeating: "a", count: 50_000 - document.unicodeScalars.count - ending.unicodeScalars.count) + ending
        _ = try store.add(documents: ["SKILL.md": body, "references/guide.md": "REFERENCE_BODY"])
        let provider = SkillRoundTripProvider(expectedSkill: body, skillsDirectory: root)
        let profiles = ProviderStore(defaults: nil)
        var profile = ProviderProfile(settings: .init(baseURL: "https://skill-fixture.invalid", model: "fixture"))
        profile.catalog = ModelCatalog(endpoint: try profile.catalogEndpoint(), fetchedAt: Date(),
            models: [.init(id: "fixture", name: "fixture", inputTokenLimit: 131_072)])
        try profiles.save(profile)
        let model = AgentViewModel(sessions: ConversationStore(inMemory: true), loadPersistentState: false,
            runServices: AgentRunServices(provider: provider, bridge: UnavailableBridge()), skills: store, providers: profiles)
        let id = model.createConversation(mode: .live)
        defer { model.stop() }
        XCTAssertTrue(model.send("Use the synthetic guide, update it and create a new guide", in: id, cloudConsent: true))
        for _ in 0..<150 where model.running { try await Task.sleep(for: .milliseconds(30)) }
        XCTAssertFalse(model.running)
        XCTAssertEqual(model.sessions.conversation(id)?.phase, .completed)
        let tools = model.sessions.conversation(id)?.messages.compactMap(\.tool) ?? []
        XCTAssertEqual(tools.map(\.name), ["load_skill", "read", "edit", "load_skill", "write", "load_skill"])
        XCTAssertTrue(tools.allSatisfy { $0.state == .succeeded })
        XCTAssertEqual(tools.first?.skillName, "Synthetic Guide")
        XCTAssertEqual(tools.first?.symbol, "book.closed")
        XCTAssertEqual(tools.last?.skillName, "New Guide")
        XCTAssertTrue(tools.last?.result.contains("NEW_SKILL_BODY") == true)
        XCTAssertTrue(tools.contains { $0.result.contains("BODY_NOT_A_SUMMARY") })
        XCTAssertTrue(tools.contains { $0.result.contains("REFERENCE_BODY") })
    }
}

private struct SkillRoundTripProvider: ModelProvider {
    static let name = "skill-roundtrip-fixture"
    let expectedSkill: String
    let skillsDirectory: URL
    let configuration = ProviderConfiguration(name: name, baseURL: URL(string: "https://invalid.invalid")!, defaultModel: "fixture")
    func stream(_ request: ModelRequest) -> AsyncThrowingStream<ModelEvent, Error> {
        AsyncThrowingStream { continuation in
            do {
                let response = try respond(request)
                for call in response.toolCalls { continuation.yield(.toolCall(call)) }
                if !response.text.isEmpty { continuation.yield(.text(response.text)) }
                continuation.yield(.terminal(response)); continuation.finish()
            } catch { continuation.finish(throwing: error) }
        }
    }
    func complete(_ request: ModelRequest) async throws -> ModelResponse { try respond(request) }
    private func respond(_ request: ModelRequest) throws -> ModelResponse {
        let messages = fixtureMessages(request)
        let system = messages.filter { $0.role == .system }.map(\.content).joined(separator: "\n")
        XCTAssertTrue(system.contains("Synthetic Guide"))
        XCTAssertTrue(system.contains("Read synthetic fixtures"))
        XCTAssertTrue(system.contains("ios-operation"))
        XCTAssertFalse(system.contains("search_skills"))
        XCTAssertFalse(system.contains("list_skills"))
        XCTAssertFalse(messages.filter { $0.role == .system }.contains { $0.content.contains("BODY_NOT_A_SUMMARY") })
        let results = messages.filter { $0.role == .tool }, stage = results.count
        if let first = results.first {
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(first.content.utf8)) as? [String: Any])
            XCTAssertEqual(object["content"] as? String, expectedSkill)
            XCTAssertNil(object["next_offset"])
            XCTAssertNil(object["artifactReference"])
            XCTAssertFalse(first.content.contains("REFERENCE_BODY"))
        }
        let name: String, arguments: [String: String]
        if stage == 0 {
            // The SDK may append system instructions after the catalog. Read
            // the complete JSON array rather than requiring an otherwise empty line.
            let start = try XCTUnwrap(system.range(of: "[{")) .lowerBound
            var depth = 0, quoted = false, escaped = false, end: String.Index?
            for index in system[start...].indices {
                let character = system[index]
                if quoted {
                    if escaped { escaped = false }
                    else if character == "\\" { escaped = true }
                    else if character == "\"" { quoted = false }
                } else if character == "\"" { quoted = true }
                else if character == "[" { depth += 1 }
                else if character == "]" {
                    depth -= 1
                    if depth == 0 { end = system.index(after: index); break }
                }
            }
            let metadata = system[start..<((try XCTUnwrap(end)))]
            let skills = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(metadata.utf8)) as? [[String: String]])
            let skill = try XCTUnwrap(skills.first(where: { $0["name"] == "Synthetic Guide" }))
            XCTAssertEqual(Set(skill.keys), ["name", "description"])
            name = "load_skill"; arguments = ["name": skill["name"]!]
        } else if stage == 1 || stage == 2 {
            let first = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(results[0].content.utf8)) as? [String: Any])
            let directory = try XCTUnwrap(first["directory"] as? String)
            if stage == 1 {
                name = "read"; arguments = ["file_path": directory + "/references/guide.md"]
            } else {
                name = "edit"; arguments = ["file_path": directory + "/SKILL.md", "old_string": "BODY_NOT_A_SUMMARY", "new_string": "EDITED_SKILL_BODY"]
            }
        } else if stage == 3 {
            name = "load_skill"; arguments = ["name": "Synthetic Guide"]
        } else if stage == 4 {
            let edited = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(results[3].content.utf8)) as? [String: Any])
            XCTAssertEqual(edited["content"] as? String, expectedSkill.replacingOccurrences(of: "BODY_NOT_A_SUMMARY", with: "EDITED_SKILL_BODY"))
            name = "write"; arguments = ["file_path": skillsDirectory.appendingPathComponent("new-guide/SKILL.md").path,
                "content": "---\nname: New Guide\ndescription: Created during this run\n---\nNEW_SKILL_BODY"]
        } else if stage == 5 {
            XCTAssertFalse(system.contains("New Guide"))
            name = "load_skill"; arguments = ["name": "New Guide"]
        } else {
            let created = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(results[5].content.utf8)) as? [String: Any])
            XCTAssertEqual(created["skill_name"] as? String, "New Guide")
            XCTAssertTrue((created["content"] as? String)?.contains("NEW_SKILL_BODY") == true)
            XCTAssertTrue(results.contains { $0.content.contains("BODY_NOT_A_SUMMARY") })
            XCTAssertTrue(results.contains { $0.content.contains("REFERENCE_BODY") })
            return ModelResponse(text: "合成技能与参考已读取。", finishReason: .stop, request: request, providerName: Self.name)
        }
        return ModelResponse(text: "", finishReason: .toolCalls, toolCalls: [.init(id: "skill-\(stage)", name: name,
            arguments: String(decoding: try JSONEncoder().encode(arguments), as: UTF8.self))], request: request, providerName: Self.name)
    }
}
