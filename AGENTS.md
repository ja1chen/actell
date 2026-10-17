# 项目命名

- 项目英文名为 **Actell**，中文名为 **执言**。新增或修改面向用户的文档、界面文案时使用对应名称，不再以 PhoneAgent 或 iOS Use 作为项目展示名称。
- 采用渐进式迁移。现有源码目录、类型名、Xcode 工程与 scheme、Bundle ID 等内部标识按后续改动范围逐步迁移；文档中的路径、链接和构建命令须与实际工程保持一致，不能只替换名称而使其失效。
- 中英文 README 同步维护

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
