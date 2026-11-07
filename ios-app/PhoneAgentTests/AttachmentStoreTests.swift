import XCTest
import UIKit
import AgentKit
import ProviderCore
@testable import PhoneAgent

@MainActor final class AttachmentStoreTests: XCTestCase {
    private func directory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("assets-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }; return root
    }
    private func png() -> Data {
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: 64, height: 40), format: format).pngData { context in
            UIColor.systemBlue.setFill(); context.fill(CGRect(x: 0, y: 0, width: 64, height: 40))
        }
    }
    func testRuntimeImageAndPreviewRemainReadableThroughSandboxDirectoryAlias() async throws {
        let root = try directory(), actual = root.appendingPathComponent("actual/Documents"), alias = root.appendingPathComponent("alias/Documents")
        let id = UUID(), data = png(), writer = AttachmentStore(directory: actual)
        let attachment = try await writer.store(data, name: "screen.png", conversationID: id)
        try FileManager.default.createSymbolicLink(at: alias.deletingLastPathComponent(), withDestinationURL: actual.deletingLastPathComponent())
        let images = try SessionStorageLayout(root: actual).directory(for: id).appendingPathComponent("attachments")
        try FileManager.default.moveItem(at: images.appendingPathComponent("\(attachment.id)/original"), to: images.appendingPathComponent(attachment.digest))
        try FileManager.default.removeItem(at: images.appendingPathComponent(attachment.id.uuidString))
        let reader = AttachmentStore(directory: alias)
        let original = try await reader.read(attachment, conversationID: id)
        let preview = try await reader.preview(attachment, conversationID: id)
        XCTAssertEqual(original, data)
        XCTAssertNotNil(UIImage(data: preview))
    }
    func testOriginalCanBeSavedThroughSandboxDirectoryAlias() async throws {
        let root = try directory(), actual = root.appendingPathComponent("actual/Documents"), alias = root.appendingPathComponent("alias/Documents")
        try FileManager.default.createDirectory(at: actual, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: alias.deletingLastPathComponent(), withDestinationURL: actual.deletingLastPathComponent())
        let store = AttachmentStore(directory: alias), id = UUID(), data = png()
        let attachment = try await store.store(data, name: "screen.png", conversationID: id)
        let original = try await store.read(attachment, conversationID: id)
        XCTAssertEqual(original, data)
    }
    func testAttachmentDirectorySymlinkCannotEscapeSession() async throws {
        let root = try directory(), documents = root.appendingPathComponent("documents"), outside = root.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: documents, withIntermediateDirectories: true)
        try ConversationJournal.install([], in: documents)
        let id = UUID(), session = try SessionStorageLayout(root: documents).ensureDirectory(for: id, createdAt: Date())
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: session.appendingPathComponent("attachments"), withDestinationURL: outside)
        do { _ = try await AttachmentStore(directory: documents).store(png(), name: "screen.png", conversationID: id); XCTFail("Escaped the session") } catch {}
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: outside.path).isEmpty)
    }
    func testRuntimeImageFallbackVerifiesBytesAndDoesNotDeleteJournalImages() async throws {
        let root = try directory(), id = UUID(), data = png(), store = AttachmentStore(directory: root)
        let attachment = try await store.store(data, name: "screen.png", conversationID: id)
        let images = try SessionStorageLayout(root: root).directory(for: id).appendingPathComponent("attachments")
        let original = images.appendingPathComponent("\(attachment.id)/original")
        let runtimeImage = images.appendingPathComponent(attachment.digest)
        try FileManager.default.moveItem(at: original, to: runtimeImage)
        let restored = try await store.read(attachment, conversationID: id)
        XCTAssertEqual(restored, data)
        _ = try await store.removeUnreferenced(keeping: [])
        XCTAssertTrue(FileManager.default.fileExists(atPath: runtimeImage.path))
        do { _ = try await store.read(attachment, conversationID: UUID()); XCTFail("Cross-session image read") } catch {}
        try Data("corrupt".utf8).write(to: runtimeImage)
        do { _ = try await store.read(attachment, conversationID: id); XCTFail("Corrupt runtime image read") } catch {}
        try FileManager.default.removeItem(at: runtimeImage)
        let outside = root.appendingPathComponent("outside.png")
        try data.write(to: outside)
        try FileManager.default.createSymbolicLink(at: runtimeImage, withDestinationURL: outside)
        do { _ = try await store.read(attachment, conversationID: id); XCTFail("Symlink runtime image read") } catch {}
    }
    func testImageOriginalSurvivesRestartAndPreviewAndSendAreDerivedLocally() async throws {
        let root = try directory(), id = UUID(), data = png()
        let store = AttachmentStore(directory: root)
        let attachment = try await store.store(data, name: "synthetic.png", conversationID: id)
        let restored = AttachmentStore(directory: root)
        let original = try await restored.read(attachment, conversationID: id)
        let preview = try await restored.preview(attachment, conversationID: id)
        let sent = try await restored.inferenceImage(attachment, conversationID: id)
        XCTAssertEqual(original, data); XCTAssertNotNil(UIImage(data: preview)); XCTAssertNotNil(UIImage(data: sent))
        XCTAssertEqual(attachment.width, 64); XCTAssertEqual(attachment.height, 40)
        let encoded = try JSONEncoder().encode(attachment)
        XCTAssertLessThan(encoded.count, 1500)
        XCTAssertFalse(String(data: encoded, encoding: .utf8)!.contains(data.base64EncodedString()))
        XCTAssertEqual(try root.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup, false)
    }
    func testDuplicateContentIsDeduplicatedOnlyWithinItsConversation() async throws {
        let root = try directory(), store = AttachmentStore(directory: root), a = UUID(), b = UUID(), data = png()
        let first = try await store.store(data, name: "one.png", conversationID: a)
        let again = try await store.store(data, name: "two.png", conversationID: a)
        let other = try await store.store(data, name: "one.png", conversationID: b)
        XCTAssertEqual(first.id, again.id); XCTAssertNotEqual(first.conversationID, other.conversationID)
        do { _ = try await store.read(first, conversationID: b); XCTFail("cross-session read") } catch {}
        let count = try await store.removeUnreferenced(keeping: [first])
        XCTAssertEqual(count, 1)
        let preserved = try await store.read(first, conversationID: a); XCTAssertEqual(preserved, data)
    }
    func testUTF8FileImportCopiesOriginalAndRejectsUnsupportedBinaryAndOversize() async throws {
        let root = try directory(), store = AttachmentStore(directory: root.appendingPathComponent("store")), id = UUID()
        let file = root.appendingPathComponent("fixture.md"), data = Data("# Synthetic\n你好".utf8)
        try data.write(to: file)
        let attachment = try await store.importFile(file, conversationID: id)
        try FileManager.default.removeItem(at: file)
        let restored = try await store.read(attachment, conversationID: id); XCTAssertEqual(restored, data)
        for (name, bytes) in [("private.pdf", Data("%PDF".utf8)), ("text.txt", Data([0, 1])), ("long.txt", Data(repeating: 65, count: AttachmentStore.textLimit + 1))] {
            do { _ = try await store.store(bytes, name: name, conversationID: id); XCTFail("must reject \(name)") } catch {}
        }
    }
    func testInvalidPathsSymlinksAndOtherConversationReferencesCannotReadFiles() async throws {
        let root = try directory(), store = AttachmentStore(directory: root.appendingPathComponent("store")), id = UUID()
        let file = root.appendingPathComponent("real.txt"), alias = root.appendingPathComponent("alias.txt")
        try Data("synthetic".utf8).write(to: file)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: file)
        do { _ = try await store.importFile(alias, conversationID: id); XCTFail("symlink import") } catch {}
        let item = try await store.store(png(), name: "../../picture.png", conversationID: id)
        XCTAssertEqual(item.name, "picture.png")
        let original = try SessionStorageLayout(root: root.appendingPathComponent("store")).directory(for: id).appendingPathComponent("attachments/\(item.id)/original")
        try FileManager.default.removeItem(at: original)
        try FileManager.default.createSymbolicLink(at: original, withDestinationURL: file)
        do { _ = try await store.read(item, conversationID: id); XCTFail("symlink read") } catch {}
    }
    func testCapacityNeverEvictsOriginalAndExplicitCleanupKeepsReferences() async throws {
        let root = try directory(), store = AttachmentStore(directory: root, capacity: 10), id = UUID()
        let item = try await store.store(Data("first".utf8), name: "one.txt", conversationID: id)
        do { _ = try await store.store(Data("second".utf8), name: "two.txt", conversationID: id); XCTFail("capacity must fail") } catch {}
        let before = try await store.read(item, conversationID: id); XCTAssertEqual(before, Data("first".utf8))
        let kept = try await store.removeUnreferenced(keeping: [item]); XCTAssertEqual(kept, 0)
        let removed = try await store.removeUnreferenced(keeping: []); XCTAssertEqual(removed, 1)
    }
    func testCleanupPreservesInlineModelImageFilesAndAttachmentMetadata() async throws {
        let root = try directory(), sessions = ConversationStore(directory: root), id = sessions.create(mode: .demo)
        let resources = AttachmentStore(directory: root), bytes = png()
        let user = try await resources.store(Data("referenced text".utf8), name: "retained.txt", conversationID: id)
        let orphan = try await resources.store(Data("unreferenced text".utf8), name: "orphan.txt", conversationID: id)
        let engine = try sessions.engineStore(for: id)
        _ = try engine.appendSync(.init(sessionID: id, kind: .turnStarted, contextItems: [.message(role: .user, content: [.image(.init(data: bytes))])]), expecting: 0)
        let folder = try sessions.sessionDirectory(id), attachments = folder.appendingPathComponent("attachments")
        let modelFiles = try FileManager.default.contentsOfDirectory(at: attachments, includingPropertiesForKeys: [.isRegularFileKey]).filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true }
        XCTAssertEqual(modelFiles.count, 1)
        let removed = try await resources.removeUnreferenced(keeping: [user]); XCTAssertEqual(removed, 1)
        XCTAssertEqual(try Data(contentsOf: try XCTUnwrap(modelFiles.first)), bytes)
        XCTAssertTrue(FileManager.default.fileExists(atPath: attachments.appendingPathComponent(user.id.uuidString).appendingPathComponent("metadata.json").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: attachments.appendingPathComponent(orphan.id.uuidString).path))
        let context = try engine.loadContextSync(id)
        let images = context.items.flatMap { item -> [ModelImage] in if case .message(_, let parts) = item { return parts.compactMap { if case .image(let image) = $0 { return image }; return nil } }; return [] }
        XCTAssertEqual(try images.first?.bytes(), bytes)
    }

    func testDamagedOriginalCanBeRepairedWithVerifiedReplacementBytes() async throws {
        let root = try directory(), store = AttachmentStore(directory: root), id = UUID(), data = png()
        let item = try await store.store(data, name: "image.png", conversationID: id)
        try Data("damaged".utf8).write(to: SessionStorageLayout(root: root).directory(for: id).appendingPathComponent("attachments/\(item.id)/original"))
        do { _ = try await store.read(item, conversationID: id); XCTFail("corrupt") } catch {}
        let repaired = try await store.store(data, name: "image.png", conversationID: id)
        XCTAssertEqual(repaired.id, item.id)
        let read = try await store.read(item, conversationID: id); XCTAssertEqual(read, data)
    }
}

