# AgentKit 的分层接入与改动理由

AgentKit 管理会话事实、运行状态和模型有效上下文；ProviderKit 将准备好的请求转换为服务协议并校验响应；PhoneAgent 管理账号、设备授权、界面和 App 数据布局。三层不能分别维护同一会话的历史和续接状态。完整运行契约见 [AgentKit 设计](AGENTKIT-DESIGN.md)，目录和迁移见 [会话存储](CONVERSATION-STORAGE.md)。

## ProviderKit

这些改动不是把设备功能移入 ProviderKit。删除 Provider 内的上下文编排，是为了使 AgentKit 提交的窗口、磁盘恢复出的窗口和实际发送的窗口一致。协议适配器仍可拒绝不合法的协议对象，但不自行删除历史、生成摘要或执行工具。

| 文件 | 职责与必要性 | 不这样处理的后果 |
| --- | --- | --- |
| `ProviderCore/ModelTypes.swift` | 增加请求归属、缓存策略和独立用量字段；图像携带观察来源及尺寸；工具 schema 使用 ProviderCore 自有 JSON 类型；明确区分服务已拒绝请求与受理结果不明。 | 每次请求身份与会话身份混用；缓存命中无法核实；设备截图与用户附件无法采取不同保留策略；普通网络错误可能被误当成可重试。 |
| `ProviderCore/NativeItems.swift` | 原生消息、工具调用、reasoning、压缩项使用稳定的 provider／endpoint／account／project／model／session 作用域；原生压缩返回值和 Chat 续接数据有明确类型。 | 重启或新 turn 后合法原生项失效，或跨账号／服务误用不透明数据；压缩窗口无法完整持久化。 |
| `ProviderCore/Compaction.swift` | 将原生压缩声明为可选的 `ModelCompactingProvider`，请求和返回值都携带完整输入窗口；缓存策略与会话存储策略分开。 | 把“支持 Responses”误判为“支持 compact”，或把缓存命中等同于服务端保存了会话。 |
| `ProviderCore/ModelInputProjection.swift` | 保留纯消息格式转换及流组装快照类型。它不拥有历史，不裁剪图像，不写续接 checkpoint。 | 第二个上下文所有者会在 AgentKit 之外改变已提交窗口。 |
| 原 `ProviderCore/ContextCoordinator.swift` | 会话编排职责移交 AgentKit 后删除该实现；需要的纯投影留在前一行的模块。 | 两套 head、窗口和持久化边界可能不一致；恢复时无法确定哪一份是权威状态。 |
| `OpenAIAdapter/ChatInputProjection.swift` | 将同一份规范输入窗口转换为 Chat `messages`，按顺序组合 assistant 文本、工具调用和工具结果，并保留受作用域约束的 Chat 续接状态。 | Chat 路线只能使用另一份简化文本历史，工具关联和压缩后续接与 Responses 路线不同。 |
| `OpenAIAdapter/OpenAIWireCodec.swift` | 接受完整规范输入，稳定编码请求 JSON；保留支持的原生项、缓存字段和各类用量；在服务协议边界校验作用域与能力。 | 同一历史会因重新拼装产生不一致输入；原生字段或缓存用量可能在 SDK DTO 转换时丢失。 |
| `OpenAIAdapter/CompactionCodec.swift` | 通过独立 compact 路由编解码，验证并保留服务返回的整个规范窗口，包括保留输入和压缩项；不只抽取一段摘要。 | 丢弃服务返回的保留项，或在未验证候选时替换有效上下文。 |
| `OpenAIAdapter/ModelStreamDecoder.swift` | Chat 解析从 App 移入适配器：组装交错工具片段、可读 reasoning、作用域内的续接字段和较晚到达的 usage；只在合法终态后形成权威响应。 | AgentKit 的 Chat 支持依赖 App 内部解析器；预览片段被误当作可执行工具，或终态后的用量丢失。 |
| `OpenAIAdapter/ReadableReasoningDecoder.swift` | 可读 reasoning 的纯解析随 Chat 解码器归入适配器；展示文本与服务续接字段分别保存。 | 展示层格式处理渗入模型协议，或用 UI 文本重新构造服务要求的原始续接数据。 |
| `OpenAIAdapter/ResponsesReducer.swift` | 保留终态、项身份和工具完整性检查；诊断扩展达到数量／字节配额后停止额外保留，不中止有效响应。 | 可选诊断材料过多会阻断正常 Agent 执行。 |
| `OpenAIAdapter/ResponsesTransport.swift` | 取消当前网络任务时保留可复用 transport；只把明确的容量／失效 head 拒绝标记为未受理。错误正文有独立读取上限。 | 一次取消导致后续请求永久不可用，或超时等未知结果被自动重发。 |
| `Package.swift`、`Package.resolved` | 增加独立契约测试 target，固定包级解析结果；现有模型 SDK 依赖保持适配器内部使用。 | 只靠 App 编译无法单独验证协议边界，包测试和 App 可能解析到不同依赖。 |
| `Tests/ProviderKitTests/ProviderContractsTests.swift` | 检查规范输入、作用域、终态、压缩候选、续接字段和缓存用量；只使用合成数据。 | 真实服务偶尔接受不完整请求时，协议缺口会被成功响应掩盖。 |

