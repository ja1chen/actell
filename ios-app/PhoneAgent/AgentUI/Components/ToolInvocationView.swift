// Adapted from ManifoldKit ToolInvocationView.swift and
// ToolInvocationStyle.swift (PlainToolInvocationBody), revision
// 15c9c2443770c9289c2e93c88a55bdebc4562771.
// Copyright (c) 2026 Rory Ford. MIT; full text: Licenses/ManifoldKit-MIT.txt.
// Original snapshots and hashes: Vendor/ManifoldPresentation/.
// PhoneAgent changes: app-owned data, Chinese labels, explicit denied/cancelled
// states, public parameter preview, screenshot slot, iOS 17 colors. No runtime.

import SwiftUI

/// Shared symbol sizing for message disclosure and approval headers.
struct MessageHeaderIcon: View {
    let systemName: String
    var body: some View {
        Image(systemName: systemName)
            .font(.body).imageScale(.small).foregroundStyle(.secondary).accessibilityHidden(true)
    }
}

struct ToolInvocationConfiguration {
    let tool: ToolStep
    var onApprove: (() -> Void)?
    var onDeny: (() -> Void)?
}

/// Manifold's presentation-only shell, adapted to the existing execution layer.
/// Closures dispatch scoped intents; this view never authorizes a device itself.
struct ToolInvocationView<Preview: View>: View {
    let configuration: ToolInvocationConfiguration
    @ViewBuilder var preview: () -> Preview

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            switch configuration.tool.state {
            case .awaitingApproval: toolHeader
            case .requested, .running, .approved, .executing: toolHeader
            case .succeeded, .failed, .denied, .cancelled, .interrupted, .outcomeUnknown: resultView
            }
        }
        .padding(.vertical, 2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("tool-invocation-\(configuration.tool.state.rawValue)-\(configuration.tool.name)")
    }

    private var toolHeader: some View {
        HStack(spacing: 8) {
            MessageHeaderIcon(systemName: configuration.tool.symbol)
            Text(configuration.tool.title)
                .font(.body).fontWeight(.regular).foregroundStyle(.secondary)
            Spacer(minLength: 8)
            if configuration.tool.state != .succeeded {
                Text(configuration.tool.state.label).font(.caption).lineLimit(1)
                    .foregroundStyle(statusColor)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(statusColor.opacity(0.10), in: Capsule())
            }
        }
    }

    private var statusColor: Color {
        switch configuration.tool.state {
        case .failed: return .red
        case .awaitingApproval, .denied: return .orange
        default: return .secondary
        }
    }

    private var resultView: some View {
        ConversationDisclosureGroup {
            ToolResultCard {
                VStack(alignment: .leading, spacing: 6) {
                    if let arguments = configuration.tool.displayArguments {
                        Text(String(localized: "Request arguments")).font(.caption2).foregroundStyle(.tertiary)
                        Text(arguments).font(.caption.monospaced()).textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if !configuration.tool.displayResult.isEmpty {
                        Text(configuration.tool.state == .succeeded ? String(localized: "Result") : String(localized: "Result details"))
                            .font(.caption2).foregroundStyle(.tertiary)
                        Text(configuration.tool.displayResult).font(.footnote).textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    preview()
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
        } label: {
            toolHeader
        }.tint(.secondary)
    }
}

/// Short results size to their content; long results scroll inside the card.
private struct ToolResultCard<Content: View>: View {
    @ViewBuilder var content: () -> Content
    @State private var contentHeight: CGFloat = 1
    @State private var atEnd = false
    var body: some View {
        ScrollView(.vertical) {
            content()
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
        }
        .frame(height: min(contentHeight, 320))
        .scrollBounceBehavior(.basedOnSize)
        .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(Color.secondary.opacity(0.22), lineWidth: 1) }
        .onScrollGeometryChange(for: Bool.self) {
            $0.contentOffset.y + $0.containerSize.height >= $0.contentSize.height + $0.contentInsets.bottom - 2
        } action: { _, value in atEnd = value }
        .accessibilityIdentifier("toolResultScroll")
        .accessibilityValue(atEnd ? String(localized: "End reached") : String(localized: "More content available"))
        .padding(.top, 4)
    }
}

/// The current approval lives above the composer, outside conversation history.
/// Its parent supplies callbacks already scoped to the run, step and approval ID.
struct ToolApprovalCard<Preview: View>: View {
    let configuration: ToolInvocationConfiguration
    @ViewBuilder var preview: () -> Preview
    @State private var detailsExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                MessageHeaderIcon(systemName: configuration.tool.symbol)
                Text(configuration.tool.title).foregroundStyle(.secondary)
                Spacer()
                Text(String(localized: "Approval required")).font(.caption).foregroundStyle(.secondary)
            }.font(.body)
            Text(configuration.tool.detail).font(.subheadline).lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
            ConversationDisclosureGroup(isExpanded: $detailsExpanded) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(configuration.tool.detail).font(.subheadline).textSelection(.enabled)
                        if let arguments = configuration.tool.displayArguments {
                            Text(String(localized: "Request arguments")).font(.caption).foregroundStyle(.secondary)
                            Text(arguments).font(.caption.monospaced()).textSelection(.enabled)
                        }
                        preview()
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 4)
                }.frame(height: 180).scrollBounceBehavior(.basedOnSize)
                    .accessibilityIdentifier("approvalDetails")
            } label: {
                Text(String(localized: "Action details")).font(.footnote).foregroundStyle(.secondary)
                    .accessibilityIdentifier("approvalDetailsToggle")
            }.tint(.secondary)
            HStack(spacing: 10) {
                Spacer(minLength: 0)
                Button(String(localized: "Deny"), role: .destructive) { configuration.onDeny?() }
                    .buttonStyle(.bordered).disabled(configuration.onDeny == nil)
                    .accessibilityIdentifier("rejectTool")
                Button(String(localized: "Approve once")) { configuration.onApprove?() }
                    .buttonStyle(.borderedProminent).disabled(configuration.onApprove == nil)
                    .accessibilityIdentifier("approveTool")
            }.font(.subheadline).controlSize(.regular)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 18))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("approvalCard")
    }
}
