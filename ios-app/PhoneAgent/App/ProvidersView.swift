import SwiftUI

struct ProvidersView: View {
    @ObservedObject var model: AgentViewModel
    @ObservedObject private var providers: ProviderStore
    @Environment(\.dismiss) private var dismiss
    @State private var editing: ProviderProfile?
    @State private var removing: ProviderProfile?
    @State private var adding = false
    init(model: AgentViewModel) { self.model = model; providers = model.providers }
    var body: some View {
        Group {
            List {
                if let warning = providers.warning { Text(warning).foregroundStyle(.orange) }
                if providers.profiles.isEmpty {
                    ContentUnavailableView(String(localized: "Add a model provider"), systemImage: "server.rack", description: Text(String(localized: "Configure an address and model, then select them in a conversation.")))
                }
                ForEach(providers.profiles) { profile in
                    Button { editing = profile } label: {
                        HStack {
                            Text(profile.name).foregroundStyle(.primary)
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
                                .accessibilityHidden(true)
                        }
                        .contentShape(Rectangle())
                    }.buttonStyle(.plain).accessibilityIdentifier("provider-\(profile.id)")
                    .swipeActions { Button(String(localized: "Remove"), role: .destructive) { removing = profile }.disabled(model.hasBusySessions) }
                }
                if !providers.removed.isEmpty {
                    Section(String(localized: "Removed · Restorable")) {
                        ForEach(providers.removed) { profile in
                            HStack {
                                Text(profile.name)
                                Spacer()
                                Button(String(localized: "Restore")) { model.restoreProvider(profile.id) }.disabled(model.hasBusySessions)
                            }
                        }
                    }
                }
            }
            .navigationTitle(String(localized: "Provider"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button { adding = true } label: { Image(systemName: "plus") }
                        .accessibilityLabel(String(localized: "Add provider")).accessibilityIdentifier("addProvider")
                        .disabled(model.hasBusySessions || providers.warning != nil)
                }
            }
            .sheet(item: $editing) { profile in ProviderEditor(model: model, profile: profile) }
            .sheet(isPresented: $adding) { ProviderCreationView(model: model) }
            .alert(String(localized: "Remove this provider?"), isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } })) {
                Button(String(localized: "Remove provider"), role: .destructive) {
                    if let removing { model.removeProvider(removing.id) }; removing = nil
                }
                Button(String(localized: "Cancel"), role: .cancel) { removing = nil }
            } message: {
                Text(String(localized: "Configuration and keys will be kept. You can restore them here."))
            }
        }
    }

}

private struct ProviderCreationView: View {
    @ObservedObject var model: AgentViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var draft: ProviderProfile?
    var body: some View {
        if let draft {
            ProviderEditor(model: model, profile: draft)
        } else {
            NavigationStack {
                List {
                    Button(String(localized: "OpenAI")) { select(.openAI) }.accessibilityIdentifier("providerPresetOpenAI")
                    Button(String(localized: "OpenRouter")) { select(.openRouter) }.accessibilityIdentifier("providerPresetOpenRouter")
                    Button(String(localized: "ChatGPT subscription")) { select(.chatGPTSubscription) }.accessibilityIdentifier("providerPresetChatGPTSubscription")
                    Button(String(localized: "Custom provider")) { select(nil) }.accessibilityIdentifier("providerPresetCustom")
                }
                .navigationTitle(String(localized: "Add provider")).navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button(String(localized: "Cancel")) { dismiss() } } }
            }
        }
    }
    private func select(_ preset: ProviderKind?) {
        var profile = ProviderProfile()
        profile.protocolKind = preset ?? .openAI
        profile.name = preset.map { $0 == .openAI ? "OpenAI" : $0.title } ?? ""
        profile.settings.baseURL = preset?.defaultBase ?? ""
        profile.settings.model = ""
        if preset == .chatGPTSubscription { profile.inferenceKind = .responses }
        draft = profile
    }
}

