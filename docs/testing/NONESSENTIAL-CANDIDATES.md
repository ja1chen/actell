# 测试保留与执行边界

测试精简的目标是保留独立、稳定的生产契约，避免重复矩阵、一次性排查和与改动无关的执行。剩余用例包括核心必需与专项长期；位于 `PhoneAgentTests` 不代表已获核心认证。核心也只按本次影响范围执行，不要求每次全量运行。

统计按自有源码方法/函数计，不等于运行器实际发现或通过数量。表驱动输入、条件编译和 C 断言不能与方法数直接比较；下载依赖、vendor 和本地实验材料不计入。

## 剩余范围

| 范围 | 源码方法/函数 | 主要职责 |
| --- | ---: | --- |
| App 单元测试 `PhoneAgentTests` | 619 | 聊天、持久化、运行生命周期、授权、设备接线，以及下列专项 |
| App UI `PhoneAgentUITests` | 53 | 发送与附件入口、审批、停止、历史恢复和必要的设置交互 |
| `RemoteTests` | 118 | Muse/远程认证、配对、权限、传输和独立运行时，仅显式执行 |
| `RemoteTests/UI` | 6 | Muse 设置、配对确认和设备权限 UI，仅显式执行 |
| AgentKit | 57 | 权威事务、运行恢复、上下文、压缩和工具执行状态 |
| ProviderKit | 15 | 请求投影、SSE、终态、推理字段和服务商协议契约 |
| CommandKit | 4 | 命令输入包络、字节边界和输出解码 |
| CoreDevice Swift | 47 | 视频解码/裁剪、原生 ABI、身份、诊断、取消和链路夹具 |
| CoreDevice Rust | 78 | 协议帧、身份校验、队列、媒体、AX、传输和取消 |
| 工程/Git Python | 16 | 签名隔离、工程生成和测试域隔离 |
| Muse 工具 Python | 10 | 工程成员关系、共同协议基线/HMAC 向量、日志提取与脱敏 |
| ESP32 USB Python | 25 | 固件 TCP 交互、ACK/执行、停止、重放和连接状态 |
| ESP32 C 测试 | 6 个文件，不按断言拆计 | USB 协议与 HID、通用 I/O/plist、Lockdown probe、NCM core/socket/relay |

合计为 Swift 919 个方法、Rust 78 个函数、Python 51 个方法；数量只用于核对覆盖范围，不作为测试配额或执行要求。

## 核心必需保护什么

| 契约 | 必须覆盖的真实行为 | 主要测试入口 |
| --- | --- | --- |
| 普通聊天可执行 | 纯文本可发送；设备离线、模型可选能力或文件工作区不可用时降级；拒绝有明确原因；长输入不截断 | `ConversationRuntimeTests`、`SessionCommandTests` 中普通 send 两项、`CoreDeviceBridgeTests` 的普通聊天场景 |
| 会话与数据完整 | 草稿首次发送、附件身份、旧展示保存不覆盖新输出、磁盘失败可重试、损坏保留前缀/原件、索引失败不损坏权威日志 | `AgentSessionPersistenceTests`、`ConversationJournalTests`、`ConversationTests`、AgentKit `SessionStoreTests` |
| 真实模型输入与流式终态 | 工具调用、参数、图片、思考与正文正确投影；分片不丢；未验证、失败、截断的终态不能释放工具 | `ModelStreamTests`、`ProviderRuntimeTests`、`ProviderTransportTests`、ProviderKit `ProviderContractsTests` |
| 工具执行与停止 | 调用有序；停止立即围栏；取消或迟到 allow 不再派发；工具失败可反馈给模型，不伪造完成 | `MultiToolTests`、`SafetyTests`、`ExecutionToolTests` 的执行围栏、AgentKit `RuntimeCoreTests` |
| 会话、运行与授权隔离 | 审批单次消费且绑定正确 run/参数；旧事件、旧停止和另一会话不能影响当前运行 | `ApprovalRecordTests`、`AgentPresentationTests`、`ConversationRuntimeTests`、`RunLifecycleTests` |
| 未知结果与恢复不重放 | ACK 不等于实际执行；未知送达事实不改写为成功；重启不继承授权，不重发历史动作；checkpoint 兼容不放宽这些保证 | `CheckpointMergeTests`、`RunLifecycleTests`、AgentKit 事务/恢复用例，以及各受支持协议的停止释放测试 |
| 默认设备路线接线 | VPN/CoreDevice 身份、几何坐标、连接代际、截图、动作和清理正确；连接错误仅影响相关工具 | `CoreDeviceBridgeTests`、`DeviceControlRouteTests`、CoreDevice Swift/Rust；App 保留一个 iOS 解码与 MIME 冒烟 |
| 文件与凭据边界 | 会话相对路径和真实目录别名正常可用；附件不跨会话误读/误删；凭据不发送到错误端点；失败后正常任务仍可继续 | `FileWorkspaceTests`、`AttachmentStoreTests`、`ProviderStoreTests`、相关传输/认证用例 |

这里列的是应保留的契约，不是把表内整个文件认证为核心。[会话与存储逐项清单](SESSION-STORAGE.md)中，98 个现存方法分为核心必需 37、专项长期 49、合并调整 12；后两类不因本轮精简自动转为核心。

## 专项长期还剩什么

