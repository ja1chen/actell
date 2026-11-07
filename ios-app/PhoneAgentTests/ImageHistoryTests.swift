import XCTest
import UIKit
@testable import PhoneAgent

private final class HistoryImageHTTPStub: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var bytes = Data()
    nonisolated(unsafe) static var status = 200
    nonisolated(unsafe) static var calls = 0
    nonisolated(unsafe) static var delay = false
    private var work: DispatchWorkItem?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.calls += 1
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        XCTAssertNil(request.value(forHTTPHeaderField: "Cookie"))
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.client?.urlProtocol(self, didReceive: HTTPURLResponse(url: self.request.url!, statusCode: Self.status,
                httpVersion: nil, headerFields: ["Content-Type": "image/png"])!, cacheStoragePolicy: .notAllowed)
            self.client?.urlProtocol(self, didLoad: Self.bytes)
            self.client?.urlProtocolDidFinishLoading(self)
        }
        work = item
        DispatchQueue.main.asyncAfter(deadline: .now() + (Self.delay ? 0.2 : 0), execute: item)
    }
    override func stopLoading() { work?.cancel() }
}

@MainActor final class ImageHistoryTests: XCTestCase {
    private let source = URL(string: "https://synthetic.invalid/image.png")!
    private func setup() throws -> (URL, ConversationStore, AgentViewModel, UUID, UUID, MessageImageDownloader) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("history-\(UUID())")
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let sessions = ConversationStore(directory: root), id = sessions.create(mode: .demo)
        let run = sessions.begin(in: id, query: "![synthetic](\(source.absoluteString))")!
        sessions.finish(run, phase: .completed, summary: "")
        let model = AgentViewModel(sessions: sessions, loadPersistentState: false,
            attachments: AttachmentStore(directory: root))
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        HistoryImageHTTPStub.bytes = UIGraphicsImageRenderer(size: CGSize(width: 32, height: 20), format: format).pngData { context in
            UIColor.systemTeal.setFill(); context.fill(CGRect(x: 0, y: 0, width: 32, height: 20))
        }
        HistoryImageHTTPStub.status = 200; HistoryImageHTTPStub.calls = 0; HistoryImageHTTPStub.delay = false
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [HistoryImageHTTPStub.self]
        return (root, sessions, model, id, sessions.conversation(id)!.messages[0].id, MessageImageDownloader(configuration: config))
    }
    func testDownloadedOriginalPersistsAcrossRestartAndExpiredSourceWithoutNetwork() async throws {
        let (root, sessions, model, id, messageID, downloader) = try setup()
        let asset = try await model.cacheMessageImage(source, messageID: messageID, conversationID: id, downloader: downloader)
        XCTAssertEqual(sessions.referencedAttachments.count, 1)
        HistoryImageHTTPStub.status = 403
        let restored = ConversationStore(directory: root)
        let reopened = AgentViewModel(sessions: restored, loadPersistentState: false,
            attachments: AttachmentStore(directory: root))
        let cached = try await reopened.cacheMessageImage(source, messageID: messageID, conversationID: id, downloader: downloader)
        XCTAssertEqual(cached, asset); XCTAssertEqual(HistoryImageHTTPStub.calls, 1)
        let bytes = try await reopened.attachments.read(cached, conversationID: id)
        XCTAssertEqual(bytes, HistoryImageHTTPStub.bytes)
        XCTAssertNil(reopened.latestFrame); XCTAssertNil(reopened.currentRun); XCTAssertNil(reopened.approval)
        let removed = try await reopened.clearUnreferencedAttachments(); XCTAssertEqual(removed, 0)
    }
    func testMissingCacheAndExpiredUncachedURLFailHonestlyAndCanRetry() async throws {
        let (root, _, model, id, messageID, downloader) = try setup()
        HistoryImageHTTPStub.status = 403
        do { _ = try await model.cacheMessageImage(source, messageID: messageID, conversationID: id, downloader: downloader); XCTFail() }
        catch { XCTAssertTrue(error.localizedDescription.contains("无法恢复")) }
        HistoryImageHTTPStub.status = 200
        let asset = try await model.cacheMessageImage(source, messageID: messageID, conversationID: id, downloader: downloader)
        try FileManager.default.removeItem(at: SessionStorageLayout(root: root).directory(for: id).appendingPathComponent("attachments/\(asset.id)/original"))
        _ = try await model.cacheMessageImage(source, messageID: messageID, conversationID: id, downloader: downloader)
        let read = try await model.attachments.read(asset, conversationID: id); XCTAssertEqual(read, HistoryImageHTTPStub.bytes)
        XCTAssertEqual(model.sessions.referencedAttachments.count, 1)
    }
    func testOnlyExistingMessageImageURLsCanDownload() async throws {
        let (_, _, model, id, messageID, downloader) = try setup()
        for (url, message, conversation) in [(URL(string: "https://other.invalid/x")!, messageID, id), (source, UUID(), id), (source, messageID, UUID())] {
            do { _ = try await model.cacheMessageImage(url, messageID: message, conversationID: conversation, downloader: downloader); XCTFail() } catch {}
        }
        XCTAssertEqual(HistoryImageHTTPStub.calls, 0)
    }
    func testRetryWithChangedSourceReplacesMissingReferenceAndPersistsNewOriginal() async throws {
        let (root, sessions, model, id, messageID, downloader) = try setup()
        let old = try await model.cacheMessageImage(source, messageID: messageID, conversationID: id, downloader: downloader)
        try FileManager.default.removeItem(at: SessionStorageLayout(root: root).directory(for: id).appendingPathComponent("attachments/\(old.id)/original"))
        HistoryImageHTTPStub.bytes = UIGraphicsImageRenderer(size: CGSize(width: 24, height: 16)).pngData { context in
            UIColor.systemRed.setFill(); context.fill(CGRect(x: 0, y: 0, width: 24, height: 16))
        }
        let replacement = try await model.cacheMessageImage(source, messageID: messageID, conversationID: id, downloader: downloader)
        XCTAssertNotEqual(old.id, replacement.id)
        XCTAssertEqual(sessions.conversation(id)?.messages.first?.attachments, [replacement])
        let restored = ConversationStore(directory: root)
        XCTAssertEqual(restored.conversation(id)?.messages.first?.attachments, [replacement])
        let removed = try await model.clearUnreferencedAttachments(); XCTAssertEqual(removed, 1)
        HistoryImageHTTPStub.status = 403
        let cached = try await model.cacheMessageImage(source, messageID: messageID, conversationID: id, downloader: downloader)
        XCTAssertEqual(cached, replacement); XCTAssertEqual(HistoryImageHTTPStub.calls, 2)
    }
    func testInFlightDownloadCannotRecreateDeletedMessageAndBlocksCleanup() async throws {
        let (_, sessions, model, id, messageID, downloader) = try setup()
        HistoryImageHTTPStub.delay = true
        let task = Task { try await model.cacheMessageImage(source, messageID: messageID, conversationID: id, downloader: downloader) }
        try await Task.sleep(for: .milliseconds(40))
        do { _ = try await model.clearUnreferencedAttachments(); XCTFail("cleanup raced import") } catch {}
        sessions.delete(id)
        do { _ = try await task.value; XCTFail("deleted message restored") } catch {}
        XCTAssertTrue(sessions.conversations.isEmpty)
        let removed = try await model.clearUnreferencedAttachments(); XCTAssertEqual(removed, 0)
    }
    func testLongHistoryKeepsAllMessagesAndReferencedOriginalAfterRestart() async throws {
        let (root, sessions, model, id, _, _) = try setup()
        let run = sessions.begin(in: id, query: "observe")!
        sessions.updateTool(callID: "screen", name: "screenshot", state: .succeeded, identity: run)
        let asset = try await model.attachments.store(HistoryImageHTTPStub.bytes, name: "synthetic.png", conversationID: id)
        XCTAssertTrue(sessions.attach(asset, toTool: "screen", identity: run))
        sessions.finish(run, phase: .completed, summary: "")
        for index in 0..<220 { sessions.addNotice("notice \(index)", in: id) }
        let restored = ConversationStore(directory: root)
        let reopened = AgentViewModel(sessions: restored, loadPersistentState: false, attachments: model.attachments)
        let adapter = AgentPresentationAdapter(model: reopened, sessionID: id)
        let message = try XCTUnwrap(restored.conversation(id)?.messages.first { $0.tool != nil })
        XCTAssertEqual(adapter.presentation(for: message)?.attachments, [asset])
        XCTAssertNil(adapter.presentation(for: message)?.image); XCTAssertNil(adapter.presentation(for: message)?.approval)
        XCTAssertEqual(restored.conversation(id)?.messages.count, 223)
    }
}
