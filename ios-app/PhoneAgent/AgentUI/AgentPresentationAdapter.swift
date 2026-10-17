import Foundation
import Combine
import SwiftAgentKit

/// App-owned display boundary. Views send scoped intents; they never receive an
/// Agent, a provider, a transport, or an approval continuation.
enum AgentUIIntent {
    case send(sessionID: UUID, text: String, cloudConsent: Bool)
    case approve(step: StepIdentity, approvalID: UUID)
    case deny(step: StepIdentity, approvalID: UUID)
    case stop(run: RunIdentity)
}

struct ToolPresentation {
    let identity: StepIdentity
    let tool: ToolStep
    let approval: Approval?
    let image: FrameImage?
    let attachments: [StoredAttachment]
}

@MainActor final class AgentPresentationAdapter: ObservableObject {
    private let model: AgentViewModel
    private let navigationModel: AgentViewModel
    let sessionID: UUID
    private var subscriptions = Set<AnyCancellable>()
    @Published private(set) var activityNavigation: ActivityNavigation?

    init(model: AgentViewModel, sessionID: UUID) {
        self.navigationModel = model; self.model = model.executionModel(for: sessionID); self.sessionID = sessionID
        self.model.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &subscriptions)
        model.$activityNavigation
            .map { $0.flatMap { $0.route.sessionID == sessionID ? $0 : nil } }
            .removeDuplicates()
            .sink { [weak self] in self?.activityNavigation = $0 }.store(in: &subscriptions)
        model.sessions.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &subscriptions)
    }

    var session: AgentConversation? { model.sessions.conversation(sessionID) }
    var activeTurnID: UUID? { model.sessions.activeRuns[sessionID]?.runID }
    var activeRun: RunIdentity? { model.ownedRun.flatMap { $0.conversationID == sessionID ? $0 : nil } }
    var backgroundStatus: String { model.backgroundStatus }
    var running: Bool { activeRun != nil && model.running }
    var stopping: Bool { model.stopping }
    var status: String { running ? model.status : session?.phase.label ?? "" }
    var warning: String? { model.errorMessage ?? model.sessions.warning }
    var providers: [ProviderProfile] { model.providers.profiles }
    var providerID: UUID? { model.selectedProvider(in: sessionID)?.id }
    var selectedModel: String { model.selectedModel(in: sessionID) }
    var availableModels: [String] { model.selectedProvider(in: sessionID)?.availableModels ?? [] }
    var selectedProvider: ProviderProfile? { model.selectedProvider(in: sessionID) }
    var attachments: AttachmentStore { model.attachments }
    func importAttachment(data: Data, name: String) async throws { try await model.importDraftAttachment(data: data, name: name, in: sessionID) }
    func importAttachment(file: URL) async throws { try await model.importDraftAttachment(file: file, in: sessionID) }
    func removeAttachment(_ id: UUID) { model.sessions.removeDraftAttachment(id, in: sessionID) }
    func sendDraft(_ text: String) async throws -> Bool { try await model.sendDraft(text, in: sessionID, cloudConsent: true) }
    func cacheImage(_ url: URL, messageID: UUID) async throws -> StoredAttachment {
        try await model.cacheMessageImage(url, messageID: messageID, conversationID: sessionID)
    }
    var modelName: String { selectedModel.isEmpty ? String(localized: "Choose a provider and model") : selectedModel }
    func selectProvider(_ id: UUID) { model.selectProvider(id, in: sessionID) }
    func selectModel(_ name: String) { model.selectModel(name, in: sessionID) }
    var reasoningMetadata: DiscoveredModel? { selectedProvider?.metadata(for: selectedModel) }
    var reasoningEffort: String? { selectedProvider?.parameters(for: selectedModel).reasoningEffort }
    var canChangeReasoningEffort: Bool { !navigationModel.hasBusySessions }
    func selectReasoningEffort(_ effort: String?) { model.selectReasoningEffort(effort, in: sessionID) }
    var approvalID: UUID? { model.approval(in: sessionID)?.id }
    var pendingApproval: ToolPresentation? {
        guard let messages = session?.messages else { return nil }
        return messages.reversed().lazy.compactMap { self.presentation(for: $0) }.first { $0.approval != nil }
    }

    func open() { navigationModel.selectConversation(sessionID) }
    func close() { navigationModel.leaveConversation(sessionID) }
    var awaitingTaskConfirmation: Bool { session?.entry?.state == .pendingConfirmation }
    func dismissPreparedTask() {
        do { try model.sessions.dismissPreparedTask(in: sessionID) }
        catch { model.errorMessage = error.localizedDescription }
    }
    func saveDraft(_ text: String) { model.sessions.setDraft(text, in: sessionID) }

    func presentation(for message: ChatMessage) -> ToolPresentation? {
        guard let runID = message.runID, let tool = message.tool else { return nil }
        let step = StepIdentity(run: RunIdentity(conversationID: sessionID, runID: runID), stepID: tool.callID)
        let approval = activeRun == step.run && tool.state == .awaitingApproval
            ? model.approval(in: sessionID).flatMap { $0.callID == step.stepID ? $0 : nil } : nil
        let frame = model.latestFrame
        let image: FrameImage?
        if let frame, frame.step == step { image = frame.image }
        else if let frame, frame.step.run == step.run, approval?.imageID == frame.image.id { image = frame.image }
        else { image = nil }
        return ToolPresentation(identity: step, tool: tool, approval: approval, image: image, attachments: message.attachments ?? [])
    }

    @discardableResult func dispatch(_ intent: AgentUIIntent) -> Bool {
        guard navigationModel.selectedConversationID == sessionID else { return false }
        switch intent {
        case .send(let id, let text, let consent):
            guard id == sessionID else { return false }
            return model.send(text, in: id, cloudConsent: consent)
        case .approve(let step, let id), .deny(let step, let id):
            guard step.run == activeRun, let request = model.approval(in: sessionID),
                  request.id == id, request.callID == step.stepID else { return false }
            if case .approve = intent { model.approve(true, approvalID: id, conversationID: sessionID) }
            else { model.approve(false, approvalID: id, conversationID: sessionID) }
            return true
        case .stop(let run):
            guard run == activeRun else { return false }
            model.stop(); return true
        }
    }
}

