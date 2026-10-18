#if DEBUG
import SwiftUI
import UniformTypeIdentifiers
import UIKit

/// Opt-in diagnostics; never appears in normal Debug or Release navigation.
struct MuseDevelopmentView: View {
    @ObservedObject var model: AgentViewModel
    var body: some View {
        List {
            NavigationLink(String(localized: "Legacy Connection Settings")) { MuseDeveloperConnectionView(model: model) }
        }
        .navigationTitle(String(localized: "Muse Developer Tools"))
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct MuseDeveloperConnectionView: View {
    @ObservedObject var model: AgentViewModel
    @State private var connection = PhoneAgentRuntime.shared.museConnection
    @State private var host = ""
    @State private var port = "8765"
    @State private var sources = ""
    private enum Field: Hashable { case host, port, sources }
    @FocusState private var focusedField: Field?
    @State private var importing = false
    @State private var sheet: MuseConnectionSheet?
    @State private var starting = false
    @State private var removingCertificate = false
    @State private var revoking: RemoteClientRegistration?
    private var canEdit: Bool { !connection.isActive && !model.hasBusySessions }
    private var changed: Bool {
        host != connection.settings.host || port != String(connection.settings.port) || sources != connection.settings.sources.joined(separator: "\n")
    }
    var body: some View {
        Form {
            Section {
                LabeledContent(String(localized: "Connection Status"), value: statusText).accessibilityIdentifier("museConnectionStatus")
                if let message = connection.message { Text(message).font(.caption).accessibilityIdentifier("museConnectionMessage") }
                if connection.isActive {
                    Button(String(localized: "Stop Connection"), role: .destructive) { connection.stop() }
                        .disabled(connection.status == .stopping).accessibilityIdentifier("museStopConnection")
                } else {
                    Button(String(localized: "Start Connection")) { starting = true }
                        .disabled(changed || connection.settings.certificate == nil || connection.settings.clients.isEmpty || !canEdit)
                        .accessibilityIdentifier("museStartConnection")
                }
            } header: { Text("Muse Gadget") } footer: {
                Text(String(localized: "Authorized clients can receive screenshots and app lists. Allowed actions run without further prompts. Tasks may stop when the phone locks or background execution becomes unavailable."))
            }
            Section {
                TextField(String(localized: "Certificate IP Address or Domain"), text: $host).textInputAutocapitalization(.never).autocorrectionDisabled()
                    .focused($focusedField, equals: .host).accessibilityIdentifier("museServerHost")
                TextField(String(localized: "Port"), text: $port).keyboardType(.numberPad).focused($focusedField, equals: .port).accessibilityIdentifier("museServerPort")
                TextField(String(localized: "Allowed client IP addresses, one per line"), text: $sources, axis: .vertical)
                    .lineLimit(2...4).textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.asciiCapable)
                    .focused($focusedField, equals: .sources).accessibilityIdentifier("museAllowedSources")
                if changed {
                    Button(String(localized: "Save Connection Settings")) { perform { try connection.configure(host: host, port: port, sources: sources); reload() } }
                        .accessibilityIdentifier("museSaveConnection")
                }
            } header: { Text(String(localized: "Connection Address")) } footer: {
                Text(String(localized: "Enter an iPhone address reachable by Muse that matches the server certificate. Use the client IP address received by Actell; subnets and wildcards are unsupported."))
            }.disabled(!canEdit)
            Section {
                if let certificate = connection.settings.certificate {
                    LabeledContent(String(localized: "Server Certificate"), value: certificate.name)
                    LabeledContent(String(localized: "Expires"), value: certificate.expiresAt.formatted(date: .abbreviated, time: .omitted))
                    Text(verbatim: "SHA-256: " + certificate.fingerprint).font(.caption.monospaced()).textSelection(.enabled)
                        .accessibilityIdentifier("museCertificateFingerprint")
                } else { Text(String(localized: "No server certificate imported")).foregroundStyle(.secondary).accessibilityIdentifier("museMissingCertificate") }
                Button(connection.settings.certificate == nil ? String(localized: "Import Certificate") : String(localized: "Replace Certificate"), systemImage: "doc.badge.plus") { importing = true }
                    .accessibilityIdentifier("museImportCertificate")
                if connection.settings.certificate != nil {
                    Button(String(localized: "Remove Certificate"), role: .destructive) { removingCertificate = true }
                }
            } header: { Text(String(localized: "Server Certificate")) } footer: {
                Text(String(localized: "Import a .p12 or .pfx file containing the certificate and private key. They are stored in this device’s Keychain. Clients must still verify the certificate and connection address."))
            }.disabled(!canEdit)
            Section {
                if connection.settings.clients.isEmpty { Text(String(localized: "No authorized clients")).foregroundStyle(.secondary).accessibilityIdentifier("museNoClients") }
                ForEach(connection.settings.clients) { client in
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(client.name).accessibilityIdentifier("museClientName-" + client.id)
                            Text(String(client.id.prefix(8))).font(.caption.monospaced()).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button(String(localized: "Revoke"), role: .destructive) { revoking = client }.buttonStyle(.borderless)
                            .accessibilityIdentifier("museRevokeClient-" + client.id)
                    }
                }
                Button(String(localized: "Add Client"), systemImage: "person.badge.plus") { sheet = .addClient }
                    .disabled(changed || connection.settings.host.isEmpty || connection.settings.sources.isEmpty)
                    .accessibilityIdentifier("museAddClient")
            } header: { Text(String(localized: "Authorized Clients")) } footer: {
                Text(String(localized: "Adding a client creates credentials shown only once. Transfer them securely to your trusted Muse client. Revoking stops its task and access; actions already sent cannot be undone."))
            }
            Section(String(localized: "Muse device")) {
                Text(String(localized: "Set up the device account and Wi-Fi in the Muse app."))
                Text(String(localized: "Starting the service does not confirm a Muse connection or image delivery to its model."))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .navigationTitle(String(localized: "Muse Connection")).navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button(String(localized: "Done Editing")) { focusedField = nil }.accessibilityIdentifier("museFinishInput")
            }
        }
        .onAppear { reload() }
        .fileImporter(isPresented: $importing, allowedContentTypes: [UTType(filenameExtension: "p12") ?? .data, UTType(filenameExtension: "pfx") ?? .data]) { result in
            switch result {
            case .success(let url): sheet = .certificate(url)
            case .failure: connection.message = String(localized: "No certificate selected. Choose a file again.")
            }
        }
        .sheet(item: $sheet) { destination in
            switch destination {
            case .addClient: MuseAddClientSheet(connection: connection)
            case .certificate(let url): MuseCertificateSheet(connection: connection, url: url)
            }
        }
        .confirmationDialog(String(localized: "Allow authorized clients to access Actell?"), isPresented: $starting, titleVisibility: .visible) {
            Button(String(localized: "Allow and Start")) { perform { try connection.start() } }
            Button(String(localized: "Cancel"), role: .cancel) {}
        } message: { Text(String(localized: "Clients can read screenshots and app lists and request phone control. Allowed actions run without further prompts. This starts the HTTPS service on the configured port.")) }
        .confirmationDialog(String(localized: "Remove server certificate?"), isPresented: $removingCertificate, titleVisibility: .visible) {
            Button(String(localized: "Remove"), role: .destructive) { perform { try connection.removeCertificate() } }
        }
        .confirmationDialog(String(localized: "Revoke this client?"), isPresented: Binding(get: { revoking != nil }, set: { if !$0 { revoking = nil } }), titleVisibility: .visible) {
            Button(String(localized: "Revoke Client"), role: .destructive) { if let client = revoking { perform { try connection.revoke(client) } }; revoking = nil }
        } message: { Text(revoking?.name ?? "") }
    }
    private var statusText: String {
        switch connection.status {
        case .stopped: return String(localized: "Not Started")
        case .starting: return String(localized: "Starting")
        case .listening: return String(localized: "Listening")
        case .running: return String(localized: "A remote task is using this device")
        case .stopping: return String(localized: "Stopping the task")
        }
    }
    private func reload() {
        host = connection.settings.host; port = String(connection.settings.port)
        sources = connection.settings.sources.joined(separator: "\n")
    }
    private func perform(_ action: () throws -> Void) {
        do { try action() } catch { connection.message = error.localizedDescription }
    }
}

