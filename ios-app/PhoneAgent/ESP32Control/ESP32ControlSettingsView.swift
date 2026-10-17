// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI

struct ESP32ControlSettingsView: View {
    @State private var flow = PairingFlow.shared
    @State private var showingTouchTest = false
    @State private var localAddress = PairingFlow.shared.vpnConfiguration.localAddress
    @State private var peerAddress = PairingFlow.shared.vpnConfiguration.peerAddress
    @State private var error: String?
    private enum AddressField: Hashable { case local, peer }
    @FocusState private var editing: AddressField?
    var body: some View {
        Form {
            if flow.route == .vpnLoopback {
                vpnConfigurationSection
            }
            PairingSection { showingTouchTest = true }
        }
            .navigationTitle(flow.route.controlTitle)
            .navigationBarTitleDisplayMode(.inline)
            .fullScreenCover(isPresented: $showingTouchTest) {
                TouchVerificationView(flow: PairingFlow.shared)
            }
            .toolbar {
                ToolbarItem(id: "vpnLoopbackSave", placement: .confirmationAction) {
                    if flow.route == .vpnLoopback && changed {
                        Button(String(localized: "Save"), action: save)
                            .accessibilityIdentifier("saveVPNLoopbackConfiguration")
                            .disabled(!flow.canChangeRoute)
                    }
                }
            }
            .task { PairingFlow.shared.resume() }
    }
    private var changed: Bool {
        localAddress != flow.vpnConfiguration.localAddress || peerAddress != flow.vpnConfiguration.peerAddress
    }
    private var vpnConfigurationSection: some View {
        Section {
            addressRow(String(localized: "Interface address"), text: $localAddress,
                defaultAddress: VPNLoopbackConfiguration.defaults.localAddress,
                candidates: [VPNLoopbackConfiguration.defaults.localAddress, "198.18.0.1"],
                field: .local, identifier: "vpnLoopbackInterfaceAddress")
            addressRow(String(localized: "Peer address"), text: $peerAddress,
                defaultAddress: VPNLoopbackConfiguration.defaults.peerAddress,
                candidates: [VPNLoopbackConfiguration.defaults.peerAddress],
                field: .peer, identifier: "vpnLoopbackPeerAddress")
            if let error { Text(error).font(.footnote).foregroundStyle(.red) }
        } footer: {
            Text(String(localized: "A Wi-Fi connection is needed while connecting"))
        }
        .keyboardType(.numbersAndPunctuation)
        .textInputAutocapitalization(.never)
        .autocorrectionDisabled()
        .submitLabel(.done)
        .disabled(!flow.canChangeRoute)
        .onSubmit(save)
    }
    private func addressRow(_ title: String, text: Binding<String>, defaultAddress: String,
                            candidates: [String], field: AddressField, identifier: String) -> some View {
        LabeledContent(title) {
            HStack(spacing: 4) {
                TextField(defaultAddress, text: text)
                    .multilineTextAlignment(.trailing)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier(identifier)
                    .focused($editing, equals: field)
                Menu {
                    ForEach(candidates, id: \.self) { address in
                        Button(address) {
                            text.wrappedValue = address
                            error = nil
                            editing = nil
                        }
                    }
                    Divider()
                    Button(String(localized: "Custom")) { editing = field }
                        .accessibilityIdentifier(identifier + "Custom")
                } label: {
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(String(localized: "\(title) options"))
                .accessibilityIdentifier(identifier + "Presets")
            }
        }
    }
    private func save() {
        do {
            try flow.saveVPNConfiguration(localAddress: localAddress, peerAddress: peerAddress)
            localAddress = flow.vpnConfiguration.localAddress
            peerAddress = flow.vpnConfiguration.peerAddress
            error = nil; editing = nil
        } catch let failure as NCMControlError {
            if case .unavailable(let message) = failure { error = message }
        } catch {
            self.error = String(localized: "Enter two different, valid IPv4 addresses")
        }
    }
}
