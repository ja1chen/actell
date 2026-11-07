import Foundation
import ImageIO
import UniformTypeIdentifiers
import CryptoKit
import AgentKit
import Darwin

struct StoredAttachment: Codable, Equatable, Identifiable, Sendable {
    enum Kind: String, Codable, Sendable { case image, text }
    var id: UUID
    var conversationID: UUID
    var name: String
    var kind: Kind
    var mimeType: String
    var byteCount: Int
    var digest: String
    var width: Int?
    var height: Int?
    var sourceURL: URL?

    static func sessionImage(_ image: SessionImageReference, conversationID: UUID) -> StoredAttachment {
        let digest = image.digest, prefix = String(digest.prefix(32))
        let uuidText = [String(prefix.prefix(8)), String(prefix.dropFirst(8).prefix(4)), String(prefix.dropFirst(12).prefix(4)), String(prefix.dropFirst(16).prefix(4)), String(prefix.suffix(12))].joined(separator: "-")
        return StoredAttachment(id: UUID(uuidString: uuidText)!, conversationID: conversationID,
            name: image.mimeType == "image/jpeg" ? String(localized: "Device screenshot.jpg") : String(localized: "Device screenshot.png"),
            kind: .image, mimeType: image.mimeType, byteCount: image.byteCount, digest: digest,
            width: image.width, height: image.height)
    }
}

