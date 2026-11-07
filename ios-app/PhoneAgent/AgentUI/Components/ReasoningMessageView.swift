import SwiftUI

/// Uses the same native disclosure pattern as the adjacent tool cards.
struct ReasoningMessageView: View {
    let reasoning: ReasoningMessage
    let messageID: UUID
    @State private var expanded = false
    var body: some View {
        ConversationDisclosureGroup(isExpanded: $expanded) {
            Text(reasoning.text).font(.callout).foregroundStyle(Color.secondary.opacity(0.85))
                .textSelection(.enabled)
                .accessibilityIdentifier("reasoningContent-\(messageID)")
                .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 4)
        } label: {
            HStack(spacing: 8) {
                MessageHeaderIcon(systemName: "brain")
                Text(String(localized: "Reasoning")).font(.body)
            }.foregroundStyle(.secondary)
                .accessibilityIdentifier("reasoningDisclosure-\(messageID)")
        }.tint(.secondary)
        .padding(.vertical, -2)
    }
}

private struct ConversationDisclosureActionKey: EnvironmentKey {
    static let defaultValue: () -> Void = {}
}
extension EnvironmentValues {
    var conversationDisclosureChanged: () -> Void {
        get { self[ConversationDisclosureActionKey.self] }
        set { self[ConversationDisclosureActionKey.self] = newValue }
    }
}

/// Pause following before expansion changes layout, including nested tool folds.
struct ConversationDisclosureGroup<Content: View, Label: View, Trailing: View>: View {
    @Environment(\.conversationDisclosureChanged) private var changed
    @State private var expanded = false
    private let externalExpansion: Binding<Bool>?
    private let content: Content
    private let label: Label
    private let trailing: Trailing
    init(isExpanded: Binding<Bool>? = nil, @ViewBuilder content: () -> Content, @ViewBuilder label: () -> Label, @ViewBuilder trailing: () -> Trailing) {
        externalExpansion = isExpanded
        self.content = content()
        self.label = label()
        self.trailing = trailing()
    }
    init(isExpanded: Binding<Bool>? = nil, @ViewBuilder content: () -> Content, @ViewBuilder label: () -> Label) where Trailing == EmptyView {
        self.init(isExpanded: isExpanded, content: content, label: label, trailing: { EmptyView() })
    }
    var body: some View {
        DisclosureGroup(isExpanded: Binding(
            get: { externalExpansion?.wrappedValue ?? expanded },
            set: { value in
                changed()
                if let externalExpansion { externalExpansion.wrappedValue = value }
                else { expanded = value }
            }
        )) { content } label: { label }
        .disclosureGroupStyle(ConversationDisclosureStyle(trailing: trailing))
    }
}

/// The whole header is one button, with the chevron beside its label.
/// Toggle without a layout animation so the next tap targets the same header.
private struct ConversationDisclosureStyle<Trailing: View>: DisclosureGroupStyle {
    let trailing: Trailing
    func makeBody(configuration: Configuration) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                var transaction = Transaction(animation: nil)
                transaction.disablesAnimations = true
                withTransaction(transaction) { configuration.isExpanded.toggle() }
            } label: {
                HStack(spacing: 8) {
                    configuration.label
                    DisclosureChevron(isExpanded: configuration.isExpanded)
                    Spacer(minLength: 8)
                    trailing
                }
                .foregroundStyle(Color.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(configuration.isExpanded ? String(localized: "Expanded") : String(localized: "Collapsed"))
            if configuration.isExpanded {
                // Text selection must not intercept taps above the body.
                configuration.content.contentShape(Rectangle())
            }
        }
    }
}

/// One chevron glyph rotated between states, so collapsed and expanded share
/// the same design and weight as the header text. The angle change runs in
/// its own transaction and only when this row toggles: layout movement caused
/// by other rows stays under the outer no-animation transaction, so this
/// chevron always moves rigidly with the header text.
private struct DisclosureChevron: View {
    let isExpanded: Bool
    @State private var angle = 0.0
    var body: some View {
        Image(systemName: "chevron.right")
            .font(.body).imageScale(.small)
            .foregroundStyle(Color.secondary)
            .rotationEffect(.degrees(angle))
            .onAppear { angle = isExpanded ? 90 : 0 }
            .onChange(of: isExpanded) { _, expanded in
                withAnimation(.easeInOut(duration: 0.16)) { angle = expanded ? 90 : 0 }
            }
            .accessibilityHidden(true)
    }
}