private struct ProviderEditor: View {
    @ObservedObject var model: AgentViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var profile: ProviderProfile
    @State private var key = ""
    @State private var hasSavedKey = false
    @FocusState private var keyFocused: Bool
    @StateObject private var discovery = ModelDiscoveryState()
    @State private var showingModels = false
    @State private var addingModel = false
    @State private var manualModel = ""
    @StateObject private var signIn = ChatGPTSignInController()
    @State private var subscriptionLoading = false
    @State private var subscriptionTask: Task<Void, Never>?
    init(model: AgentViewModel, profile: ProviderProfile) {
        self.model = model
        var draft = profile
        draft.selectDefaultModelIfNeeded()
        _profile = State(initialValue: draft)
        _hasSavedKey = State(initialValue: model.hasSavedProviderKey(for: draft))
    }
    var body: some View {
        NavigationStack {
            Form {
                Section(String(localized: "Provider")) {
                    TextField(String(localized: "Name"), text: $profile.name).accessibilityIdentifier("providerName")
                    LabeledContent(String(localized: "Provider"), value: profile.providerKind.title).accessibilityIdentifier("providerKind")
                    if !profile.providerKind.isSelectable {
                        Text(String(localized: "This provider type was removed from the list. Its configuration and key are kept. Return to the list to add a new provider."))
                            .font(.caption).foregroundStyle(.orange)
                    }
                    if profile.providerKind == .chatGPTSubscription {
                        let connectionStatus = signIn.accounts.first(where: { $0.id == signIn.selected })?.status ?? .disconnected
                        if connectionStatus != .planAuthorized {
                            Text(connectionStatus.message).accessibilityIdentifier("chatGPTConnectionStatus")
                        }
                        if let account = signIn.accounts.first(where: { $0.id == signIn.selected }) {
                            LabeledContent(String(localized: "Signed-in account"), value: account.label).accessibilityIdentifier("chatGPTAccount")
                        }
                        if connectionStatus == .disconnected {
                            Button(String(localized: "Sign in with ChatGPT")) { connect() }
                                .disabled(signIn.busy || model.hasBusySessions).accessibilityIdentifier("chatGPTSignIn")
                        }
                        if signIn.selected != nil {
                            Button(String(localized: "Sign out of this account"), role: .destructive) { Task { await signIn.disconnect(profileID: profile.id); profile.catalog = nil; profile.settings.model = ""; profile.models = []; connectedAccountChanged(); _ = model.saveProvider(profile, key: "") } }
                                .disabled(model.hasBusySessions).accessibilityIdentifier("chatGPTDisconnect")
                        }
                        if signIn.busy { Button(String(localized: "Cancel ChatGPT sign-in")) { signIn.cancel() }.accessibilityIdentifier("chatGPTCancelSignIn") }
                        if let message = signIn.message { Text(message).accessibilityIdentifier("chatGPTSignInMessage") }
                        LabeledContent(String(localized: "API format"), value: "OpenAI Responses")
                    } else {
                    TextField(String(localized: "HTTPS API base URL"), text: $profile.settings.baseURL)
                        .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                        .accessibilityIdentifier("providerURL")
                    SecureField(String(localized: "API key"), text: $key, prompt: Text(hasSavedKey && key.isEmpty && !keyFocused ? "" : String(localized: "API key")))
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .focused($keyFocused)
                        .overlay(alignment: .leading) {
                            if hasSavedKey && key.isEmpty && !keyFocused {
                                Text(verbatim: "••••••••").foregroundStyle(.primary)
                                    .allowsHitTesting(false).accessibilityHidden(true)
                            }
                        }
                        .accessibilityLabel(String(localized: "API key"))
                        .accessibilityValue(key.isEmpty ? (hasSavedKey ? String(localized: "Saved key") : String(localized: "No key set")) : String(localized: "Key entered"))
                        .accessibilityIdentifier("providerKey")
                    if profile.providerKind.supportsResponses {
                        Picker(String(localized: "API format"), selection: Binding(get: { profile.inferenceAPI }, set: { api in
                            profile.inferenceKind = api
                            if api == .chatCompletions { profile.contextKind = .stateless }
                        })) { ForEach(InferenceAPI.allCases) { Text($0.title).tag($0) } }.accessibilityIdentifier("providerInferenceAPI")
                        if profile.inferenceAPI == .responses {
                            if profile.providerKind.supportsResponseChain { Picker(String(localized: "Context"), selection: Binding(get: { profile.contextPolicy }, set: { profile.contextKind = $0 })) {
                                ForEach(ProviderContextPolicy.allCases) { Text($0.title).tag($0) }
                            }.accessibilityIdentifier("providerContextPolicy") }
                        }
                    }
                    }
                }
                Section {
                    ForEach(profile.previewModels, id: \.self) { id in
                        Button { profile.settings.model = id } label: {
                            ProviderModelRow(id: id, metadata: profile.metadata(for: id), selected: id == profile.settings.model)
                        }.buttonStyle(.plain).accessibilityIdentifier("providerModel-" + id)
                            .accessibilityValue(id == profile.settings.model ? String(localized: "Selected") : String(localized: "Unselected"))
                    }
                    if profile.availableModels.count > 5 {
                        Button(String(localized: "Browse all models")) { showingModels = true }.accessibilityIdentifier("browseAllProviderModels")
                    }
                } header: {
                    HStack(spacing: 0) {
                        Text(String(localized: "Model"))
                        Spacer(minLength: 12)
                        HStack(spacing: 0) {
                            if profile.providerKind != .chatGPTSubscription { Button { manualModel = ""; addingModel = true } label: { Image(systemName: "plus").frame(width: 44, height: 44) }
                                .accessibilityLabel(String(localized: "Add model")).accessibilityIdentifier("addProviderModel") }
                            if discovery.loading || subscriptionLoading {
                                Button { discovery.cancel(); subscriptionTask?.cancel(); subscriptionLoading = false } label: {
                                    ProgressView().frame(width: 44, height: 44)
                                }.accessibilityLabel(String(localized: "Cancel model refresh")).accessibilityIdentifier("cancelModels")
                            } else {
                                Button { refresh() } label: { Image(systemName: "arrow.clockwise").frame(width: 44, height: 44) }
                                    .accessibilityLabel(String(localized: "Refresh models")).accessibilityIdentifier("fetchModels")
                                    .disabled(!profile.providerKind.isSelectable || (profile.providerKind == .chatGPTSubscription && profile.chatGPTAccountReference == nil))
                            }
                        }
                        .font(.body)
                        // Align the visible trailing icon with the row content,
                        // while retaining each button's 44-point touch target.
                        .padding(.trailing, -12)
                    }.buttonStyle(.borderless)
                }
                if !profile.settings.model.isEmpty {
                    ModelReasoningSection(metadata: profile.metadata(for: profile.settings.model),
                        parameters: Binding(get: { profile.parameters(for: profile.settings.model) }, set: { value in
                            if profile.modelParameters == nil { profile.modelParameters = [:] }
                            profile.modelParameters?[profile.settings.model] = value
                        }))
                }
                #if DEBUG
                if ProcessInfo.processInfo.arguments.contains("--ui-test-chatgpt-loopback") { ChatGPTLoopbackProbeView() }
                #endif
                if let message = discovery.message { Text(message).font(.caption).accessibilityIdentifier("modelDiscoveryStatus") }
                if let error = model.errorMessage { Text(error).foregroundStyle(.red) }
            }
            .disabled(model.hasBusySessions)
            .navigationTitle(String(localized: "Edit provider")).navigationBarTitleDisplayMode(.inline)
            .task { if profile.providerKind == .chatGPTSubscription { await signIn.reload(profileID: profile.id) } }
            .sheet(isPresented: $showingModels) {
                ProviderModelPicker(profile: profile) { profile.settings.model = $0 }
            }
            .alert(String(localized: "Add model"), isPresented: $addingModel) {
                TextField(String(localized: "Model ID"), text: $manualModel).textInputAutocapitalization(.never).autocorrectionDisabled()
                Button(String(localized: "Add")) {
                    let id = manualModel.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !profile.models.contains(id) { profile.models.append(id) }
                    profile.settings.model = id
                }.disabled(manualModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Button(String(localized: "Cancel"), role: .cancel) { manualModel = "" }
            }
            .onChange(of: profile.settings.baseURL) { _, _ in invalidateDiscovery(); hasSavedKey = model.hasSavedProviderKey(for: profile) }
            .onChange(of: profile.protocolKind) { _, _ in invalidateDiscovery(); hasSavedKey = model.hasSavedProviderKey(for: profile) }
            .onChange(of: key) { _, _ in discovery.cancel(); profile.catalog = nil }
            .onDisappear { discovery.cancel(); subscriptionTask?.cancel(); signIn.cancel() }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(String(localized: "Cancel")) { key = ""; dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "Save")) {
                        if model.saveProvider(profile, key: key) { key = ""; dismiss() }
                    }.disabled(model.hasBusySessions || signIn.busy || !profile.providerKind.isSelectable).accessibilityIdentifier("saveProvider")
                }
            }
        }
    }
    private func invalidateDiscovery() {
        discovery.cancel(); profile.catalog = nil; profile.modelParameters = nil
    }
    private func refresh() {
        if profile.providerKind == .chatGPTSubscription {
            subscriptionTask?.cancel(); subscriptionLoading = true
            let draft = profile
            subscriptionTask = Task {
                defer { subscriptionLoading = false }
                do {
                    let catalog = try await ChatGPTAccountManager.shared.models(profile: draft)
                    guard !Task.isCancelled, profile.chatGPTAccountReference == draft.chatGPTAccountReference else { return }
                    profile.catalog = catalog
                    if profile.settings.model.isEmpty { profile.settings.model = catalog.models.first?.id ?? "" }
                    _ = model.saveProvider(profile, key: "")
                } catch { if !Task.isCancelled { discovery.fail(error) } }
            }
            return
        }
        do {
            let credential = try model.discoveryKey(for: profile, typedKey: key)
            discovery.refresh(profile: profile, key: credential) {
                profile.catalog = $0
                profile.selectDefaultModelIfNeeded()
            }
        } catch { discovery.fail(error) }
    }
    private func connect() {
        guard model.saveProvider(profile, key: "") else { return }
        signIn.start(profileID: profile.id) { connectedAccountChanged(); refresh() }
    }
    private func connectedAccountChanged() {
        subscriptionTask?.cancel()
        if profile.chatGPTAccountReference != signIn.selected {
            profile.chatGPTAccountReference = signIn.selected; profile.settings.model = ""; profile.models = []
            invalidateDiscovery(); _ = model.saveProvider(profile, key: "")
        }
    }
}

