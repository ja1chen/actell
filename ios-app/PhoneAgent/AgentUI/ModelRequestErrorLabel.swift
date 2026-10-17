import Foundation

// Translate app-owned diagnostics at the presentation boundary. Provider/model
// content is not a localization key and is never rewritten.
enum ModelRequestErrorLabel {
    static func title(_ message: String) -> String {
        switch message {
        case "Unsupported image type": return String(localized: "Unsupported image type")
        case "Image exceeds byte limit": return String(localized: "Image exceeds the size limit")
        case "Runtime message coordinator requires portable messages; explicit native context belongs at the wire adapter boundary": return String(localized: "This message context is not supported. Start a new conversation.")
        case "Tool result missing call ID": return String(localized: "A tool result is missing its call ID")
        case "Tool result missing ID": return String(localized: "A tool result is missing its call ID")
        case "HTTPS endpoint required": return String(localized: "An HTTPS service URL is required")
        case "System instructions belong in instructions": return String(localized: "The model request contains unsupported system instructions")
        case "模型请求超过 24 MiB 限制": return String(localized: "The model request exceeds the 24 MiB limit")
        case "Subscription requires local stateless foreground context": return String(localized: "Subscription requests require local context without a saved response chain")
        case "Subscription request exceeds limit": return String(localized: "The subscription request exceeds the size limit")
        case "Tool arguments must be a JSON object": return String(localized: "Tool arguments must be a JSON object")
        default: return message
        }
    }
}
