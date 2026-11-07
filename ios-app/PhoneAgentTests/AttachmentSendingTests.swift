import XCTest
import UIKit
import ProviderCore
@testable import PhoneAgent

private final class AttachmentReceiptProvider: ModelProvider, @unchecked Sendable {
    static let name = "synthetic-attachment-receipt"
    let configuration = ProviderConfiguration(name: name, baseURL: URL(string: "https://invalid.invalid")!, defaultModel: "fixture")
    private let lock = NSLock()
    private var captured: [ModelRequest] = []
    var requests: [ModelRequest] { lock.withLock { captured } }
    func stream(_ request: ModelRequest) -> AsyncThrowingStream<ModelEvent, Error> {
        lock.withLock { captured.append(request) }
        return AsyncThrowingStream { continuation in
            if !fixtureMessages(request).contains(where: { $0.role == .tool }) {
                continuation.yield(.toolCall(ModelToolCall(id: "attachment-observe", name: "screenshot", arguments: "{}")))
                continuation.yield(.terminal(.init(text: "", toolCalls: [.init(id: "attachment-observe", name: "screenshot", arguments: "{}")], request: request, providerName: Self.name)))
            } else {
                continuation.yield(.text("已读取合成附件。")); continuation.yield(.terminal(.init(text: "已读取合成附件。", request: request, providerName: Self.name)))
            }
            continuation.finish()
        }
    }
    func complete(_ request: ModelRequest) async throws -> ModelResponse { throw AppError.invalid("stream only") }
}