| 域 | 仍保留的测试及必要性 | 执行条件 |
| --- | --- | --- |
| Siri/App Intent | prepare/execute、命令身份、冷启动交接、取消限定、认证与实时活动接线；不与普通 send 混算 | 修改相应入口 |
| 后台与实时活动 | 音频/PiP/定位、待命、权限、多个所有者、异步激活/释放、前后台展示刷新；停止不复活的底层保证不能删 | 修改对应驱动、调度或生命周期 |
| 隐藏的 systemTask 分支 | 租约、过期、旧状态不启用、不借用其他来源；生产默认选择已经过滤它 | 修改该分支或兼容状态；不代表默认后台路线验收 |
| ESP32 HID/ScreenCaptureKit | USB 选择、视频方向、捕获生命周期、ACK 与真实执行、停止释放、未知结果恢复 | 修改可选路线或共享协议；不随普通聊天回归 |
| ChatGPT OAuth/订阅 | 签名、账户隔离、密钥轮换/注销、协议输入和浏览器回调 | 修改该 provider、认证或共享凭据逻辑 |
| 模型发现/旧服务商 | 分页、未知能力、手工选择、旧 profile、保留的 Anthropic/Gemini/Ollama 来源兼容 | 修改目录或相应兼容格式 |
| Skill | 发现、导入、启停、版本 metadata、路径、资源、完整 Unicode 文档与运行快照 | 修改 Skill 或其工具接线 |
| Python/curl/命令运行时 | 嵌入解释器、代表性 Pillow/NumPy 能力、环境恢复、超时、输出及下载；不重复自测上游算法 | 修改命令运行时或依赖打包 |
| 图片下载、缓存和展示 | 原图持久化、过期来源、取消、删除、缓存修复；正常图片/附件完整性仍是主链保证 | 修改相应网络/存储/展示逻辑 |
| 迁移与索引性能 | 旧归档、旧目录、旧 UI JSONL、原子发布与重试；派生缓存的懒加载/增量更新 | 修改相应格式、兼容来源或索引实现 |
| 诊断与归档 | 白名单、凭据脱敏、受控原始事件保存、诊断失败不阻塞业务 | 修改日志、错误映射或诊断工具 |
| Muse 与远程 | 配对、TLS/HMAC、防重放、权限撤销、限界传输、模型无关运行时和 UI | 仅在用户明确要求执行该域时运行 |
| 国际化与 UI | 编译后 bundle、复数、关键披露、附件选择、键盘遮挡、审批可点击、折叠后答案可见 | 修改对应资源/交互；不默认逐页截图或双主题重复跑完整流程 |
| 工程/Git | target 成员、scheme 隔离、配置继承、签名变量不污染共享工程、暂存区规则 | 修改相应生成器、脚本或钩子 |

## 精简后如何避免再次膨胀

- CoreDevice 视频的完整矩阵集中到包层；App 只保留必要的平台冒烟和实际 bridge 接线，不复制纯包测试。
- 通用 SSE 和图片投影断言集中到 ProviderKit；权威事务的修订冲突由 AgentKit 负责。App 层只为独有集成行为保留测试。
- 不维护无生产调用者的展示查询测试，也不用它证明实际模型输入。思考/正文持久化与真实 wire 输入分别保留。
- 不用源码 `guard`、注释、构造器字符串或路径存在来代替运行行为或许可证完整性；来源和许可证材料本身保留。
- Python 脚本参数和文件测试不运行十秒倒计时；curl 下载用例不启动 Python 检查 SSL；固定第三方版本与上游算法矩阵不作为业务断言。
- UI 不为一像素间距或没有主题相关断言的重复交互建立独立长期用例。完成前后两种真实时序继续覆盖，等待实际折叠状态，不逐秒采样十秒。
- 单纯的多轮有序性使用代表性轮数。真实历史阈值、分片/载荷边界和 Unicode 编码边界不能因减少输入规模而丢失。
- 命令管道 FD 泄漏的 100 次压力场景有独立故障价值，保留现有方法，仅显式执行：设置 `RUN_COMMAND_STRESS_TESTS=1` 并选择 `ExecutionToolTests/testEmbeddedPythonRepeatedCommandsReleasePipelineDescriptors`。普通命令回归不附带运行。

## 验证入口

- App：`bash ios-app/scripts/test_core.sh <隔离模拟器 UDID> <Class[/method]> ...`。不指定 selector 仍是整个主 target，里面仍有专项长期测试，不能简称为“只跑核心必需”。UI 选择开关也选整个当前域，应优先按相关用例选择。
- 后台专项复用上述类/方法选择，不再维护会偷偷选择整个 App target 的平行后台脚本。
- CoreDevice 链路：`bash tools/test_coredevice_chain.sh` 只选择 12 项实际 fixture ABI/relay/跨语言用例；普通 Swift 包入口负责纯单元矩阵。
- CoreDevice Rust：`bash tools/test_coredevice_rust.sh [测试过滤参数]` 只运行自有 backend。上游兼容套件通过 `bash tools/test_coredevice_rust.sh --upstream [测试过滤参数]` 单独选择。
- Muse/远程：`bash ios-app/scripts/test_remote.sh <隔离模拟器 UDID> [Class[/method]] ...`，或显式选择 `PhoneAgentRemote` scheme。普通核心/UI 回归不包含它。

新增长期用例必须说明独立契约缺口，优先扩展已有场景。专项是否退役取决于生产功能或格式是否停止支持，不能把“非核心”直接等同于“不必要”。
