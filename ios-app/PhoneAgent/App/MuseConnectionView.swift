import SwiftUI

struct MuseConnectionView: View {
    @ObservedObject var model: AgentViewModel
    @State private var connection = PhoneAgentRuntime.shared.museConnection
    @State private var selected: RemoteClientRegistration?
    @State private var revoking: RemoteClientRegistration?
    @State private var adding = false
    @State private var error: String?
    @State private var diagnosticsCopied = false

    var body: some View {
        Form {
            Section {
                Toggle(String(localized: "Muse Gadget Service"), isOn: Binding(get: { connection.isEnabled }, set: { enabled in
                    if enabled { perform { try connection.start() } }
                    else { connection.stop() }
                }))
                .disabled(!connection.isEnabled && (connection.status == .starting || connection.status == .stopping || model.hasBusySessions))
                .accessibilityIdentifier("museAllowConnection")
                LabeledContent(String(localized: "Status"), value: connectionStatus)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(String(localized: "Status"))
                    .accessibilityValue(connectionStatus)
                    .accessibilityIdentifier("museServiceStatus")
            } footer: {
                Text(connection.connectionIssue ?? String(localized: "Connect to the same local network as Muse."))
            }
            Section {
                if connection.settings.clients.isEmpty {
                    Text(String(localized: "No devices added")).foregroundStyle(.secondary)
                        .accessibilityIdentifier("museNoDevices")
                }
                ForEach(connection.settings.clients) { client in
                    if client.identityConfirmed {
                        Button { selected = connection.settings.clients.first { $0.id == client.id } } label: {
                            HStack(spacing: 10) {
                                deviceLabel(client)
                                Image(systemName: "chevron.right")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.tertiary)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .tint(.primary)
                        .accessibilityIdentifier("museDevice-" + client.id)
                        .swipeActions { removeButton(client) }
                    } else {
                        HStack {
                            deviceLabel(client)
                            removeButton(client).buttonStyle(.borderless)
                        }
                    }
                }
                if connection.isEnabled {
                    Button {
                        perform { try connection.openPairingWindow(); adding = true }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "plus")
                            Text(String(localized: "Add Muse"))
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .tint(.blue)
                    .disabled(!connection.pairing.available || model.hasBusySessions)
                    .accessibilityIdentifier("museAddCompanion")
                }
            } header: { Text(String(localized: "Devices")) }
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("--muse-development") {
                Section {
                    NavigationLink(String(localized: "Muse Developer Tools")) { MuseDevelopmentView(model: model) }
                }
            }
            #endif
        }
        .navigationTitle("Muse Gadget").navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button(diagnosticsCopied ? String(localized: "Diagnostic log copied") : String(localized: "Copy diagnostic log")) {
                        UIPasteboard.general.string = model.usbDiagnosticReport()
                        diagnosticsCopied = true
                    }
                    .accessibilityIdentifier("copyMuseDiagnostics")
                } label: { Label(String(localized: "More"), systemImage: "ellipsis") }
            }
        }
        .sheet(item: $selected) { MuseDevicePermissionsSheet(connection: connection, client: $0) }
        .sheet(isPresented: $adding, onDismiss: { connection.cancelPairing() }) {
            MuseLANPairingSheet(connection: connection)
        }
        .alert(String(localized: "Could Not Complete Operation"), isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button(String(localized: "OK"), role: .cancel) { error = nil }
        } message: { Text(error ?? "") }
        .confirmationDialog(String(localized: "Remove this device?"), isPresented: Binding(get: { revoking != nil }, set: { if !$0 { revoking = nil } }), titleVisibility: .visible) {
            Button(String(localized: "Remove Device"), role: .destructive) {
                if let client = revoking { perform { try connection.revoke(client) } }
                revoking = nil
            }
        } message: { Text(String(localized: "This stops the device’s task and removes its access.")) }
    }
    private var connectionStatus: String {
        switch connection.status {
        case .stopped: return connection.connectionIssue != nil ? String(localized: "Service Not Running") : connection.isEnabled ? String(localized: "Paused") : String(localized: "Stopped")
        case .starting: return String(localized: "Starting")
        case .listening, .running: return String(localized: "Running")
        case .stopping: return String(localized: "Stopping")
        }
    }
    private func deviceLabel(_ client: RemoteClientRegistration) -> some View {
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            HStack(spacing: 12) {
                Text(client.name).foregroundStyle(.primary)
                Spacer(minLength: 8)
                Text(deviceStatus(client, now: Date()))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.trailing)
                    .layoutPriority(1)
                    .accessibilityIdentifier("musePeerStatus-" + client.id)
            }
        }
    }
    private func deviceStatus(_ client: RemoteClientRegistration, now: Date) -> String {
        guard client.identityConfirmed else {
            if client.lanPairingState == .pendingAck { return String(localized: "Completing pairing") }
            return client.bootstrapExpiresAt.map({ $0 <= now }) == true ? String(localized: "Pairing Expired") : String(localized: "Pairing Incomplete")
        }
        if client.scopes.isEmpty { return String(localized: "Access Not Allowed") }
        guard connection.isPeerOnline(client.id) else { return String(localized: "Not connected") }
        return String(localized: "Connected")
    }
    private func removeButton(_ client: RemoteClientRegistration) -> some View {
        Button(String(localized: "Remove"), role: .destructive) { revoking = client }
            .accessibilityIdentifier("museRemoveDevice-" + client.id)
    }
    private func perform(_ action: () throws -> Void) {
        do { try action() } catch { self.error = error.localizedDescription }
    }
}

