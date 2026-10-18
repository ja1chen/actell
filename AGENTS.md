# 项目命名

- 项目英文名为 **Actell**，中文名为 **执言**。仅在新增内容需要使用产品名时使用对应名称。
- 不主动进行名称迁移，也不因命名约定改写已有文案或内部标识；已有名称仅在用户明确要求时调整。
- 中英文 README 同步维护

# 文档写作

- 文档描述通用的功能、设计、约束与使用方式，不写成工作日志。非必要禁止加入日期、时间、具体设备或型号、本机路径、日志片段、单次测试记录和操作过程；确有必要时仅保留与主题直接相关的内容。
- README 应以概要为主，同时保留理解和使用工程所需的信息结构，包括核心能力、前置条件、构建与验证入口、工程布局、依赖与来源。精简应着重去除重复和过程信息，不以篇幅最短为目标，也不将必要的章节、列表或表格压成笼统段落。
- 依赖与来源优先沿用已有列表或表格结构，说明用途、使用方式和来源链接。共同构成一项能力的相关组件、具有直接源码复用关系的项目可合并说明；职责不同且无直接关联的模块分别列出，不为缩短篇幅强行合并，也不机械地将所有项目拆成独立条目。
- 实现细节放入对应技术文档并按需链接；README 保留必要的用途与边界说明，不堆叠内部字段、迁移分支或验证过程。
- 文档调整限于当前任务涉及的内容，不顺带批量改写无关段落。

# UI 设计约束

新增或修改界面前先读 `DESIGN.md`，遵循其中的产品定位、信息层级与文案约束。

# 国际化

- 所有国际化 key 使用英文，优先使用完整英文句子；不能把中文作为 key。协议字段、枚举持久化值、资源路径和辅助功能标识不作为翻译 key，也不随语言改变。
- 所有应用提供的 UI 文案都要支持英文与简体中文，包括按钮、标题、占位符、辅助功能说明、动态状态、错误、权限提示、Siri 和实时活动。用户输入、模型原文及用户导入内容保持原文。
- SwiftUI 固定文案使用本地化资源；普通 `String`、模型层提供的展示文案和插值消息使用 `String(localized:)`。整句本地化，不拼接句子片段；带数量的文案按需配置复数规则。
- 主 App 与实时活动共用 `ios-app/Shared/Localizable.xcstrings`；系统权限文案维护各 target 的 `InfoPlist.xcstrings`，快捷指令短语维护 `AppShortcuts.xcstrings`。中英文须成对提供且占位符含义、数量和类型一致。
- 新增或修改文案后运行 `python3 ios-app/scripts/check_localizations.py`，并核对编译提取的字符串；优先通过代码、资源和测试检查中英文覆盖、插值与复数，不依赖逐页截图验证。诊断日志与测试夹具保留原始标识，不能为通过检查将其加入用户翻译。

# 阅读与验证入口

当前 App 默认路线是 iOS 27 + VPN 回环开发者服务截图/触控（免 ESP32）；可在设置选择 ESP32 NCM 模式，复用系统配对身份与 CoreDevice 后端。ScreenCaptureKit + USB Device NCM/HID 实现保留，暂未提供切换开关。先读 `README.md` 和本次改动涉及的源码；项目待办与能力边界在 `docs/PROJECT-TODOS.md`。

默认检索范围：`ios-app/PhoneAgent`、`ios-app/PhoneAgentTests`、`ios-app/PhoneAgentUITests`、`coredevice/swift`、`coredevice/rust/src`、`devices/esp32/shared`、`devices/esp32/tests`。不要默认递归读取 `.build/`、`ios-app/Vendor/`、`coredevice/rust/vendor/` 或下载的 `managed_components/`；当问题涉及相应实现、上游兼容或历史证据时再按需查看。许可证与来源清单保留。

默认验证：

- USB 输入协议/停止释放：`CC=clang bash devices/esp32/tools/test_usb.sh`（仅回环网络）。
- App 改动：`bash ios-app/scripts/test_core.sh <隔离模拟器 UDID>`；加 `RUN_UI_TESTS=1` 跑现行 UI 用例。
- 最终无签名 iPhoneOS build：参见 `ios-app/README.md`。
- 核心协议、单次授权、会话隔离、未知结果、不重放、checkpoint 迁移和停止释放测试始终保留在默认 target。不能为缩短验证删除这些覆盖。

固件构建和验证入口见 `devices/esp32/README.md`，跨语言链路回归为 `bash tools/test_coredevice_chain.sh`。

# 本机日志排查

- 用户要求排查运行故障时，优先通过系统日志服务、Xcode 原生 MCP、CLI 和已有日志文件自行提取证据；Computer Use/AX 仅在原生路径不可用时兜底。不默认要求用户复制日志、截图或点击重连。Muse 日志入口与只读提取步骤见 `docs/muse-remote/DIAGNOSTICS.md`。
- 读取 Xcode 已有输出与触发设备动作分开：不得因此点击 Run/Stop/Pause、重新连接、调用工具、重新配对或清除日志；真机操作仍受用户当前授权约束。
- 优先过滤固定诊断阶段/错误码和哈希关联 ID，不读取或输出凭据、签名、请求正文或无关 console 内容。真实日志证据放在忽略的 `.build/validation/`，共享文档只写原因与结论。
- 日志缺失时先核对现有 Console 是否隐藏、过滤或缺少相应进程/版本的历史。只有自行可访问的路径确实不可用时才说明具体缺口，不将用户操作作为默认排查步骤。
