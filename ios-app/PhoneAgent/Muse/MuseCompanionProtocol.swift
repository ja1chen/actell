import Foundation

/// Independent Actell companion protocol. Official Muse setup v5 is not used.
/// Bonjour is only a locator; trust comes from user-controlled USB provisioning.
enum MuseCompanionProtocol {
    static let version = 1
    static let serviceType = "_actell-muse._tcp"
    static let helloOperation = "companion.hello"
    static let maximumDeviceNameLength = 64
    // Presence display only: two 30-second probes plus discovery/TLS/retry time.
    // Authentication, request deadlines and execution permissions are independent.
    static let peerFreshness: TimeInterval = 90
}

enum MuseCompanionScope: String, Codable, CaseIterable, Identifiable {
    case screenshot, listApps = "list_apps", control
    var id: String { rawValue }
    var title: String {
        switch self {
        case .screenshot: return "读取屏幕截图"
        case .listApps: return "读取应用列表"
        case .control: return "操控手机"
        }
    }
}

/// No grant is implicit, including for credentials created by older versions.
/// Control never implies permission to disclose screenshots or the app list.
enum MuseCompanionAuthorization {
    // Local Muse policy: paired-device scopes authorize a run without per-action prompts.
    static let inputMode = InputAuthorizationMode.task
    static func permits(op: String, params: [String: Any], scopes: Set<MuseCompanionScope>) -> Bool {
        guard !scopes.isEmpty else { return false }
        switch op {
        case "capabilities", "runs.open", "runs.get", "runs.cancel", "calls.get": return true
        case "images.get": return scopes.contains(.screenshot)
        case "tools.call":
            guard let tool = params["tool"] as? String else { return false }
            switch tool {
            case "screenshot": return scopes.contains(.screenshot)
            case "list_apps": return scopes.contains(.listApps)
            case "tap", "drag", "home", "launch_app", "type_text", "wait": return scopes.contains(.control)
            default: return false
            }
        default: return false
        }
    }
}
