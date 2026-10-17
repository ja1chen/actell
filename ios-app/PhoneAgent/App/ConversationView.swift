import SwiftUI
import MarkdownUI

struct ConversationView: View {
    @State private var browsingModels = false
    @State private var showingModelSettings = false
    @StateObject private var presentation: AgentPresentationAdapter
    init(model: AgentViewModel, conversationID: UUID) {
        _presentation = StateObject(wrappedValue: AgentPresentationAdapter(model: model, sessionID: conversationID))
    }
    @State private var draft = ""
    @State private var followLatest = true
    @State private var userScrolling = false
    @State private var lastMessageVisible = false
    @State private var focused = false
    @State private var scrollPosition = ScrollPosition()
    @State private var deferredViewportShift: CGFloat = 0
    @State private var viewportDiagnostic = ""
    @State private var importingAttachments = false
    @State private var sendingAttachments = false
    @State private var attachmentFailure: String?
    @State private var sendingTask: Task<Void, Never>?
    @State private var importCancellation = 0
    private var session: AgentConversation? { presentation.session }
    private var running: Bool { presentation.running }
    private var canSend: Bool {
        !running && !presentation.stopping && !importingAttachments && !sendingAttachments &&
        (!draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || session?.draftAttachments?.isEmpty == false) && draft.count <= 2_000
    }
    var body: some View {
        Group {
            if let session {
                VStack(spacing: 0) {
                    Group {
                        ScrollView {
                            messageStack(session)
                                .padding(.horizontal, 20).padding(.vertical, 12).frame(maxWidth: 780).frame(maxWidth: .infinity)
                        }
                        .accessibilityIdentifier("conversationMessages")
                        .accessibilityValue(scrollDiagnostic)
                        .scrollDismissesKeyboard(.interactively)
                        .simultaneousGesture(TapGesture().onEnded { focused = false })
                        .scrollEdgeEffectStyle(.soft, for: .bottom)
                        .defaultScrollAnchor(.bottom, for: .initialOffset)
                        .scrollPosition($scrollPosition, anchor: .top)
                        .onScrollPhaseChange { old, phase, context in
                            userScrolling = phase == .tracking || phase == .interacting || phase == .decelerating
                            if phase == .idle && (old == .interacting || old == .decelerating) {
                                followLatest = lastMessageVisible || session.messages.isEmpty
                                if deferredViewportShift != 0 {
                                    let geometry = context.geometry
                                    scrollPosition.scrollTo(y: max(0, geometry.contentOffset.y + geometry.contentInsets.top + deferredViewportShift))
                                    deferredViewportShift = 0
                                }
                            }
                        }
                        .onScrollGeometryChange(for: ScrollGeometry.self) { $0 } action: { old, new in
                            let shift = old.containerSize.height - new.containerSize.height
                            if ProcessInfo.processInfo.arguments.contains("--ui-test-composer-history") {
                                viewportDiagnostic = "offset=\(new.contentOffset.y) height=\(new.containerSize.height) bottomInset=\(new.contentInsets.bottom) topInset=\(new.contentInsets.top) shift=\(shift)"
                            }
                            if shift != 0 {
                                if userScrolling {
                                    deferredViewportShift += shift
                                } else if followLatest {
                                    scrollPosition.scrollTo(edge: .bottom)
                                } else {
                                    scrollPosition.scrollTo(y: max(0, old.contentOffset.y + new.contentInsets.top + shift))
                                }
                            } else if followLatest && !userScrolling && old.contentSize != new.contentSize {
                                scrollPosition.scrollTo(edge: .bottom)
                            }
                        }
                        .onChange(of: session.messages) { _, _ in if followLatest && !userScrolling { scrollPosition.scrollTo(edge: .bottom) } }
                        .onChange(of: presentation.activeTurnID) { old, new in
                            guard old != nil, new == nil else { return }
                            userScrolling = false
                            deferredViewportShift = 0
                            followLatest = true
                            scrollPosition = ScrollPosition()
                            scrollPosition.scrollTo(edge: .bottom)
                        }
                        .onChange(of: presentation.approvalID) { _, _ in if followLatest && !userScrolling { scrollPosition.scrollTo(edge: .bottom) } }
                        .onChange(of: followLatest) { _, follows in
                            // Drop a programmatic target when reading history,
                            // leaving layout changes and bounce under user control.
                            if !follows { scrollPosition = ScrollPosition() }
                        }
                        .task(id: presentation.activityNavigation?.id) {
                            // Every entry and repeated deep link targets the tail.
                            // Use the scroll view's bound edge, which remains
                            // addressable when LazyVStack has unloaded the tail.
                            followLatest = true
                            deferredViewportShift = 0
                            await Task.yield()
                            guard !Task.isCancelled else { return }
                            scrollPosition.scrollTo(edge: .bottom)
                        }

                    }
                }
                .safeAreaBar(edge: .bottom, spacing: 0) { composer }
                .navigationTitle(session.title).navigationBarTitleDisplayMode(.inline)
                .sheet(isPresented: $browsingModels) {
                    if let profile = presentation.selectedProvider {
                        ProviderModelPicker(profile: profile) { presentation.selectModel($0) }
                    }
                }
                .onAppear { presentation.open(); draft = session.draft }
                .onDisappear { sendingTask?.cancel(); presentation.close() }
                .onChange(of: draft) { _, text in presentation.saveDraft(text) }
            } else { ContentUnavailableView(String(localized: "Conversation deleted"), systemImage: "bubble.left") }
        }
        .environment(\.conversationDisclosureChanged, {
            followLatest = false
        })
    }
    @ViewBuilder private func messageStack(_ session: AgentConversation) -> some View {
        if presentation.activeTurnID != nil {
            LazyVStack(alignment: .leading, spacing: 12) { messageRows(session) }
        } else {
            // Completed turns are folded and short. Eager layout avoids keeping
            // an expanded lazy stack's stale geometry after foreground cleanup.
            VStack(alignment: .leading, spacing: 12) { messageRows(session) }
        }
    }
    @ViewBuilder private func messageRows(_ session: AgentConversation) -> some View {
        if presentation.awaitingTaskConfirmation {
            VStack(alignment: .leading, spacing: 12) {
                Label(String(localized: "Siri · Awaiting confirmation"), systemImage: "waveform").font(.headline)
                Text(String(localized: "Review or edit the text below, then choose “Confirm and start”."))
                    .foregroundStyle(.secondary)
                Text(session.draft).textSelection(.enabled).accessibilityIdentifier("siriRecognizedTask")
                Button(String(localized: "Discard this draft"), role: .cancel) {
                    presentation.dismissPreparedTask()
                    if !presentation.awaitingTaskConfirmation { draft = "" }
                }.accessibilityIdentifier("dismissSiriTask")
            }.padding(.vertical, 20)
        } else if session.messages.isEmpty { welcome(session.mode) }
        ForEach(ConversationTurn.group(session.messages)) { turn in
            if let runID = turn.runID, runID == presentation.activeTurnID {
                ForEach(turn.messages) { message in messageView(message).id(message.id) }
            } else {
                completedTurn(turn)
            }
        }
        if running && presentation.pendingApproval == nil { HStack(spacing: 8) { ProgressView().controlSize(.small); Text(presentation.status).font(.caption).foregroundStyle(.secondary) } }
        Color.clear.frame(height: 1).id("latest")
            .onScrollVisibilityChange(threshold: 0.01) { visible in
                lastMessageVisible = visible
                if userScrolling { followLatest = visible }
            }
    }
    private var scrollDiagnostic: String {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--ui-test-conversation-navigation"),
           let session, let runID = session.messages.first(where: { $0.runID != nil })?.runID {
            return AgentActivityRoute(sessionID: session.id, runID: runID).url.absoluteString
        }
        #endif
        return viewportDiagnostic
    }
    private var modelMenuOptions: [String] {
        var models = Array(presentation.availableModels.prefix(12))
        let selected = presentation.selectedModel
        if !selected.isEmpty, !models.contains(selected) { models.append(selected) }
        return models
    }
    private var modelPicker: some View {
        Button { showingModelSettings = true } label: {
            HStack(spacing: 4) {
                Text(presentation.modelName).lineLimit(1)
                if let effort = presentation.reasoningEffort { Text(ReasoningEffortLabel.title(effort)).foregroundStyle(.secondary) }
                Image(systemName: "chevron.down").imageScale(.small).accessibilityHidden(true)
            }
        }
        .disabled(running || presentation.stopping)
        .accessibilityIdentifier("conversationModelPicker")
        .popover(isPresented: $showingModelSettings, arrowEdge: .bottom) {
            modelSettingsPanel
                .presentationCompactAdaptation(.popover)
        }
    }
    private var modelSettingsPanel: some View {
        VStack(spacing: 0) {
            Menu {
                ForEach(presentation.providers) { provider in
                    Button { presentation.selectProvider(provider.id) } label: {
                        Text(provider.name + (provider.id == presentation.providerID ? "  ✓" : ""))
                    }
                }
            } label: {
                modelSettingRow(String(localized: "Provider"), value: presentation.selectedProvider?.name ?? String(localized: "Not selected"))
            }.accessibilityIdentifier("conversationProviderRow")
                .accessibilityLabel(String(localized: "Provider"))
                .accessibilityValue(presentation.selectedProvider?.name ?? String(localized: "Not selected"))
            Divider()
            Menu {
                ForEach(modelMenuOptions, id: \.self) { name in
                    Button { presentation.selectModel(name) } label: {
                        Text(name + (name == presentation.selectedModel ? "  ✓" : ""))
                    }
                }
                Button(String(localized: "Browse all models")) {
                    showingModelSettings = false
                    browsingModels = true
                }
            } label: {
                modelSettingRow(String(localized: "Model"), value: presentation.modelName)
            }.disabled(presentation.providerID == nil)
                .accessibilityIdentifier("conversationModelRow")
                .accessibilityLabel(String(localized: "Model"))
                .accessibilityValue(presentation.modelName)
            Divider()
            Menu {
                Button(reasoningDefaultLabel) { presentation.selectReasoningEffort(nil) }
                ForEach(presentation.reasoningMetadata?.reasoningEfforts ?? [], id: \.self) { effort in
                    Button { presentation.selectReasoningEffort(effort) } label: {
                        Text(ReasoningEffortLabel.title(effort) + (effort == presentation.reasoningEffort ? "  ✓" : ""))
                    }
                }
            } label: {
                modelSettingRow(String(localized: "Reasoning effort"), value: presentation.reasoningEffort.map(ReasoningEffortLabel.title) ?? reasoningDefaultLabel)
            }.disabled(!presentation.canChangeReasoningEffort || presentation.providerID == nil)
                .accessibilityIdentifier("conversationReasoningEffort")
                .accessibilityLabel(String(localized: "Reasoning effort"))
                .accessibilityValue(presentation.reasoningEffort.map(ReasoningEffortLabel.title) ?? reasoningDefaultLabel)
        }
        .menuOrder(.fixed)
        .buttonStyle(.plain)
        .font(.subheadline)
        .padding(.horizontal, 16)
        .frame(width: 340)
        .disabled(running || presentation.stopping)
    }
    private var reasoningDefaultLabel: String {
        presentation.reasoningMetadata?.defaultReasoningEffort.map { String(localized: "Provider default (\(ReasoningEffortLabel.title($0)))") } ?? String(localized: "Provider default")
    }
    private func modelSettingRow(_ title: String, value: String) -> some View {
        HStack(spacing: 16) {
            Text(title).foregroundStyle(.primary)
            Spacer(minLength: 8)
            Text(value).lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary)
            Image(systemName: "chevron.up.chevron.down")
                .font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                .accessibilityHidden(true)
        }
        .padding(.vertical, 16)
        .contentShape(Rectangle())
    }
    private func welcome(_ mode: RunMode) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            Image(systemName: "sparkles").font(.largeTitle).foregroundStyle(.blue).padding(.top, 34)
            Text(String(localized: "What can we accomplish together?")).font(.title2.bold())
            Text(mode == .demo ? String(localized: "This conversation uses a fixed script to demonstrate viewing the screen, approving a tap, and checking the result.") : String(localized: "Describe your question or goal. Agent replies and tool activity will be kept here."))
                .foregroundStyle(.secondary)
            Button(mode == .demo ? String(localized: "Try a complete demo") : String(localized: "Help me outline the steps for a task")) {
                draft = mode == .demo ? String(localized: "View the demo screen, tap the counter once, then check the result") : String(localized: "Help me outline the steps for a task")
                focused = true
            }.buttonStyle(.bordered).accessibilityIdentifier("suggestedPrompt")
        }.padding(.bottom, 24)
    }
    private func completedTurn(_ turn: ConversationTurn) -> some View {
        let folded = turn.foldedMessages
        let foldedIDs = Set(folded.map(\.id))
        return VStack(alignment: .leading, spacing: 12) {
            ForEach(turn.messages) { message in
                if message.id == folded.first?.id {
                    ConversationDisclosureGroup {
                        VStack(alignment: .leading, spacing: 12) {
                            ForEach(folded) { item in
                                if let reasoning = item.reasoning, !reasoning.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                    ReasoningMessageView(reasoning: reasoning, messageID: item.id)
                                }
                                if item.role != .assistant || item.id != folded.last?.id {
                                    messageView(item, includeReasoning: false).id(item.id)
                                }
                            }
                        }.padding(.top, 8)
                    } label: {
                        HStack(spacing: 8) {
                            MessageHeaderIcon(systemName: "text.bubble")
                            Text(turn.summaryLabel)
                        }
                    }
                }
                if !foldedIDs.contains(message.id) || (message.id == folded.last?.id && message.role == .assistant) {
                    if message.role != .tool && (message.role != .assistant || !message.text.isEmpty || message.attachments?.isEmpty == false || message.state == .interrupted || message.state == .failed) {
                        messageView(message, includeReasoning: false).id(message.id)
                    }
                }
            }
        }
    }
    @ViewBuilder private func messageView(_ message: ChatMessage, includeReasoning: Bool = true) -> some View {
        switch message.role {
        case .user:
            VStack(alignment: .trailing, spacing: 8) {
                HStack { Spacer(minLength: 36); Text(message.text).textSelection(.enabled).padding(12).background(.blue.opacity(0.10), in: RoundedRectangle(cornerRadius: 18)).foregroundStyle(.primary) }
                MessageAttachmentsView(message: message, presentation: presentation)
            }
        case .assistant:
            VStack(alignment: .leading, spacing: 6) {
                if includeReasoning, let reasoning = message.reasoning, !reasoning.text.isEmpty {
                    ReasoningMessageView(reasoning: reasoning, messageID: message.id)
                }
                if !message.text.isEmpty {
                    Markdown(message.text).markdownTheme(.basic)
                        .markdownImageProvider(NoRemoteMarkdownImages()).markdownInlineImageProvider(NoRemoteInlineImages())
                        .textSelection(.enabled)
                } else if message.state == .streaming && message.reasoning == nil { Text(String(localized: "Preparing a reply…")).foregroundStyle(.secondary) }
                if message.state == .interrupted { Text(message.text.isEmpty && message.reasoning != nil ? String(localized: "Reasoning interrupted") : String(localized: "Reply interrupted")).font(.caption).foregroundStyle(.secondary) }
                if message.state == .failed { Text(String(localized: "Reply incomplete")).font(.caption).foregroundStyle(.secondary) }
                MessageAttachmentsView(message: message, presentation: presentation)
            }.frame(maxWidth: .infinity, alignment: .leading)
        case .tool:
            if let item = presentation.presentation(for: message) {
                ToolInvocationView(configuration: ToolInvocationConfiguration(tool: item.tool)) { toolPreview(item) }
            }
        case .notice:
            Text(message.text)
                .font(.footnote).foregroundStyle(.secondary).textSelection(.enabled)
                .padding(.vertical, 2).frame(maxWidth: .infinity, alignment: .leading)
        }
    }
    private var composer: some View {
        VStack(spacing: 10) {
            if let item = presentation.pendingApproval, let request = item.approval {
                ToolApprovalCard(configuration: ToolInvocationConfiguration(tool: item.tool,
                    onApprove: { _ = presentation.dispatch(.approve(step: item.identity, approvalID: request.id)) },
                    onDeny: { _ = presentation.dispatch(.deny(step: item.identity, approvalID: request.id)) })) {
                    toolPreview(item)
                }.id(request.id)
            }
            if let warning = presentation.warning { Text(warning).font(.caption).foregroundStyle(.orange) }
            if let attachmentFailure { Text(attachmentFailure).font(.caption).foregroundStyle(.orange).accessibilityIdentifier("attachmentFailure") }
            if importingAttachments || sendingAttachments {
                HStack {
                    ProgressView(importingAttachments ? String(localized: "Copying attachments to this device…") : String(localized: "Preparing attachments…"))
                    Button(String(localized: "Cancel")) { importCancellation += 1; sendingTask?.cancel() }
                }.font(.caption)
            }
            if let assets = session?.draftAttachments, !assets.isEmpty {
                ScrollView(.horizontal) {
                    HStack(alignment: .top, spacing: 12) {
                        ForEach(assets) { asset in
                            VStack(alignment: .leading, spacing: 5) {
                                AttachmentThumbnail(attachment: asset, store: presentation.attachments, conversationID: presentation.sessionID)
                                    .frame(width: 100, height: 90).clipped()
                                Button(String(localized: "Remove"), systemImage: "xmark.circle") { presentation.removeAttachment(asset.id) }
                                    .font(.caption).disabled(running || sendingAttachments)
                                    .accessibilityIdentifier("removeAttachment-" + asset.id.uuidString)
                            }
                        }
                    }
                }.accessibilityIdentifier("draftAttachments")
                Text(String(localized: "Images and text will be sent to the current model after you send the message. Supports single-frame images up to 20 MiB and UTF-8 TXT/MD/JSON/CSV up to 256 KiB; PDF and Office files are not supported. Images are sent at a maximum dimension of 2,048 pixels. Originals stay on this device."))
                    .font(.caption2).foregroundStyle(.secondary)
            }
            VStack(spacing: 0) {
                HStack(alignment: .center, spacing: 4) {
                    if !focused { attachmentButton }
                    messageField
                    if !focused { sendButton }
                }
                .padding(.leading, focused ? 10 : 4)
                .padding(.trailing, focused ? 10 : 9)
                if focused {
                    HStack(spacing: 8) {
                        attachmentButton
                        Spacer(minLength: 0)
                        if session?.mode != .demo { modelPicker.font(.caption).foregroundStyle(.secondary) }
                        sendButton
                    }.padding(.leading, 4).padding(.trailing, 8)
                }
            }.padding(.vertical, 6)
                .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 24))
        }.padding(.horizontal, 16).padding(.top, 10).padding(.bottom, 8)
    }
    private var attachmentButton: some View {
        AttachmentPicker(presentation: presentation, busy: $importingAttachments, failure: $attachmentFailure, cancellation: $importCancellation)
            .disabled(sendingAttachments)
    }
    private var messageField: some View {
        ZStack(alignment: .topLeading) {
            if draft.isEmpty {
                Text(String(localized: "Type anything")).foregroundStyle(.tertiary).padding(.vertical, 10)
                    .allowsHitTesting(false).accessibilityHidden(true)
            }
            MessageInput(text: $draft, focused: $focused, disabled: running || presentation.stopping || sendingAttachments, onSubmit: send)
        }
    }
    @ViewBuilder private var sendButton: some View {
        if running {
            Button { if let run = presentation.activeRun { presentation.dispatch(.stop(run: run)) } } label: { Image(systemName: "stop.fill").font(.body.bold()).frame(width: 38, height: 38).background(Color(uiColor: .label), in: Circle()).foregroundStyle(Color(uiColor: .systemBackground)) }
                .accessibilityLabel(String(localized: "Stop execution")).accessibilityIdentifier("stopRun")
        } else if presentation.awaitingTaskConfirmation {
            Button(String(localized: "Confirm and start")) { sendConfirmedTask() }
                .buttonStyle(.borderedProminent).disabled(!canSend)
                .accessibilityIdentifier("confirmSiriTask")
        } else {
            Button { send() } label: { Image(systemName: "arrow.up").font(.body.bold()).frame(width: 38, height: 38).background(.blue, in: Circle()).foregroundStyle(.white) }
                .disabled(!canSend)
                .accessibilityLabel(String(localized: "Send")).accessibilityIdentifier("sendMessage")
        }
    }
    @ViewBuilder private func toolPreview(_ item: ToolPresentation) -> some View {
        if !item.attachments.isEmpty, item.approval == nil {
            ForEach(item.attachments) { attachment in
                AttachmentThumbnail(attachment: attachment, store: presentation.attachments, conversationID: presentation.sessionID)
            }
        } else if let image = item.image, let uiImage = UIImage(data: image.png) {
            Image(uiImage: uiImage).resizable().scaledToFit().frame(maxHeight: 280)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .accessibilityLabel(image.isDemo ? String(localized: "Synthetic demo screen, not a device screenshot") : String(localized: "Device screenshot for the current step"))
        } else if item.tool.name == "screenshot", item.tool.state == .succeeded {
            Text(String(localized: "This historical screenshot has no saved local original and cannot be recovered from the tool record.")).font(.caption).foregroundStyle(.secondary)
        }
    }
    private func send() {
        guard !presentation.awaitingTaskConfirmation else { return }
        sendConfirmedTask()
    }
    private func sendConfirmedTask() {
        guard canSend else { return }
        // The Send button and keyboard submission both authorize this request.
        if session?.draftAttachments?.isEmpty != false {
            if presentation.dispatch(.send(sessionID: presentation.sessionID, text: draft, cloudConsent: true)) {
                draft = ""; focused = false; followLatest = true
            }
            return
        }
        sendingAttachments = true; attachmentFailure = nil
        let text = draft
        sendingTask = Task { @MainActor in
            defer { sendingAttachments = false }
            do {
                if try await presentation.sendDraft(text) { draft = ""; focused = false; followLatest = true }
            } catch { if !Task.isCancelled { attachmentFailure = error.localizedDescription } }
        }
    }
}