@MainActor final class AttachmentSendingTests: XCTestCase {
    private func fixture(attachmentCapacity: Int = AttachmentStore.capacity) -> (AgentViewModel, UUID, AttachmentReceiptProvider, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("send-assets-\(UUID())")
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let provider = AttachmentReceiptProvider()
        let model = AgentViewModel(sessions: ConversationStore(directory: root), loadPersistentState: false,
            runServices: AgentRunServices(provider: provider, bridge: DemoBridge()), attachments: AttachmentStore(directory: root, capacity: attachmentCapacity))
        return (model, model.createConversation(mode: .demo), provider, root)
    }
    private func image() -> Data {
        UIGraphicsImageRenderer(size: CGSize(width: 20, height: 15)).pngData { context in
            UIColor.orange.setFill(); context.fill(CGRect(x: 0, y: 0, width: 20, height: 15))
        }
    }
    func testSelectedAssetsStayLocalUntilSendThenReachRealAgentLoopAndRemainAfterScreenshot() async throws {
        let (model, id, provider, root) = fixture()
        try await model.importDraftAttachment(data: image(), name: "synthetic.png", in: id)
        try await model.importDraftAttachment(data: Data("SYNTHETIC_FILE_CONTENT".utf8), name: "notes.md", in: id)
        XCTAssertTrue(provider.requests.isEmpty); XCTAssertFalse(model.running)
        let draft = try XCTUnwrap(model.sessions.conversation(id)?.draftAttachments)
        XCTAssertEqual(draft.count, 2)
        let restored = ConversationStore(directory: root)
        XCTAssertEqual(restored.conversation(id)?.draftAttachments, draft)
        XCTAssertFalse(model.send("do not silently omit files", in: id))
        let sent = try await model.sendDraft("read files", in: id, cloudConsent: true); XCTAssertTrue(sent)
        for _ in 0..<100 where model.running { try await Task.sleep(for: .milliseconds(30)) }
        XCTAssertFalse(model.running); XCTAssertEqual(provider.requests.count, 2)
        for request in provider.requests {
            let user = try XCTUnwrap(fixtureMessages(request).first { $0.role == .user && $0.content.contains("SYNTHETIC_FILE_CONTENT") })
            XCTAssertEqual(user.images.count, 1)
        }
        XCTAssertNil(model.sessions.conversation(id)?.draftAttachments)
        XCTAssertEqual(model.sessions.conversation(id)?.messages.first?.attachments, draft)
        let disk = try Data(contentsOf: SessionStorageLayout(root: root).directory(for: id).appendingPathComponent("history.jsonl"))
        XCTAssertTrue(String(decoding: disk, as: UTF8.self).contains("SYNTHETIC_FILE_CONTENT"), "The protected authoritative JSONL retains the full prepared text")
        let screenshot = try XCTUnwrap(model.sessions.conversation(id)?.messages.first { $0.tool?.name == "screenshot" })
        let original = try XCTUnwrap(screenshot.attachments?.first)
        let originalBytes = try await model.attachments.read(original, conversationID: id)
        XCTAssertNotNil(UIImage(data: originalBytes))
        model.sessions.reloadPresentation(id)
        XCTAssertEqual(model.sessions.conversation(id)?.messages.first { $0.id == screenshot.id }?.attachments, [original])
        let reloaded = ConversationStore(directory: root)
        XCTAssertEqual(reloaded.conversation(id)?.messages.first { $0.id == screenshot.id }?.attachments, [original])
        let reopenedAttachments = AttachmentStore(directory: root)
        let reloadedBytes = try await reopenedAttachments.read(original, conversationID: id)
        XCTAssertEqual(reloadedBytes, originalBytes)
    }
    func testRepeatSelectionRemoveAndOtherSessionAreIsolated() async throws {
        let (model, id, provider, _) = fixture(), bytes = image()
        try await model.importDraftAttachment(data: bytes, name: "one.png", in: id)
        try await model.importDraftAttachment(data: bytes, name: "again.png", in: id)
        XCTAssertEqual(model.sessions.conversation(id)?.draftAttachments?.count, 1)
        let other = model.createConversation(mode: .demo)
        do { try await model.importDraftAttachment(data: bytes, name: "late.png", in: id); XCTFail() } catch {}
        XCTAssertNil(model.sessions.conversation(other)?.draftAttachments)
        model.selectConversation(id)
        let asset = try XCTUnwrap(model.sessions.conversation(id)?.draftAttachments?.first)
        model.sessions.removeDraftAttachment(asset.id, in: id)
        XCTAssertEqual(model.sessions.conversation(id)?.draftAttachments?.count, 0)
        XCTAssertTrue(provider.requests.isEmpty)
    }
    func testScreenshotPreviewUsesCommittedImageWithoutRequiringADuplicateOriginal() async throws {
        let (model, id, _, root) = fixture(attachmentCapacity: 0)
        XCTAssertTrue(model.send("capture a synthetic screen", in: id))
        for _ in 0..<100 where model.running { try await Task.sleep(for: .milliseconds(30)) }
        XCTAssertFalse(model.running)
        let message = try XCTUnwrap(model.sessions.conversation(id)?.messages.first { $0.tool?.name == "screenshot" })
        let attachment = try XCTUnwrap(message.attachments?.first)
        let bytes = try await model.attachments.read(attachment, conversationID: id)
        XCTAssertNotNil(UIImage(data: bytes))
        let folder = try SessionStorageLayout(root: root).directory(for: id).appendingPathComponent("attachments")
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent(attachment.digest).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent("\(attachment.id)/original").path))
        let restored = ConversationStore(directory: root)
        XCTAssertEqual(restored.conversation(id)?.messages.first { $0.id == message.id }?.attachments, [attachment])
        XCTAssertNil(model.storageWarning)
    }
    func testInvalidMissingAndCancelledAttachmentsNeverSendOrDiscardDraft() async throws {
        let (model, id, provider, root) = fixture()
        do { try await model.importDraftAttachment(data: Data("%PDF".utf8), name: "unsupported.pdf", in: id); XCTFail() } catch {}
        try await model.importDraftAttachment(data: image(), name: "synthetic.png", in: id)
        let asset = try XCTUnwrap(model.sessions.conversation(id)?.draftAttachments?.first)
        let cancelled = Task { try await model.sendDraft("cancelled", in: id, cloudConsent: true) }
        cancelled.cancel()
        do { _ = try await cancelled.value; XCTFail() } catch {}
        try FileManager.default.removeItem(at: SessionStorageLayout(root: root).directory(for: id).appendingPathComponent("attachments/\(asset.id)/original"))
        do { _ = try await model.sendDraft("missing", in: id, cloudConsent: true); XCTFail() } catch {}
        XCTAssertTrue(provider.requests.isEmpty); XCTAssertEqual(model.sessions.conversation(id)?.draftAttachments?.count, 1)
    }
    func testWireRequestPreservesThePreparedAttachmentAndObservationWindow() throws {
        let provider = try PrivateVisionProvider(settings: .init(baseURL: "https://invalid.invalid/v1", model: "fixture"), apiKey: "synthetic-key", limits: AgentLimits(), sessionID: UUID())
        defer { provider.cancel() }
        let user = ModelImage(data: Data([1])), old = ModelImage(data: Data([2])), newest = ModelImage(data: Data([3]))
        var request = ModelRequest(model: "fixture", messages: [])
        request.input = [.message(role: .user, content: [.text("attached"), .image(user)]),
            .replay(.functionCall(.init(id: "old", name: "screenshot", arguments: "{}"))),
            .functionResult(callID: "old", output: "old"), .message(role: .user, content: [.image(old)]),
            .replay(.functionCall(.init(id: "new", name: "screenshot", arguments: "{}"))),
            .functionResult(callID: "new", output: "new"), .message(role: .user, content: [.image(newest)])]
        let body = try XCTUnwrap(try provider.prepareRequest(request, stream: true).httpBody)
        let encoded = String(decoding: body, as: UTF8.self)
        XCTAssertTrue(encoded.contains("AQ==")); XCTAssertTrue(encoded.contains("Ag==")); XCTAssertTrue(encoded.contains("Aw=="))
        XCTAssertEqual(body, try provider.prepareRequest(request, stream: true).httpBody,
                       "Provider serialization preserves the prepared window; AgentKit commits observation retention separately")
    }
    func testDiscoveryOnlyProtocolsRejectSendWithoutDroppingDraftOrLoadingCredentials() async throws {
        for kind in [ProviderKind.anthropic, .gemini] {
            let model = AgentViewModel(sessions: ConversationStore(inMemory: true), loadPersistentState: false)
            let id = model.createConversation(mode: .live)
            var profile = ProviderProfile(name: "Synthetic", settings: .init(baseURL: kind.defaultBase, model: "fixture"))
            profile.protocolKind = kind
            try model.providers.save(profile); model.selectProvider(profile.id, in: id)
            try await model.importDraftAttachment(data: Data("synthetic content".utf8), name: "fixture.txt", in: id)
            let sent = try await model.sendDraft("read", in: id, cloudConsent: true)
            XCTAssertFalse(sent); XCTAssertFalse(model.running)
            XCTAssertEqual(model.sessions.conversation(id)?.draftAttachments?.count, 1)
            XCTAssertTrue(model.errorMessage?.contains("仅支持模型发现") == true)
        }
    }
}
