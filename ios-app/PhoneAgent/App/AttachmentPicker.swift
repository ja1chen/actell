import SwiftUI
import PhotosUI
import UniformTypeIdentifiers

struct AttachmentPicker: View {
    @ObservedObject var presentation: AgentPresentationAdapter
    @Binding var busy: Bool
    @Binding var failure: String?
    @Binding var cancellation: Int
    @State private var photos = false
    @State private var files = false
    @State private var selection: [PhotosPickerItem] = []
    @State private var importing: Task<Void, Never>?
    var body: some View {
        HStack(spacing: 0) {
            Menu {
                Button(String(localized: "Add photo"), systemImage: "photo") { photos = true }
                Button(String(localized: "Add file"), systemImage: "doc") { files = true }
            } label: {
                Image(systemName: "plus").font(.title3).frame(width: 44, height: 44).contentShape(Rectangle())
            }
            .accessibilityLabel(String(localized: "Add attachment")).accessibilityIdentifier("addAttachment")
            .buttonStyle(.plain)
            .contentShape(Rectangle())
            .disabled(busy || presentation.running || presentation.stopping)
        }
        .photosPicker(isPresented: $photos, selection: $selection, matching: .images)
        .fileImporter(isPresented: $files, allowedContentTypes: [.image, .plainText, .json, .commaSeparatedText, UTType(filenameExtension: "md") ?? .plainText], allowsMultipleSelection: true) { result in
            guard case .success(let urls) = result, !urls.isEmpty else {
                if case .failure(let error) = result { failure = error.localizedDescription }
                return
            }
            start {
                for url in urls {
                    try Task.checkCancellation()
                    try await presentation.importAttachment(file: url)
                }
            }
        }
        .onChange(of: selection) { _, items in
            guard !items.isEmpty else { return }
            start {
                defer { selection = [] }
                for item in items {
                    try Task.checkCancellation()
                    guard let bytes = try await item.loadTransferable(type: Data.self) else { throw AppError.unavailable(String(localized: "The photo could not be loaded. Select it again.")) }
                    try Task.checkCancellation()
                    try await presentation.importAttachment(data: bytes, name: String(localized: "Photo.") + (item.supportedContentTypes.first?.preferredFilenameExtension ?? "png"))
                }
            }
        }
        .onDisappear { importing?.cancel() }
        .onChange(of: cancellation) { _, _ in importing?.cancel() }
    }
    private func start(_ action: @escaping @MainActor () async throws -> Void) {
        guard !busy else { return }
        busy = true; failure = nil
        importing = Task { @MainActor in
            defer { busy = false }
            do { try await action() }
            catch { if !Task.isCancelled { failure = error.localizedDescription } }
        }
    }
}
