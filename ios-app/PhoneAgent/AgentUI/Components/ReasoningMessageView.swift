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
                Spacer(minLength: 8)
            }.foregroundStyle(.secondary)
                .accessibilityIdentifier("reasoningDisclosure-\(messageID)")
        }.tint(.secondary).padding(.vertical, 2)
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
struct ConversationDisclosureGroup<Content: View, Label: View>: View {
    @Environment(\.conversationDisclosureChanged) private var changed
    @State private var expanded = false
    private let externalExpansion: Binding<Bool>?
    private let content: Content
    private let label: Label
    init(isExpanded: Binding<Bool>? = nil, @ViewBuilder content: () -> Content, @ViewBuilder label: () -> Label) {
        externalExpansion = isExpanded
        self.content = content()
        self.label = label()
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
        .disclosureGroupStyle(ConversationDisclosureStyle())
    }
}

/// The whole header is one button, including the spacer and trailing chevron.
/// Toggle without a layout animation so the next tap targets the same header.
private struct ConversationDisclosureStyle: DisclosureGroupStyle {
    func makeBody(configuration: Configuration) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                var transaction = Transaction(animation: nil)
                transaction.disablesAnimations = true
                withTransaction(transaction) { configuration.isExpanded.toggle() }
            } label: {
                HStack(spacing: 8) {
                    configuration.label.frame(maxWidth: .infinity, alignment: .leading)
                    Image(systemName: configuration.isExpanded ? "chevron.down" : "chevron.right")
                        .font(.body.weight(.semibold)).imageScale(.small)
                        .foregroundStyle(Color.secondary)
                        .accessibilityHidden(true)
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
