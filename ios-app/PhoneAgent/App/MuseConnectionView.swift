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
                Toggle("Muse Gadget 服务", isOn: Binding(get: { connection.isEnabled }, set: { enabled in
                    if enabled { perform { try connection.start() } }
                    else { connection.stop() }
                }))
                .disabled(!connection.isEnabled && (connection.status == .starting || connection.status == .stopping || model.hasBusySessions))
                .accessibilityIdentifier("museAllowConnection")
                LabeledContent("状态", value: connectionStatus)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("状态")
                    .accessibilityValue(connectionStatus)
                    .accessibilityIdentifier("museServiceStatus")
            } footer: {
                Text(connection.connectionIssue ?? "与 Muse 处于同一局域网。")
            }
            Section {
                if connection.settings.clients.isEmpty {
                    Text("尚未添加设备").foregroundStyle(.secondary)
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
                            Text("添加 Muse")
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .tint(.blue)
                    .disabled(!connection.pairing.available || model.hasBusySessions)
                    .accessibilityIdentifier("museAddCompanion")
                }
            } header: { Text("设备") } footer: {
                Text("添加设备后，可分别选择允许访问的内容。")
            }
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("--muse-development") {
                Section {
                    NavigationLink("Muse 开发工具") { MuseDevelopmentView(model: model) }
                }
            }
            #endif
        }
        .navigationTitle("Muse Gadget").navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button(diagnosticsCopied ? "诊断日志已复制" : "复制诊断日志") {
                        UIPasteboard.general.string = model.usbDiagnosticReport()
                        diagnosticsCopied = true
                    }
                    .accessibilityIdentifier("copyMuseDiagnostics")
                } label: { Label("更多", systemImage: "ellipsis") }
            }
        }
        .sheet(item: $selected) { MuseDevicePermissionsSheet(connection: connection, client: $0) }
        .sheet(isPresented: $adding, onDismiss: { connection.cancelPairing() }) {
            MuseLANPairingSheet(connection: connection)
        }
        .alert("操作未完成", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("好", role: .cancel) { error = nil }
        } message: { Text(error ?? "") }
        .confirmationDialog("移除这个设备？", isPresented: Binding(get: { revoking != nil }, set: { if !$0 { revoking = nil } }), titleVisibility: .visible) {
            Button("移除设备", role: .destructive) {
                if let client = revoking { perform { try connection.revoke(client) } }
                revoking = nil
            }
        } message: { Text("将停止此设备的任务并关闭访问权限。") }
    }
    private var connectionStatus: String {
        switch connection.status {
        case .stopped: return connection.connectionIssue != nil ? "服务未运行" : connection.isEnabled ? "已暂停" : "已停止"
        case .starting: return "正在启动"
        case .listening, .running: return "运行中"
        case .stopping: return "正在停止"
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
            if client.lanPairingState == .pendingAck { return "正在完成配对" }
            return client.bootstrapExpiresAt.map({ $0 <= now }) == true ? "配对已过期" : "配对未完成"
        }
        if client.scopes.isEmpty { return "权限未开放" }
        guard connection.isPeerOnline(client.id) else { return "未连接" }
        return "已连接"
    }
    private func removeButton(_ client: RemoteClientRegistration) -> some View {
        Button("移除", role: .destructive) { revoking = client }
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
                        Text("名称")
                        TextField("设备名称", text: $name)
                            .multilineTextAlignment(.trailing)
                            .autocorrectionDisabled()
                            .accessibilityIdentifier("museDeviceName")
                    }
                }
                Section {
                    ForEach(MuseCompanionScope.allCases) { scope in
                        Toggle(scope.title, isOn: Binding(get: { scopes.contains(scope) }, set: { enabled in
                            if enabled { scopes.insert(scope) } else { scopes.remove(scope) }
                        }))
                        .accessibilityIdentifier("musePermission-" + scope.rawValue)
                    }
                } header: { Text("允许访问") } footer: {
                    Text("截图和应用信息可能经 Muse 发送给其服务或模型。已开放的操作直接执行，无需逐次确认。")
                        .accessibilityIdentifier("museCapabilityDataDisclosure")
                }
                Section {
                    Button("移除设备", role: .destructive) { removing = true }
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
            .confirmationDialog("移除这个设备？", isPresented: $removing, titleVisibility: .visible) {
                Button("移除设备", role: .destructive) {
                    do { try connection.revoke(client); dismiss() }
                    catch { self.error = error.localizedDescription }
                }
            } message: { Text("将停止此设备的任务并关闭访问权限。") }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
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
                            Label("已配对", systemImage: "checkmark.circle.fill")
                                .frame(maxWidth: .infinity, alignment: .center)
                                .alignmentGuide(.listRowSeparatorLeading) { _ in 0 }
                                .accessibilityIdentifier("musePairingComplete")
                            Text(name)
                                .frame(maxWidth: .infinity, alignment: .center)
                                .multilineTextAlignment(.center)
                        }
                    } else if let pending = connection.pairing.pending {
                        Section {
                            Text(pending.name).font(.headline)
                                .frame(maxWidth: .infinity, alignment: .center)
                                .multilineTextAlignment(.center)
                            if pending.approved {
                                ProgressView("正在完成配对")
                                    .frame(maxWidth: .infinity, alignment: .center)
                                    .multilineTextAlignment(.center)
                                    .padding(.vertical, 8)
                            } else {
                                Button("允许") { perform { try connection.approvePairing() } }
                                    .accessibilityIdentifier("musePairingAllow")
                                Button("拒绝", role: .destructive) { connection.pairing.reject() }
                                    .accessibilityIdentifier("musePairingReject")
                            }
                        }
                    } else if connection.pairing.windowRemaining > 0 {
                        Section {
                            ProgressView("等待 Muse 申请")
                                .frame(maxWidth: .infinity, alignment: .center)
                                .multilineTextAlignment(.center)
                                .padding(.vertical, 8)
                        } footer: {
                            Text("在 Muse 上选择“连接 Actell”。")
                        }
                    } else {
                        Section {
                            Text("添加已结束")
                                .frame(maxWidth: .infinity, alignment: .center)
                                .multilineTextAlignment(.center)
                            Button("重新添加") { perform { try connection.openPairingWindow() } }
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
            .navigationTitle("添加 Muse").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(connection.pairing.completedName == nil ? "取消" : "完成") { dismiss() }
                }
            }
        }
    }
    private func perform(_ action: () throws -> Void) {
        do { try action() } catch { self.error = error.localizedDescription }
    }
}
