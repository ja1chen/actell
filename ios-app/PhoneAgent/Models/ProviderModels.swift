import Foundation

// Service identity/discovery policy; wire format is selected separately by InferenceAPI.
// Raw values remain compatible with the legacy protocolKind settings field.
enum ProviderKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case openAI, anthropic, gemini, ollama, openRouter, chatGPTSubscription
    // Retain legacy raw values so existing archives remain readable; only these
    // services are offered when creating or editing a configuration.
    static let selectableKinds: [ProviderKind] = [.openAI, .openRouter, .chatGPTSubscription]
    var isSelectable: Bool { Self.selectableKinds.contains(self) }
    var id: String { rawValue }
    var title: String {
        switch self {
        case .openAI: return String(localized: "OpenAI-compatible")
        case .anthropic: return "Anthropic"
        case .gemini: return "Gemini"
        case .ollama: return "Ollama"
        case .openRouter: return "OpenRouter"
        case .chatGPTSubscription: return String(localized: "ChatGPT subscription")
        }
    }
    var supportsResponses: Bool { self == .openAI || self == .openRouter || self == .chatGPTSubscription }
    var supportsResponseChain: Bool { self == .openAI }
    var supportsInference: Bool { self != .anthropic && self != .gemini }
    var inferenceNotice: String {
        if self == .chatGPTSubscription { return ChatGPTSubscriptionPolicy.mobileLoginNotice }
        return supportsInference ? String(localized: "Select the inference API explicitly. The model must support images and tools. A model listing does not prove Responses compatibility.") : String(localized: "Only model discovery is supported for this protocol. Tasks cannot start until native inference is available.")
    }
    var defaultBase: String {
        switch self {
        case .openAI, .chatGPTSubscription: return "https://api.openai.com/v1"
        case .anthropic: return "https://api.anthropic.com/v1"
        case .gemini: return "https://generativelanguage.googleapis.com/v1beta"
        case .ollama: return "https://ollama.example"
        case .openRouter: return "https://openrouter.ai/api/v1"
        }
    }
    var baseHint: String {
        switch self {
        case .chatGPTSubscription: return String(localized: "Uses official authorization and Responses endpoints only. API keys and custom URLs are not accepted.")
        case .openAI: return String(localized: "Enter the API base URL, usually ending in /v1. Keep any proxy prefix and omit /chat/completions. The app will not guess or add /v1.")
        case .anthropic: return String(localized: "Enter an HTTPS URL with any proxy prefix, optionally including /v1. Model discovery appends /models.")
        case .gemini: return String(localized: "Enter an HTTPS URL with any proxy prefix, optionally including /v1beta. Model discovery appends /models.")
        case .ollama: return String(localized: "Enter the Ollama HTTPS server root URL, using a reverse proxy if needed. Keep any proxy prefix. Discovery uses /api and inference uses /v1. Plain HTTP is not supported.")
        case .openRouter: return String(localized: "Enter the full API base URL, usually https://openrouter.ai/api/v1. Keep any proxy prefix.")
        }
    }
    func baseURL(_ text: String) throws -> URL {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if self == .chatGPTSubscription, text != defaultBase { throw AppError.invalid(String(localized: "ChatGPT subscription access requires the official fixed URL")) }
        guard var parts = URLComponents(string: text), parts.scheme == "https", parts.host?.isEmpty == false,
              parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil else {
            throw AppError.invalid(String(localized: "Enter an HTTPS base URL without credentials, query parameters, or a fragment"))
        }
        while parts.path.hasSuffix("/") { parts.path.removeLast() }
        let lower = parts.path.lowercased()
        guard !["/chat/completions", "/responses", "/messages", "/models", "/api/tags", "/api/show"].contains(where: lower.hasSuffix),
              !lower.contains(":generatecontent"), !lower.contains(":streamgeneratecontent") else {
            throw AppError.invalid(String(localized: "Enter a base URL. Remove the endpoint path, such as /chat/completions or /models."))
        }
        guard !parts.path.split(separator: "/").contains(where: { $0 == "." || $0 == ".." }) else {
            throw AppError.invalid(String(localized: "The base URL cannot contain relative path components"))
        }
        if self == .anthropic, !parts.path.hasSuffix("/v1") { parts.path += "/v1" }
        if self == .gemini, !parts.path.hasSuffix("/v1beta") { parts.path += "/v1beta" }
        if self == .ollama {
            guard !parts.path.hasSuffix("/v1") else { throw AppError.invalid(String(localized: "For Ollama, enter the server root URL and remove the trailing /v1")) }
            if parts.path.hasSuffix("/api") { parts.path.removeLast(4) }
        }
        guard let url = parts.url else { throw AppError.invalid(String(localized: "Invalid base URL format")) }
        return url
    }
    func inferenceBase(_ text: String) throws -> URL {
        guard supportsInference else { throw AppError.unavailable(inferenceNotice) }
        let base = try baseURL(text)
        return self == .ollama ? base.appendingPathComponent("v1") : base
    }
}

enum CapabilitySupport: String, Codable, Sendable {
    case supported, unsupported, unknown
    init(_ value: Bool?) { self = value.map { $0 ? .supported : .unsupported } ?? .unknown }
    var label: String {
        switch self { case .supported: return String(localized: "Supported"); case .unsupported: return String(localized: "Not supported"); case .unknown: return String(localized: "Unknown") }
    }
}

