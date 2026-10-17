#if DEBUG
import SwiftUI
import UniformTypeIdentifiers
import UIKit

/// Opt-in diagnostics; never appears in normal Debug or Release navigation.
struct MuseDevelopmentView: View {
    @ObservedObject var model: AgentViewModel
    var body: some View {
        List {
            NavigationLink("旧版连接配置") { MuseDeveloperConnectionView(model: model) }
        }
        .navigationTitle("Muse 开发工具")
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
                LabeledContent("连接状态", value: statusText).accessibilityIdentifier("museConnectionStatus")
                if let message = connection.message { Text(message).font(.caption).accessibilityIdentifier("museConnectionMessage") }
                if connection.isActive {
                    Button("停止连接", role: .destructive) { connection.stop() }
                        .disabled(connection.status == .stopping).accessibilityIdentifier("museStopConnection")
                } else {
                    Button("启动连接") { starting = true }
                        .disabled(changed || connection.settings.certificate == nil || connection.settings.clients.isEmpty || !canEdit)
                        .accessibilityIdentifier("museStartConnection")
                }
            } header: { Text("Muse Gadget") } footer: {
                Text("仅允许已授权客户端访问。截图和应用列表会提供给该客户端；已开放的操作直接执行，无需逐次确认。锁屏或后台资格失效时可能暂停，回到前台后自动恢复。")
            }
            Section {
                TextField("证书对应的 IP 或域名", text: $host).textInputAutocapitalization(.never).autocorrectionDisabled()
                    .focused($focusedField, equals: .host).accessibilityIdentifier("museServerHost")
                TextField("端口", text: $port).keyboardType(.numberPad).focused($focusedField, equals: .port).accessibilityIdentifier("museServerPort")
                TextField("允许的客户端来源 IP，每行一个", text: $sources, axis: .vertical)
                    .lineLimit(2...4).textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.asciiCapable)
                    .focused($focusedField, equals: .sources).accessibilityIdentifier("museAllowedSources")
                if changed {
                    Button("保存连接配置") { perform { try connection.configure(host: host, port: port, sources: sources); reload() } }
                        .accessibilityIdentifier("museSaveConnection")
                }
            } header: { Text("连接地址") } footer: {
                Text("填写 Muse 客户端可到达的 iPhone 地址，且须与服务器证书匹配。来源 IP 须是执言实际收到的地址；不支持网段或通配符。")
            }.disabled(!canEdit)
            Section {
                if let certificate = connection.settings.certificate {
                    LabeledContent("服务器证书", value: certificate.name)
                    LabeledContent("到期", value: certificate.expiresAt.formatted(date: .abbreviated, time: .omitted))
                    Text("SHA-256：" + certificate.fingerprint).font(.caption.monospaced()).textSelection(.enabled)
                        .accessibilityIdentifier("museCertificateFingerprint")
                } else { Text("尚未导入服务器证书").foregroundStyle(.secondary).accessibilityIdentifier("museMissingCertificate") }
                Button(connection.settings.certificate == nil ? "导入证书" : "更换证书", systemImage: "doc.badge.plus") { importing = true }
                    .accessibilityIdentifier("museImportCertificate")
                if connection.settings.certificate != nil {
                    Button("移除证书", role: .destructive) { removingCertificate = true }
                }
            } header: { Text("服务器证书") } footer: {
                Text("导入包含证书与私钥的 .p12 或 .pfx 文件。证书与导入密码仅保存在本机钥匙串；客户端仍须验证证书和连接地址。")
            }.disabled(!canEdit)
            Section {
                if connection.settings.clients.isEmpty { Text("暂无已授权客户端").foregroundStyle(.secondary).accessibilityIdentifier("museNoClients") }
                ForEach(connection.settings.clients) { client in
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(client.name).accessibilityIdentifier("museClientName-" + client.id)
                            Text(String(client.id.prefix(8))).font(.caption.monospaced()).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("撤销", role: .destructive) { revoking = client }.buttonStyle(.borderless)
                            .accessibilityIdentifier("museRevokeClient-" + client.id)
                    }
                }
                Button("添加客户端", systemImage: "person.badge.plus") { sheet = .addClient }
                    .disabled(changed || connection.settings.host.isEmpty || connection.settings.sources.isEmpty)
                    .accessibilityIdentifier("museAddClient")
            } header: { Text("已授权客户端") } footer: {
                Text("添加后会生成独立连接信息，仅在本次添加时提供。请通过安全方式交给你信任的 Muse 客户端。撤销会拒绝后续请求，并停止该客户端当前运行；已送出的动作无法撤回。")
            }
            Section("Muse 设备") {
                Text("板卡的账号与 Wi-Fi 配对请在 Muse App 中完成。")
                Text("当前尚未验证 Home Link 联动；启动监听不代表 Muse 已连接或模型已看到截图。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Muse 连接").navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("完成输入") { focusedField = nil }.accessibilityIdentifier("museFinishInput")
            }
        }
        .onAppear { reload() }
        .fileImporter(isPresented: $importing, allowedContentTypes: [UTType(filenameExtension: "p12") ?? .data, UTType(filenameExtension: "pfx") ?? .data]) { result in
            switch result {
            case .success(let url): sheet = .certificate(url)
            case .failure: connection.message = "证书选择未完成，可重新选择"
            }
        }
        .sheet(item: $sheet) { destination in
            switch destination {
            case .addClient: MuseAddClientSheet(connection: connection)
            case .certificate(let url): MuseCertificateSheet(connection: connection, url: url)
            }
        }
        .confirmationDialog("允许已授权客户端访问执言？", isPresented: $starting, titleVisibility: .visible) {
            Button("允许并启动") { perform { try connection.start() } }
            Button("取消", role: .cancel) {}
        } message: { Text("客户端可读取屏幕与应用列表并请求操控；已开放的操作无需逐次确认。此操作会在当前端口启动 HTTPS 监听。") }
        .confirmationDialog("移除服务器证书？", isPresented: $removingCertificate, titleVisibility: .visible) {
            Button("移除", role: .destructive) { perform { try connection.removeCertificate() } }
        }
        .confirmationDialog("撤销这个客户端？", isPresented: Binding(get: { revoking != nil }, set: { if !$0 { revoking = nil } }), titleVisibility: .visible) {
            Button("撤销客户端", role: .destructive) { if let client = revoking { perform { try connection.revoke(client) } }; revoking = nil }
        } message: { Text(revoking?.name ?? "") }
    }
    private var statusText: String {
        switch connection.status {
        case .stopped: return "未启动"
        case .starting: return "正在启动"
        case .listening: return "正在监听"
        case .running: return "远程任务正在占用设备"
        case .stopping: return "正在停止并释放执行"
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
                SecureField("证书导入密码", text: $password).accessibilityIdentifier("museCertificatePassword")
                if let error { Text(error).foregroundStyle(.red) }
                Text("导入失败时原证书保留。导入不会自动启动连接。私钥和密码不会写入连接信息。")
                    .font(.caption).foregroundStyle(.secondary)
            }.navigationTitle("导入服务器证书")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("取消") { password = ""; dismiss() } }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("导入") {
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
                        LabeledContent("设备", value: invitation.client.name)
                        Text("设备编号：" + invitation.client.id).font(.caption.monospaced()).textSelection(.enabled)
                        Text("连接信息已生成").accessibilityIdentifier("museInvitationReady")
                        Text("包含此设备独有凭据与公开服务器证书，10 分钟内有效。通过你控制的 USB 串口交付；普通局域网页面不属于可信交付渠道。")
                            .font(.caption)
                        Button(copied ? "已复制（5 分钟后过期）" : "复制连接信息") {
                            UIPasteboard.general.setItems([[UTType.utf8PlainText.identifier: invitation.text]], options: [.localOnly: true, .expirationDate: Date().addingTimeInterval(300)])
                            copied = true
                        }.accessibilityIdentifier("museCopyInvitation")
                        Text("仅交付到你控制的 USB 配置工具；不要发送到聊天、普通网页或不可信串口。设备拿到材料后仍需在此申请绑定和授权。")
                        Text("关闭后不会再次显示密钥。若未成功交付，请撤销客户端后重新添加。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                } else {
                    Section {
                        TextField("客户端名称", text: $name).accessibilityIdentifier("museClientNameInput")
                        if let error { Text(error).foregroundStyle(.red) }
                    } footer: { Text("例如书桌上的 Muse。生成材料不授予任何能力；设备完成可信 USB 配置并申请绑定后，你再确认身份与授权。") }
                }
            }.navigationTitle(invitation == nil ? "添加客户端" : "客户端连接信息")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button(invitation == nil ? "取消" : "完成") { dismiss() } }
                    if invitation == nil {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("添加") {
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