private struct MuseDevicePermissionsSheet: View {
    let connection: RemoteConnectionController
    let client: RemoteClientRegistration
    @Environment(\.dismiss) private var dismiss
    @State private var scopes: Set<MuseCompanionScope> = []
    @State private var name = ""
    private var normalizedName: String? { try? RemoteConnectionStore.normalizedDeviceName(name) }
    @State private var error: String?
    @State private var removing = false
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack {
                        Text(String(localized: "Name"))
                        TextField(String(localized: "Device Name"), text: $name)
                            .multilineTextAlignment(.trailing)
                            .autocorrectionDisabled()
                            .accessibilityIdentifier("museDeviceName")
                    }
                    .alignmentGuide(.listRowSeparatorLeading) { _ in 0 }
                }
                Section {
                    ForEach(MuseCompanionScope.allCases) { scope in
                        Toggle(scope.title, isOn: Binding(get: { scopes.contains(scope) }, set: { enabled in
                            if enabled { scopes.insert(scope) } else { scopes.remove(scope) }
                        }))
                        .accessibilityIdentifier("musePermission-" + scope.rawValue)
                    }
                } header: { Text(String(localized: "Allow Access")) } footer: {
                    Text(String(localized: "Screenshots and app information may be sent through Muse to its service or model. Allowed actions run without further prompts."))
                        .accessibilityIdentifier("museCapabilityDataDisclosure")
                }
                Section {
                    Button(String(localized: "Remove Device"), role: .destructive) { removing = true }
                        .accessibilityIdentifier("museRemoveSelectedDevice")
                }
                if let error { Text(error).foregroundStyle(.red) }
            }
            .navigationTitle(client.name)
            .navigationBarTitleDisplayMode(.inline)
            .onAppear {
                let current = connection.settings.clients.first(where: { $0.id == client.id }) ?? client
                scopes = current.scopes; name = current.name
            }
            .confirmationDialog(String(localized: "Remove this device?"), isPresented: $removing, titleVisibility: .visible) {
                Button(String(localized: "Remove Device"), role: .destructive) {
                    do { try connection.revoke(client); dismiss() }
                    catch { self.error = error.localizedDescription }
                }
            } message: { Text(String(localized: "This stops the device’s task and removes its access.")) }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(String(localized: "Cancel")) { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "Save")) {
                        do { try connection.authorize(client, scopes: scopes, identityConfirmed: true, name: name); dismiss() }
                        catch { self.error = error.localizedDescription }
                    }
                    .disabled(normalizedName == nil || (scopes == client.scopes && normalizedName == client.name))
                }
            }
        }
    }
}


private struct MuseLANPairingSheet: View {
    let connection: RemoteConnectionController
    @Environment(\.dismiss) private var dismiss
    @State private var error: String?
    var body: some View {
        NavigationStack {
            TimelineView(.periodic(from: .now, by: 1)) { _ in
                Form {
                    if let name = connection.pairing.completedName {
                        Section {
                            Label(String(localized: "Paired"), systemImage: "checkmark.circle.fill")
                                .frame(maxWidth: .infinity, alignment: .center)
                                .alignmentGuide(.listRowSeparatorLeading) { _ in 0 }
                                .accessibilityIdentifier("musePairingComplete")
                            Text(name)
                                .frame(maxWidth: .infinity, alignment: .center)
                                .multilineTextAlignment(.center)
                                .alignmentGuide(.listRowSeparatorLeading) { _ in 0 }
                        }
                    } else if let pending = connection.pairing.pending {
                        Section {
                            Text(pending.name).font(.headline)
                                .frame(maxWidth: .infinity, alignment: .center)
                                .multilineTextAlignment(.center)
                                .alignmentGuide(.listRowSeparatorLeading) { _ in 0 }
                            if pending.approved {
                                ProgressView(String(localized: "Completing pairing"))
                                    .frame(maxWidth: .infinity, alignment: .center)
                                    .multilineTextAlignment(.center)
                                    .padding(.vertical, 8)
                            } else {
                                Button(String(localized: "Allow")) { perform { try connection.approvePairing() } }
                                    .accessibilityIdentifier("musePairingAllow")
                                Button(String(localized: "Deny"), role: .destructive) { connection.pairing.reject() }
                                    .accessibilityIdentifier("musePairingReject")
                            }
                        }
                    } else if connection.pairing.windowRemaining > 0 {
                        Section {
                            ProgressView(String(localized: "Waiting for Muse"))
                                .frame(maxWidth: .infinity, alignment: .center)
                                .multilineTextAlignment(.center)
                                .padding(.vertical, 8)
                        } footer: {
                            Text(String(localized: "Choose “Connect Actell” on Muse."))
                        }
                    } else {
                        Section {
                            Text(String(localized: "Pairing Ended"))
                                .frame(maxWidth: .infinity, alignment: .center)
                                .multilineTextAlignment(.center)
                            Button(String(localized: "Add Again")) { perform { try connection.openPairingWindow() } }
                                .disabled(!connection.pairing.available)
                        }
                    }
                    if let error = error ?? connection.pairing.error {
                        Text(error).foregroundStyle(.red)
                            .frame(maxWidth: .infinity, alignment: .center)
                            .multilineTextAlignment(.center)
                    }
                }
            }
            .navigationTitle(String(localized: "Add Muse")).navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(connection.pairing.completedName == nil ? String(localized: "Cancel") : String(localized: "Done")) { dismiss() }
                }
            }
        }
    }
    private func perform(_ action: () throws -> Void) {
        do { try action() } catch { self.error = error.localizedDescription }
    }
}
