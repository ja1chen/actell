#if DEBUG
import Foundation
import AgentKit
import ProviderCore

/// Explicit acceptance probe. Only synthetic conversation data enters its private cache.
/// Exportable reports contain counts, capabilities, usage and assertion results.
@MainActor enum AgentLiveValidation {
    private static var started = false
    private static var work: Task<Void, Never>?
    private static var isChatValidation: Bool { ProcessInfo.processInfo.arguments.contains("--agentkit-live-validation-deepseek") }
    private static var reportRoot: URL { URL.documentsDirectory.appending(path: isChatValidation ? "AgentKitChatValidation" : "AgentKitValidation", directoryHint: .isDirectory) }
    private static var privateRoot: URL { URL.cachesDirectory.appending(path: isChatValidation ? "AgentKitChatLiveValidation" : "AgentKitLiveValidation", directoryHint: .isDirectory) }
    private struct SavedRun: Codable {
        let sessionID: UUID
        let profileID: UUID
        let modelID: String
        let marker: String
    }
    private struct Report: Codable {
        var phase = "starting"
        var status = "running"
        var modelID: String?
        var providerKind = "chatGPTSubscription"
        var wire = "responses"
        var appModelAdmission = "notChecked"
        var textDeltaCount = 0
        var reasoningDeltaCount = 0
        var cacheUsageReported = false
        var cacheHitObserved = false
        var reasoningContentReplayCapability = false
        var reasoningEffortOverride = "providerDefault"
        var rawReasoningReplayObserved = false
        var rawReasoningStatesInReopenedContext = 0
        var serverChain = "unsupported"
        var nativeCompaction = "unsupported"
        var savedProfileCount = 0
        var turnsCompleted = 0
        var modelOutputInferenceCount = 0
        var syntheticToolCalls: Int?
        var toolTurnAuthoritativeResponses: Int?
        var durableSyntheticToolResults: Int?
        var modelOutputUsage: [ModelUsage] = []
        var assertions: [String: Bool] = [:]
        var historyCount: Int?
        var contextCount: Int?
        var compactionMethod: String?
        var compactionSourceRevision: Int?
        var compactionTargetRevision: Int?
        var beforeTokens: Int?
        var afterTokens: Int?
        var failureCode: String?
    }
    private actor LookupCounter {
        private var value = 0
        func record() { value += 1 }
        func count() -> Int { value }
    }
    private enum ProbeFailure: Error { case missingProfile, missingCatalogModel, missingAccount, failedTurn, timedOut, missingRun, wrongBinding, assertionFailed }