/// One protected resource store for drafts, messages, screenshots and remote images.
/// Original bytes are durable; thumbnails are derived and may be regenerated.
actor AttachmentStore {
    static let imageLimit = 20 * 1_024 * 1_024
    static let textLimit = 256 * 1_024
    static let capacity = 1_024 * 1_024 * 1_024
    static let supportedTextExtensions = Set(["txt", "md", "markdown", "json", "csv"])
    private let root: URL
    private let legacyRoot: URL
    private let capacity: Int
    init(directory: URL? = nil, capacity: Int = AttachmentStore.capacity) {
        self.root = directory ?? SessionStorageLayout.defaultRoot
        self.legacyRoot = directory ?? SessionStorageLayout.defaultLegacyRoot
        self.capacity = capacity
    }
    private func create(_ folder: URL) throws {
        try SessionStorageLayout.createProtectedDirectory(folder)
    }
    func importFile(_ url: URL, conversationID: UUID) throws -> StoredAttachment {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let info = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard info.isRegularFile == true, info.isSymbolicLink != true else { throw AppError.invalid(String(localized: "Select a regular file. Folders and symbolic links are not supported.")) }
        let text = Self.supportedTextExtensions.contains(url.pathExtension.lowercased())
        guard let size = info.fileSize, size <= (text ? Self.textLimit : Self.imageLimit) else {
            throw AppError.invalid(String(localized: "File too large. Images can be up to 20 MiB and UTF-8 text up to 256 KiB."))
        }
        return try store(Data(contentsOf: url, options: .mappedIfSafe), name: url.lastPathComponent, conversationID: conversationID)
    }
    func store(_ data: Data, name: String, conversationID: UUID, sourceURL: URL? = nil) throws -> StoredAttachment {
        guard !data.isEmpty, data.count <= Self.imageLimit else { throw AppError.invalid(String(localized: "The attachment is empty or larger than 20 MiB")) }
        let kind: StoredAttachment.Kind, mime: String, width: Int?, height: Int?
        let source = CGImageSourceCreateWithData(data as CFData, nil)
        if let source, let type = CGImageSourceGetType(source) as String?,
           [UTType.png.identifier, UTType.jpeg.identifier, UTType.heic.identifier, UTType.heif.identifier, UTType.webP.identifier].contains(type) {
            guard CGImageSourceGetCount(source) == 1,
                  let dimensions = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                  let w = dimensions[kCGImagePropertyPixelWidth] as? Int, let h = dimensions[kCGImagePropertyPixelHeight] as? Int,
                  w > 0, h > 0, w <= 20_000, h <= 20_000, w * h <= 50_000_000 else {
                throw AppError.invalid(String(localized: "The image is too large or has multiple frames. Select a single image."))
            }
            kind = .image; mime = UTType(type)?.preferredMIMEType ?? "image/png"; width = w; height = h
        } else {
            guard Self.supportedTextExtensions.contains((name as NSString).pathExtension.lowercased()),
                  data.count <= Self.textLimit, let text = String(data: data, encoding: .utf8), !text.contains("\0") else {
                throw AppError.invalid(String(localized: "Supports single PNG/JPEG/HEIC/WebP images and UTF-8 TXT/Markdown/JSON/CSV files. PDF, Office, archives, and executables are not supported."))
            }
            kind = .text; mime = "text/plain"; width = nil; height = nil
        }
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let prefix = String(digest.prefix(32))
        let uuidText = [String(prefix.prefix(8)), String(prefix.dropFirst(8).prefix(4)), String(prefix.dropFirst(12).prefix(4)), String(prefix.dropFirst(16).prefix(4)), String(prefix.suffix(12))].joined(separator: "-")
        let id = UUID(uuidString: uuidText)!
        let attachment = StoredAttachment(id: id, conversationID: conversationID,
            name: String((name as NSString).lastPathComponent.prefix(160)), kind: kind, mimeType: mime,
            byteCount: data.count, digest: digest, width: width, height: height, sourceURL: sourceURL)
        try ensureSession(conversationID)
        let folder = try directory(attachment)
        try requireOwnedDirectory(attachment)
        if FileManager.default.fileExists(atPath: folder.appendingPathComponent("original").path) {
            if (try? read(attachment, conversationID: conversationID)) != nil {
                return attachment // Content deduplication is scoped to this conversation.
            }
            // Repair a damaged copy only after validating the replacement bytes.
            try FileManager.default.removeItem(at: folder)
        }
        guard try usage() + data.count <= capacity else {
            throw AppError.unavailable(String(localized: "Attachment storage is full. Original images are not deleted automatically. Clean up unused attachments or delete unwanted conversations in Settings."))
        }
        try create(root); try create(folder)
        do {
            try data.write(to: folder.appendingPathComponent("original"), options: [.atomic, .completeFileProtection])
            try JSONEncoder().encode(attachment).write(to: folder.appendingPathComponent("metadata.json"), options: [.atomic, .completeFileProtection])
        } catch {
            try? FileManager.default.removeItem(at: folder)
            throw AppError.unavailable(String(localized: "The attachment could not be saved or added to the message. Check available storage."))
        }
        return attachment
    }
    private func ensureSession(_ id: UUID) throws {
        try create(root)
        let layout = SessionStorageLayout(root: root)
        if !layout.isInstalled {
            guard !FileManager.default.fileExists(atPath: legacyRoot.appendingPathComponent("conversations-v1.json").path),
                  try !SessionStorageMigration.hasLegacyResources(in: legacyRoot) else { throw SessionStorageLayout.Failure.migrationRequired }
            try ConversationJournal.install([], in: root)
        }
        _ = try layout.ensureDirectory(for: id, createdAt: Date())
    }
    private func directory(_ attachment: StoredAttachment) throws -> URL {
        try SessionStorageLayout(root: root).directory(for: attachment.conversationID)
            .resolvingSymlinksInPath()
            .appendingPathComponent("attachments", isDirectory: true).appendingPathComponent(attachment.id.uuidString, isDirectory: true)
    }
    private func requireOwnedDirectory(_ attachment: StoredAttachment) throws {
        // Resolve the existing session first. Resolving a missing UUID directory
        // can normalize the sandbox prefix differently on a physical device.
        // All appended components are fixed names or UUIDs; reject links only
        // below this trusted base, without depending on nonexistent realpaths.
        let folder = try directory(attachment)
        for candidate in [folder.deletingLastPathComponent(), folder] {
            var info = stat()
            if lstat(candidate.path, &info) != 0 {
                if errno == ENOENT { continue }
                throw AppError.invalid(String(localized: "The attachment folder contains an invalid path reference"))
            }
            guard info.st_mode & S_IFMT == S_IFDIR else {
                throw AppError.invalid(String(localized: "The attachment folder contains an invalid path reference"))
            }
        }
    }
    func read(_ attachment: StoredAttachment, conversationID: UUID) throws -> Data {
        guard attachment.conversationID == conversationID else { throw AppError.invalid(String(localized: "The attachment does not belong to this conversation")) }
        try requireOwnedDirectory(attachment)
        let folder = try directory(attachment)
        var file = folder.appendingPathComponent("original")
        if !FileManager.default.fileExists(atPath: file.path) {
            // AgentKit owns the durable image; previews do not require a second copy.
            guard attachment.digest.count == 64, attachment.digest.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
                throw AppError.invalid(String(localized: "Local attachment verification failed. Select it again or retry the existing image URL."))
            }
            let images = folder.deletingLastPathComponent()
            try SessionStorageLayout.requireDirectory(images)
            file = images.appendingPathComponent(attachment.digest)
        }
        guard let info = try? file.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey]),
              info.isRegularFile == true, info.isSymbolicLink != true,
              let size = info.fileSize, size <= Self.imageLimit else { throw AppError.unavailable(String(localized: "The local attachment is unavailable. Retry downloading an existing remote image or select the file again.")) }
        let data = try Data(contentsOf: file, options: .mappedIfSafe)
        guard data.count == attachment.byteCount,
              SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined() == attachment.digest else {
            throw AppError.unavailable(String(localized: "Local attachment verification failed. Select it again or retry the existing image URL."))
        }
        return data
    }
    func preview(_ attachment: StoredAttachment, conversationID: UUID, fullSize: Bool = false) throws -> Data {
        let original = try read(attachment, conversationID: conversationID)
        guard attachment.kind == .image else { return original }
        if fullSize { return original }
        return try Self.render(original, maxPixel: 512, type: UTType.jpeg.identifier)
    }
    func inferenceImage(_ attachment: StoredAttachment, conversationID: UUID) throws -> Data {
        guard attachment.kind == .image else { throw AppError.invalid(String(localized: "The attachment is not an image")) }
        return try Self.render(read(attachment, conversationID: conversationID), maxPixel: 2_048, type: UTType.png.identifier)
    }
    private static func render(_ data: Data, maxPixel: Int, type: String) throws -> Data {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: maxPixel] as CFDictionary) else {
            throw AppError.invalid(String(localized: "The image could not be decoded"))
        }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, type as CFString, 1, nil) else { throw AppError.invalid(String(localized: "Could not create an image preview")) }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw AppError.invalid(String(localized: "Could not save the image preview")) }
        return output as Data
    }
    func usage() throws -> Int {
        var bytes = 0
        for folder in try SessionStorageLayout(root: root).directories().values {
            let attachments = folder.appendingPathComponent("attachments")
            guard FileManager.default.fileExists(atPath: attachments.path) else { continue }
            try SessionStorageLayout.requireDirectory(attachments)
            let files = FileManager.default.enumerator(at: attachments, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey])
            while let url = files?.nextObject() as? URL {
                let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey])
                if values.isSymbolicLink == true { files?.skipDescendants(); continue }
                if values.isRegularFile == true { bytes += values.fileSize ?? 0 }
            }
        }
        return bytes
    }
    /// Called only after explicit confirmation. Referenced message/draft originals survive.
    func removeUnreferenced(keeping references: [StoredAttachment]) throws -> Int {
        let keep = Set(references.map { $0.conversationID.uuidString + "/" + $0.id.uuidString })
        var removed = 0
        for (id, folder) in try SessionStorageLayout(root: root).directories() {
            let attachments = folder.appendingPathComponent("attachments")
            guard FileManager.default.fileExists(atPath: attachments.path) else { continue }
            try SessionStorageLayout.requireDirectory(attachments)
            for asset in try FileManager.default.contentsOfDirectory(at: attachments, includingPropertiesForKeys: [.isSymbolicLinkKey]) {
                guard UUID(uuidString: asset.lastPathComponent) != nil,
                      !keep.contains(id.uuidString + "/" + asset.lastPathComponent),
                      try asset.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else { continue }
                try FileManager.default.removeItem(at: asset); removed += 1
            }
        }
        return removed
    }

}

