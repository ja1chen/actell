# 项目待办与能力边界

当前能力与使用条件见 [README](../README.zh-CN.md)。此处只保留尚需解决或取得独立证据的事项，不累计实施日志。

- 完整模型任务闭环：真实服务商、跨 App 截图/输入、拖动与停止释放，按 VPN、NCM 和 USB HID 分别验收。
- 系统生命周期：长时间后台、Siri 空闲后台接收、音频中断、PiP、定位、锁屏、网络切换与重启恢复；模拟器不能证明系统持续给 CPU。
- 首次开发者服务准备：匹配 DDI 的获取、个性化、挂载和重启后的准备流程尚未由 App 自动完成。
- 协议资源与远端清理：用户态网络和 RemoteXPC 全链路资源限额；定向媒体停止在异常断线下的边界与触点释放的实际效果。不能以本地传输关闭替代远端确认。
- 真实服务兼容性：Provider 的线上流式变体、第三方文件提供器和订阅账号授权需独立验证；离线 mock 仅证明本地处理规则。
- 已报告但缺少现场证据的 Conversion error：需要故障版本的原始调用栈与触发条件，不能将模拟器未复现视为已修复。
- 外部 Agent 集成：标准 MCP 服务接口仍是后续方向，现有 Muse 专用接口不等同于通用 MCP。

[CoreDevice 兼容性](../coredevice/docs/COMPATIBILITY.md) · [后台机制](background-execution/IMPLEMENTATION.md) · [Muse 验证边界](muse-remote/VALIDATION.md)

默认测试始终保留核心协议、授权、会话隔离、未知结果、不重放、checkpoint 迁移和停止释放。原始日志、截图及单次测试报告保存在忽略的 `.build/validation/`，不写入共享文档。
