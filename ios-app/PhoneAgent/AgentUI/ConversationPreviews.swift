#if DEBUG
import SwiftUI
import UIKit

/// Developer-only Xcode previews for tuning the conversation UI. Page
/// previews render the real `ConversationView` against an in-memory
/// `ConversationStore` seeded with synthetic content, so layout, typography
/// and interaction tuning happen on the shipping views. The card gallery
/// drives `ToolInvocationView` directly with representative `ToolStep`
/// values. Nothing here is reachable from the shipped app.
@MainActor private enum ConversationPreviewSeed {
    static func makeModel() -> AgentViewModel {
        AgentViewModel(sessions: ConversationStore(inMemory: true), loadPersistentState: false)
    }

    /// Synthetic home-screen image for attachment and preview slots.
    static func syntheticImage() -> UIImage {
        UIGraphicsImageRenderer(size: CGSize(width: 300, height: 560)).image { context in
            UIColor.systemBlue.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 300, height: 560))
            UIColor.white.withAlphaComponent(0.85).setFill()
            for row in 0..<4 {
                for column in 0..<3 {
                    let rect = CGRect(x: 30 + column * 92, y: 64 + row * 122, width: 64, height: 64)
                    UIBezierPath(roundedRect: rect, cornerRadius: 14).fill()
                }
            }
        }
    }

    static let longResult = String(repeating: "已识别的应用行：设置、指南针、测距仪、文件、快捷指令、指针控制。\n", count: 40) + "列表到此结束。"

    @discardableResult
    static func seedCompleted(in model: AgentViewModel) -> UUID {
        let conversation = model.sessions.create(mode: .live)
        guard let first = model.sessions.begin(in: conversation, query: "打开设置，把深色模式开启，然后回到主屏幕") else { return conversation }
        model.sessions.beginAssistantTurn(first)
        model.sessions.completeAssistantTurn("我先查看当前屏幕，然后打开设置。",
            reasoning: "主屏幕没有直接看到设置图标，先截图确认当前页面，再决定是否需要搜索启动。", identity: first)
        model.sessions.updateTool(callID: "shot-1", name: "screenshot", state: .succeeded, detail: "截取当前屏幕",
            result: #"{"screen_information_mode":"screenshot","image_width":1179,"image_height":2556}"#, identity: first)
        model.sessions.updateTool(callID: "launch-1", name: "launch_app", state: .succeeded, detail: "启动设置 App",
            result: "已启动 com.apple.Preferences。",
            arguments: "{\n  \"bundle_id\" : \"com.apple.Preferences\"\n}", identity: first)
        model.sessions.updateTool(callID: "tap-1", name: "tap", state: .failed, detail: "轻点“显示与亮度”",
            result: "坐标 (540, 1180) 未命中可交互元素，操作未生效。",
            arguments: "{\n  \"x\" : 540,\n  \"y\" : 1180,\n  \"description\" : \"打开显示与亮度\"\n}", identity: first)
        model.sessions.updateTool(callID: "tap-2", name: "tap", state: .succeeded, detail: "轻点“深色模式”开关",
            result: "开关已切换为深色外观。",
            arguments: "{\n  \"x\" : 962,\n  \"y\" : 402,\n  \"description\" : \"切换深色模式\"\n}", identity: first)
        model.sessions.updateTool(callID: "home-1", name: "home", state: .succeeded, detail: "回到主屏幕",
            result: "已回到主屏幕。", identity: first)
        model.sessions.beginAssistantTurn(first)
        model.sessions.completeAssistantTurn("深色模式已开启，并已回到主屏幕。首次点击未命中目标，重试后成功。",
            reasoning: "“深色模式”开关位于显示与亮度页面顶部，首次点击坐标落在标题上，重试后命中。", identity: first)
        model.sessions.finish(first, phase: .completed, summary: "")
        model.sessions.addNotice("运行期间的系统提示以这种样式显示。", in: conversation)

        guard let second = model.sessions.begin(in: conversation, query: "屏幕上现在有哪些 App？列一下。") else { return conversation }
        model.sessions.beginAssistantTurn(second)
        model.sessions.completeAssistantTurn("", reasoning: "直接查询应用列表即可，无需截图。", identity: second)
        model.sessions.updateTool(callID: "apps-1", name: "list_apps", state: .succeeded, detail: "查询已安装应用",
            result: longResult, arguments: "{\n  \"filter\" : \"installed\"\n}", identity: second)
        model.sessions.beginAssistantTurn(second)
        model.sessions.completeAssistantTurn("共识别到 24 个应用，完整列表可在上方工具卡片中展开查看。",
            reasoning: "列表较长，折叠在工具卡片里，按需展开。", identity: second)
        model.sessions.finish(second, phase: .completed, summary: "")
        return conversation
    }

    /// Attachment bytes live in the store, so images are attached after the
    /// synchronous conversation seed. Attaching by message ID also works for
    /// finished runs, whose identity is no longer accepted.
    static func seedAttachments(_ model: AgentViewModel, conversationID: UUID) async {
        guard let png = syntheticImage().pngData(),
              let attachment = try? await model.attachments.store(png, name: "屏幕快照.png", conversationID: conversationID) else { return }
        let messages = model.sessions.conversation(conversationID)?.messages ?? []
        if let user = messages.first(where: { $0.role == .user && $0.attachments == nil }) {
            model.sessions.attach(attachment, to: user.id, in: conversationID)
        }
        if let shot = messages.last(where: { $0.tool?.callID == "shot-1" }) {
            model.sessions.attach(attachment, to: shot.id, in: conversationID)
        }
    }

    /// Seeds the composer with draft text plus one image and one text file so
    /// the draft strip and removal buttons render with representative content.
    /// The image and the file are also attached to the user messages, showing
    /// the message card style without removal buttons.
    static func seedDraft(_ model: AgentViewModel, conversationID: UUID) async {
        model.sessions.setDraft("统计完应用数量后，把这份运行记录整理成摘要。", in: conversationID)
        let messages = model.sessions.conversation(conversationID)?.messages ?? []
        let userMessages = messages.filter { $0.role == .user && $0.attachments == nil }
        guard let png = syntheticImage().pngData(),
              let image = try? await model.attachments.store(png, name: "屏幕快照.png", conversationID: conversationID) else { return }
        model.sessions.addDraftAttachment(image, in: conversationID)
        if let first = userMessages.first { model.sessions.attach(image, to: first.id, in: conversationID) }
        let log = "第 1 步 截取屏幕：成功\n第 2 步 打开设置：成功\n第 3 步 切换深色外观：成功"
        if let file = try? await model.attachments.store(Data(log.utf8), name: "运行记录.txt", conversationID: conversationID) {
            model.sessions.addDraftAttachment(file, in: conversationID)
            if userMessages.count > 1 { model.sessions.attach(file, to: userMessages[1].id, in: conversationID) }
        }
    }

    /// Seeds an assistant reply that links to remote screenshots the way the
    /// model writes them: prose links plus a Markdown image, so the inline
    /// "See image below" placeholder and the parsed bottom image region render
    /// together for styling checks. The download stays uncached.
    @discardableResult
    static func seedRemoteImage(in model: AgentViewModel) -> UUID {
        let conversation = model.sessions.create(mode: .live)
        guard let run = model.sessions.begin(in: conversation, query: "把当前屏幕截图发给我看看") else { return conversation }
        model.sessions.beginAssistantTurn(run)
        model.sessions.completeAssistantTurn("""
            截图完成，图片见下方。

            [下载高清 PNG](https://example.com/shots/screenshot-hd.png) · [查看原图对比](mona-splash-ink/comparison.png)

            ![设备屏幕截图](https://example.com/shots/screenshot-hd.png)

            ![对比图](mona-splash-ink/comparison.png)
            """, reasoning: "用户想看屏幕内容，直接返回截图链接。", identity: run)
        model.sessions.finish(run, phase: .completed, summary: "")
        return conversation
    }
}

