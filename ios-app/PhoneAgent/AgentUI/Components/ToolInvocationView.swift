import SwiftUI

/// Data shared by the in-conversation tool card and the approval card. The
/// closures belong to the caller's run/step/approval scope; cards only invoke
/// them and never perform an authorization action themselves.
struct ToolInvocationConfiguration {
    let tool: ToolStep
    // True when the preview slot renders content; without it an empty slot
    // would draw an empty bordered box instead of a header-only card.
    var hasPreview = false
    var onApprove: (() -> Void)? = nil
    var onDeny: (() -> Void)? = nil
}

/// One tool call inside the conversation. While the call is still in progress
/// only the header row is shown; once it reaches a terminal state the request
/// arguments and result fold out beneath the same header.
struct ToolInvocationView<Preview: View>: View {
    private let configuration: ToolInvocationConfiguration
    private let preview: Preview

    init(configuration: ToolInvocationConfiguration, @ViewBuilder preview: () -> Preview) {
        self.configuration = configuration
        self.preview = preview()
    }

    var body: some View {
        Group {
            if configuration.tool.state.isTerminal {
                ConversationDisclosureGroup {
                    resultArea
                } label: {
                    title
                } trailing: {
                    if configuration.tool.state != .succeeded { stateBadge }
                }
            } else {
                HStack(spacing: 8) {
                    title
                    Spacer(minLength: 8)
                    stateBadge
                }
            }
        }
        .tint(.secondary)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("tool-invocation-\(configuration.tool.state.rawValue)-\(configuration.tool.name)")
        // Activity rows sit tighter than the message rhythm; both the tool
        // and reasoning rows opt in symmetrically so gaps stay equal.
        .padding(.vertical, -2)
    }

    private var title: some View {
        HStack(spacing: 8) {
            MessageHeaderIcon(systemName: configuration.tool.symbol)
            Text(configuration.tool.title).font(.body).lineLimit(1)
        }
        .foregroundStyle(.secondary)
    }

    // A result reads as data next to the secondary header, and every badge
    // pairs its color with the state label so color is never the only carrier.
    private var stateBadge: some View {
        let color = badgeColor
        return Text(configuration.tool.state.label)
            .font(.caption).lineLimit(1)
            .foregroundStyle(color)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(color.opacity(0.15), in: Capsule())
    }

    private var badgeColor: Color {
        switch configuration.tool.state {
        case .failed: .red
        case .awaitingApproval, .denied: .orange
        default: .secondary
        }
    }

    @ViewBuilder private var resultArea: some View {
        if hasTextContent {
            ResultScrollRegion(maxHeight: 320, identifier: "toolResultScroll") {
                VStack(alignment: .leading, spacing: 10) {
                    if let arguments = configuration.tool.displayArguments {
                        ToolArgumentsSection(arguments)
                    }
                    if let result = resultText {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(resultTitle).font(.caption).foregroundStyle(.secondary)
                            Text(result)
                                .font(.footnote)
                                .foregroundStyle(.primary)
                                .textSelection(.enabled)
                        }
                    }
                    preview
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
            }
            .padding(.top, 8)
        } else if configuration.hasPreview {
            // An image-only result reads as the content itself; a bordered
            // box around nothing but the image adds noise, not structure.
            preview
                .padding(.top, 8)
        }
    }

    private var hasTextContent: Bool {
        configuration.tool.displayArguments != nil || resultText != nil
    }

    private var resultText: String? {
        let result = configuration.tool.displayResult
        guard !result.isEmpty else { return nil }
        if configuration.hasPreview && Self.isStructured(result) { return nil }
        return result
    }

    // Image previews replace structured image metadata. Without a preview,
    // structured results use the same text result region as other tools.
    private static func isStructured(_ text: String) -> Bool {
        guard let first = text.first(where: { !$0.isWhitespace }), first == "{" || first == "[" else { return false }
        return (try? JSONSerialization.jsonObject(with: Data(text.utf8))) != nil
    }

    private var resultTitle: String {
        configuration.tool.state == .succeeded ? String(localized: "Result") : String(localized: "Result details")
    }
}

/// The "Request arguments" block shared by both cards: a small secondary label
/// above monospaced, selectable caption text.
struct ToolArgumentsSection: View {
    let arguments: String
    init(_ arguments: String) { self.arguments = arguments }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(String(localized: "Request arguments")).font(.caption).foregroundStyle(.secondary)
            Text(arguments)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.primary)
                .textSelection(.enabled)
        }
    }
}

/// The expanded detail region shared by both cards: hugs short content and
/// scrolls long content inside a capped height, so scrolling stays inside the
/// region and the surrounding layout never moves.
struct ResultScrollRegion<Content: View>: View {
    let maxHeight: CGFloat
    let identifier: String
    @ViewBuilder let content: () -> Content
    @State private var atEnd = true

    var body: some View {
        BoundedResultScroll(maxHeight: maxHeight) {
            ScrollView {
                content()
            }
            .onScrollGeometryChange(for: Bool.self) { geometry in
                let visible = geometry.containerSize.height
                let limit = geometry.contentSize.height - visible
                return geometry.contentSize.height <= visible + 1 || geometry.contentOffset.y >= limit - 1
            } action: { _, reached in
                atEnd = reached
            }
            .accessibilityIdentifier(identifier)
            .accessibilityValue(atEnd ? String(localized: "End reached") : String(localized: "More content available"))
        }
        .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.secondary.opacity(0.2), lineWidth: 0.5))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}

/// Sizes a scroller to its content up to `maxHeight` in the first layout
/// pass, so a short result fits its text immediately and a long one is capped
/// without a second-frame height jump.
private struct BoundedResultScroll: Layout {
    let maxHeight: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let scroller = subviews.first else { return .zero }
        let width = proposal.width ?? scroller.sizeThatFits(ProposedViewSize(width: nil, height: nil)).width
        let natural = scroller.sizeThatFits(ProposedViewSize(width: width, height: nil)).height
        return CGSize(width: width, height: min(natural, maxHeight))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard let scroller = subviews.first else { return }
        scroller.place(at: bounds.origin, proposal: ProposedViewSize(width: bounds.width, height: bounds.height))
    }
}