struct DiscoveredModel: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var name: String
    var vision: CapabilitySupport = .unknown
    var tools: CapabilitySupport = .unknown
    var generation: CapabilitySupport = .unknown
    var thinking: CapabilitySupport = .unknown
    var inputTokenLimit: Int?
    var outputTokenLimit: Int?
    var maxTemperature: Double?
    var supportedParameters: [String]?
    var generationMethods: [String]?
    var pricing: [String: String]?
    var reasoningEfforts: [String]?
    var defaultReasoningEffort: String?
    var detailNotice: String?
    var capabilitySummary: String { String(localized: "Images: \(vision.label) · Tools: \(tools.label)") }
}

struct ModelCatalog: Codable, Equatable, Sendable {
    var endpoint: String
    var fetchedAt: Date
    var models: [DiscoveredModel]
}

enum ModelParameter: String, CaseIterable, Identifiable, Sendable {
    case temperature, topP = "top_p", maxTokens = "max_tokens", maxCompletionTokens = "max_completion_tokens", seed
    var id: String { rawValue }
    var isInteger: Bool { self != .temperature && self != .topP }
    static func fields(for providerKind: ProviderKind) -> [ModelParameter] {
        guard providerKind.supportsInference, providerKind != .chatGPTSubscription else { return [] }
        return providerKind == .openAI ? allCases : allCases.filter { $0 != .maxCompletionTokens }
    }
    func support(providerKind: ProviderKind, model: DiscoveredModel?) -> CapabilitySupport {
        guard Self.fields(for: providerKind).contains(self) else { return .unsupported }
        if let parameters = model?.supportedParameters { return CapabilitySupport(parameters.contains(rawValue)) }
        // A protocol accepting a field is not evidence that every model accepts it.
        return .unknown
    }
    func hint(providerKind: ProviderKind, model: DiscoveredModel?) -> String {
        if self == .temperature {
            return providerKind == .ollama ? String(localized: "Number; the API did not report a model range") : String(localized: "0–2; the model may have additional limits")
        }
        if self == .topP { return String(localized: "0–1; usually set this or temperature, not both") }
        if self == .seed { return String(localized: "Integer; does not guarantee fully deterministic results") }
        return model?.outputTokenLimit.map { String(localized: "Positive integer; reported maximum: \($0)") } ?? String(localized: "Positive integer; model limit unknown")
    }
}

struct ModelParameters: Codable, Equatable, Sendable {
    // Only allowlisted, explicitly entered values are sent. Empty means omitted.
    var values: [String: String] = [:]
    var reasoningEffort: String?
    func requestFields(providerKind: ProviderKind, model: DiscoveredModel?) throws -> [String: Any] {
        if providerKind == .chatGPTSubscription, values.values.contains(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
            throw AppError.invalid(String(localized: "ChatGPT subscription access does not support sampling or output limit parameters. Clear them before saving."))
        }
        var result: [String: Any] = [:]
        if let effort = reasoningEffort, !effort.isEmpty {
            guard model?.reasoningEfforts?.contains(effort) == true else {
                throw AppError.invalid(String(localized: "This provider or model did not report the selected reasoning effort. Refresh models or use the default."))
            }
            result["reasoning_effort"] = effort
        }
        for field in ModelParameter.fields(for: providerKind) {
            guard let text = values[field.rawValue]?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { continue }
            guard field.support(providerKind: providerKind, model: model) != .unsupported else { continue }
            if field.isInteger {
                guard let value = Int64(text) else { throw AppError.invalid(String(localized: "\(field.rawValue) requires an integer")) }
                if field != .seed {
                    guard value > 0, model?.outputTokenLimit.map({ value <= $0 }) ?? true else {
                        throw AppError.invalid(String(localized: "\(field.rawValue) is outside the model's reported output range"))
                    }
                }
                result[field.rawValue] = value
            } else {
                guard let value = Double(text), value.isFinite else { throw AppError.invalid(String(localized: "\(field.rawValue) requires a finite number")) }
                if field == .topP, !(0...1).contains(value) { throw AppError.invalid(String(localized: "top_p must be between 0 and 1")) }
                if field == .temperature, providerKind != .ollama, !(0...2).contains(value) {
                    throw AppError.invalid(String(localized: "temperature must be between 0 and 2 for this protocol"))
                }
                result[field.rawValue] = value
            }
        }
        guard result["max_tokens"] == nil || result["max_completion_tokens"] == nil else {
            throw AppError.invalid(String(localized: "Set either max_tokens or max_completion_tokens"))
        }
        return result
    }
}

/// Optional fields on ProviderProfile preserve existing settings as Chat Completions.
enum InferenceAPI: String, Codable, CaseIterable, Identifiable, Sendable {
    case chatCompletions, responses
    var id: String { rawValue }
    var title: String { self == .responses ? "OpenAI Responses" : "OpenAI Chat Completions" }
}
enum ProviderContextPolicy: String, Codable, CaseIterable, Identifiable, Sendable {
    case stateless, responseChain
    var id: String { rawValue }
    var title: String { self == .stateless ? String(localized: "Local replay · Remote responses are not saved") : String(localized: "Server response chain · Remote responses are saved") }
}

// Display known levels without changing values sent to the provider. Unknown
// provider-defined levels remain verbatim, just like model IDs and names.
enum ReasoningEffortLabel {
    static func title(_ value: String) -> String {
        switch value {
        case "none": return String(localized: "None")
        case "minimal": return String(localized: "Minimal")
        case "low": return String(localized: "Low")
        case "medium": return String(localized: "Medium")
        case "high": return String(localized: "High")
        case "xhigh": return String(localized: "Extra high")
        case "max": return String(localized: "Maximum")
        case "ultra": return String(localized: "Ultra")
        default: return value
        }
    }
}