/// Receives the FIFO stream from the actual SwiftAgentKit run. No Manifold
/// runtime/progress consumer is involved. Approval/transport callbacks carry
/// the same run token and update the same step in ConversationStore.
@MainActor enum AgentEventProjection {
    static func record(_ event: AgentEvent, run: RunIdentity, frame: PresentedFrame?, in store: ConversationStore, skillNames: [String: String] = [:]) {
        guard store.accepts(run) else { return }
        func skillName(_ call: AgentToolCall) -> String? {
            guard call.name == "load_skill", let id = call.parameters["id"]?.value as? String else { return nil }
            return skillNames[id.uppercased()]
        }
        switch event {
        case .llmCallStarted: store.beginAssistantTurn(run)
        case .streamChunk(let text): store.appendText(text, identity: run)
        case .reasoningChunk(let text): store.appendReasoning(text, identity: run)
        case .llmCallCompleted(_, let response): store.completeAssistantTurn(response.text, reasoning: response.reasoning, identity: run)
        case .toolCallsReceived(let calls):
            for call in calls {
                store.updateTool(callID: call.id, name: call.name, state: .requested, arguments: arguments(for: call), skillName: skillName(call), identity: run)
            }
        case .toolExecutionStarted(let call):
            store.updateTool(callID: call.id, name: call.name, state: .running, arguments: arguments(for: call), skillName: skillName(call), identity: run)
        case .toolExecutionFinished(let call, let result):
            store.updateTool(callID: call.id, name: call.name, state: result.isError ? .failed : .succeeded,
                result: result.result, arguments: arguments(for: call), skillName: skillName(call), identity: run)
        default: break // Unrelated framework events stay out of UI/history.
        }
    }

    static func arguments(for call: AgentToolCall) -> String? {
        guard !call.parameters.isEmpty else { return nil }
        let allowed: [String]
        switch call.name {
        case "screenshot": allowed = []
        case "tap": allowed = ["x", "y", "purpose"]
        case "drag": allowed = ["from_x", "from_y", "to_x", "to_y", "duration_ms", "purpose"]
        case "wait": allowed = ["duration_ms"]
        case "finish": allowed = ["summary"]
        case "load_skill": allowed = ["id", "revision", "resource", "offset"]
        default: return String(localized: "Unregistered tool. Raw arguments are hidden.")
        }
        var values: [String: Any] = [:]
        for key in allowed {
            guard let value = call.parameters[key]?.value else { continue }
            if let string = value as? String { values[key] = String(string.prefix(key == "summary" ? 1_000 : 160)) }
            else if let number = value as? NSNumber, number.doubleValue.isFinite { values[key] = number }
            else { values[key] = String(localized: "Unsupported argument type") }
        }
        guard let data = try? JSONSerialization.data(withJSONObject: values, options: [.sortedKeys, .prettyPrinted]),
              let text = String(data: data, encoding: .utf8) else { return String(localized: "Arguments could not be displayed") }
        return ToolStep.nonemptyArguments(text)
    }
}
