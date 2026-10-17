import SwiftUI

struct SettingsView: View {
    @ObservedObject var model: AgentViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var control = PairingFlow.shared
    @State private var clear = false
    @State private var clearAssets = false
    @State private var assetStatus = ""
    var body: some View {
        NavigationStack {
            Form {
                Section(String(localized: "Model")) {
                    NavigationLink { ProvidersView(model: model) } label: {
                        Text(String(localized: "Provider"))
                    }.accessibilityIdentifier("openProviders")
                }
                Section(String(localized: "Phone control")) {
                    Picker(String(localized: "Connection mode"), selection: Binding(get: { control.route }, set: { _ = control.selectRoute($0) })) {
                        Text(DeviceControlRoute.vpnLoopback.title).tag(DeviceControlRoute.vpnLoopback)
                        Text(DeviceControlRoute.ncmDeveloper.title).tag(DeviceControlRoute.ncmDeveloper)
                    }.disabled(model.hasBusySessions || !control.canChangeRoute)
                        .accessibilityIdentifier("deviceControlMode")
                    NavigationLink { ESP32ControlSettingsView() } label: {
                        Text(String(localized: "Connection and verification"))
                    }.accessibilityIdentifier("esp32ControlSettings")
                }
                Section(String(localized: "Execution mode")) {
                    NavigationLink { BackgroundSettingsView() } label: {
                        Text(String(localized: "Mode"))
                    }.accessibilityIdentifier("openBackgroundSettings")
                }
                Section(String(localized: "Extensions")) {
                    NavigationLink { SkillsView(model: model, store: model.skills) } label: {
                        Text(String(localized: "Skills"))
                    }.accessibilityIdentifier("manageSkills")
                    NavigationLink { MuseConnectionView(model: model) } label: {
                        Text("Muse Gadget")
                    }.accessibilityIdentifier("openMuseConnection")
                }
                Section(String(localized: "Local records")) {
                    Button(String(localized: "Clear local conversations and task records"), role: .destructive) { clear = true }
                        .disabled(model.hasBusySessions)
                    Button(String(localized: "Remove unused attachments"), role: .destructive) { clearAssets = true }
                        .disabled(model.hasBusySessions).accessibilityIdentifier("clearUnusedAttachments")
                    if !assetStatus.isEmpty { Text(assetStatus).font(.caption) }
                }
                if let warning = model.storageWarning { Text(warning).foregroundStyle(.orange) }
            }
            .navigationTitle(String(localized: "Settings"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button(String(localized: "Close")) { dismiss() } } }
            .confirmationDialog(String(localized: "Delete tasks and results saved on this device? They cannot be recovered in the app."), isPresented: $clear, titleVisibility: .visible) {
                Button(String(localized: "Clear records"), role: .destructive) { model.clearHistory() }
            }
            .alert(String(localized: "Remove unused attachments?"), isPresented: $clearAssets) {
                Button(String(localized: "Cancel"), role: .cancel) {}
                Button(String(localized: "Clean up"), role: .destructive) {
                    Task {
                        do { assetStatus = String(localized: "Removed \(try await model.clearUnreferencedAttachments()) unused files") }
                        catch { assetStatus = String(localized: "Could not clean up attachments. Original files were kept.") }
                    }
                }
            } message: { Text(String(localized: "Original images and files referenced by messages and drafts will be kept. Deleted unused files cannot be recovered.")) }
        }
    }
}


private struct BackgroundSettingsView: View {
    @ObservedObject private var settings = BackgroundSettingsStore.shared
    @ObservedObject private var background = BackgroundExecutionCoordinator.shared

    var body: some View {
        Form {
            ForEach(BackgroundMechanism.allCases) { mechanism in
                Section {
                    Toggle(mechanism.title, isOn: Binding(
                        get: { settings.selection.contains(mechanism) },
                        set: { selected in
                            if mechanism == .location { background.setLocationSelected(selected) }
                            else { settings.set(mechanism, selected: selected) }
                        }))
                        .disabled(settings.futureSchema)
                        .accessibilityIdentifier("backgroundMechanism." + mechanism.rawValue)
                    if mechanism == .location && settings.selection.contains(.location) {
                        if background.location?.authorization == .denied {
                            Link(String(localized: "Open system Settings"), destination: URL(string: UIApplication.openSettingsURLString)!)
                                .accessibilityIdentifier("backgroundLocationSettings")
                        }
                    }
                } footer: {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(explanation(mechanism))
                        if mechanism == .location && settings.selection.contains(.location) {
                            Text(locationPermissionStatus)
                                .accessibilityIdentifier("backgroundLocationPermissionStatus")
                        }
                    }
                }
            }
            Section {
                Toggle(String(localized: "Keep running in background"), isOn: Binding(
                    get: { settings.residentEnabled }, set: { settings.setResident($0) }))
                    .disabled(settings.futureSchema)
                    .accessibilityIdentifier("backgroundResidentEnabled")
            } footer: {
                VStack(alignment: .leading, spacing: 6) {
                    Text(String(localized: "Keep the selected audio, picture-in-picture, or location options active after a task ends so later tasks can start in the background. Uses more battery; turn off when not needed."))
                    if settings.residentEnabled && settings.selection.intersection(BackgroundMechanism.continuous).isEmpty {
                        Text(String(localized: "Turn on audio, picture-in-picture, or location first. System background tasks alone cannot keep the app on standby."))
                            .accessibilityIdentifier("backgroundNoIdleSource")
                    }
                }
            }
            if let warning = settings.warning {
                Section { Text(warning).foregroundStyle(.orange) }
            }
        }
        .navigationTitle(String(localized: "Background execution"))
        .navigationBarTitleDisplayMode(.inline)
    }

    private func explanation(_ mechanism: BackgroundMechanism) -> String {
        switch mechanism {
        case .audio:
            return String(localized: "Plays silent audio to help tasks continue after switching apps. No additional permission is needed. Playback stops when the task ends, or continues during background standby. May use more battery.")
        case .pictureInPicture:
            return background.media?.supported == true
                ? String(localized: "Shows task status in a floating window to help tasks continue after switching apps. No additional permission is needed. Closing the window stops this option.")
                : String(localized: "This device does not support picture-in-picture. Choose another background option.")
        case .systemTask:
            return String(localized: "Requests system time to continue the current task. No additional permission is needed. The system decides availability and duration; the task pauses if the system cancels or ends background execution.")
        case .location:
            return String(localized: "Uses location services to help tasks continue after switching apps. Requires location access while using the app. Only used during a task or background standby. Coordinates are not saved or uploaded. Shows the system location indicator and uses more battery. Other features do not require location.")
        }
    }

    private var locationPermissionStatus: String {
        guard let location = background.location else { return String(localized: "Location is currently unavailable.") }
        if !location.servicesEnabled { return String(localized: "System Location Services are off. Turn them on in system Settings.") }
        switch location.authorization {
        case .notDetermined: return String(localized: "Not authorized yet. Turning on location requests permission.")
        case .denied: return String(localized: "Location access is not allowed. Change it in system Settings. Other background options are unaffected.")
        case .restricted: return String(localized: "System restrictions prevent location access. This option is currently unavailable.")
        case .authorizedWhenInUse, .authorizedAlways: return String(localized: "Location access is allowed. It is only used during a task or background standby.")
        @unknown default: return String(localized: "Location permission could not be determined. Check system Settings.")
        }
    }
}
