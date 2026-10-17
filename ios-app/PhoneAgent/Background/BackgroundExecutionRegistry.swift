import Foundation

struct BackgroundSourceToken: Hashable, Sendable {
    let mechanism: BackgroundMechanism
    let owner: UUID
    var generation = UUID()
}

/// Receipts only. System grants stay inside the owning run's composite lease.
@MainActor final class BackgroundExecutionRegistry {
    static let shared = BackgroundExecutionRegistry()
    private var sources: Set<BackgroundSourceToken> = []
    private var observers: [UUID: () -> Void] = [:]
    var active: Bool { !sources.isEmpty }
    func publish(_ token: BackgroundSourceToken) {
        guard token.mechanism != .systemTask else { return }
        sources = sources.filter { $0.owner != token.owner || $0.mechanism != token.mechanism }
        sources.insert(token); refresh()
    }
    func revoke(_ token: BackgroundSourceToken) { if sources.remove(token) != nil { refresh() } }
    func effectiveSources(allowed: Set<BackgroundMechanism>) -> Set<BackgroundMechanism> {
        Set(sources.map(\.mechanism)).intersection(allowed)
    }
    func observe(_ callback: @escaping () -> Void) -> UUID {
        let token = UUID(); observers[token] = callback; return token
    }
    func removeObserver(_ token: UUID) { observers.removeValue(forKey: token) }
    func refresh() { for observer in Array(observers.values) { observer() } }
}

enum BackgroundDriverState: String {
    case idle = "空闲", waitingForForeground = "等待前台", requestingPermission = "等待定位授权"
    case starting = "正在启动，尚无生效回执", active = "已有运行证据", pausedBySystem = "系统已暂停"
    case interrupted = "已中断", failed = "启动失败", stopped = "已停止"

    var title: String {
        switch self {
        case .idle: return String(localized: "Idle")
        case .waitingForForeground: return String(localized: "Waiting for the app to open")
        case .requestingPermission: return String(localized: "Waiting for location permission")
        case .starting: return String(localized: "Starting")
        case .active: return String(localized: "Active")
        case .pausedBySystem: return String(localized: "Paused by the system")
        case .interrupted: return String(localized: "Interrupted")
        case .failed: return String(localized: "Could not start")
        case .stopped: return String(localized: "Stopped")
        }
    }
}
