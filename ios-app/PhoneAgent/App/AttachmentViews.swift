import SwiftUI
import UIKit
import Photos

/// Largest size within the bounds that keeps this size's aspect ratio.
extension CGSize {
    func fitted(maxWidth: CGFloat, maxHeight: CGFloat) -> CGSize {
        guard width > 0, height > 0 else { return self }
        let scale = min(maxWidth / width, maxHeight / height)
        return CGSize(width: (width * scale).rounded(.down), height: (height * scale).rounded(.down))
    }
}

struct AttachmentThumbnail: View {
    let attachment: StoredAttachment
    let store: AttachmentStore
    let conversationID: UUID
    var showsName = true
    var contentAlignment: HorizontalAlignment = .leading
    @State private var preview: Data?
    @State private var failure: String?
    @State private var showingOriginal = false
    var body: some View {
        Button { showingOriginal = true } label: {
            VStack(alignment: contentAlignment, spacing: 5) {
                imageArea
                if showsName { Text(attachment.name).font(.caption).lineLimit(1) }
                if let failure { Text(failure).font(.caption).foregroundStyle(.orange) }
            }
            // Button styles center their label; the thumbnail aligns itself
            // to the edge its container asks for. The content shape keeps the
            // whole aligned frame tappable, including the area beside the
            // image, so automated and centered taps still open the viewer.
            .frame(maxWidth: .infinity, alignment: Alignment(horizontal: contentAlignment, vertical: .center))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).accessibilityLabel(String(localized: "Preview attachment: \(attachment.name)"))
        .accessibilityIdentifier("attachment-" + attachment.id.uuidString)
        .task(id: attachment.id) {
            do { preview = try await store.preview(attachment, conversationID: conversationID); failure = nil }
            catch { failure = String(localized: "The local file is temporarily unavailable") }
        }
        .sheet(isPresented: $showingOriginal) { AttachmentPreview(attachment: attachment, store: store, conversationID: conversationID) }
    }

    // The image is placed at an explicit fitted size (scaledToFit centers
    // within a flexible proposal), and the loading state reserves the same
    // area from the stored metadata, so expansion never shows a placeholder
    // image or moves the layout.
    @ViewBuilder private var imageArea: some View {
        if let preview, attachment.kind == .image, let image = UIImage(data: preview) {
            let size = displaySize(for: image.size)
            Image(uiImage: image)
                .resizable()
                .frame(width: size.width, height: size.height)
                .clipShape(RoundedRectangle(cornerRadius: 12))
        } else if attachment.kind == .image, let size = reservedSize {
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.primary.opacity(0.04))
                .frame(width: size.width, height: size.height)
        } else {
            Image(systemName: attachment.kind == .image ? "photo" : "doc.text").font(.title2).frame(minHeight: 35)
        }
    }

    private var reservedSize: CGSize? {
        guard let width = attachment.width, let height = attachment.height, width > 0, height > 0 else { return nil }
        return CGSize(width: CGFloat(width), height: CGFloat(height)).fitted(maxWidth: 320, maxHeight: 220)
    }

    private func displaySize(for imageSize: CGSize) -> CGSize {
        reservedSize ?? imageSize.fitted(maxWidth: 320, maxHeight: 220)
    }
}