    /// Starts an independent task so the existing launch task and UI remain available.
    static func runIfRequested() {
        guard ProcessInfo.processInfo.arguments.contains("--agentkit-live-validation"), !started else { return }
        started = true
        work = Task { await run(reopen: ProcessInfo.processInfo.arguments.contains("--agentkit-live-validation-reopen")) }
    }
    private static func save(_ report: Report, name: String = "status") throws {
        try FileManager.default.createDirectory(at: reportRoot, withIntermediateDirectories: true)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(report).write(to: reportRoot.appending(path: name + ".json"), options: [.atomic, .completeFileProtection])
    }
    private static func run(reopen: Bool) async {
        var report = Report()
        report.providerKind = isChatValidation ? "openAI-compatible" : "chatGPTSubscription"
        report.wire = isChatValidation ? "chatCompletions" : "responses"
        var provider: (any CancellableModelProvider)?
        do {
            try save(report)
            let profiles = ProviderStore()
            report.savedProfileCount = profiles.profiles.count
            let savedURL = privateRoot.appending(path: "run.json")
            let saved: SavedRun
            let profile: ProviderProfile
            if reopen {
                guard FileManager.default.fileExists(atPath: savedURL.path) else { throw ProbeFailure.missingRun }
                saved = try JSONDecoder().decode(SavedRun.self, from: Data(contentsOf: savedURL))
                guard let existing = profiles.profile(saved.profileID), matchesProfile(existing) else { throw ProbeFailure.wrongBinding }
                profile = existing
            } else {
                guard let existing = profiles.profiles.first(where: { value in
                    matchesProfile(value) && (isChatValidation || value.settings.model.lowercased().contains("luna"))
                }) else { throw ProbeFailure.missingProfile }
                profile = existing
                let remembered = profiles.lastSelection.flatMap { $0.providerID == profile.id && (isChatValidation || $0.model.lowercased().contains("luna")) ? $0.model : nil } ?? profile.settings.model
                saved = .init(sessionID: UUID(), profileID: profile.id, modelID: remembered, marker: "orchid-" + UUID().uuidString.lowercased())
            }
            guard profile.currentCatalog?.models.contains(where: { $0.id == saved.modelID }) == true else { throw ProbeFailure.missingCatalogModel }
            report.modelID = saved.modelID
            do { try profile.requireInference(model: saved.modelID); report.appModelAdmission = "passed" }
            catch { report.appModelAdmission = "rejected"; throw error }
            report.assertions["savedModelPassedAppAdmission"] = true
            report.reasoningEffortOverride = profile.parameters(for: saved.modelID).values["reasoning_effort"] ?? "providerDefault"
            let cloud: any CancellableModelProvider
            let replayScope: ProviderReplayScope
            if isChatValidation {
                var settings = profile.settings; settings.model = saved.modelID
                let key = try SecretStore.load(profile.keyAccount) ?? ""
                let compatible = try PrivateVisionProvider(settings: settings, apiKey: key, limits: .init(),
                    providerKind: profile.providerKind, parameters: profile.parameters(for: saved.modelID), metadata: profile.metadata(for: saved.modelID),
                    inferenceAPI: .chatCompletions, contextPolicy: .stateless, accountReference: profile.keyAccount, sessionID: saved.sessionID)
                cloud = compatible; replayScope = compatible.replayScope
            } else {
                guard let account = profile.chatGPTAccountReference,
                      try await ChatGPTAccountManager.shared.selectedAccount(profileID: profile.id) == account else { throw ProbeFailure.missingAccount }
                let subscription = try ChatGPTSubscriptionProvider(profile: profile, model: saved.modelID, account: account, sessionID: saved.sessionID)
                cloud = subscription; replayScope = subscription.replayScope
            }
            provider = cloud
            let capabilities = try await cloud.capabilities(for: saved.modelID)
            report.reasoningContentReplayCapability = capabilities.chatReasoningContentReplay
            report.serverChain = capabilities.responseChain ? "supported" : "unsupported"
            report.nativeCompaction = capabilities.compaction ? "supported" : "unsupported"
            report.assertions[isChatValidation ? "chatServerModeNotClaimed" : "subscriptionServerModeRejected"] = !capabilities.responseChain
            report.assertions[isChatValidation ? "chatNativeCompactNotClaimed" : "subscriptionNativeCompactNotClaimed"] = !capabilities.compaction
            let root = privateRoot.appending(path: saved.sessionID.uuidString, directoryHint: .isDirectory)
            let configuration = AgentConfiguration(model: saved.modelID,
                instructions: "This is a synthetic conversation continuity validation. No tools are available. Reply briefly. Preserve exact validation codes when summarizing historical facts.",
                scope: replayScope, budget: .init(planningTokens: 131072, outputReserve: 2048, toolResultReserve: 0), maximumInferences: 1)
            var store = JSONLSessionStore(root: root, sessionID: saved.sessionID, requireExistingHistory: reopen)
            // Existing synthetic runs exercise the same format conversion as
            // App sessions before a new runtime restores their context.
            try store.migrateLegacySync { _ in throw StoreError.unsupportedSchema }
            var runtime = AgentRuntime(store: store, provider: cloud, configuration: configuration)
            if !reopen {
                try FileManager.default.createDirectory(at: privateRoot, withIntermediateDirectories: true)
                try JSONEncoder().encode(saved).write(to: savedURL, options: [.atomic, .completeFileProtection])
                _ = try await runtime.createSession(id: saved.sessionID)
                for index in 0..<6 {
                    report.phase = "local-turn-\(index + 1)"; try save(report)
                    let fact = index == 0 ? "The exact synthetic validation code is \(saved.marker). Preserve it verbatim in every later memory summary." : "The validation code remains unchanged."
                    let filler = String(repeating: "Synthetic ledger entry \(index): only conversation continuity is under test; no device action, credentials or real user data are involved. ", count: 60)
                    _ = try await turn(runtime, provider: cloud, session: saved.sessionID,
                        text: fact + "\n" + filler + "\nReply only ACK.", report: &report)
                }
                report.phase = "portable-compaction"; try save(report)
                let historyBefore = try await store.readPage(.init(sessionID: saved.sessionID, limit: 1000))
                let compactingRuntime = runtime
                let operation = Task { try await compactingRuntime.compactSession(saved.sessionID, strategy: .portable) }
                let timeout = Task {
                    do { try await Task.sleep(for: .seconds(180)); operation.cancel(); cloud.cancel() } catch {}
                }
                let outcome: CompactionOutcome
                do { outcome = try await operation.value; timeout.cancel() }
                catch { timeout.cancel(); throw error }
                report.compactionMethod = outcome.method.rawValue
                report.compactionSourceRevision = outcome.sourceRevision; report.compactionTargetRevision = outcome.targetRevision
                report.beforeTokens = outcome.beforeTokens; report.afterTokens = outcome.afterTokens
                report.assertions["portableCompactionCommitted"] = outcome.method == .portable && outcome.targetRevision > outcome.sourceRevision
                report.assertions["compactionReducedContext"] = outcome.afterTokens < outcome.beforeTokens
                let historyAfter = try await store.readPage(.init(sessionID: saved.sessionID, limit: 1000))
                report.assertions["compactionPreservedHistory"] = historyBefore.items == historyAfter.items
                report.historyCount = historyAfter.items.count
                guard report.assertions.values.allSatisfy({ $0 }) else { throw ProbeFailure.assertionFailed }
                // A new store and runtime reload the authoritative compacted journal.
                store = JSONLSessionStore(root: root, sessionID: saved.sessionID)
                runtime = AgentRuntime(store: store, provider: cloud, configuration: configuration)
            }
            if reopen {
                let restored = try await store.loadContext(saved.sessionID)
                if let existing = restored.snapshot?.scope, existing != replayScope { throw ProbeFailure.wrongBinding }
                // A crash before the first model commit can leave only public user
                // input and no head. Validate any retained native state directly.
                for item in restored.items {
                    switch item {
                    case .replay(let output): _ = try output.asReplayInput(scope: replayScope)
                    case .chatReplayState(let state): _ = try state.reasoningDetailsForReplay(scope: replayScope)
                    case .compacted(let value): guard value.scope == replayScope else { throw ProbeFailure.wrongBinding }
                    default: break
                    }
                }
            }
            report.phase = reopen ? "process-reopen" : "runtime-reopen"; try save(report)
            let loaded = try await runtime.loadSession(saved.sessionID)
            report.contextCount = loaded.context.count
            report.rawReasoningStatesInReopenedContext = loaded.context.filter { item in
                if case .chatReplayState(let state) = item { return (try? state.reasoningContentForReplay(scope: replayScope)) != nil }
                return false
            }.count
            if isChatValidation, report.reasoningDeltaCount > 0 { report.assertions["scopedRawReasoningSurvivedReload"] = report.rawReasoningStatesInReopenedContext > 0 }
            report.assertions["reopenedNonemptyContext"] = !loaded.context.isEmpty
            let history = try await store.readPage(.init(sessionID: saved.sessionID, limit: 1000))
            report.historyCount = history.items.count
            report.assertions["originalHistoryRetained"] = history.items.contains { $0.role == "user" && $0.text.contains(saved.marker) }
            let result = try await turn(runtime, provider: cloud, session: saved.sessionID,
                text: "What exact synthetic validation code did I give you at the beginning? Reply with only that code.", report: &report)
            report.assertions[reopen ? "processRestartRecall" : "postCompactionRecall"] = result.text.trimmingCharacters(in: .whitespacesAndNewlines) == saved.marker
            guard report.assertions.values.allSatisfy({ $0 }) else { throw ProbeFailure.assertionFailed }
            if ProcessInfo.processInfo.arguments.contains("--agentkit-live-validation-tools") {
                report.phase = "synthetic-tool-round-trip"; try save(report)
                try save(report, name: "tools")
                let receipt = "lookup-" + UUID().uuidString.lowercased()
                let counter = LookupCounter()
                let lookup = ClosureTool(descriptor: .init(name: "validation_lookup",
                    description: "Read a fresh synthetic validation receipt. Call exactly once with an empty JSON object. This read-only tool performs no device, network, account or user-data operation.",
                    parameters: .object(["type": .string("object"), "properties": .object([:]), "required": .array([]), "additionalProperties": .bool(false)]))) { _, context in
                        try await context.checkCancellation()
                        await counter.record()
                        return .init(content: receipt)
                    }
                let toolConfiguration = AgentConfiguration(model: saved.modelID,
                    instructions: "This is a synthetic tool round-trip validation. Call validation_lookup exactly once with {} to obtain a fresh receipt. The receipt is available only in its tool result. After receiving it, reply with only the exact receipt and make no further tool calls. Preserve earlier conversation facts.",
                    scope: replayScope, budget: .init(planningTokens: 131072, outputReserve: 2048, toolResultReserve: 1024), maximumInferences: 3)
                let toolRuntime = AgentRuntime(store: store, provider: cloud, configuration: toolConfiguration, tools: [lookup])
                _ = try await toolRuntime.loadSession(saved.sessionID)
                let responsesBefore = report.modelOutputInferenceCount
                let result = try await turn(toolRuntime, provider: cloud, session: saved.sessionID,
                    text: "Use validation_lookup once now, then return only its exact fresh receipt.", report: &report)
                let calls = await counter.count()
                let transactions = try await store.readTransactions(saved.sessionID)
                let results = transactions.filter { $0.turnID == result.turnID }.flatMap(\.toolResults)
                report.syntheticToolCalls = calls
                report.toolTurnAuthoritativeResponses = report.modelOutputInferenceCount - responsesBefore
                report.durableSyntheticToolResults = results.count
                report.assertions["syntheticLookupCalledExactlyOnce"] = calls == 1
                report.assertions["toolTurnHadMultipleAuthoritativeResponses"] = report.toolTurnAuthoritativeResponses! >= 2
                report.assertions["syntheticLookupReceiptReturnedExactly"] = result.text.trimmingCharacters(in: .whitespacesAndNewlines) == receipt
                report.assertions["syntheticLookupResultDurable"] = results.count == 1 && results[0].outcome.kind == .returned && results[0].outcome.content == receipt
                guard report.assertions.values.allSatisfy({ $0 }) else { throw ProbeFailure.assertionFailed }
                report.phase = "synthetic-tool-round-trip-complete"; report.status = "passed"
                try save(report, name: "tools")
            }
            if ProcessInfo.processInfo.arguments.contains("--agentkit-live-validation-remember-selection") {
                guard !isChatValidation, profile.providerKind == .chatGPTSubscription,
                      saved.modelID.lowercased().contains("luna") else { throw ProbeFailure.wrongBinding }
                try profiles.rememberSelection(providerID: profile.id, model: saved.modelID)
                let restored = ProviderStore().defaultSelection
                report.assertions["defaultSelectionRestoredToLuna"] = restored?.profile.id == profile.id && restored?.model == saved.modelID
                guard report.assertions["defaultSelectionRestoredToLuna"] == true else { throw ProbeFailure.assertionFailed }
            }
            report.phase = reopen ? "process-reopen-complete" : "awaiting-process-reopen"
            report.status = "passed"
            try save(report)
            try save(report, name: reopen ? "reopen" : "local")
        } catch {
            report.status = "failed"
            report.failureCode = safeCode(error)
            try? save(report)
            try? save(report, name: reopen ? "reopen" : "local")
            if ProcessInfo.processInfo.arguments.contains("--agentkit-live-validation-tools") { try? save(report, name: "tools") }
        }
        provider?.cancel()
    }
    private static func turn(_ runtime: AgentRuntime, provider: any CancellableModelProvider, session: UUID,
                             text: String, report: inout Report) async throws -> TurnResult {
        let handle = try await runtime.startTurn(in: session, input: .init(text: text))
        let observer = Task { () -> ([ModelUsage?], Int, Int, Bool) in
            var usage: [ModelUsage?] = [], textDeltas = 0, reasoningDeltas = 0, rawReasoning = false
            for await event in handle.events {
                switch event {
                case .responseCommitted(let response):
                    usage.append(response.usage)
                    if let state = response.replayState, (try? state.reasoningContentForReplay(scope: state.scope)) != nil { rawReasoning = true }
                case .assistantDelta(_, let text): if !text.isEmpty { textDeltas += 1 }
                case .reasoningDelta(_, let text): if !text.isEmpty { reasoningDeltas += 1 }
                default: break
                }
            }
            return (usage, textDeltas, reasoningDeltas, rawReasoning)
        }
        var expired = false
        let timeout = Task {
            do { try await Task.sleep(for: .seconds(120)); expired = true; await runtime.cancelTurn(handle.id); provider.cancel() } catch {}
        }
        let result = await handle.result()
        timeout.cancel()
        let (usage, textDeltas, reasoningDeltas, rawReasoning) = await observer.value
        report.modelOutputInferenceCount += usage.count; report.modelOutputUsage += usage.compactMap { $0 }
        report.textDeltaCount += textDeltas; report.reasoningDeltaCount += reasoningDeltas
        report.rawReasoningReplayObserved = report.rawReasoningReplayObserved || rawReasoning
        report.cacheUsageReported = report.modelOutputUsage.contains { $0.cachedTokens != nil }
        report.cacheHitObserved = report.modelOutputUsage.contains { ($0.cachedTokens ?? 0) > 0 }
        report.assertions["streamedTextObserved"] = report.textDeltaCount > 0
        if expired { throw ProbeFailure.timedOut }
        guard result.status == .completed else { throw ProbeFailure.failedTurn }
        report.turnsCompleted += 1
        try save(report)
        return result
    }
    private static func matchesProfile(_ profile: ProviderProfile) -> Bool {
        if isChatValidation {
            return profile.providerKind == .openAI && profile.inferenceAPI == .chatCompletions && URL(string: profile.settings.baseURL)?.host?.lowercased() == "api.deepseek.com"
        }
        return profile.providerKind == .chatGPTSubscription
    }
    private static func safeCode(_ error: Error) -> String {
        if let failure = error as? ProbeFailure {
            switch failure {
            case .missingProfile: return isChatValidation ? "missingSavedDeepSeekChatProfile" : "missingRememberedSubscriptionLunaProfile"
            case .missingCatalogModel: return "rememberedModelNotInAccountCatalog"
            case .missingAccount: return "missingSelectedAccountBinding"
            case .failedTurn: return "turnDidNotComplete"
            case .timedOut: return "deadlineExceeded"
            case .missingRun: return "missingPrivateReopenState"
            case .wrongBinding: return "profileBindingChanged"
            case .assertionFailed: return "continuityAssertionFailed"
            }
        }
        if error is CancellationError { return "cancelled" }
        if error is ChatGPTAuthError { return "accountAuthorizationUnavailable" }
        if let failure = error as? ModelError {
            switch failure {
            case .httpError(let status, _): return "http-\(status)"
            case .rejectedBeforeAcceptance: return "requestRejectedBeforeAcceptance"
            case .unsupportedCapability, .unsupportedOperation: return "unsupportedCapability"
            default: return "providerFailure"
            }
        }
        if error is AgentRuntimeError { return "runtimeValidationFailure" }
        return "localValidationFailure"
    }
}
#endif