/// A multiline composer whose Return key submits while preserving multiline
/// text insertion and input-method composition.
private struct MessageInput: UIViewRepresentable {
    @Binding var text: String
    @Binding var focused: Bool
    let disabled: Bool
    let onSubmit: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.delegate = context.coordinator
        view.backgroundColor = .clear
        view.font = .preferredFont(forTextStyle: .body)
        view.adjustsFontForContentSizeCategory = true
        view.textColor = .label
        view.textContainerInset = UIEdgeInsets(top: 10, left: 0, bottom: 10, right: 0)
        view.textContainer.lineFragmentPadding = 0
        view.returnKeyType = .send
        view.enablesReturnKeyAutomatically = true
        view.accessibilityLabel = String(localized: "Type anything")
        view.accessibilityIdentifier = "messageInput"
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return view
    }
    func updateUIView(_ view: UITextView, context: Context) {
        context.coordinator.parent = self
        if view.text != text, view.markedTextRange == nil { view.text = text }
        view.isEditable = !disabled
        view.isUserInteractionEnabled = !disabled
        let coordinator = context.coordinator
        if focused && !disabled && !view.isFirstResponder {
            DispatchQueue.main.async { [weak view] in
                guard coordinator.parent.focused, !coordinator.parent.disabled, view?.window != nil else { return }
                view?.becomeFirstResponder()
            }
        } else if (!focused || disabled) && view.isFirstResponder {
            DispatchQueue.main.async { [weak view] in
                guard !coordinator.parent.focused || coordinator.parent.disabled else { return }
                view?.resignFirstResponder()
            }
        }
    }
    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UITextView, context: Context) -> CGSize? {
        guard let width = proposal.width, width > 0 else { return nil }
        let lineHeight = uiView.font?.lineHeight ?? 20
        let insets = uiView.textContainerInset.top + uiView.textContainerInset.bottom
        let height = uiView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height
        return CGSize(width: width, height: min(max(height, lineHeight + insets), lineHeight * 5 + insets))
    }
    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: MessageInput
        init(_ parent: MessageInput) { self.parent = parent }
        func textViewDidChange(_ textView: UITextView) { parent.text = textView.text }
        func textViewDidBeginEditing(_ textView: UITextView) {
            if !parent.focused { parent.focused = true }
        }
        func textViewDidEndEditing(_ textView: UITextView) {
            if parent.focused { parent.focused = false }
        }
        func textView(_ textView: UITextView, shouldChangeTextIn range: NSRange, replacementText text: String) -> Bool {
            guard text == "\n", textView.markedTextRange == nil else { return true }
            if !parent.disabled { parent.onSubmit() }
            return false
        }
    }
}

private struct NoRemoteMarkdownImages: MarkdownUI.ImageProvider {
    func makeImage(url: URL?) -> some View { Text(String(localized: "See image below")).font(.caption).foregroundStyle(.secondary) }
}
private struct NoRemoteInlineImages: MarkdownUI.InlineImageProvider {
    func image(with url: URL, label: String) async throws -> Image { Image(systemName: "photo") }
}