private extension ToolStep {
    static func preview(_ callID: String, _ name: String, _ state: ToolStepState, _ detail: String,
                        result: String = "", arguments: String? = nil, skillName: String? = nil) -> ToolStep {
        ToolStep(callID: callID, name: name, state: state, detail: detail, result: result, arguments: arguments, skillName: skillName)
    }
}

/// Every `ToolStepState` plus the display edge cases: long scrollable result,
/// request arguments, skill title, lost historical screenshot, and a preview
/// slot image.
private struct ToolCardGallery: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                card(.preview("wait-r", "wait", .requested, "等待页面动画结束", arguments: #"{"seconds": 2}"#))
                card(.preview("shot-r", "screenshot", .running, "截取当前屏幕"))
                card(.preview("tap-a", "tap", .awaitingApproval, "轻点“文件”图标", arguments: #"{"x": 312, "y": 700, "description": "打开文件 App"}"#))
                card(.preview("tap-p", "tap", .approved, "已获授权，准备轻点“文件”图标", arguments: #"{"x": 312, "y": 700}"#))
                card(.preview("tap-e", "tap", .executing, "正在发送轻点动作", arguments: #"{"x": 312, "y": 700}"#))
                card(.preview("wait-s", "wait", .succeeded, "等待页面动画结束", result: "已等待 2 秒。"))
                card(.preview("apps-s", "list_apps", .succeeded, "查询已安装应用",
                    result: ConversationPreviewSeed.longResult, arguments: #"{"filter": "installed"}"#))
                card(.preview("launch-s", "launch_app", .succeeded, "启动设置 App",
                    result: "已启动 com.apple.Preferences。", arguments: #"{"bundle_id": "com.apple.Preferences"}"#)) {
                    Image(uiImage: ConversationPreviewSeed.syntheticImage()).resizable().scaledToFit()
                        .frame(maxHeight: 280).clipShape(RoundedRectangle(cornerRadius: 10))
                }
                card(.preview("skill-s", "load_skill", .succeeded, "",
                    result: """
                        {"skill_name":"Synthetic Guide","content":"# 使用步骤\\n1. 读取当前屏幕内容\\n2. 按文档顺序执行操作\\n3. 每步完成后再核对结果","resource":"SKILL.md","offset":0,"total_scalars":64,"next_offset":null}
                        """,
                    arguments: #"{"id": "C1F2A4D9-0000-4000-8000-000000000001", "revision": "r2", "resource": "SKILL.md"}"#,
                    skillName: "Synthetic Guide"))
                card(.preview("read-s", "read", .succeeded, "",
                    result: #"{"file_path":"notes.md","content":"1: # 运行记录\n2: 第 1 步 截取屏幕：成功\n3: 第 2 步 打开设置：成功\n4: 第 3 步 切换深色外观：成功","offset":1,"total_lines":4,"returned_lines":4,"next_offset":null,"truncated":false,"line_truncated":false}"#,
                    arguments: #"{"file_path": "notes.md", "limit": 2000, "offset": 1}"#))
                card(.preview("write-s", "write", .succeeded, "",
                    result: #"{"file_path":"todo.md","bytes_written":48,"written":true}"#,
                    arguments: """
                        {
                          "content" : "# 待办\\n- [x] 重构存储层\\n- [ ] 补充测试\\n- [ ] 清理历史日志",
                          "file_path" : "todo.md"
                        }
                        """))
                card(.preview("edit-a", "edit", .awaitingApproval, "",
                    arguments: """
                        {
                          "file_path" : "todo.md",
                          "old_string" : "- [ ] 补充测试",
                          "new_string" : "- [x] 补充测试\\n- [ ] 校验 diff 展示",
                          "replace_all" : false
                        }
                        """))
                card(.preview("edit-s", "edit", .succeeded, "",
                    result: #"{"file_path":"todo.md","bytes_written":52,"replacements":1,"edited":true}"#,
                    arguments: """
                        {
                          "file_path" : "todo.md",
                          "old_string" : "第 1 步 截取屏幕：成功\\n第 2 步 打开设置：成功",
                          "new_string" : "第 1 步 截取屏幕：成功\\n第 2 步 打开设置：已由用户手动完成"
                        }
                        """))
                card(.preview("shot-l", "screenshot", .succeeded, "截取当前屏幕",
                    result: #"{"screen_information_mode":"screenshot","image_width":1179,"image_height":2556}"#))
                card(.preview("tap-f", "tap", .failed, "轻点“显示与亮度”",
                    result: "坐标 (540, 1180) 未命中可交互元素，操作未生效。",
                    arguments: #"{"x": 540, "y": 1180, "description": "打开显示与亮度"}"#))
                card(.preview("tap-d", "tap", .denied, "轻点“深色模式”开关", arguments: #"{"x": 962, "y": 402}"#))
                card(.preview("type-c", "type_text", .cancelled, "输入搜索关键词"))
                card(.preview("drag-i", "drag", .interrupted, "拖动亮度滑块"))
                card(.preview("home-u", "home", .outcomeUnknown, "回到主屏幕"))
            }
            .padding(.horizontal, 16).padding(.vertical, 12)
        }
        .background(Color(uiColor: .systemBackground))
    }

    private func card(_ tool: ToolStep) -> some View {
        ToolInvocationView(configuration: ToolInvocationConfiguration(tool: tool)) { EmptyView() }
    }

    private func card<Preview: View>(_ tool: ToolStep, @ViewBuilder preview: () -> Preview) -> some View {
        ToolInvocationView(configuration: ToolInvocationConfiguration(tool: tool, hasPreview: true), preview: preview)
    }
}

/// Renders the seeded real conversation page. Model and history are prepared
/// synchronously; attachment bytes land on the next tick via the store actor.
private struct ConversationPreviewPage: View {
    var seed: (AgentViewModel) async -> UUID = { model in
        let conversation = ConversationPreviewSeed.seedCompleted(in: model)
        await ConversationPreviewSeed.seedAttachments(model, conversationID: conversation)
        return conversation
    }
    @State private var model: AgentViewModel?
    @State private var conversationID: UUID?

    var body: some View {
        Group {
            if let model, let conversationID {
                NavigationStack { ConversationView(model: model, conversationID: conversationID) }
            } else {
                Color(uiColor: .systemBackground)
            }
        }
        .task { await prepare() }
    }

    private func prepare() async {
        guard model == nil else { return }
        let seededModel = ConversationPreviewSeed.makeModel()
        let seededConversation = await seed(seededModel)
        model = seededModel
        conversationID = seededConversation
    }
}

#Preview("会话 · 已完成历史") {
    ConversationPreviewPage()
}

#Preview("消息 · 远程图片") {
    ConversationPreviewPage(seed: { model in
        ConversationPreviewSeed.seedRemoteImage(in: model)
    })
}

#Preview("输入框 · 草稿与附件") {
    ConversationPreviewPage(seed: { model in
        let conversation = ConversationPreviewSeed.seedCompleted(in: model)
        await ConversationPreviewSeed.seedDraft(model, conversationID: conversation)
        return conversation
    })
}

#Preview("输入框 · 附件导入占位") {
    HStack(spacing: 8) {
        PendingAttachmentCard(name: nil)
        PendingAttachmentCard(name: "report.md")
    }
    .padding(16)
    .background(Color(uiColor: .systemBackground))
}

#Preview("工具卡片 · 全部状态") {
    ToolCardGallery()
}
#endif