private struct AttachmentPreview: View {
    let attachment: StoredAttachment
    let store: AttachmentStore
    let conversationID: UUID
    @Environment(\.dismiss) private var dismiss
    @State private var data: Data?
    @State private var failure: String?
    var body: some View {
        NavigationStack {
            Group {
                if let data, attachment.kind == .image, let image = UIImage(data: data) {
                    ZoomableImageView(image: image)
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

/// Scroll-view-backed image viewer: opens centered at a fit-to-screen scale,
/// and supports pinch zooming that follows the fingers past the limits and
/// springs back on release, finger-midpoint anchoring, panning while zoomed,
/// and a double-tap toggle between the fitted and an enlarged scale. All of
/// this is native UIScrollView behavior; this wrapper only keeps the image
/// centered in dimensions it does not overflow.
private struct ZoomableImageView: UIViewRepresentable {
    let image: UIImage

    func makeUIView(context: Context) -> UIScrollView {
        let scrollView = ZoomableScrollView()
        scrollView.delegate = context.coordinator
        scrollView.imageView.image = image
        scrollView.imageView.isAccessibilityElement = true
        scrollView.imageView.accessibilityLabel = String(localized: "Local original image")
        let doubleTap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.toggleZoom(_:)))
        doubleTap.numberOfTapsRequired = 2
        scrollView.addGestureRecognizer(doubleTap)
        return scrollView
    }

    func updateUIView(_ scrollView: UIScrollView, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, UIScrollViewDelegate {
        func viewForZooming(in scrollView: UIScrollView) -> UIView? {
            (scrollView as? ZoomableScrollView)?.imageView
        }

        func scrollViewWillBeginZooming(_ scrollView: UIScrollView, with view: UIView?) {
            (scrollView as? ZoomableScrollView)?.isZoomGestureActive = true
        }

        func scrollViewDidEndZooming(_ scrollView: UIScrollView, with view: UIView?, atScale scale: CGFloat) {
            (scrollView as? ZoomableScrollView)?.isZoomGestureActive = false
        }

        func scrollViewDidZoom(_ scrollView: UIScrollView) {
            (scrollView as? ZoomableScrollView)?.centerVisibleImage()
        }

        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            (scrollView as? ZoomableScrollView)?.centerVisibleImage()
        }

        @objc func toggleZoom(_ sender: UITapGestureRecognizer) {
            guard let scrollView = sender.view as? ZoomableScrollView else { return }
            let enlarged = scrollView.minimumZoomScale * 3
            if scrollView.zoomScale >= enlarged {
                scrollView.setZoomScale(scrollView.minimumZoomScale, animated: true)
            } else {
                // The rect to enlarge, in image coordinates, is the visible
                // area rescaled to the target zoom, centered on the tap.
                let factor = scrollView.zoomScale / enlarged
                let size = CGSize(width: scrollView.bounds.width * factor, height: scrollView.bounds.height * factor)
                let point = sender.location(in: scrollView.imageView)
                let rect = CGRect(origin: .zero, size: size)
                    .offsetBy(dx: point.x - size.width / 2, dy: point.y - size.height / 2)
                scrollView.zoom(to: rect, animated: true)
            }
        }
    }
}

private final class ZoomableScrollView: UIScrollView {
    let imageView = UIImageView()
    var isZoomGestureActive = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        imageView.contentMode = .scaleAspectFit
        addSubview(imageView)
        minimumZoomScale = 1
        maximumZoomScale = 8
        bouncesZoom = true
    }

    required init?(coder: NSCoder) { nil }

    override func layoutSubviews() {
        super.layoutSubviews()
        // Establish the base frame only when fully at rest: touching the
        // zooming view mid-gesture breaks the scroll view's pinch anchor and
        // its bounce past the zoom limits.
        guard !isZoomGestureActive, zoomScale <= minimumZoomScale + .leastNormalMagnitude,
            bounds.width > 0, bounds.height > 0, let image = imageView.image, image.size.width > 0 else { return }
        if imageView.frame.size != bounds.size {
            imageView.frame = CGRect(origin: .zero, size: bounds.size)
            contentSize = bounds.size
        }
        let fitScale = min(bounds.width / image.size.width, bounds.height / image.size.height)
        maximumZoomScale = max(8, 1 / fitScale)
    }

    /// Centers the image in any dimension where it fits within the visible
    /// area, by offset alone; dimensions it overflows keep native panning and
    /// the pinch anchor. The image is centered inside its frame by the aspect
    /// fit, so centering the frame centers the image.
    func centerVisibleImage() {
        let visible = bounds.size
        guard visible.width > 0, visible.height > 0, let image = imageView.image, image.size.width > 0 else { return }
        let fitted = image.size.fitted(maxWidth: visible.width, maxHeight: visible.height)
        let content = CGSize(width: visible.width * zoomScale, height: visible.height * zoomScale)
        var offset = contentOffset
        if fitted.width * zoomScale <= visible.width { offset.x = (content.width - visible.width) / 2 }
        if fitted.height * zoomScale <= visible.height { offset.y = (content.height - visible.height) / 2 }
        if offset != contentOffset { contentOffset = offset }
    }
}

struct MessageAttachmentsView: View {
    let message: ChatMessage
    @ObservedObject var presentation: AgentPresentationAdapter
    var contentAlignment: HorizontalAlignment = .leading
    var showsName = true
    var body: some View {
        let attachments = (message.attachments ?? []).filter { $0.sourceURL == nil }
        let imageURLs = Array(NSOrderedSet(array: MessageImageSources.urls(in: message.text))) as? [URL] ?? []
        if !attachments.isEmpty || !imageURLs.isEmpty {
            VStack(alignment: contentAlignment, spacing: 10) {
                ForEach(attachments) { attachment in
                    AttachmentThumbnail(attachment: attachment, store: presentation.attachments, conversationID: presentation.sessionID,
                        showsName: showsName, contentAlignment: contentAlignment)
                }
                ForEach(imageURLs, id: \.self) { url in
                    RemoteMessageImage(url: url, message: message, presentation: presentation)
                }
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
