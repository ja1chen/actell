import Foundation

/// Deliberately excludes goal text, model output, screenshots, endpoints and secrets.
/// A system-visible card may expose only these application-owned labels.
struct AgentStatusSnapshot: Equatable, Sendable {
    enum Phase: String, Sendable {
        case idle = "尚未开始"
        case running = "正在运行"
        case confirmation = "等待确认"
        case stopped = "已停止"
        case interrupted = "前台任务已中断"
        case completed = "运行结束，请核对"
        case blocked = "需要回到 App 检查"

        var title: String {
            switch self {
            case .idle: return String(localized: "Not started")
            case .running: return String(localized: "Running")
            case .confirmation: return String(localized: "Waiting for confirmation")
            case .stopped: return String(localized: "Stopped")
            case .interrupted: return String(localized: "Foreground task interrupted")
            case .completed: return String(localized: "Run finished. Check the result.")
            case .blocked: return String(localized: "Return to the app to check")
            }
        }
    }
    let isDemo: Bool
    let phase: Phase
    var title: String { isDemo ? String(localized: "Demo counter task") : String(localized: "Current authorized task") }
    var detail: String {
        switch phase {
        case .confirmation: return String(localized: "Return to the app to view the screenshot and confirm")
        case .interrupted: return String(localized: "Restart manually after returning")
        case .running: return String(localized: "The system decides how long background tasks can run")
        default: return String(localized: "This card shows status only and does not perform actions")
        }
    }
    var interrupted: Self { Self(isDemo: isDemo, phase: .interrupted) }

    static func make(mode: RunMode, phase: RunPhase?, running: Bool, awaitingApproval: Bool) -> Self {
        let display: Phase
        if awaitingApproval { display = .confirmation }
        else if running { display = .running }
        else {
            switch phase {
            case .stopped: display = .stopped
            case .interrupted: display = .interrupted
            case .completed: display = .completed
            case .blocked: display = .blocked
            default: display = .idle
            }
        }
        return Self(isDemo: mode == .demo, phase: display)
    }
}
