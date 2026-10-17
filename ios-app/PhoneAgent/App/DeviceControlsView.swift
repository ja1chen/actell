import SwiftUI

struct DeviceControlsView: View {
    @ObservedObject var model: AgentViewModel
    @ObservedObject private var capture: ScreenCaptureController
    @Environment(\.dismiss) private var dismiss
    init(model: AgentViewModel) { self.model = model; capture = model.capture }
    var body: some View {
        NavigationStack {
            Group {
                if DeviceControlRoute.current != .localCaptureUSB {
                    ESP32ControlSettingsView()
                } else {
                    legacyControls
                }
            }
            .navigationTitle(DeviceControlRoute.current != .localCaptureUSB ? DeviceControlRoute.current.controlTitle : String(localized: "Device control")).navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button(String(localized: "Done")) { dismiss() } } }
        }
    }
    private var legacyControls: some View {
        Form {
            Section {
                Label(capture.status, systemImage: "rectangle.inset.filled.and.person.filled")
                Button(String(localized: "Allow full-screen capture")) { capture.present() }
                    .disabled(capture.active || capture.busy || !capture.isSupported || model.hasBusySessions)
                    .accessibilityIdentifier("startScreenCapture")
                Button(String(localized: "Stop capture"), role: .destructive) { model.stopCapture() }
                    .disabled(!capture.active && !capture.busy).accessibilityIdentifier("stopScreenCapture")
            } header: { Text(String(localized: "Screen capture")) } footer: {
                Text(String(localized: "Screen viewing uses full-screen capture on this device. After you start a task, the agent sends screenshots to the conversation's selected provider as needed."))
            }
            Section {
                Text(model.usbConnectionStatus.message)
                    .foregroundStyle(model.usbConnectionStatus.isFailure ? Color.red : Color.primary)
                    .accessibilityIdentifier("usbConnectionStatus")
                if model.usbConnectionStatus.isConnecting {
                    HStack { ProgressView(); Text(String(localized: "Connecting…")) }
                    Button(String(localized: "Cancel connection"), role: .cancel) { model.disconnect() }.accessibilityIdentifier("cancelUSBConnection")
                } else if model.usbConnectionStatus.isReady {
                    Button(String(localized: "Disconnect USB"), role: .destructive) { model.disconnect() }.accessibilityIdentifier("disconnectUSB")
                } else {
                    Button(String(localized: "Connect USB NCM")) { model.connectUSB() }
                        .disabled(model.hasBusySessions).accessibilityIdentifier("connectUSBNCM")
                }
            } header: { Text("USB NCM") } footer: {
                Text(String(localized: "Tapping and dragging require USB HID. Screenshots do not require an ESP32 connection. The connection stays open between tasks; disconnecting stops current input. Set USB Ethernet to 192.168.7.2 with subnet mask 255.255.255.0 and leave router and DNS blank."))
            }
            Section(String(localized: "Diagnostics")) { USBDiagnosticsControls(model: model) }
            if let error = model.errorMessage { Text(error).foregroundStyle(.red) }
        }
    }
}

private struct USBDiagnosticsControls: View {
    @ObservedObject var model: AgentViewModel
    @State private var showingLog = false
    @State private var report = ""
    @State private var copied = false

    private func refresh() { report = model.usbDiagnosticReport() }
    private func copy() {
        refresh()
        // Only this explicit button writes the clipboard; never read it.
        UIPasteboard.general.string = report
        copied = true
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Button(String(localized: "Copy diagnostic log"), action: copy).accessibilityIdentifier("copyUSBDiagnostics")
                Button(String(localized: "View log")) { refresh(); showingLog = true }.accessibilityIdentifier("showUSBDiagnostics")
            }.buttonStyle(.bordered)
            if copied { Text(String(localized: "Diagnostic log copied")).font(.caption).accessibilityIdentifier("usbDiagnosticsCopied") }
            Text(String(localized: "Keeps the latest 600 capture and USB diagnostics for this app session, and the latest 300 Muse diagnostics across app launches. Screenshots, task text, and keys are excluded."))
                .font(.caption).foregroundStyle(.secondary)
        }
        .sheet(isPresented: $showingLog) {
            NavigationStack {
                ScrollView {
                    Text(report).font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding()
                        .accessibilityIdentifier("usbDiagnosticsReport")
                }
                .navigationTitle(String(localized: "Capture and USB diagnostics"))
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) { Button(String(localized: "Done")) { showingLog = false } }
                    ToolbarItemGroup(placement: .topBarTrailing) {
                        Button(String(localized: "Refresh"), action: refresh).accessibilityIdentifier("refreshUSBDiagnostics")
                        Button(String(localized: "Copy"), action: copy).accessibilityIdentifier("copyUSBReport")
                    }
                }
            }
        }
    }
}
