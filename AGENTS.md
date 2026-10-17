# 项目命名

- 项目英文名为 **Actell**，中文名为 **执言**。仅在新增内容需要使用产品名时使用对应名称。
- 不主动进行名称迁移，也不因命名约定改写已有文案或内部标识；已有名称仅在用户明确要求时调整。
- 中英文 README 同步维护

# UI 设计约束

新增或修改界面前先读 `DESIGN.md`，遵循其中的产品定位、信息层级与文案约束。

# 国际化

- 所有国际化 key 使用英文，优先使用完整英文句子；不能把中文作为 key。协议字段、枚举持久化值、资源路径和辅助功能标识不作为翻译 key，也不随语言改变。
- 所有应用提供的 UI 文案都要支持英文与简体中文，包括按钮、标题、占位符、辅助功能说明、动态状态、错误、权限提示、Siri 和实时活动。用户输入、模型原文及用户导入内容保持原文。
- SwiftUI 固定文案使用本地化资源；普通 `String`、模型层提供的展示文案和插值消息使用 `String(localized:)`。整句本地化，不拼接句子片段；带数量的文案按需配置复数规则。
- 主 App 与实时活动共用 `ios-app/Shared/Localizable.xcstrings`；系统权限文案维护各 target 的 `InfoPlist.xcstrings`，快捷指令短语维护 `AppShortcuts.xcstrings`。中英文须成对提供且占位符含义、数量和类型一致。
- 新增或修改文案后运行 `python3 ios-app/scripts/check_localizations.py`，并核对编译提取的字符串；优先通过代码、资源和测试检查中英文覆盖、插值与复数，不依赖逐页截图验证。诊断日志与测试夹具保留原始标识，不能为通过检查将其加入用户翻译。

# 阅读与验证入口

当前 App 默认路线是 iOS 27 + VPN 回环开发者服务截图/触控（免 ESP32）；可在设置选择 ESP32 NCM 模式，复用系统配对身份与 CoreDevice 后端。ScreenCaptureKit + PA3 USB Device NCM/HID 和 TLS 实现保留，旧链路暂未提供切换开关。先读 `README.md` 和本次改动涉及的源码；项目待办重评/证据在 `docs/PROJECT-TODOS.md`。

默认检索范围：`ios-app/PhoneAgent`、`ios-app/PhoneAgentTests`、`ios-app/PhoneAgentUITests`、`firmware-device/main`、`tests/usb_device`。不要默认递归读取 `.build/`、`archives/`、`ios-app/Vendor/` 或旧 Host `firmware/`、`tests/usb_host_sim/`；当问题涉及相应实现、上游兼容或历史证据时再按需查看。许可证与来源清单保留。

默认验证：

- PA3 协议/停止释放：`CC=clang bash tools/test_usb_device.sh`（仅回环网络）。
- App 改动：`bash ios-app/scripts/test_core.sh <隔离模拟器 UDID>`；加 `RUN_UI_TESTS=1` 跑现行 UI 用例。
- 最终无签名 iPhoneOS build：参见 `ios-app/README.md`。
- 核心协议、单次授权、会话隔离、未知结果、不重放、checkpoint 迁移和停止释放测试始终保留在默认 target。不能为缩短验证删除这些覆盖。

归档入口见 `archives/README.md`。非核心 PiP 状态展示和 Siri UI 测试可通过 `INCLUDE_ARCHIVED_TESTS=1 python3 ios-app/scripts/generate_xcode_project.py` 临时加入；结束后不带该变量重新生成默认工程。旧控制调试 UI 用例是历史证据，不代表当前导航验收。固件 Host 测试的原目录和脚本继续保留，按涉及范围显式运行。

# 本机日志排查

- 用户要求排查运行故障时，优先通过系统日志服务、Xcode 原生 MCP、CLI 和已有日志文件自行提取证据；Computer Use/AX 仅在原生路径不可用时兜底。不默认要求用户复制日志、截图或点击重连。Muse 日志入口与只读提取步骤见 `docs/muse-remote/DIAGNOSTICS.md`。
- 读取 Xcode 已有输出与触发设备动作分开：不得因此点击 Run/Stop/Pause、重新连接、调用工具、重新配对或清除日志；真机操作仍受用户当前授权约束。
- 优先过滤固定诊断阶段/错误码和哈希关联 ID，不读取或输出凭据、签名、请求正文或无关 console 内容。真实日志证据放在忽略的 `.build/validation/`，共享文档只写原因与结论。
- 日志缺失时先核对现有 Console 是否隐藏、过滤或缺少相应进程/版本的历史。只有自行可访问的路径确实不可用时才说明具体缺口，不将用户操作作为默认排查步骤。
