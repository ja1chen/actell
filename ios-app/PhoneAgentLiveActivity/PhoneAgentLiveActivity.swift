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
                    Label(String(localized: "Waiting for tasks"), systemImage: "sparkles")
                        .font(.subheadline).foregroundStyle(.cyan)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(16)
                } else {
                    ActivityCard(context: context)
                }
            }
                .activityBackgroundTint(Color.black)
                .activitySystemActionForegroundColor(.white)
                .widgetURL(activityURL(context))
        } dynamicIsland: { context in
            let _ = traceActivityContext(context, destination: "island")
            let standby = context.state.phase == .standby
            let stale = context.isStale && !context.state.phase.isTerminal
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    if standby {
                        IslandSymbol(name: "sparkles").foregroundStyle(.cyan)
                    } else {
                        Label {
                            Text((context.state.isDemo ?? context.attributes.isDemo) ? String(localized: "\(AppIdentity.displayName) · Offline demo") : AppIdentity.displayName)
                        } icon: {
                            IslandSymbol(name: "sparkles")
                        }.font(.caption).foregroundStyle(.secondary)
                    }
                }
                DynamicIslandExpandedRegion(.center) {
                    IslandStatus(title: stale ? String(localized: "View") : context.state.compactTitle,
                                 symbol: stale ? "exclamationmark.circle" : context.state.symbol,
                                 expanded: true)
                        .foregroundStyle(activityTint(context))
                }
                DynamicIslandExpandedRegion(.bottom) {
                    if !standby {
                        VStack(alignment: .leading, spacing: 8) {
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
                IslandSymbol(name: "sparkles").foregroundStyle(.cyan)
            } compactTrailing: {
                if !standby {
                    IslandStatus(title: stale ? String(localized: "View") : context.state.compactTitle,
                                 symbol: stale ? "exclamationmark.circle" : context.state.symbol)
                        .foregroundStyle(activityTint(context))
                }
            } minimal: {
                IslandSymbol(name: standby ? "sparkles" : (stale ? "exclamationmark.circle" : context.state.symbol))
                    .foregroundStyle(activityTint(context))
                    .accessibilityLabel(stale ? String(localized: "View") : context.state.compactTitle)
            }
            .widgetURL(activityURL(context))
            .keylineTint(activityTint(context))
        }
    }
}

private struct IslandSymbol: View {
    let name: String

    var body: some View {
        Image(systemName: name)
            .resizable().scaledToFit()
            .frame(width: 16, height: 16)
    }
}

private struct IslandStatus: View {
    let title: String
    let symbol: String
    var expanded = false

    var body: some View {
        HStack(spacing: 3) {
            IslandSymbol(name: symbol).accessibilityHidden(true)
            Text(title)
                .font(expanded ? .headline : .caption2)
                .lineLimit(1).minimumScaleFactor(0.8)
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
