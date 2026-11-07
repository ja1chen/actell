import SwiftUI

/// Standalone card above the composer while a tool call waits for approval.
/// It only presents the request and forwards the decision to the scoped
/// closures; every authorization action stays with the caller.
struct ToolApprovalCard<Preview: View>: View {
    private let configuration: ToolInvocationConfiguration
    private let preview: Preview
    @State private var detailsExpanded = false

    init(configuration: ToolInvocationConfiguration, @ViewBuilder preview: () -> Preview) {
        self.configuration = configuration
        self.preview = preview()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                MessageHeaderIcon(systemName: configuration.tool.symbol)
                Text(configuration.tool.title).font(.body).lineLimit(1)
                Spacer(minLength: 8)
                Text(String(localized: "Approval required"))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .foregroundStyle(.secondary)

            Text(configuration.tool.detail)
                .font(.subheadline)
                .lineLimit(3)

            ConversationDisclosureGroup(isExpanded: $detailsExpanded) {
                ResultScrollRegion(maxHeight: 180, identifier: "approvalDetails") {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(configuration.tool.detail)
                            .font(.footnote)
                            .foregroundStyle(.primary)
                            .textSelection(.enabled)
                        if let arguments = configuration.tool.displayArguments {
                            ToolArgumentsSection(arguments)
                        }
                        preview
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                }
                .padding(.top, 8)
            } label: {
                Text(String(localized: "Action details"))
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("approvalDetailsToggle")
            }
            .tint(.secondary)

            HStack(spacing: 12) {
                Spacer(minLength: 0)
                Button(String(localized: "Deny"), role: .destructive) { configuration.onDeny?() }
                    .buttonStyle(.bordered)
                    .disabled(configuration.onDeny == nil)
                    .accessibilityIdentifier("rejectTool")
                Button(String(localized: "Approve once")) { configuration.onApprove?() }
                    .buttonStyle(.borderedProminent)
                    .disabled(configuration.onApprove == nil)
                    .accessibilityIdentifier("approveTool")
            }
        }
        .padding(16)
        .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 18))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("approvalCard")
    }
}
