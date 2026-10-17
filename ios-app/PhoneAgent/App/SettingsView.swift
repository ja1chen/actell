import SwiftUI

struct SettingsView: View {
    @ObservedObject var model: AgentViewModel
    @Environment(\.dismiss) private var dismiss
    @AppStorage(BackgroundPlaybackMode.defaultsKey) private var backgroundMode = BackgroundPlaybackMode.defaultMode.rawValue
    @AppStorage(BackgroundPlaybackMode.residentDefaultsKey) private var backgroundResident = false
    @State private var control = PairingFlow.shared
    @State private var clear = false
    @State private var clearAssets = false
    @State private var assetStatus = ""
    var body: some View {
        NavigationStack {
            Form {
                Section("模型") {
                    NavigationLink { ProvidersView(model: model) } label: {
                        Text("供应商")
                    }.accessibilityIdentifier("openProviders")
                }
                Section("手机操控") {
                    Picker("连接模式", selection: Binding(get: { control.route }, set: { _ = control.selectRoute($0) })) {
                        Text(DeviceControlRoute.vpnLoopback.title).tag(DeviceControlRoute.vpnLoopback)
                        Text(DeviceControlRoute.ncmDeveloper.title).tag(DeviceControlRoute.ncmDeveloper)
                    }.disabled(model.hasBusySessions || !control.canChangeRoute)
                        .accessibilityIdentifier("deviceControlMode")
                    NavigationLink { ESP32ControlSettingsView() } label: {
                        Text("连接与验证")
                    }.accessibilityIdentifier("esp32ControlSettings")
                }
                Section {
                    Picker("执行模式", selection: $backgroundMode) {
                        ForEach(BackgroundPlaybackMode.allCases) { mode in Text(mode.title).tag(mode.rawValue) }
                    }.accessibilityIdentifier("backgroundPlaybackMode")
                    Toggle("后台常驻", isOn: $backgroundResident)
                        .accessibilityIdentifier("backgroundResidentEnabled")
                } header: {
                    Text("后台执行")
                } footer: {
                    Text(backgroundMode == BackgroundPlaybackMode.systemTask.rawValue
                         ? "系统任务会显示系统进度。开启常驻后，空闲时用音频等待新任务。"
                         : "开启后，无任务时也保持所选后台模式。")
                }
                Section("扩展能力") {
                    NavigationLink { SkillsView(model: model, store: model.skills) } label: {
                        Text("技能")
                    }.accessibilityIdentifier("manageSkills")
                    NavigationLink { MuseConnectionView(model: model) } label: {
                        Text("Muse Gadget")
                    }.accessibilityIdentifier("openMuseConnection")
                }
                Section("本地记录") {
                    Button("清空本地会话与任务记录", role: .destructive) { clear = true }
                        .disabled(model.hasBusySessions)
                    Button("清理未引用附件", role: .destructive) { clearAssets = true }
                        .disabled(model.hasBusySessions).accessibilityIdentifier("clearUnusedAttachments")
                    if !assetStatus.isEmpty { Text(assetStatus).font(.caption) }
                }
                if let warning = model.storageWarning { Text(warning).foregroundStyle(.orange) }
            }
            .navigationTitle("设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() } } }
            .confirmationDialog("删除本机保存的任务和结果？无法在 App 内恢复。", isPresented: $clear, titleVisibility: .visible) {
                Button("清空记录", role: .destructive) { model.clearHistory() }
            }
            .alert("清理未引用附件？", isPresented: $clearAssets) {
                Button("取消", role: .cancel) {}
                Button("清理", role: .destructive) {
                    Task {
                        do { assetStatus = "已清理 \(try await model.clearUnreferencedAttachments()) 个未引用文件" }
                        catch { assetStatus = "未能清理附件；原文件保留" }
                    }
                }
            } message: { Text("现有消息与草稿引用的原图和文件会保留。未引用文件删除后无法恢复。") }
        }
    }
}
