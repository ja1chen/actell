import Foundation
import Combine

/// Metadata only: never calls a generation endpoint or follows a redirect.
final class ModelDiscoveryClient: @unchecked Sendable {
    private let session: URLSession
    private let redirectGuard = NoRedirectDelegate()
    init(configuration: URLSessionConfiguration = .ephemeral) {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--ui-test-model-catalog") {
            configuration.protocolClasses = [ModelCatalogUIFixture.self]
        }
        #endif
        configuration.urlCache = nil; configuration.httpCookieStorage = nil
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 60
        session = URLSession(configuration: configuration, delegate: redirectGuard, delegateQueue: nil)
    }
    deinit { session.invalidateAndCancel() }
    static func failure(_ error: Error) -> String {
        if error is CancellationError || (error as? URLError)?.code == .cancelled { return String(localized: "Model discovery cancelled. Cached or manual model IDs remain available.") }
        if (error as? URLError)?.code == .timedOut { return String(localized: "Model discovery timed out. Retry or enter a model ID manually.") }
        return (error as? AppError)?.localizedDescription ?? String(localized: "Could not fetch models. Check the network or use cached or manual model IDs.")
    }
    private func json(_ request: URLRequest) async throws -> [String: Any] {
        try Task.checkCancellation()
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else { throw AppError.invalid(String(localized: "Invalid model list response")) }
        switch http.statusCode {
        case 200..<300: break
        case 401: throw AppError.unavailable(String(localized: "401: The API key is missing or invalid. Check this provider's key."))
        case 403: throw AppError.unavailable(String(localized: "403: This key cannot list models. You can enter an authorized model ID manually."))
        case 404: throw AppError.unavailable(String(localized: "404: The model endpoint was not found. Check the protocol and base URL, or enter a model ID manually."))
        case 429: throw AppError.unavailable(String(localized: "429: The provider limited requests. Refresh later. No automatic retry was made."))
        case 300..<400: throw AppError.unavailable(String(localized: "The provider returned a redirect. It was not followed to protect your key. Enter the final base URL directly."))
        default: throw AppError.unavailable(String(localized: "Model discovery failed (HTTP \(http.statusCode)). Use cached or manual model IDs."))
        }
        var data = Data()
        for try await byte in bytes {
            try Task.checkCancellation()
            guard data.count < 8 * 1_024 * 1_024 else { throw AppError.invalid(String(localized: "Model metadata is too large. The previous cache was kept.")) }
            data.append(byte)
        }
        guard let result = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AppError.invalid(String(localized: "The model endpoint did not return a valid JSON object. Check the protocol and base URL."))
        }
        return result
    }
    func request(profile: ProviderProfile, key: String, cursor: String? = nil, offset: Int = 0, model: String? = nil) throws -> URLRequest {
        let kind = profile.providerKind, base = try kind.baseURL(profile.settings.baseURL)
        let endpoint = kind == .ollama ? base.appendingPathComponent(model == nil ? "api/tags" : "api/show") : base.appendingPathComponent("models")
        var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)!
        switch kind {
        case .anthropic: components.queryItems = [.init(name: "limit", value: "100")] + (cursor.map { [.init(name: "after_id", value: $0)] } ?? [])
        case .gemini: components.queryItems = [.init(name: "pageSize", value: "100")] + (cursor.map { [.init(name: "pageToken", value: $0)] } ?? [])
        case .openRouter: components.queryItems = [.init(name: "limit", value: "100"), .init(name: "offset", value: String(offset))]
        case .chatGPTSubscription: throw AppError.unavailable(ChatGPTSubscriptionPolicy.mobileLoginNotice)
        case .openAI: if let cursor { components.queryItems = [.init(name: "after", value: cursor)] }
        case .ollama: break
        }
        var request = URLRequest(url: components.url!)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        switch kind {
        case .anthropic:
            if !key.isEmpty { request.setValue(key, forHTTPHeaderField: "x-api-key") }
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        case .gemini: if !key.isEmpty { request.setValue(key, forHTTPHeaderField: "x-goog-api-key") }
        default: if !key.isEmpty { request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
        }
        if let model {
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: ["model": model, "verbose": false])
        }
        return request
    }
    func fetch(profile: ProviderProfile, key: String) async throws -> ModelCatalog {
        let kind = profile.providerKind
        var models: [DiscoveredModel] = [], indices: [String: Int] = [:]
        var cursor: String?, seenCursors = Set<String>(), seenPages = Set<[String]>()
        var offset = 0
        while true {
            let value = try await json(request(profile: profile, key: key, cursor: cursor, offset: offset))
            let page = try Self.parseList(value, providerKind: kind)
            for model in page {
                if let index = indices[model.id] { models[index] = model }
                else { indices[model.id] = models.count; models.append(model) }
            }
            var hasMore = false
            switch kind {
            case .anthropic, .openAI:
                hasMore = value["has_more"] as? Bool == true
                cursor = value["last_id"] as? String ?? page.last?.id
            case .gemini:
                cursor = value["nextPageToken"] as? String
                hasMore = cursor?.isEmpty == false
            case .openRouter:
                offset += page.count
                if let total = value["total_count"] as? Int { hasMore = offset < total }
                else if let links = value["links"] as? [String: Any], links["next"] != nil {
                    hasMore = (links["next"] as? String)?.isEmpty == false
                } else { hasMore = page.count == 100 }
                cursor = String(offset) // Never follow server-provided URLs with credentials.
            case .ollama, .chatGPTSubscription: break
            }
            guard hasMore else { break }
            guard !page.isEmpty, let next = cursor, !next.isEmpty,
                  seenCursors.insert(next).inserted, seenPages.insert(page.map(\.id)).inserted,
                  models.count <= 50_000 else { throw AppError.invalid(String(localized: "Model pagination made no progress or the list is too large. The previous cache was kept.")) }
        }
        if kind == .ollama {
            // /show is metadata, not inference. Failed details remain explicitly unknown.
            for index in models.indices {
                try Task.checkCancellation()
                do {
                    let value = try await json(request(profile: profile, key: key, model: models[index].id))
                    models[index] = Self.ollamaDetails(value, model: models[index])
                } catch {
                    try Task.checkCancellation()
                    if (error as? URLError)?.code == .cancelled { throw CancellationError() }
                    models[index].detailNotice = Self.failure(error)
                }
            }
        }
        try Task.checkCancellation()
        return ModelCatalog(endpoint: try profile.catalogEndpoint(), fetchedAt: Date(), models: models)
    }
    static func parseList(_ value: [String: Any], providerKind: ProviderKind) throws -> [DiscoveredModel] {
        let arrayKey = [.gemini, .ollama, .chatGPTSubscription].contains(providerKind) ? "models" : "data"
        // Google omits an empty repeated field. Other missing arrays are format errors.
        let rows: [[String: Any]]
        if let list = value[arrayKey] as? [[String: Any]] { rows = list }
        else if providerKind == .gemini && value.isEmpty { rows = [] }
        else { throw AppError.invalid(String(localized: "The model list format does not match the selected protocol")) }
        return try rows.filter { providerKind != .chatGPTSubscription || $0["visibility"] as? String == "list" }.map { row in
            let raw = row[providerKind == .chatGPTSubscription ? "slug" : providerKind == .gemini ? "name" : providerKind == .ollama ? "name" : "id"] as? String
            guard let id = raw, !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw AppError.invalid(String(localized: "The model list contains an invalid ID")) }
            var model = DiscoveredModel(id: id, name: row["display_name"] as? String ?? row["displayName"] as? String ?? row["name"] as? String ?? id)
            switch providerKind {
            case .openAI, .ollama, .chatGPTSubscription:
                // Only server-declared choices are offered; no model-name heuristics.
                let efforts = row["supported_reasoning_efforts"] as? [String]
                    ?? (row["supported_reasoning_levels"] as? [[String: Any]])?.compactMap { $0["effort"] as? String }
                if let efforts, !efforts.isEmpty, efforts.allSatisfy({ !$0.isEmpty }), Set(efforts).count == efforts.count {
                    model.reasoningEfforts = efforts
                    let suggested = row["default_reasoning_level"] as? String ?? row["default_reasoning_effort"] as? String
                    model.defaultReasoningEffort = suggested.flatMap { efforts.contains($0) ? $0 : nil }
                }

            case .anthropic:
                let caps = row["capabilities"] as? [String: [String: Any]]
                model.vision = CapabilitySupport(caps?["image_input"]?["supported"] as? Bool)
                model.thinking = CapabilitySupport(caps?["thinking"]?["supported"] as? Bool)
                model.inputTokenLimit = positive(row["max_input_tokens"])
                model.outputTokenLimit = positive(row["max_tokens"])
            case .gemini:
                model.generationMethods = row["supportedGenerationMethods"] as? [String]
                model.generation = CapabilitySupport(model.generationMethods.map { $0.contains("generateContent") })
                model.thinking = CapabilitySupport(row["thinking"] as? Bool)
                model.inputTokenLimit = positive(row["inputTokenLimit"])
                model.outputTokenLimit = positive(row["outputTokenLimit"])
                model.maxTemperature = row["maxTemperature"] as? Double
            case .openRouter:
                let architecture = row["architecture"] as? [String: Any]
                model.vision = CapabilitySupport((architecture?["input_modalities"] as? [String]).map { $0.contains("image") })
                model.generation = CapabilitySupport((architecture?["output_modalities"] as? [String]).map { $0.contains("text") })
                model.supportedParameters = row["supported_parameters"] as? [String]
                model.tools = CapabilitySupport(model.supportedParameters.map { $0.contains("tools") })
                model.inputTokenLimit = positive(row["context_length"])
                model.outputTokenLimit = positive((row["top_provider"] as? [String: Any])?["max_completion_tokens"])
                model.pricing = row["pricing"] as? [String: String]
            }
            return model
        }
    }
    static func ollamaDetails(_ value: [String: Any], model: DiscoveredModel) -> DiscoveredModel {
        var result = model
        let caps = value["capabilities"] as? [String]
        result.vision = CapabilitySupport(caps.map { $0.contains("vision") })
        result.tools = CapabilitySupport(caps.map { $0.contains("tools") })
        result.generation = CapabilitySupport(caps.map { $0.contains("completion") })
        result.thinking = CapabilitySupport(caps.map { $0.contains("thinking") })
        if let info = value["model_info"] as? [String: Any], let architecture = info["general.architecture"] as? String {
            result.inputTokenLimit = positive(info[architecture + ".context_length"])
        }
        // The serialized parameters string contains defaults, not a schema/range.
        return result
    }
    private static func positive(_ value: Any?) -> Int? { (value as? Int).flatMap { $0 > 0 ? $0 : nil } }
}

