import ActivityKit
import SwiftUI
import WidgetKit
import OSLog

private let activityLogger = Logger(subsystem: "com.ja1chen.PhoneAgent", category: "ActivityLifecycle")

/// This observes configuration evaluation, not whether the user saw the view.
private func traceActivityContext(_ context: ActivityViewContext<AgentActivityAttributes>, destination: String) {
    activityLogger.info("activity.widgetEvaluated destination=\(destination, privacy: .public) id=\(context.activityID, privacy: .public) run=\(context.attributes.runID.uuidString, privacy: .public) phase=\(context.state.phase.rawValue, privacy: .public) operation=\(context.state.operation?.rawValue ?? "none", privacy: .public) tools=\(context.state.completedTools) stale=\(context.isStale) contentTime=\(context.state.updatedAt.timeIntervalSince1970)")
}

@main struct PhoneAgentLiveActivityBundle: WidgetBundle {
    var body: some Widget { PhoneAgentLiveActivity() }
}

struct PhoneAgentLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: AgentActivityAttributes.self) { context in
            let _ = traceActivityContext(context, destination: "card")
            Group {
                if context.state.phase == .standby {
                    Color.clear.frame(height: 1).accessibilityHidden(true)
                } else {
                    ActivityCard(context: context)
                }
            }
                .activityBackgroundTint(context.state.phase == .standby ? Color.clear : Color.black)
                .activitySystemActionForegroundColor(.white)
                .widgetURL(activityURL(context))
        } dynamicIsland: { context in
            let _ = traceActivityContext(context, destination: "island")
            let standby = context.state.phase == .standby
            let stale = context.isStale && !context.state.phase.isTerminal
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    if !standby {
                        Label((context.state.isDemo ?? context.attributes.isDemo) ? String(localized: "\(AppIdentity.displayName) · Offline demo") : AppIdentity.displayName, systemImage: "sparkles")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                DynamicIslandExpandedRegion(.center) {
                    if !standby {
                        Label(stale ? String(localized: "View") : context.state.title,
                              systemImage: stale ? "exclamationmark.circle" : context.state.symbol)
                            .font(.headline).foregroundStyle(activityTint(context)).lineLimit(2)
                    }
                }
                DynamicIslandExpandedRegion(.bottom) {
                    if !standby {
                        VStack(alignment: .leading, spacing: 8) {
                            if context.state.completedTools > 0 {
                                Text(String(localized: "Completed \(context.state.completedTools) steps"))
                                    .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                            }
                            if stale || !context.state.phase.detail.isEmpty {
                                Text(stale ? String(localized: "This status is out of date. Check execution in the app.") : context.state.phase.detail)
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Link(destination: activityURL(context)) {
                                Label(!stale && context.state.phase == .awaitingApproval ? String(localized: "Review and confirm") : (context.state.phase == .standby ? String(localized: "Open app") : String(localized: "View conversation")), systemImage: "arrow.up.forward.app")
                                    .font(.subheadline.weight(.semibold)).frame(maxWidth: .infinity)
                                    .padding(.vertical, 8).background(.white.opacity(0.12), in: Capsule())
                            }.tint(.white)
                        }
                    }
                }
            } compactLeading: {
                if !standby {
                    Image(systemName: "sparkles").foregroundStyle(.cyan)
                }
            } compactTrailing: {
                if !standby {
                    HStack(spacing: 3) {
                        Image(systemName: stale ? "exclamationmark.circle" : context.state.symbol)
                        Text(stale ? String(localized: "View") : context.state.compactTitle).lineLimit(1)
                    }.font(.caption2).foregroundStyle(activityTint(context))
                }
            } minimal: {
                if !standby {
                    Image(systemName: stale ? "exclamationmark.circle" : context.state.symbol).foregroundStyle(activityTint(context))
                }
            }
            .widgetURL(activityURL(context))
            .keylineTint(standby ? Color.clear : activityTint(context))
        }
    }
}

private func activityURL(_ context: ActivityViewContext<AgentActivityAttributes>) -> URL {
    context.state.route(attributes: context.attributes)?.url ?? URL(string: "phoneagent://home")!
}
private func activityTint(_ context: ActivityViewContext<AgentActivityAttributes>) -> Color {
    context.isStale || context.state.phase == .awaitingApproval ? .orange : .cyan
}
private struct ActivityCard: View {
    let context: ActivityViewContext<AgentActivityAttributes>
    private var stale: Bool { context.isStale && !context.state.phase.isTerminal }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label((context.state.isDemo ?? context.attributes.isDemo) ? String(localized: "\(AppIdentity.displayName) · Offline demo") : AppIdentity.displayName, systemImage: "sparkles")
                    .font(.caption).foregroundStyle(.white.opacity(0.7))
                Spacer()
            }
            Label(stale ? String(localized: "Return to the app") : context.state.title,
                  systemImage: stale ? "exclamationmark.circle" : context.state.symbol)
                .font(.headline).foregroundStyle(activityTint(context))
            if stale || !context.state.phase.detail.isEmpty {
                Text(stale ? String(localized: "This status is out of date. Check execution in the app.") : context.state.phase.detail)
                    .font(.caption).foregroundStyle(.white.opacity(0.7))
            }
            Link(destination: activityURL(context)) {
                Label(!stale && context.state.phase == .awaitingApproval ? String(localized: "Review and confirm") : (context.state.phase == .standby ? String(localized: "Open app") : String(localized: "View conversation")), systemImage: "arrow.up.forward.app")
                    .font(.subheadline.weight(.semibold)).frame(maxWidth: .infinity)
                    .padding(.vertical, 8).background(.white.opacity(0.12), in: Capsule())
            }.tint(.white)
        }.foregroundStyle(.white).padding(16)
    }
}