原生 compact 是请求范围中的可选能力，服务不支持时使用 AgentKit 的通用摘要。它不是所有 Provider 启动的前置条件。HTTP 订阅上下文的限制来自服务契约，详见 [订阅上下文](CHATGPT-SUBSCRIPTION.md#http-context-ownership)。

## PhoneAgent：模型配置与执行接入

| 文件 | 职责与必要性 | 保持的边界 |
| --- | --- | --- |
| `Agent/AgentViewModel.swift` | 创建并配置 AgentRuntime，使用持久会话 ID、稳定用户消息 ID 和 engine store；传递上下文模式与预算，消费新事件、取消句柄及类型化失败，并在订阅落后收到 `resyncRequired` 时重读展示快照。模型输入不再由 UI 最近若干条文本构造。 | 设备授权、后台租约、Siri 入口和用户操作仍由 App 管理；启动失败也执行统一退出清理，不留下永久 busy 状态。 |
| `Agent/Providers.swift` | `PrivateVisionProvider` 接受 AgentKit 已准备好的请求，提供稳定 replay scope、协议能力和可选 compact；不再保存另一份 ContextCoordinator；合成 Provider 也返回权威 terminal 事件。 | 服务商限制、参数映射和认证入口留在 App；只有明确支持的官方配置开启原生 compact。 |
| `Agent/ChatGPTSubscriptionProvider.swift` | 使用持久 session 作用域，移除 Provider 内历史提交；历史工具调用的回放不要求该工具仍在当前可调用列表中。 | 新模型输出仍校验当前工具名、namespace、账号和终态；HTTP 固定无状态请求，OAuth／Keychain 生命周期不迁入 AgentKit。 |
| 原 `Agent/ModelStreamDecoder.swift`（删除） | 纯解析实现归入 ProviderKit；调用方直接导入 OpenAIAdapter，不保留只有 import 的空壳文件。 | App 不再维护第二份 Chat 流算法。 |
| `Agent/ModelDiscovery.swift` | 将服务提供的总上下文容量写入 `contextTokenLimit`，与仅输入容量分开。 | 不把总窗口全部当成可用输入；仍须预留输出及工具结果。 |
| `Models/ProviderModels.swift` | `DiscoveredModel` 增加可选总窗口字段；App 在读取旧 OpenRouter／Ollama 元数据时识别原字段含义。 | 旧缓存可继续读取；未知容量使用有限规划预算，不伪造服务硬上限。 |
| `Models/Models.swift` | 无产品轮数预算使用可选值表达，移除 `Int.max` 哨兵值。 | 不因替换引擎增加固定任务轮数上限；网络、授权、取消和数据限制仍有效。 |

## PhoneAgent：工具与远程入口

| 文件 | 职责与必要性 | 保持的边界 |
| --- | --- | --- |
| `Agent/DeviceTools.swift` | 工具改为实现新 `AgentTool`，使用自有 JSON schema 和结构化结果；工具入口检查 runtime fence，最终发送仍由 ActionCoordinator 检查当前执行生命周期；已经发送但结果不明的动作记录为 unknown；截图携带 observation ID 和尺寸。 | 原有设备授权、当前帧约束、动作 checkpoint 和停止释放继续生效；历史调用不能触发新动作。 |
| `Agent/SkillTools.swift` | 技能读取接入新工具协议、取消检查和结构化结果；一次返回完整文档，默认读取 `SKILL.md`，引用文档按需单独读取。兼容旧调用的 Unicode 标量偏移，返回该位置之后的完整内容，`next_offset` 为 null。 | 技能仍只读本轮已启用文档，不执行脚本或访问包外路径；工具结果不截断文档正文或目录元数据。 |
| `Remote/RemoteStrictJSON.swift` | 从 ProviderCore 的 JSON schema 提取工具定义，继续为远程坐标协议补充原有约束。 | 这是删除旧工具 schema 类型后的适配，远程协议和坐标语义不随引擎迁移改变。 |
| `Remote/RemoteToolRuntime.swift` | 远程运行测试与实现使用新工具结果类型。 | 远程调用继续走自身的认证和执行生命周期。 |
| `Remote/RemoteToolsService.swift` | 将 `ToolOutcome` 的内容和分类映射到现有远程成功／失败回执；截图继续通过原有 `onImage` 回调及图像映射传递。 | 不能把 validation failure、denied 或 unknown 都转换成成功文本；不绕过原设备安全边界。 |

## PhoneAgent：持久化与展示

| 文件 | 职责与必要性 | 不这样处理的后果 |
| --- | --- | --- |
| `Storage/AgentSessionPersistence.swift` | App DTO 与 AgentKit 展示项、模型事实之间的明确转换；从已提交工具图片引用重建展示附件，缺少旧 App 附件 metadata 时也可恢复原图入口；旧会话只导入可还原的事实。 | UI 历史和模型上下文混为同一数组，已保存截图可能无法预览；不能从展示内容伪造原生密文或待执行工具。 |
| `Storage/AttachmentStore.swift` | 优先读取 UUID 附件原图，缺失时按已验证摘要读取同会话的 AgentKit 图片；原图和缩略图复用已提交资源。先规范化已存在的会话目录，再校验附件子目录与文件。 | 截图预览依赖额外副本，或因沙盒路径别名误报文件不可用；仍须拒绝跨会话引用、附件符号链接和摘要不匹配。 |
| `Storage/ConversationJournal.swift` | App 历史 facade 使用会话根目录的同一个内联 JSONL store；完整草稿、附件引用和展示 metadata 统一保存在事务中。统一准备入口识别现有来源，原始归档直接导入最终格式。 | 两套日志分歧；迟到的 UI 更新覆盖已提交回复；原始归档只能显示却不能参与下一轮推理。 |
| `Storage/ConversationStore.swift` | 提供运行时 store，采用已提交事实刷新 App 投影；损坏会话的可验证前缀可由用户显式复制为新会话。 | UI 只看到旧缓存，或损坏历史使用户无法继续；自动续跑则可能重复设备动作。 |
| `Storage/SessionListIndex.swift` | `state.json` 只保留紧凑列表概要和历史文件大小／修改信息；轻量枚举实际目录，逐条复用有效行，仅从日志重建变化会话。完整草稿与附件列表不放入概要。 | AgentKit 追加后可能长期显示旧概要，或一个失效条目导致全部历史重读。概要可重建，缓存保存失败不阻塞权威提交。 |
| `Storage/SessionStorageMigration.swift` | 从原始归档直接构建最终内联 JSONL，验证附件／检查点后切换目标树；已有会话目录的来源转换通过统一准备入口处理。 | 经未发布的中间格式绕行，或只完成展示数据迁移。 |
| `AgentUI/AgentPresentationAdapter.swift` | 将新 runtime 的 text、reasoning、工具和终态映射到稳定展示项；同一助手回复流中与终态共用身份。 | 重启或流收尾后重复消息；工具卡片和权威结果不一致。 |
| `App/ConversationView.swift` | 对损坏会话提供显式“在新会话中继续”入口并报告结果。 | 用户只能停留在不能继续追加的损坏会话；自动修复又可能掩盖缺失事实。 |
| `App/ContentView.swift` | 接收恢复产生的新会话 ID 并更新实际导航路径。 | 仅更新选中 ID 不会把当前导航栈切换到恢复后的会话。 |
| `Shared/Localizable.xcstrings` | 补齐运行失败、恢复与压缩相关的英文和简体中文文案。 | 新错误分类直接泄漏内部英文或造成单语流程。 |

截图展示附件在 AgentKit 持久化成功后的 `toolCompleted` 事件中关联；设备回调提供当前帧和执行状态，不作为原图已保存的依据。重新加载时从相同工具事务构建图片引用，不需要额外复制截图或改写历史。

`SessionStorageLayout.swift` 继续使用创建时 UTC 日期生成 `YYYY-MM-DD_<会话 UUID>`，不因接入 AgentKit 改名。每会话只以完整 `history.jsonl` 保存会话头与内联事务，二进制图片在 `attachments/<sha256>`，与 App UUID 附件目录并存；不另写会话 manifest、metadata、history index 或每事务 blob，也不增加 `agent/`。原子发布完整临时 JSONL 是转换提交点，随后清理旧辅助文件和临时来源。日志内 metadata 不随独立文件删除；设备 run checkpoint／recovery 职责不变。不同来源的兼容读取不描述成发布版本链。

## 验证入口与工程配置

| 文件或范围 | 必要性与范围 |
| --- | --- |
| `Agent/AgentLiveValidation.swift`、`App/PhoneAgentApp.swift` | DEBUG 且显式启动参数启用的合成真实服务验收入口，覆盖多轮、工具、压缩、重载和 usage。它不是生产执行核心；正常启动不运行，可独立移除。凭据始终通过 App 原有存储读取，报告不导出账号秘密或会话正文。 |
| `SessionCommands/PhoneAgentRuntime.swift`、`App/PhoneAgentApp.swift` | 隔离测试使用内存状态，启动时不自动恢复设备连接；隔离 UI 测试可创建可验证前缀加损坏尾部的合成会话，以验证显式恢复流程。普通启动不创建这些数据。 |
| `PhoneAgentTests` | 将旧引擎类型的夹具迁到新契约，同时保留授权、隔离、未知结果、不重放、迁移和停止释放测试；新增直接归档迁移、流到 runtime、取消后恢复、上下文容量与持久化回归。 |
| `PhoneAgentUITests` | 新增损坏历史恢复用例；既有用例更新当前按钮文案和系统文件选择器定位。定位修正属于验收维护，不是引擎本身的依赖。 |
| `project.yml`、工程生成器、生成工程 | 删除退役 product，链接同级 AgentKit、ProviderCore 和 OpenAIAdapter，并加入新源码。Bundle ID／开发团队不属于此次模块重构；仓库保留原默认配置，本地通过既有环境变量覆盖。 |
| `scripts/check_source.py` | 检查新包依赖边界、无退役引擎／宏依赖、AgentKit 不导入 App 或界面模块。 |
| README、技术文档、来源清单 | README 同步中英文模块边界；来源清单移除不再分发的依赖条目。自研模块在架构文档解释，不列入 THIRD_PARTY 的第三方组件说明。 |

验收辅助的显式上下文窗口覆盖值只服务于快速触发压缩；正常配置仍基于已知容量和有限规划预算。可选诊断、state 列表概要、展示订阅和缓存命中都不能成为运行成功的前置条件。必要事实无法可靠提交时可以结束当前操作，但必须释放占用、保留可核实的数据，并允许条件恢复后的新操作。
