import Foundation
import Combine

struct ProviderProfile: Identifiable, Codable, Equatable, Sendable {
    var id: UUID
    var name: String
    var settings: ProviderSettings
    var models: [String]
    var protocolKind: ProviderKind?
    var inferenceKind: InferenceAPI?
    var contextKind: ProviderContextPolicy?
    var catalog: ModelCatalog?
    var modelParameters: [String: ModelParameters]?
    // Non-secret hash of issued-client-ID + verified issuer/subject. Tokens live only in Keychain.
    var chatGPTAccountReference: String?
    // Reference only. Credentials are never encoded into UserDefaults/history.
    var keyAccount: String

    init(id: UUID = UUID(), name: String = "", settings: ProviderSettings = ProviderSettings(), models: [String] = [], keyAccount: String? = nil) {
        self.id = id; self.name = name; self.settings = settings; self.models = models
        self.keyAccount = keyAccount ?? "provider-profile:\(id):\(settings.baseURL)"
    }
    var providerKind: ProviderKind { protocolKind ?? .openAI }
    var inferenceAPI: InferenceAPI { providerKind == .chatGPTSubscription ? .responses : inferenceKind ?? .chatCompletions }
    var contextPolicy: ProviderContextPolicy { contextKind ?? .stateless }
    func catalogEndpoint() throws -> String { providerKind.rawValue + ":" + (try providerKind.baseURL(settings.baseURL)).absoluteString + (providerKind == .chatGPTSubscription ? ":" + (chatGPTAccountReference ?? "disconnected") : "") }
    var currentCatalog: ModelCatalog? { catalog?.endpoint == (try? catalogEndpoint()) ? catalog : nil }
    var availableModels: [String] {
        Array(NSOrderedSet(array: ([settings.model] + models + (currentCatalog?.models.map(\.id) ?? [])).filter { !$0.isEmpty })) as? [String] ?? []
    }
    var previewModels: [String] {
        let listed = Array(NSOrderedSet(array: (models + (currentCatalog?.models.map(\.id) ?? [])).filter { !$0.isEmpty })) as? [String] ?? []
        var preview = Array(listed.prefix(5))
        if !settings.model.isEmpty, !preview.contains(settings.model) { preview.append(settings.model) }
        return preview
    }
    mutating func selectDefaultModelIfNeeded() {
        guard settings.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        settings.model = availableModels.lazy.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty } ?? ""
    }
    func metadata(for model: String) -> DiscoveredModel? {
        let discovered = currentCatalog?.models.first { $0.id == model }
        guard [.openAI, .chatGPTSubscription].contains(providerKind),
              (try? providerKind.baseURL(settings.baseURL).absoluteString) == ChatGPTSubscriptionPolicy.resource.absoluteString,
              inferenceAPI == .responses else { return discovered }
        // Exact documented model only, official endpoint only. Never infer from a prefix.
        // https://developers.openai.com/api/docs/guides/latest-model (verified 2026-10-10)
        guard model == "gpt-6.1-sol", discovered?.reasoningEfforts == nil else { return discovered }
        var result = discovered ?? DiscoveredModel(id: model, name: model)
        result.reasoningEfforts = ["low", "medium", "high", "xhigh", "max"]
        result.defaultReasoningEffort = "medium"
        result.detailNotice = String(localized: "Reasoning levels come from OpenAI's official GPT-6.1 Sol documentation (2026-10-10). They do not confirm model access for this account.")
        return result
    }
    func parameters(for model: String) -> ModelParameters { modelParameters?[model] ?? ModelParameters() }
    func requireInference(model: String) throws {
        if providerKind == .chatGPTSubscription, chatGPTAccountReference == nil { throw ChatGPTAuthError.disconnected }
        if providerKind == .chatGPTSubscription, currentCatalog?.models.contains(where: { $0.id == model }) != true { throw AppError.unavailable(String(localized: "Refresh the model list for this ChatGPT account and select an available model")) }
        guard inferenceAPI == .chatCompletions || providerKind.supportsResponses else { throw AppError.invalid(String(localized: "This protocol supports Chat Completions inference only")) }
        guard inferenceAPI == .responses || contextPolicy == .stateless else { throw AppError.invalid(String(localized: "Server response chains require Responses")) }
        guard contextPolicy == .stateless || providerKind.supportsResponseChain else { throw AppError.invalid(String(localized: "This provider does not support server response chains. Select local replay.")) }
        guard providerKind.supportsInference else { throw AppError.unavailable(providerKind.inferenceNotice) }
        guard !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw AppError.invalid(String(localized: "Select or enter a model ID first")) }
        if let metadata = metadata(for: model), metadata.vision == .unsupported || metadata.tools == .unsupported || metadata.generation == .unsupported {
            throw AppError.unavailable(String(localized: "This provider reports that the model does not support images, tools, or text generation. Select a compatible model for screen tasks."))
        }
    }
}

