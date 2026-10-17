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
            .navigationTitle(DeviceControlRoute.current != .localCaptureUSB ? DeviceControlRoute.current.controlTitle : "设备控制").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("完成") { dismiss() } } }
        }
    }
    private var legacyControls: some View {
        Form {
            Section {
                Label(capture.status, systemImage: "rectangle.inset.filled.and.person.filled")
                Button("授权全屏采集") { capture.present() }
                    .disabled(capture.active || capture.busy || !capture.isSupported || model.hasBusySessions)
                    .accessibilityIdentifier("startScreenCapture")
                Button("停止采集", role: .destructive) { model.stopCapture() }
                    .disabled(!capture.active && !capture.busy).accessibilityIdentifier("stopScreenCapture")
            } header: { Text("屏幕采集") } footer: {
                Text("查看屏幕使用本机全屏采集。开始任务后，Agent 按需将截图发送给会话所选供应商。")
            }
            Section {
                Text(model.usbConnectionStatus.message)
                    .foregroundStyle(model.usbConnectionStatus.isFailure ? Color.red : Color.primary)
                    .accessibilityIdentifier("usbConnectionStatus")
                if model.usbConnectionStatus.isConnecting {
                    HStack { ProgressView(); Text("正在连接…") }
                    Button("取消连接", role: .cancel) { model.disconnect() }.accessibilityIdentifier("cancelUSBConnection")
                } else if model.usbConnectionStatus.isReady {
                    Button("断开 USB", role: .destructive) { model.disconnect() }.accessibilityIdentifier("disconnectUSB")
                } else {
                    Button("连接 USB NCM") { model.connectUSB() }
                        .disabled(model.hasBusySessions).accessibilityIdentifier("connectUSBNCM")
                }
            } header: { Text("USB NCM") } footer: {
                Text("点击和拖动需要 USB HID，截图无需连接 ESP32。任务结束后连接保持；断开会停止当前输入。USB 以太网地址 192.168.7.2，掩码 255.255.255.0，路由器与 DNS 留空。")
            }
            Section("故障诊断") { USBDiagnosticsControls(model: model) }
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
                Button("复制诊断日志", action: copy).accessibilityIdentifier("copyUSBDiagnostics")
                Button("查看日志") { refresh(); showingLog = true }.accessibilityIdentifier("showUSBDiagnostics")
            }.buttonStyle(.bordered)
            if copied { Text("诊断日志已复制").font(.caption).accessibilityIdentifier("usbDiagnosticsCopied") }
            Text("保留本次 App 运行最近 600 条采集与 USB 诊断，含首帧状态及丢帧原因；失败后可直接复制。采集与 USB 记录在重启后清空，Muse 请求诊断另保留最近 300 条并跨重启保存。不含截图、任务正文或密钥。")
                .font(.caption).foregroundStyle(.secondary)
        }
        .sheet(isPresented: $showingLog) {
            NavigationStack {
                ScrollView {
                    Text(report).font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding()
                        .accessibilityIdentifier("usbDiagnosticsReport")
                }
                .navigationTitle("采集与 USB 诊断日志")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) { Button("完成") { showingLog = false } }
                    ToolbarItemGroup(placement: .topBarTrailing) {
                        Button("刷新", action: refresh).accessibilityIdentifier("refreshUSBDiagnostics")
                        Button("复制", action: copy).accessibilityIdentifier("copyUSBReport")
                    }
                }
            }
        }
    }
}
