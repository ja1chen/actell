#if DEBUG
import SwiftUI
import UIKit

/// Developer-only Xcode previews for tuning the conversation UI. Page
/// previews render the real `ConversationView` against an in-memory
/// `ConversationStore` seeded with synthetic content, so layout, typography
/// and interaction tuning happen on the shipping views. Card previews drive
/// `ToolInvocationView` and `ToolApprovalCard` directly with representative
/// `ToolStep` values. Nothing here is reachable from the shipped app.
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

    @discardableResult
    static func seedActive(in model: AgentViewModel) -> UUID {
        let conversation = model.sessions.create(mode: .live)
        guard let run = model.sessions.begin(in: conversation, query: "看看屏幕上有哪些应用，统计一下数量") else { return conversation }
        model.sessions.beginAssistantTurn(run)
        model.sessions.appendReasoning("正在请求屏幕内容，等待设备返回当前画面。", identity: run)
        model.sessions.appendText("已收到截图，正在识别图标并统计数量…", identity: run)
        model.sessions.updateTool(callID: "shot-2", name: "screenshot", state: .succeeded, detail: "截取当前屏幕",
            result: #"{"screen_information_mode":"screenshot"}"#, identity: run)
        model.sessions.updateTool(callID: "tap-3", name: "tap", state: .awaitingApproval, detail: "轻点“文件”图标",
            arguments: "{\n  \"x\" : 312,\n  \"y\" : 700,\n  \"description\" : \"打开文件 App\"\n}", identity: run)
        model.sessions.updateTool(callID: "apps-2", name: "list_apps", state: .requested, detail: "查询已安装应用", identity: run)
        model.sessions.setDraft("统计完帮我打开文件", in: conversation)
        return conversation
    }

    /// Attachment bytes live in the store, so images are attached after the
    /// synchronous conversation seed. Attaching by message ID also works for
    /// finished runs, whose identity is no longer accepted.
    static func seedAttachments(_ model: AgentViewModel, conversationID: UUID, intoDraft: Bool) async {
        guard let png = syntheticImage().pngData(),
              let attachment = try? await model.attachments.store(png, name: "屏幕快照.png", conversationID: conversationID) else { return }
        let messages = model.sessions.conversation(conversationID)?.messages ?? []
        if let user = messages.first(where: { $0.role == .user && $0.attachments == nil }) {
            model.sessions.attach(attachment, to: user.id, in: conversationID)
        }
        if let shot = messages.last(where: { $0.tool?.callID == "shot-1" }) {
            model.sessions.attach(attachment, to: shot.id, in: conversationID)
        }
        if intoDraft { model.sessions.addDraftAttachment(attachment, in: conversationID) }
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
                card(.preview("skill-s", "load_skill", .succeeded, "读取技能文档",
                    result: "已读取技能文档并按其步骤执行。", skillName: "Synthetic Guide"))
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
    enum Script { case completed, active }
    let script: Script
    var colorScheme: ColorScheme = .light
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
        .environment(\.colorScheme, colorScheme)
        .task { await prepare() }
    }

    private func prepare() async {
        guard model == nil else { return }
        let seededModel = ConversationPreviewSeed.makeModel()
        let seededConversation: UUID
        switch script {
        case .completed: seededConversation = ConversationPreviewSeed.seedCompleted(in: seededModel)
        case .active: seededConversation = ConversationPreviewSeed.seedActive(in: seededModel)
        }
        await ConversationPreviewSeed.seedAttachments(seededModel, conversationID: seededConversation, intoDraft: script == .active)
        model = seededModel
        conversationID = seededConversation
    }
}

#Preview("会话 · 已完成历史") {
    ConversationPreviewPage(script: .completed)
}

#Preview("会话 · 已完成历史（深色）") {
    ConversationPreviewPage(script: .completed, colorScheme: .dark)
}

#Preview("会话 · 进行中") {
    ConversationPreviewPage(script: .active)
}

#Preview("工具卡片 · 全部状态") {
    ToolCardGallery()
}

#Preview("审批卡片") {
    ToolApprovalCard(configuration: ToolInvocationConfiguration(
        tool: .preview("tap-a", "tap", .awaitingApproval,
            "轻点“深色模式”开关，将系统切换为深色外观。",
            arguments: #"{"x": 962, "y": 402, "description": "切换深色模式"}"#),
        onApprove: {}, onDeny: {})) {
        Image(uiImage: ConversationPreviewSeed.syntheticImage()).resizable().scaledToFit()
            .frame(maxHeight: 280).clipShape(RoundedRectangle(cornerRadius: 10))
    }
    .padding(16)
    .background(Color(uiColor: .systemBackground))
}

#Preview("审批卡片 · 按钮禁用") {
    ToolApprovalCard(configuration: ToolInvocationConfiguration(
        tool: .preview("tap-n", "tap", .awaitingApproval,
            "轻点“深色模式”开关，将系统切换为深色外观。当前没有对应的授权回调。",
            arguments: #"{"x": 962, "y": 402, "description": "切换深色模式"}"#))) {
        EmptyView()
    }
    .padding(16)
    .background(Color(uiColor: .systemBackground))
}
#endif