@MainActor final class ProviderStore: ObservableObject {
    struct Selection: Codable, Equatable {
        var providerID: UUID
        var model: String
    }
    private struct Archive: Codable {
        var version = 1
        var profiles: [ProviderProfile]
        var removed: [ProviderProfile]
        var lastSelection: Selection?
    }
    @Published private(set) var profiles: [ProviderProfile] = []
    @Published private(set) var removed: [ProviderProfile] = []
    @Published private(set) var lastSelection: Selection?
    @Published private(set) var warning: String?
    private let defaults: UserDefaults?
    private var writable = true
    static let storageKey = "providerProfiles-v1"
    init(defaults: UserDefaults? = .standard) {
        self.defaults = defaults
        do {
            if let data = defaults?.data(forKey: Self.storageKey) {
                let saved = try JSONDecoder().decode(Archive.self, from: data)
                guard saved.version == 1 else { throw AppError.invalid(String(localized: "Unknown provider configuration version")) }
                profiles = saved.profiles; removed = saved.removed
                lastSelection = saved.lastSelection
                for index in profiles.indices { profiles[index].selectDefaultModelIfNeeded() }
            } else if let data = defaults?.data(forKey: "providerSettings") {
                let legacy = try JSONDecoder().decode(ProviderSettings.self, from: data)
                let host = URL(string: legacy.baseURL)?.host ?? String(localized: "Previous provider")
                let profile = ProviderProfile(name: host, settings: legacy, keyAccount: legacy.keyAccount)
                try persist(profiles: [profile], removed: [])
            }
        } catch { writable = false; warning = String(localized: "Provider settings could not be read. The original data was kept and cannot be edited for now.") }
    }
    func profile(_ id: UUID?) -> ProviderProfile? {
        guard let id else { return profiles.first }
        return profiles.first { $0.id == id }
    }
    var defaultSelection: (profile: ProviderProfile, model: String)? {
        if let lastSelection, let profile = profile(lastSelection.providerID) {
            return (profile, lastSelection.model.isEmpty ? profile.settings.model : lastSelection.model)
        }
        return profiles.first.map { ($0, $0.settings.model) }
    }
    func rememberSelection(providerID: UUID, model: String) throws {
        guard profile(providerID) != nil else { return }
        try persist(profiles: profiles, removed: removed, selection: Selection(providerID: providerID, model: model))
    }
    func prepared(_ draft: ProviderProfile) throws -> ProviderProfile {
        guard writable else { throw AppError.unavailable(warning ?? String(localized: "Settings are read-only")) }
        var value = draft
        if value.providerKind == .chatGPTSubscription {
            guard value.contextPolicy == .stateless else { throw AppError.invalid(String(localized: "Subscription providers do not support server response chains")) }
            value.inferenceKind = .responses
        }
        value.name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        value.settings.baseURL = draft.settings.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        value.settings.model = draft.settings.model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.inferenceAPI == .chatCompletions || value.providerKind.supportsResponses else { throw AppError.invalid(String(localized: "This protocol does not support Responses yet")) }
        guard value.inferenceAPI == .responses || value.contextPolicy == .stateless else { throw AppError.invalid(String(localized: "Response chains require Responses")) }
        if value.inferenceAPI == .responses, value.modelParameters?.values.contains(where: { !($0.values["seed"] ?? "").isEmpty }) == true { throw AppError.invalid(String(localized: "Responses does not support seed. Clear this parameter.")) }
        guard value.contextPolicy == .stateless || value.providerKind.supportsResponseChain else { throw AppError.invalid(String(localized: "This provider does not support server response chains")) }
        let url = try value.providerKind.baseURL(value.settings.baseURL)
        if value.name.isEmpty { value.name = url.host ?? String(localized: "Provider") }
        value.models = draft.models.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        if let previous = profiles.first(where: { $0.id == draft.id }) {
            // Editing a label/model keeps the old Keychain reference. Changing
            // destination never forwards that destination's credential.
            let sameEndpoint = try previous.catalogEndpoint() == value.catalogEndpoint()
            value.keyAccount = sameEndpoint ? previous.keyAccount : value.newKeyAccount
            if !sameEndpoint { value.modelParameters = nil }
        } else { value.keyAccount = value.newKeyAccount }
        if value.currentCatalog == nil { value.catalog = nil }
        value.selectDefaultModelIfNeeded()
        for (model, parameters) in value.modelParameters ?? [:] {
            _ = try parameters.requestFields(providerKind: value.providerKind, model: value.metadata(for: model))
        }
        return value
    }
    func save(_ draft: ProviderProfile) throws {
        let value = try prepared(draft)
        var next = profiles
        if let index = next.firstIndex(where: { $0.id == value.id }) { next[index] = value }
        else { next.append(value) }
        try persist(profiles: next, removed: removed, selection: lastSelection)
    }
    func remove(_ id: UUID) throws {
        guard let profile = profiles.first(where: { $0.id == id }) else { return }
        try persist(profiles: profiles.filter { $0.id != id }, removed: removed.filter { $0.id != id } + [profile], selection: lastSelection)
    }
    func restore(_ id: UUID) throws {
        guard var profile = removed.first(where: { $0.id == id }) else { return }
        profile.selectDefaultModelIfNeeded()
        try persist(profiles: profiles + [profile], removed: removed.filter { $0.id != id }, selection: lastSelection)
    }
    private func persist(profiles: [ProviderProfile], removed: [ProviderProfile], selection: Selection? = nil) throws {
        guard writable else { throw AppError.unavailable(warning ?? String(localized: "Settings are read-only")) }
        let data = try JSONEncoder().encode(Archive(profiles: profiles, removed: removed, lastSelection: selection))
        defaults?.set(data, forKey: Self.storageKey)
        self.profiles = profiles; self.removed = removed
        self.lastSelection = selection
    }
}

private extension ProviderProfile {
    var newKeyAccount: String {
        let discriminator = providerKind == .openAI ? "" : providerKind.rawValue + ":"
        return "provider-profile:\(id):\(discriminator)\(settings.baseURL)"
    }
}
