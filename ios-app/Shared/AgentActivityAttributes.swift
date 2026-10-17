import ActivityKit
import Foundation

/// This is the complete system-visible payload. Never add user text, tool
/// arguments, image identifiers, screenshots, endpoints or receipts here.
struct AgentActivityAttributes: ActivityAttributes {
    let sessionID: UUID
    let runID: UUID
    let isDemo: Bool

    struct ContentState: Codable, Hashable {
        var phase: Phase
        var completedTools: Int
        var approvalID: UUID?
        var updatedAt: Date
        // Optional preserves decoding of activities created before operation icons.
        var operation: Operation? = nil
        // Mutable identity lets a foreground-created standby activity follow new runs.
        var sessionID: UUID? = nil
        var runID: UUID? = nil
        var isDemo: Bool? = nil
        func route(attributes: AgentActivityAttributes) -> AgentActivityRoute? {
            guard phase != .standby else { return nil }
            return AgentActivityRoute(sessionID: sessionID ?? attributes.sessionID,
                                      runID: runID ?? attributes.runID, approvalID: approvalID)
        }
        var symbol: String { phase.isTerminal ? phase.symbol : (operation?.symbol ?? phase.symbol) }
        var title: String {
            [.working, .executing].contains(phase) ? (operation?.title ?? phase.title) : phase.title
        }
        var compactTitle: String {
            switch phase {
            case .standby: return String(localized: "Standby")
            case .thinking: return String(localized: "Thinking")
            case .working, .executing: return operation?.compactTitle ?? String(localized: "Processing")
            case .awaitingApproval: return String(localized: "Confirm")
            case .approved: return String(localized: "Approved")
            case .completed: return String(localized: "Done")
            case .stopped: return String(localized: "Stop")
            case .interrupted: return String(localized: "Interrupted")
            case .blocked: return String(localized: "View")
            }
        }
    }

    enum Operation: String, Codable, Hashable {
        case screenshot, apps, tap, drag, home, launch, text, skill, processing
        static func tool(_ name: String) -> Self {
            switch name {
            case "screenshot": return .screenshot
            case "list_apps": return .apps
            case "tap": return .tap
            case "drag": return .drag
            case "home": return .home
            case "launch_app": return .launch
            case "type_text": return .text
            case "load_skill": return .skill
            default: return .processing
            }
        }
        var symbol: String {
            switch self {
            case .screenshot, .apps: return "inset.filled.rectangle.and.person"
            case .tap, .drag, .home, .launch, .text: return "pointer.arrow.ipad"
            case .skill: return "book.closed"
            case .processing: return "gearshape"
            }
        }
        var compactTitle: String {
            switch self {
            case .screenshot: return String(localized: "View")
            case .apps: return String(localized: "Find")
            case .tap: return String(localized: "Tap")
            case .drag: return String(localized: "Swipe")
            case .home: return String(localized: "Home")
            case .launch: return String(localized: "Launch")
            case .text: return String(localized: "Type")
            case .skill: return String(localized: "Skill")
            case .processing: return String(localized: "Processing")
            }
        }
        var title: String {
            switch self {
            case .screenshot: return String(localized: "Viewing screen")
            case .apps: return String(localized: "Finding apps")
            case .tap: return String(localized: "Tapping")
            case .drag: return String(localized: "Swiping")
            case .home: return String(localized: "Going to Home Screen")
            case .launch: return String(localized: "Launching app")
            case .text: return String(localized: "Typing text")
            case .skill: return String(localized: "Reading skill")
            case .processing: return String(localized: "Processing")
            }
        }
    }

    enum Phase: String, Codable, Hashable {
        case standby, thinking, working, awaitingApproval, approved, executing
        case completed, stopped, interrupted, blocked

        var isTerminal: Bool { [.completed, .stopped, .interrupted, .blocked].contains(self) }
        var title: String {
            switch self {
            case .standby: return String(localized: "Background standby")
            case .thinking: return String(localized: "Thinking")
            case .working: return String(localized: "Processing")
            case .awaitingApproval: return String(localized: "Waiting for confirmation")
            case .approved: return String(localized: "Approval received")
            case .executing: return String(localized: "Sending action")
            case .completed: return String(localized: "Task completed")
            case .stopped: return String(localized: "Stopped")
            case .interrupted: return String(localized: "Interrupted")
            case .blocked: return String(localized: "Review needed")
            }
        }
        var symbol: String {
            switch self {
            case .awaitingApproval: return "hand.raised.fill"
            case .approved: return "checkmark.shield"
            case .completed: return "checkmark.circle"
            case .stopped: return "stop.circle"
            case .interrupted, .blocked: return "exclamationmark.circle"
            case .standby: return "sparkles"
            case .thinking: return "brain"
            case .working, .executing: return "gearshape"
            }
        }
        var detail: String {
            switch self {
            case .standby: return String(localized: "Waiting for a new task")
            case .awaitingApproval: return String(localized: "Return to the app to review and confirm this action")
            case .approved: return String(localized: "Approval does not confirm execution. Check the next status.")
            case .executing: return String(localized: "Sending does not confirm success. Check your device.")
            case .interrupted: return String(localized: "Return to the app to view the history")
            case .stopped: return String(localized: "If an action was sent, check your device")
            case .thinking, .working, .completed: return ""
            case .blocked: return String(localized: "Return to the app to see what happened")
            }
        }
    }
}

/// A navigation address, never an authorization token. Approval UUID identifies
/// the exact pending action; only the app's authoritative record can resolve it.
struct AgentActivityRoute: Equatable {
    let sessionID: UUID
    let runID: UUID
    let approvalID: UUID?

    var url: URL {
        var components = URLComponents()
        components.scheme = "phoneagent"; components.host = "activity"
        components.path = "/session/\(sessionID.uuidString)/run/\(runID.uuidString)"
        if let approvalID { components.queryItems = [URLQueryItem(name: "approval", value: approvalID.uuidString)] }
        return components.url!
    }
    init(sessionID: UUID, runID: UUID, approvalID: UUID? = nil) {
        self.sessionID = sessionID; self.runID = runID; self.approvalID = approvalID
    }
    init?(url: URL) {
        guard let c = URLComponents(url: url, resolvingAgainstBaseURL: false),
              c.scheme == "phoneagent", c.host == "activity", c.user == nil,
              c.password == nil, c.port == nil, c.fragment == nil else { return nil }
        let parts = c.path.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 5, parts[0].isEmpty, parts[1] == "session", parts[3] == "run",
              let session = UUID(uuidString: String(parts[2])), let run = UUID(uuidString: String(parts[4])) else { return nil }
        let items = c.queryItems ?? []
        guard items.count <= 1, items.allSatisfy({ $0.name == "approval" && UUID(uuidString: $0.value ?? "") != nil }) else { return nil }
        self.init(sessionID: session, runID: run, approvalID: items.first.flatMap { UUID(uuidString: $0.value ?? "") })
    }
}