#if DEBUG
private final class ModelCatalogUIFixture: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard request.url?.host == "catalog-fixture.invalid", request.url?.path == "/v1/models" else {
            client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet)); return
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type":"application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(#"{"data":[{"id":"fixture-vision","supported_reasoning_levels":[{"effort":"low"},{"effort":"high"}],"default_reasoning_level":"low"},{"id":"fixture-other"},{"id":"fixture-third"},{"id":"fixture-fourth"},{"id":"fixture-fifth"},{"id":"fixture-sixth"},{"id":"fixture-seventh"}]}"#.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
#endif

@MainActor final class ModelDiscoveryState: ObservableObject {
    @Published private(set) var loading = false
    @Published private(set) var message: String?
    private var task: Task<Void, Never>?
    private var generation = UUID()
    private let client: ModelDiscoveryClient
    init(client: ModelDiscoveryClient = ModelDiscoveryClient()) { self.client = client }
    func refresh(profile: ProviderProfile, key: String, receive: @escaping (ModelCatalog) -> Void) {
        cancel(); let token = UUID(); generation = token; loading = true; message = nil
        task = Task { [weak self, client] in
            do {
                let catalog = try await client.fetch(profile: profile, key: key)
                guard let self, self.generation == token, !Task.isCancelled else { return }
                receive(catalog); self.message = catalog.models.isEmpty ? String(localized: "The list is empty. You can enter a model ID manually.") : String(localized: "Fetched \(catalog.models.count) models")
                self.loading = false; self.task = nil
            } catch {
                guard let self, self.generation == token else { return }
                self.message = ModelDiscoveryClient.failure(error); self.loading = false; self.task = nil
            }
        }
    }
    func cancel() {
        generation = UUID(); task?.cancel(); task = nil
        if loading { message = String(localized: "Model discovery cancelled. The previous cache was kept.") }
        loading = false
    }
    func fail(_ error: Error) { message = ModelDiscoveryClient.failure(error) }
}
