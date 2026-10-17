import SwiftUI
import Photos

struct AttachmentThumbnail: View {
    let attachment: StoredAttachment
    let store: AttachmentStore
    let conversationID: UUID
    @State private var preview: Data?
    @State private var failure: String?
    @State private var showingOriginal = false
    var body: some View {
        Button { showingOriginal = true } label: {
            VStack(alignment: .leading, spacing: 5) {
                if let preview, attachment.kind == .image, let image = UIImage(data: preview) {
                    Image(uiImage: image).resizable().scaledToFit().frame(maxHeight: 220)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                } else { Image(systemName: attachment.kind == .image ? "photo" : "doc.text").font(.title2).frame(minHeight: 35) }
                Text(attachment.name).font(.caption).lineLimit(1)
                if let failure { Text(failure).font(.caption).foregroundStyle(.orange) }
            }
        }
        .buttonStyle(.plain).accessibilityLabel(String(localized: "Preview attachment: \(attachment.name)"))
        .accessibilityIdentifier("attachment-" + attachment.id.uuidString)
        .task(id: attachment.id) {
            do { preview = try await store.preview(attachment, conversationID: conversationID); failure = nil }
            catch { failure = String(localized: "The local file is temporarily unavailable") }
        }
        .sheet(isPresented: $showingOriginal) { AttachmentPreview(attachment: attachment, store: store, conversationID: conversationID) }
    }
}

private struct AttachmentPreview: View {
    let attachment: StoredAttachment
    let store: AttachmentStore
    let conversationID: UUID
    @Environment(\.dismiss) private var dismiss
    @State private var data: Data?
    @State private var failure: String?
    @State private var scale: CGFloat = 1
    var body: some View {
        NavigationStack {
            Group {
                if let data, attachment.kind == .image, let image = UIImage(data: data) {
                    GeometryReader { geometry in
                        ScrollView([.horizontal, .vertical]) {
                            Image(uiImage: image).resizable().scaledToFit()
                                .frame(width: max(1, geometry.size.width - 32) * scale)
                                .accessibilityLabel(String(localized: "Local original image"))
                        }
                        .gesture(MagnifyGesture().onEnded { scale = min(6, max(1, scale * $0.magnification)) })
                    }
                } else if let data, let text = String(data: data, encoding: .utf8) {
                    ScrollView { Text(text).font(.body.monospaced()).textSelection(.enabled).padding() }
                } else if let failure { ContentUnavailableView(String(localized: "Could not read the attachment"), systemImage: "exclamationmark.triangle", description: Text(failure)) }
                else { ProgressView() }
            }
            .navigationTitle(attachment.name).navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(String(localized: "Done")) { dismiss() } }
                ToolbarItem(placement: .primaryAction) {
                    if let data, attachment.kind == .image { SaveScreenshotButton(data: data) }
                }
            }
            .task {
                do { data = try await store.read(attachment, conversationID: conversationID) }
                catch { failure = String(localized: "The local file is missing or temporarily inaccessible. Retry remote sources from the message, or select other attachments again.") }
            }
        }
    }
}

struct MessageAttachmentsView: View {
    let message: ChatMessage
    @ObservedObject var presentation: AgentPresentationAdapter
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach((message.attachments ?? []).filter { $0.sourceURL == nil }) { attachment in
                AttachmentThumbnail(attachment: attachment, store: presentation.attachments, conversationID: presentation.sessionID)
            }
            ForEach(Array(NSOrderedSet(array: MessageImageSources.urls(in: message.text))) as? [URL] ?? [], id: \.self) { url in
                RemoteMessageImage(url: url, message: message, presentation: presentation)
            }
        }
    }
}

private struct RemoteMessageImage: View {
    let url: URL
    let message: ChatMessage
    @ObservedObject var presentation: AgentPresentationAdapter
    @State private var loading = false
    @State private var failure: String?
    @State private var task: Task<Void, Never>?
    @State private var cacheAvailable = false
    private var cached: StoredAttachment? { message.attachments?.first { $0.sourceURL == url } }
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let cached, cacheAvailable {
                AttachmentThumbnail(attachment: cached, store: presentation.attachments, conversationID: presentation.sessionID)
            } else {
                Label(String(localized: "Message image"), systemImage: "photo")
                if let failure { Text(failure).font(.caption).foregroundStyle(.orange) }
                HStack {
                    Button(failure == nil ? String(localized: "Download and cache image") : String(localized: "Retry original image source")) { load() }.disabled(loading)
                    if loading {
                        ProgressView()
                        Button(String(localized: "Cancel")) { task?.cancel(); loading = false }
                    }
                }
                Text(String(localized: "Only this message's image source will be requested. Provider keys are not sent. Cached images are available offline.")).font(.caption).foregroundStyle(.secondary)
            }
        }.accessibilityIdentifier("messageRemoteImage")
        .task(id: cached?.id) {
            if let cached { cacheAvailable = (try? await presentation.attachments.read(cached, conversationID: presentation.sessionID)) != nil }
        }
        .onDisappear { task?.cancel() }
    }
    private func load() {
        guard !loading else { return }
        loading = true; failure = nil
        task = Task { @MainActor in
            defer { loading = false }
            do { _ = try await presentation.cacheImage(url, messageID: message.id); cacheAvailable = true }
            catch { if !Task.isCancelled { failure = error.localizedDescription } }
        }
    }
}

/// Save the original image bytes, rather than recompressing a rendered preview.
struct SaveScreenshotButton: View {
    let data: Data
    @State private var saving = false
    @State private var showResult = false
    @State private var result = ""
    var body: some View {
        Button {
            guard !saving else { return }
            saving = true
            let original = data
            Task { @MainActor in
                defer { saving = false }
                var status = PHPhotoLibrary.authorizationStatus(for: .addOnly)
                if status == .notDetermined {
                    guard let token = PermissionRequestGate.shared.acquire() else {
                        result = String(localized: "Another permission request is in progress. Try again shortly."); showResult = true; return
                    }
                    status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
                    PermissionRequestGate.shared.release(token)
                }
                if status == .authorized || status == .limited {
                    do {
                        try await PHPhotoLibrary.shared().performChanges {
                            let options = PHAssetResourceCreationOptions()
                            options.originalFilename = original.starts(with: [0xff, 0xd8, 0xff]) ? String(localized: "PhoneAgent-Screenshot.jpg") : String(localized: "PhoneAgent-Screenshot.png")
                            PHAssetCreationRequest.forAsset().addResource(with: .photo, data: original, options: options)
                        }
                        result = String(localized: "Saved to Photos")
                    } catch { result = String(localized: "Could not save. Try again.") }
                } else { result = String(localized: "Could not save. Allow the app to add photos in system Settings.") }
                showResult = true
            }
        } label: {
            if saving { ProgressView().controlSize(.small) }
            else { Image(systemName: "square.and.arrow.down") }
        }
        .buttonStyle(.borderless)
        .disabled(saving)
        .accessibilityLabel(String(localized: "Save to Photos"))
        .accessibilityIdentifier("saveScreenshotToPhotos")
        .alert(String(localized: "Save screenshot"), isPresented: $showResult) { Button(String(localized: "OK"), role: .cancel) {} } message: { Text(result) }
    }
}
