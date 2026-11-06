import XCTest
import UIKit
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
