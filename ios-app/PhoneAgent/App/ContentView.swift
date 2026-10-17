import SwiftUI

struct ContentView: View {
    @ObservedObject var model: AgentViewModel
    @ObservedObject var statusPiP: StatusPiPController
    @ObservedObject private var sessions: ConversationStore
    let commands: SessionCommandService
    @Environment(\.scenePhase) private var scenePhase
    @State private var path: [UUID] = []
    @State private var consumedActivityNavigationID: UUID?
    @State private var search = ""
    private enum Panel: String, Identifiable { case settings; var id: String { rawValue } }
    @State private var panel: Panel?
    init(model: AgentViewModel, statusPiP: StatusPiPController, commands: SessionCommandService) {
        self.commands = commands
        self.model = model; self.statusPiP = statusPiP; self.sessions = model.sessions
    }
    private var visible: [AgentConversation] {
        sessions.conversations.filter { search.isEmpty || $0.title.localizedCaseInsensitiveContains(search) || $0.preview.localizedCaseInsensitiveContains(search) }
            .sorted { $0.updatedAt > $1.updatedAt }
    }
    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if sessions.conversations.isEmpty {
                    VStack(spacing: 22) {
                        Spacer()
                        Image(systemName: "sparkle").font(.system(size: 46, weight: .light)).foregroundStyle(.blue)
                            .frame(width: 98, height: 98).background(.blue.opacity(0.08), in: RoundedRectangle(cornerRadius: 30))
                        VStack(spacing: 8) {
                            Text(String(localized: "Start with an idea")).font(.title2.bold())
                            Text(String(localized: "Talk with the agent and follow its progress.\nConfirm the next step when needed.")).multilineTextAlignment(.center).foregroundStyle(.secondary)
                        }
                        Button(action: createConversation) { Label(String(localized: "New conversation"), systemImage: "plus").padding(.horizontal, 20).padding(.vertical, 6) }
                            .buttonStyle(.borderedProminent).controlSize(.large).accessibilityIdentifier("newConversation")
                        Spacer(); Spacer()
                    }.padding(28).frame(maxWidth: .infinity)
                } else {
                    List {
                        if let warning = sessions.warning { Label(warning, systemImage: "exclamationmark.triangle").font(.footnote).foregroundStyle(.orange) }
                        ForEach(visible) { session in
                            NavigationLink(value: session.id) {
                                Text(session.title).font(.headline).lineLimit(1)
                                    .frame(maxWidth: .infinity, minHeight: 40, alignment: .leading)
                            }
                            .listRowInsets(EdgeInsets(top: 10, leading: 20, bottom: 10, trailing: 16))
                            .swipeActions { if !model.isRunning(in: session.id) { Button(String(localized: "Delete"), role: .destructive) { sessions.delete(session.id) } } }
                        }
                        if visible.isEmpty { ContentUnavailableView.search(text: search) }
                    }.listStyle(.plain)
                }
            }
            .navigationTitle(String(localized: "Conversations"))
            .searchable(text: $search, prompt: String(localized: "Search conversations"))
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button { panel = .settings } label: { Image(systemName: "gear") }.accessibilityLabel(String(localized: "Settings")) }
                ToolbarItem(placement: .topBarTrailing) { Button(action: createConversation) { Image(systemName: "square.and.pencil") }.accessibilityLabel(String(localized: "New conversation")).accessibilityIdentifier("newConversationToolbar") }
            }
            .navigationDestination(for: UUID.self) { id in
                ConversationView(model: model, conversationID: id).id(id)
            }
            .sheet(item: $panel) { item in
                switch item {
                case .settings: SettingsView(model: model)
                }
            }

        }
        .onOpenURL { url in
            if url == URL(string: "phoneagent://home") {
                consumedActivityNavigationID = model.activityNavigation?.id
                path = []; panel = nil
            } else { model.openActivityURL(url) }
        }
        .onChange(of: path) { old, new in
            for id in old where !new.contains(id) { model.discardConversationDraft(id) }
        }
        #if DEBUG
        .task {
            if ProcessInfo.processInfo.arguments.contains("--task-pip-probe"),
               ProcessInfo.processInfo.arguments.contains("--background-stream-probe"), let id = sessions.conversations.first?.id {
                path = [id]
            }
        }
        #endif
        .onChange(of: model.activityNavigation, initial: true) { _, _ in
            routeActivityNavigation()
        }
        .alert(String(localized: "Live Activity link"), isPresented: Binding(get: { model.activityLinkError != nil }, set: { if !$0 { model.activityLinkError = nil } })) {
            Button(String(localized: "Got it")) { model.activityLinkError = nil }
        } message: { Text(model.activityLinkError ?? "") }
        .onChange(of: commands.pendingRoute, initial: true) { _, _ in routePreparedTask() }
        .onChange(of: model.running) { _, _ in routePreparedTask() }
        .onChange(of: model.stopping) { _, _ in routePreparedTask() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { routeActivityNavigation(); routePreparedTask() }
        }
        .onChange(of: panel) { _, value in if value == nil { routePreparedTask() } }
    }
    private func routeActivityNavigation() {
        // A completion can arrive while UIKit is still displaying another app.
        // Keep its destination pending until this scene can mount the message UI.
        guard scenePhase == .active, let destination = model.activityNavigation,
              consumedActivityNavigationID != destination.id else { return }
        consumedActivityNavigationID = destination.id
        panel = nil
        path = [destination.route.sessionID]
    }
    private func routePreparedTask() {
        guard scenePhase == .active, panel == nil, let id = commands.pendingRoute,
              path.last != id else { return }
        if case .open(let destination) = try? commands.perform(SessionCommand(.open, sessionID: id, source: .app)) {
            path = [destination]
        }
    }
    private func createConversation() {
        path.append(model.createConversationDraft(mode: .live))
    }
}