struct ProviderModelPicker: View {
    let profile: ProviderProfile
    let select: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""
    var body: some View {
        NavigationStack {
            List(profile.availableModels.filter { search.isEmpty || $0.localizedCaseInsensitiveContains(search) }, id: \.self) { id in
                Button { select(id); dismiss() } label: {
                    ProviderModelRow(id: id, metadata: profile.metadata(for: id))
                }.buttonStyle(.plain)
                    .accessibilityIdentifier("providerModelOption-" + id)
            }
            .searchable(text: $search, placement: .navigationBarDrawer(displayMode: .always), prompt: String(localized: "Search model IDs"))
            .navigationTitle(String(localized: "Choose a model"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button(String(localized: "Cancel")) { dismiss() } } }
        }
    }
}

private struct ProviderModelRow: View {
    let id: String
    let metadata: DiscoveredModel?
    var selected = false
    var body: some View {
        HStack(spacing: 8) {
            Text(id).foregroundStyle(.primary)
            HStack(spacing: 6) {
                capabilityIcon("photo", label: String(localized: "Supports image input"), support: metadata?.vision)
                capabilityIcon("wrench.and.screwdriver", label: String(localized: "Supports tool calls"), support: metadata?.tools)
                capabilityIcon("brain", label: String(localized: "Supports reasoning"), support: metadata?.thinking)
                capabilityIcon("text.bubble", label: String(localized: "Supports text generation"), support: metadata?.generation)
            }
            .font(.caption).foregroundStyle(.secondary)
            Spacer()
            if selected { Image(systemName: "checkmark").foregroundStyle(.tint).accessibilityHidden(true) }
        }.padding(.vertical, 4)
    }
    @ViewBuilder private func capabilityIcon(_ symbol: String, label: String, support: CapabilitySupport?) -> some View {
        if support == .supported {
            Image(systemName: symbol).accessibilityLabel(label).help(label)
        }
    }
}