/// The caller must bind this URL to an existing message before and after await.
/// This client has no provider credentials, cookies, redirects or automatic retry.
final class MessageImageDownloader: @unchecked Sendable {
    private let session: URLSession
    private let redirectGuard = NoRedirectDelegate()
    init(configuration: URLSessionConfiguration = .ephemeral) {
        configuration.httpCookieStorage = nil; configuration.urlCache = nil
        configuration.urlCredentialStorage = nil
        configuration.timeoutIntervalForRequest = 30; configuration.timeoutIntervalForResource = 60
        session = URLSession(configuration: configuration, delegate: redirectGuard, delegateQueue: nil)
    }
    deinit { session.invalidateAndCancel() }
    func download(_ url: URL) async throws -> Data {
        guard url.scheme == "https", url.host?.isEmpty == false, url.user == nil, url.password == nil else {
            throw AppError.invalid(String(localized: "Only HTTPS image links without embedded credentials are supported"))
        }
        let (bytes, response) = try await session.bytes(for: URLRequest(url: url))
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              http.mimeType?.hasPrefix("image/") == true else {
            throw AppError.unavailable(String(localized: "The image link is unavailable or did not return an image. Redirects were not followed. You can retry the original link."))
        }
        guard response.expectedContentLength <= AttachmentStore.imageLimit else { throw AppError.invalid(String(localized: "The remote image is larger than 20 MiB")) }
        var data = Data()
        for try await byte in bytes {
            try Task.checkCancellation()
            guard data.count < AttachmentStore.imageLimit else { throw AppError.invalid(String(localized: "The remote image is larger than 20 MiB")) }
            data.append(byte)
        }
        return data
    }
}

enum MessageImageSources {
    // The initial migration supports standard Markdown image links, never arbitrary
    // URLs found in surrounding text or model-generated filesystem paths.
    static func urls(in text: String) -> [URL] {
        guard let pattern = try? NSRegularExpression(pattern: #"!\[[^\]]*\]\(\s*(https://[^\s\)]+)(?:\s+"[^"]*")?\s*\)"#) else { return [] }
        let source = text as NSString
        return pattern.matches(in: text, range: NSRange(location: 0, length: source.length)).compactMap {
            URL(string: source.substring(with: $0.range(at: 1)))
        }
    }
}