private final class MessageImageHTTPStub: URLProtocol, @unchecked Sendable {
    static let bytes = Data([1, 2, 3, 4]) // Transport fixture; decoding is tested separately.
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        XCTAssertNil(request.value(forHTTPHeaderField: "Cookie"))
        XCTAssertEqual(request.url?.host, "message-image.invalid")
        let status = request.url!.path == "/redirect" ? 302 : request.url!.path == "/expired" ? 403 : 200
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil,
            headerFields: ["Content-Type":"image/png", "Location":"https://foreign.invalid/private"] )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.bytes); client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

final class MessageImageDownloadTests: XCTestCase {
    func testImageDownloadHasNoProviderHeadersAndDoesNotFollowRedirectOrExpiredURL() async throws {
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [MessageImageHTTPStub.self]
        let downloader = MessageImageDownloader(configuration: config)
        let data = try await downloader.download(URL(string: "https://message-image.invalid/image")!)
        XCTAssertEqual(data, MessageImageHTTPStub.bytes)
        for path in ["redirect", "expired"] {
            do { _ = try await downloader.download(URL(string: "https://message-image.invalid/\(path)")!); XCTFail("must fail") }
            catch { XCTAssertTrue(error.localizedDescription.contains("失效")) }
        }
    }
    func testImageDownloadRejectsEmbeddedCredentialsAndNonHTTPSBeforeNetwork() async {
        let downloader = MessageImageDownloader()
        for url in ["https://user:password@message-image.invalid/x", "http://message-image.invalid/x", "file:///private/x"] {
            do { _ = try await downloader.download(URL(string: url)!); XCTFail("must reject") } catch {}
        }
    }
}
