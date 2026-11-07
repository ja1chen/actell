# ProviderKit

[English](README.md) | 简体中文

ProviderKit 将模型协议与会话历史、设备执行分开。`ProviderCore` 提供请求、事件、有序回放项、用量、作用域与能力契约，不依赖模型 SDK。`OpenAIAdapter` 实现 Chat Completions 和 Responses 编解码、流组装、终态校验与显式原生压缩。AgentKit 提供完整的已准备请求，管理历史、上下文 revision、保留策略、续接 head 与持久化提交。Provider 不重建会话，也不写另一份续接 checkpoint。

适配器使用远程 Swift 包 [MacPaw/OpenAI 0.5.2](https://github.com/MacPaw/OpenAI/tree/0.5.2)，不复制或修改 SDK 源码，SDK DTO 仅在适配器内部使用。包要求 Swift 6.2、iOS 16 或 macOS 13；App 维护自身的平台下限。SDK 构造器处理通用字段，显式协议对象保留支持的回放数据与网关扩展字段。

## 请求与回放

`ProviderReplayScope` 标识服务商、规范服务地址、账号引用、project、模型和持久会话。网络尝试、用户回合和上下文 epoch 不改变该服务作用域。不透明 reasoning、Chat reasoning 块、压缩项与 response ID 不能跨作用域回放；凭据不进入作用域或缓存身份。`ProviderScope` 是同一个稳定作用域的既有领域命名。

Responses 默认完整无状态回放，使用 `store=false`。显式响应链使用 `store=true`、带作用域的 previous response ID 和新增输入。调用方选择完整输入或增量续接，适配器不从 UI 消息推断。远端 handle 缺失或被拒绝时明确返回错误，不自动重放已受理请求。后台生成、Conversations、hosted tools 和远端取消确认尚未支持。兼容服务必须显式声明响应链能力。

`ModelInputProjection` 仅转换消息格式，不裁剪图像或历史。媒体保留由 AgentKit 决定。图像在序列化前使用写时复制 Data 或文件引用；用户附件与工具结果保持独立事实。图像离开本地窗口后，服务端响应链仍可能保留它；`store=false` 不保证服务商完全不记录日志。

## 流与故障处理

临时 HTTP 会话禁用 Cookie 和缓存，拒绝重定向，在解析失败或消费者终止时取消对应网络任务。取消当前任务不使 transport 永久失效，后续仍可发起请求。请求体上限为 24 MiB，响应为 4 MiB，SSE 行和事件为 256 KiB，单图像为 8 MiB，JSON 嵌套深度为 48。此包不记录请求或响应正文。

Responses 完成快照必须匹配所有已完整组装的输出项；工具 ID、参数、项地址、作用域与终态在派发前校验。相同序列与内容的重复事件被忽略，冲突或乱序则失败。未收到有效终态即 EOF 时失败，不自动重试。Chat 流支持交错工具参数分片、明确可读的 reasoning 字段与较晚到达的用量帧。有序网关 `reasoning_details` 作为带作用域的回放状态保存，只有明确可读字段进入展示。

未知流扩展经过凭据脱敏后作为诊断附件保存，不进入模型输入，也不授权执行。每个响应最多保留 128 条、512 KiB；超过限额仅省略额外诊断，不拒绝有效响应。可执行的未知输出仍不支持。Stream checkpoint 是内存中的组装快照，不管理持久化续接。

## 压缩、缓存与用量

Chat 的续接字段与可读 reasoning 分开。[DeepSeek 思考模式契约](https://api-docs.deepseek.com/guides/thinking_mode/)要求带工具的请求回传之前助手项的原始 `reasoning_content`。适配器将原字段保存在有作用域的持久回放状态中；App 仅对已核实的官方 DeepSeek Chat 地址启用回放，无工具请求省略该字段，未知网关不自动获得此能力。不能用 UI 展示文字重建原始续接字段。

`ModelCompactingProvider` 是可选能力。显式启用后，OpenAI Responses 适配器支持文档规定的 [compact 端点](https://developers.openai.com/api/docs/guides/compaction)。压缩请求不带工具，返回完整规范输入窗口，包含保留的输入消息／结果与带类型、作用域的不透明压缩项。调用方原子采用整个已校验窗口；不支持的保留内容使候选校验失败，不改变历史。兼容 Responses 服务不会自动获得 compact 能力。App 当前只对官方 OpenAI Responses 地址启用该能力，自定义兼容服务使用通用摘要压缩。

ChatGPT 订阅 HTTP 推理遵循官方 [Sign in with ChatGPT 限制](https://developers.openai.com/siwc/token-sharing-open-source/preview-limitations)：每次使用 `store=false`、`stream=true`，省略 `previous_response_id`，发送 AgentKit 准备的有效上下文窗口；压缩后使用已提交摘要与保留项，完整 JSONL 历史仍保存在本地。官方 WebSocket 续接仅限同一认证连接，并非持久会话存储；本 App 使用 HTTP/SSE。此授权不声明持久服务端续接或原生 compact 路由支持。调用方可用无工具摘要推理压缩本地上下文，不能将其称为服务端续接或原生压缩。

Prompt cache key 与可选 retention 字段是显式请求策略；订阅推理省略不支持的 retention 字段。稳定请求 JSON 保留输入顺序并排序对象 key。用量分别保存输入、输出、cached、cache-write 与 reasoning token，缺失值保持 unknown。缓存命中必须来自真实服务端用量，不能从本地 hash 推断。

## 验证

```sh
swift test --package-path ios-app/ProviderKit
bash ios-app/scripts/test_core.sh <隔离模拟器 UDID>
```

主机默认使用独立 Command Line Tools 时，应为 XCTest 选择完整 Xcode 工具链。包测试仅使用合成数据，不需要凭据。App 测试保留设备授权、会话隔离、未知结果与停止释放覆盖。离线测试不能证明真实端点支持、缓存命中、远端取消或实体设备行为。
