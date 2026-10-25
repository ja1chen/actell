// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI

/// Merged phone-control settings page: the connection mode picker stays on
/// top and the route-specific setup renders below it and switches in place.
struct PhoneControlSettingsView: View {
    @ObservedObject var model: AgentViewModel
    @State private var flow = DeviceControlCoordinator.shared
    @State private var showingTouchTest = false
    @State private var localAddress = DeviceControlCoordinator.shared.vpnConfiguration.localAddress
    @State private var peerAddress = DeviceControlCoordinator.shared.vpnConfiguration.peerAddress
    @State private var error: String?
    var body: some View {
        Form {
            Section {
                Picker(selection: Binding(get: { flow.route }, set: { _ = flow.selectRoute($0) })) {
                    Text(DeviceControlRoute.vpnLoopback.title).tag(DeviceControlRoute.vpnLoopback)
                    Text(DeviceControlRoute.ncmDeveloper.title).tag(DeviceControlRoute.ncmDeveloper)
                } label: {
                    Text(String(localized: "Connection mode"))
                }
                .disabled(model.hasBusySessions || !flow.canChangeRoute)
                    .accessibilityIdentifier("deviceControlMode")
            }
            DeviceControlRouteSections(localAddress: $localAddress, peerAddress: $peerAddress, error: $error,
                showTouchTest: { showingTouchTest = true }, save: save)
        }
            .navigationTitle(String(localized: "Phone control"))
            .navigationBarTitleDisplayMode(.inline)
            .fullScreenCover(isPresented: $showingTouchTest) {
                TouchVerificationView(flow: DeviceControlCoordinator.shared)
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
            .task { DeviceControlCoordinator.shared.resume() }
    }
    private var changed: Bool {
        localAddress != flow.vpnConfiguration.localAddress || peerAddress != flow.vpnConfiguration.peerAddress
    }
    private func save() {
        do {
            try flow.saveVPNConfiguration(localAddress: localAddress, peerAddress: peerAddress)
            localAddress = flow.vpnConfiguration.localAddress
            peerAddress = flow.vpnConfiguration.peerAddress
            error = nil
        } catch let failure as CoreDeviceControlError {
            if case .unavailable(let message) = failure { error = message }
        } catch {
            self.error = String(localized: "Enter two different, valid IPv4 addresses")
        }
    }
}

/// Standalone per-route page kept for the in-run device control panel.
struct DeviceControlSettingsView: View {
    @State private var flow = DeviceControlCoordinator.shared
    @State private var showingTouchTest = false
    @State private var localAddress = DeviceControlCoordinator.shared.vpnConfiguration.localAddress
    @State private var peerAddress = DeviceControlCoordinator.shared.vpnConfiguration.peerAddress
    @State private var error: String?
    var body: some View {
        Form {
            DeviceControlRouteSections(localAddress: $localAddress, peerAddress: $peerAddress, error: $error,
                showTouchTest: { showingTouchTest = true }, save: save)
        }
            .navigationTitle(flow.route.controlTitle)
            .navigationBarTitleDisplayMode(.inline)
            .fullScreenCover(isPresented: $showingTouchTest) {
                TouchVerificationView(flow: DeviceControlCoordinator.shared)
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
            .task { DeviceControlCoordinator.shared.resume() }
    }
    private var changed: Bool {
        localAddress != flow.vpnConfiguration.localAddress || peerAddress != flow.vpnConfiguration.peerAddress
    }
    private func save() {
        do {
            try flow.saveVPNConfiguration(localAddress: localAddress, peerAddress: peerAddress)
            localAddress = flow.vpnConfiguration.localAddress
            peerAddress = flow.vpnConfiguration.peerAddress
            error = nil
        } catch let failure as CoreDeviceControlError {
            if case .unavailable(let message) = failure { error = message }
        } catch {
            self.error = String(localized: "Enter two different, valid IPv4 addresses")
        }
    }
}

/// Route-specific rows shared by both pages. State and the Save action live in
/// the hosting page; this view only renders them so toolbar styling stays with
/// the page-level toolbar.
struct DeviceControlRouteSections: View {
    @State private var flow = DeviceControlCoordinator.shared
    @Binding var localAddress: String
    @Binding var peerAddress: String
    @Binding var error: String?
    let showTouchTest: () -> Void
    let save: () -> Void
    private enum AddressField: Hashable { case local, peer }
    @FocusState private var editing: AddressField?
    var body: some View {
        Group {
            if flow.route == .vpnLoopback {
                vpnConfigurationSection
            }
            DeviceConnectionSection(showTouchTest: showTouchTest)
        }
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
}