private struct ModelReasoningSection: View {
    let metadata: DiscoveredModel?
    @Binding var parameters: ModelParameters
    var body: some View {
        Section {
            if let efforts = metadata?.reasoningEfforts, !efforts.isEmpty {
                Picker(String(localized: "Reasoning effort"), selection: Binding(get: { parameters.reasoningEffort ?? "" }, set: { parameters.reasoningEffort = $0.isEmpty ? nil : $0 })) {
                    Text(metadata?.defaultReasoningEffort.map { String(localized: "Provider default (\($0))") } ?? String(localized: "Provider default")).tag("")
                    ForEach(efforts, id: \.self) { Text(ReasoningEffortLabel.title($0)).tag($0) }
                }.accessibilityIdentifier("reasoningEffort")
                if let selected = parameters.reasoningEffort, !efforts.contains(selected) {
                    Text(String(localized: "The previous reasoning effort is no longer available. Choose a current level or the default.")).foregroundStyle(.orange)
                }
            } else {
                Text(String(localized: "This model has not reported available reasoning levels. Using the provider default."))
                if parameters.reasoningEffort != nil { Button(String(localized: "Clear previous reasoning effort")) { parameters.reasoningEffort = nil } }
            }
        } header: { Text(String(localized: "Reasoning effort")) }
    }
}