private enum MuseConnectionSheet: Identifiable {
    case addClient, certificate(URL)
    var id: String { switch self { case .addClient: return "client"; case .certificate: return "certificate" } }
}
private struct MuseCertificateSheet: View {
    let connection: RemoteConnectionController
    let url: URL
    @Environment(\.dismiss) private var dismiss
    @State private var password = ""
    @State private var error: String?
    var body: some View {
        NavigationStack {
            Form {
                Text(url.lastPathComponent)
                SecureField(String(localized: "Certificate Password"), text: $password).accessibilityIdentifier("museCertificatePassword")
                if let error { Text(error).foregroundStyle(.red) }
                Text(String(localized: "A failed import keeps the previous certificate. Importing does not start the service. Connection details exclude private keys and passwords."))
                    .font(.caption).foregroundStyle(.secondary)
            }.navigationTitle(String(localized: "Import Server Certificate"))
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button(String(localized: "Cancel")) { password = ""; dismiss() } }
                    ToolbarItem(placement: .confirmationAction) {
                        Button(String(localized: "Import")) {
                            do { try connection.importCertificate(url: url, password: password); password = ""; dismiss() }
                            catch { self.error = error.localizedDescription; password = "" }
                        }.accessibilityIdentifier("museConfirmCertificateImport")
                    }
                }
        }
    }
}
private struct MuseAddClientSheet: View {
    let connection: RemoteConnectionController
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var invitation: RemoteClientInvitation?
    @State private var error: String?
    @State private var copied = false
    var body: some View {
        NavigationStack {
            Form {
                if let invitation {
                    Section {
                        LabeledContent(String(localized: "Devices"), value: invitation.client.name)
                        Text(String(localized: "Device ID: \(invitation.client.id)")).font(.caption.monospaced()).textSelection(.enabled)
                        Text(String(localized: "Connection Details Ready")).accessibilityIdentifier("museInvitationReady")
                        Text(String(localized: "Contains device credentials and the public server certificate, valid for 10 minutes. Transfer only through a trusted USB serial connection."))
                            .font(.caption)
                        Button(copied ? String(localized: "Copied (expires in 5 minutes)") : String(localized: "Copy Connection Details")) {
                            UIPasteboard.general.setItems([[UTType.utf8PlainText.identifier: invitation.text]], options: [.localOnly: true, .expirationDate: Date().addingTimeInterval(300)])
                            copied = true
                        }.accessibilityIdentifier("museCopyInvitation")
                        Text(String(localized: "Use only your trusted USB setup tool to transfer these credentials. Do not send them through chat or a web page. The device must still request pairing and permission here."))
                        Text(String(localized: "The key will not be shown again after closing. If transfer fails, revoke the client and add it again."))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                } else {
                    Section {
                        TextField(String(localized: "Client Name"), text: $name).accessibilityIdentifier("museClientNameInput")
                        if let error { Text(error).foregroundStyle(.red) }
                    } footer: { Text(String(localized: "For example, Desk Muse. Generating credentials does not grant access. Confirm the device and permissions after USB setup and its pairing request.")) }
                }
            }.navigationTitle(invitation == nil ? String(localized: "Add Client") : String(localized: "Client Connection Details"))
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button(invitation == nil ? String(localized: "Cancel") : String(localized: "Done")) { dismiss() } }
                    if invitation == nil {
                        ToolbarItem(placement: .confirmationAction) {
                            Button(String(localized: "Add")) {
                                do { invitation = try connection.addClient(name: name) }
                                catch { self.error = error.localizedDescription }
                            }.disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                                .accessibilityIdentifier("museConfirmAddClient")
                        }
                    }
                }
        }
    }
}

#endif
