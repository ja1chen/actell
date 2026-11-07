import Foundation

/// A per-run observation policy. Protocol values and saved preferences do not localize.
enum ScreenInformationMode: String, CaseIterable, Sendable {
    case screenshot
    case accessibility
    case screenshotAndAccessibility = "screenshot_and_accessibility"
    case automatic

    static let defaultsKey = "screenInformationMode"
    static func load(from defaults: UserDefaults = .standard) -> Self {
        if let raw = defaults.string(forKey: defaultsKey), let mode = Self(rawValue: raw) { return mode }
        let mode: Self = defaults.object(forKey: defaultsKey) == nil && defaults.bool(forKey: "accessibilityTreeEnabled")
            ? .screenshotAndAccessibility : .screenshot
        defaults.set(mode.rawValue, forKey: defaultsKey)
        defaults.removeObject(forKey: "accessibilityTreeEnabled")
        return mode
    }
    var title: String {
        switch self {
        case .screenshot: return String(localized: "Screenshot")
        case .accessibility: return String(localized: "Accessibility content")
        case .screenshotAndAccessibility: return String(localized: "Screenshot + accessibility content")
        case .automatic: return String(localized: "Automatic")
        }
    }
    var includesScreenshot: Bool { self == .screenshot || self == .screenshotAndAccessibility }
    var includesAccessibility: Bool { self == .accessibility || self == .screenshotAndAccessibility }
    var toolInstruction: String {
        switch self {
        case .screenshot: return "Return only a current screenshot with image_id and exact pixel dimensions."
        case .accessibility: return "Return accessible screen content and input_coordinates for logical-point taps and drags, without capturing or sending an image. All operation tools remain available."
        case .screenshotAndAccessibility: return "Return a current screenshot with image_id and exact pixel dimensions, plus accessible content when available. An AX failure still returns the screenshot."
        case .automatic: return "Choose mode on every call: accessibility for text/structure and logical-point input, screenshot for visual layout and pixel input, or screenshot_and_accessibility when both help. Infer the choice from the task and previous results. If AX is unavailable or insufficient, you may choose screenshot next; the app does not choose or retry for you."
        }
    }
}
