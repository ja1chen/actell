# 项目待办重评与实施

范围来源：[用户待办 Page](https://chatgpt.com/space/page_36704b3c39e88191b5bc6190c62af3b6)，只读核对 sequence 612；本次明确实施取代页内旧“暂缓”。独立分支 `feature/project-todos`，基线 `80b1c8f`。未修改 `with-esp` 主线未提交签名、`app-only`、CoreDevice worktree、Page 或真实数据。

| 待办 | 基线重评 | 本分支结果/依据 |
| --- | --- | --- |
| 并发 STOP 回执 | PA3 已修 | `USBCommandClient.stopInputs` 共享任务；固件按输入代号拒绝后续 STOP。补 ID2/ID3 连续 STOP 回归，保留连接；未改固件 |
| 双 checkpoint | 仍需 | `RunCheckpointStore` 读取通用、旧 USB 及恢复归档，按会话/运行/代号去重并合并事务。任一未确认发送均保留 unknown；新运行不会覆盖恢复归档。提示在会话中幂等，恢复不授予租约、不保留可用审批、不重放 |
| PING/健康轮询 | 周期 PING 已收敛；健康轮询仍重复 | PING 保留 client 单一调度；model/lease/bridge 共用 context 一个健康定时器。实际入队仍同步验证。修复读 PING 前采样时间导致“负数心跳年龄”的竞态；750ms 失效不变 |
| 重复结束/取消/释放 | 下层已部分修 | `ActionCoordinator.stop` 共享收尾任务；model 不再重复取消、finish 或重复停止同一 bridge；断线释放兜底保留 |
| 文档/测试瘦身 | 仍需 | 精简两级 README；68 个历史文件移入 `archives/history`，相对 Markdown 链接重定位。非核心 PiP 展示/Siri UI 测试可恢复归档，旧调试 UI 测试作为历史保存。核心审批、隔离、协议、迁移、释放测试保留。`AGENTS.md` 提供默认阅读/验证入口 |
| 移除离线演示入口 | 仍需 | 移除整个控制调试页；不新增演示入口。历史演示会话、底层合成回归夹具仍兼容 |
| 移除旧 Host 卡片 | 仍需 | 设备面板只含 SCK/USB NCM；旧 Host 固件和配置数据保留 |
| 移除调试任务/截图/动作记录 UI | 仍需 | 删除调试展示与入口，未删除已有会话和记录；保留用户主动查看的故障诊断 |
| Conversion error | 需证据 | 未找到应用内相同字符串或 UIKit 坐标转换调用；不凭字符串推测修复。仍需原设备的触发步骤、iOS 版本与错误时调用栈。模拟器结果见下方 |
| 查看屏幕后“提交执行结果” | finish 已非强制，schema 仍暴露 | 设备工具只注册 screenshot/tap/drag/wait，以最终文字答复结束；历史 finish 展示名改“结束本轮”。截图的 tool result 仍正常返回模型，不是多余工具调用；后续技能工具为按需只读能力 |
| 多余运行限制 | 部分已移除；次数/token/框架 loop 仍在 | 去除 12 轮、16 次输入、20,000 累计 token、1024 输出 token、默认 60s lifecycle inactivity、URLSession 45/60s 强制超时及框架重复循环终止。使用系统网络超时；保留响应体/协议大小、实际后台资格、锁屏、采集终止、手动停止、防重放和未知结果输入阻断 |
| 导航栏设备按钮 | 仍需 | 会话首页及会话内按钮打开设备控制面板，管理采集/USB 连接、取消与断开；关闭面板不触发任务收尾 |
| 多服务商/会话选模型 | 仍需 | 独立页面增改、确认移除及恢复；会话保存 provider UUID/model ID。旧配置保留原 Keychain 引用，地址变更不携带旧地址密钥，同地址不同新服务商可独立持有密钥。移除后已绑定会话不会静默改用其他服务商。运行中不变更配置 |
| 设置移除 USB | 仍需 | 设备与服务商各自独立；设置保留记录／附件清理、技能管理和后台说明 |

原 STOP 审计证据更正：连续命令 **ID2 STOP 与 ID3 STOP**，五轮复现均只有 ID3 的 executed；不是“五个 STOP 收到三次”。本次 PA3 测试期望 ID2 executed、旧代号 ID3 cancelled，两边均有明确终态。

实施阶段为：恢复/执行生命周期 → 设备入口与服务商 → 归档及回归。真实输入权限沿用 `80b1c8f`，未扩大任务授权。

## 回归与构建

- PA3 生产 C 的 ASan/UBSan 协议/HID 夹具通过；25 个本机 TCP 测试通过（含 ID2/ID3 STOP、重复 ID、取消、断线、代号撤销、STOP 丢失回执）。无实际 USB/HID。
- 12 个 Python wire-contract 回归通过。
- 新增 XCTest：双文件未知事务保全/去重/新运行后保留/无授权复用；迁移 Keychain 引用、独立服务商、地址变更、删除恢复与会话绑定；并发 cleanup 一次释放；单一定时器；心跳取时竞态；18 次输入及 14 次重复观察/超过20,000报告 token 后正常完成；真实 schema 不提供 finish。
- 首轮 172 tests 中存在 11 个失败断言，不能引用旧“166 tests”作最新覆盖。部分是基线已取消的前台/画面匹配限制，部分是测试夹具仍要求 finish。已保留并改写未授权拒绝、撤销/单次消费测试；恢复测试原来保留 pendingApproval 的断言改为不可恢复授权。
- 原 Page 阶段 XCTest：**174 个核心 + 4 个 UI 全部通过，0 失败**，证据 `.build/validation/core.yGz9qf/Tests.xcresult` 与同目录 `test.log`。UI 覆盖设备面板/设置入口、多服务商/会话模型选择、确认取消/移除/恢复、历史停止不重放。已核对 `.build/ui-final/` 的 6 张截图。iOS 27 的 confirmationDialog 未显示显式取消按钮，已改成带取消按钮的 alert。
- 该阶段 iPhoneOS 27 无签名 build 通过（`.build/device-build-verified.log`）。生成工程的全部 build settings 与基线一致，包含原 Live Activities 声明，签名配置未改变。存在原有方向支持警告；没有新增编译错误。
- 此次模拟器 UI 及 App 运行日志未出现所报 Conversion error（`.build/conversion-check.log`），不能据此认定真机问题已修。主机默认 xcrun 路径使 Xcode 的附加诊断收集失败；通过明确的 DEVELOPER_DIR 导出截图和日志，测试本身成功。未改变系统 Xcode 选择。
- 可选归档 PiP 展示/Siri UI、旧 Host 全量、真实服务商与真机测试未跑；本次未改相应固件或 Siri 功能。默认工程与临时恢复归档工程均已检查文件引用，最终提交默认工程。
- 原始构建日志、xcresult、截图只在本分支 `.build/`，不提交用户设备或会话原始数据。默认测试命令见 [App README](../ios-app/README.md)。

## 边界与待证据

未推送、未合并主线、未烧录、未运行真实设备输入、未更改签名/系统设置，未请求真实模型服务。固件源码无变化，继续兼容 PA3，无需本次固件升级。

待真机验收：系统采集授权、AssistiveTouch HID 的拖动/停止/断线释放、跨 App 持续闭环、多服务商实际视觉/工具兼容性，以及 Conversion error 原始调用栈。用户此前报告 PING、截图与点击可用不等于上述全量验收。

此前自动审批审查拒绝了取消“每次模型响应仅一个工具”的附加改动，认为缺少扩大单次响应输入范围的明确授权。该阶段保留边界；用户随后明确确认 B1 多工具，见下方实施记录。审查也曾拒绝直接反转旧权限测试；随后改为保留未授权拒绝并用实际 `80b1c8f` 证据区分观察与显式授权，未修改生产输入授权规则。

## 后续独立任务：模型发现与参数（基于 95557f3）

| 协议 | 模型发现 | 本次推理支持 |
| --- | --- | --- |
| OpenAI-compatible | `GET <base>/models`；列表字段缺失时能力未知，兼容显式游标分页 | Chat Completions |
| Anthropic | `GET <base>/v1/models`，`after_id`，`x-api-key`/`anthropic-version`；读取 capabilities/token 上限 | **仅发现**，任务发送前明确阻止；不伪装 OpenAI |
| Gemini | `GET <base>/v1beta/models`，`pageToken`，`x-goog-api-key`；读取生成方法/token/温度上限 | **仅发现**，任务发送前明确阻止 |
| Ollama | `GET <root>/api/tags` + 每模型 `POST <root>/api/show`（只读元数据）；单个详情失败保留未知 | 显式使用 `<root>/v1/chat/completions`，图片/工具须模型支持 |
| OpenRouter | `GET <base>/models`，offset/limit 分页；读取参数列表、模态、token 上限、原始报价 | Chat Completions |

UI 提供协议/基础地址/密钥、获取/取消/刷新、缓存搜索选择、手动 Model ID 和每服务商/模型参数。模型字段三态；未知可手动填写已知协议字段，明确不支持的字段不发送。支持 temperature、top_p、输出 token 上限、seed；OpenAI 可显式选择 max_tokens 或 max_completion_tokens，不能同时填。只发送用户配置项，不根据模型名猜测。原生 Anthropic/Gemini 参数编辑暂不提供。

基础地址保留代理路径、兼容尾斜杠，拒绝误填完整推理接口。OpenAI 不猜测或自动补 /v1；Anthropic/Gemini 避免重复版本路径。维持 HTTPS，Ollama 明文 HTTP 需自行使用 HTTPS 代理。所有重定向拒绝；分页不跟随远端链接、不跨主机转发密钥；错误不显示响应正文或密钥。更改协议/地址隔离密钥引用、缓存和旧参数，更改密钥清空编辑器缓存。缓存随服务商保存且可离线用，失败/取消不覆盖原缓存；保存本身不联网。服务商移除/恢复及旧单服务商迁移不变。

依据（2026-10-05 核对）：[OpenAI Models](https://developers.openai.com/api/reference/resources/models)、[Chat Completions 参数](https://developers.openai.com/api/reference/resources/chat/subresources/completions/methods/create)、[Anthropic Models](https://platform.claude.com/docs/en/api/models/list)、[Gemini Models](https://ai.google.dev/api/models)、[OpenRouter Models](https://openrouter.ai/docs/api/api-reference/models/list-all-models-and-their-properties)、[Ollama OpenAI 兼容](https://docs.ollama.com/api/openai-compatibility)及[官方 OpenAPI](https://raw.githubusercontent.com/ollama/ollama/main/docs/openapi.yaml)。

验证：新增 14 项模拟 HTTP/请求编码/缓存隔离测试；**188 项核心 + 5 项 UI 全通过**（`.build/validation/core.DLPb76/Tests.xcresult`），包含旧 provider、停止、隔离、迁移回归，以及获取模型→参数→会话缓存选择。该阶段无签名 iPhoneOS build 通过（`.build/discovery-device-build.log`），截图在 `.build/discovery-ui/`。未读取用户实际密钥，未实测任何真实服务商、收费推理或物理设备。单响应单工具限制保留。

后续已授权、分任务提交：输入/授权卡片外背景；统一持久附件资源与图片历史；原生照片/文件选择及真实发送；SKILL.md 管理；按需 list/search/load 技能工具及图标。不自动导入本机用户技能，不执行脚本，不自动发送选中附件。

## 后续独立任务：输入区／授权卡片外背景

从模型发现阶段实际会话截图确认，额外背景来自 composer 共用容器的 `.background(.bar)`。仅移除该层，保留输入框和授权卡本体的圆角背景、safeAreaInset、键盘适配与原审批语义。新增亮／暗 2 项 UI 回归均通过，检查键盘不遮挡输入框、授权按钮在输入框上方、展开及滚动后仍可停止。证据 `.build/ComposerTests.xcresult`、`.build/composer-ui/`；无其他运行或协议行为变化。

## 共享依赖：持久附件资源层

`AttachmentStore` 按会话 UUID/内容 ID 存储原始资源，完整文件保护、排除备份、拒绝符号链接和跨会话读取。数据保存在独立文件，消息只需保存短引用；预览及发送用 PNG 从原图派生，发送图最长边 2048，不转发 EXIF。相同内容只在同一会话去重。支持单帧 PNG/JPEG/HEIC/WebP（20 MiB、5000 万像素以内）和 UTF-8 TXT/Markdown/JSON/CSV（256 KiB），其他格式明确拒绝。1 GiB 容量满后拒绝新增，不自动淘汰原图；显式清理需传入完整消息/草稿引用集合。远程图片客户端无凭据/Cookie、不跟随重定向；消息绑定由后续 UI/模型集成负责。

此提交为图片持久缓存与附件 picker 共用基础，尚不单独新增用户入口。8 项合成资源／模拟 HTTP 测试通过（`.build/AttachmentStoreVerified.xcresult`），覆盖重启、原图/预览、重复内容、会话隔离、文件类型/大小、路径/损坏修复、容量及保留引用、过期/重定向链接。未使用用户照片或文件。

## 后续独立任务：图片历史与本地缓存

新设备截图保存到统一资源层，消息仅记录资源引用；停止、重启后可展开缩略图并查看原图，历史图不恢复输入授权。已有标准 Markdown 图片链接提供按需下载／取消／重试，只访问所属消息已有的 HTTPS 图源，不附加服务商密钥、Cookie 或凭据存储，不跟随跳转。已缓存图片优先读本地，失效且未缓存的旧图片明确无法恢复。旧版只存文字的截图记录同样不伪造恢复。保留含资源的历史消息，设置提供确认后清理未引用附件，下载绑定期间阻止清理竞态。

5 项图片历史回归通过（`.build/ImageHistoryTests.xcresult`）；模拟器“合成截图→停止→重启→暗色原图预览” UI 通过（`.build/ImageHistoryUI.xcresult`，截图 `.build/image-history-ui/`）。覆盖本地重启、过期源、损坏修复、消息归属、删除期间下载、清理引用及旧授权不恢复。没有访问实际图源或用户图片。

## 后续独立任务：照片／文件附件与发送

输入左侧 44 点“＋”菜单打开系统 PhotosPicker 或文件选择器，不申请完整相册权限。选中内容复制到会话草稿，支持预览、移除、重复去重、取消、失败提示与跨会话隔离；只有显式发送才传给当前模型。图片派生为最长边 2048 的 PNG，文本文件内容随当前用户消息发送；当前用户附件在工具截图之后仍保留，旧设备截图只保留最新一张。草稿和历史只存资源引用，不保存文本附件正文／Base64。未支持的协议、类型及大小限制明确报错，失败保留草稿。历史附件不会自动再次发送。

5 项发送回归＋4 项 UI 通过（`.build/AttachmentNativeVerified.xcresult`）：原生照片成功／重复选择、原生文件选择／预览、取消、合成草稿移除及显式发送，真实 Agent 往返中的文本／图片保留，以及 Anthropic/Gemini 仅发现协议的发送拒绝。初期无键盘加号测试的自动点击未触发；实际中心触控成功，现以 44 点区域和中心触控验证，未将此归因于未取得调用栈的 Conversion error。截图在 `.build/attachment-native-ui/`。仅用合成资源；真实 iCloud／第三方文件提供器仍待设备验收。

## 后续独立任务：技能管理与按需读取

设置提供技能查看、启用／禁用、原生文件导入和明确删除确认。导入 SKILL.md 或根目录含该文件的纯文本目录；元数据支持 name、description、可选 version 的简单文本／多行值，格式与限制在页面说明。只收 UTF-8 Markdown/TXT，不执行脚本，不跟随符号链接，不自动导入本机技能。相同内容版本去重；同名不同内容保留独立 UUID/revision，旧版本不自动删除。持久存档受完整文件保护并排除备份，损坏原件保留。

每次运行冻结启用版本；仅注册 list_skills/search_skills/load_skill，前两者只返回名称与摘要。加载按精确 id/revision 和包内资源路径，正文每页最多 2000 字并返回 next_offset，避免大结果被框架直接裁掉；参考文档另外按需读取。工具每次检查当前运行／取消资格，技能文本不能改变设备权限或覆盖任务。无技能正文注入系统提示，无外部文件／脚本执行器。历史工具卡只保留公开文档回执，使用书籍类 SF Symbols 和技能名称。

7 项技能回归＋1 条完整 UI 流程通过（`.build/SkillFinal.xcresult`，截图 `.build/skill-ui/`）：导入与重启、版本去重／禁用／删除、损坏存档、非法路径／符号链接、取消、分页不漏字、真实 Agent 的查询→主文档→参考文档往返，以及系统文件选择→详情→启停→重复导入→取消删除／确认删除→工具卡名称图标。未调用真实模型，未读取实际用户技能。

## 图片缓存重试补充

原图丢失后，同一远程链接可能返回不同内容；修复重试只追加新资源、却仍先读到旧失效引用的问题。下载成功后按消息内图源替换绑定，其他附件及尚有效的本地原图保持原行为；旧孤立资源仍由用户确认清理。新增回归验证新原图重启后可读、旧资源可清理、远程链接随后过期也不再请求网络。图片历史／附件存储／无凭据下载共 **14 项通过**（`.build/ImageRetryVerified.xcresult`）。

## 最终综合验收（2026-10-05）

- 全套当前 target：**214 项核心 + 13 项 UI，0 失败**，`.build/validation/core.dGj1mk/Tests.xcresult`。界面截图与索引在 `.build/final-ui/`；已检查附件草稿、会话模型选择、历史原图与技能卡的代表性截图。
- 随后只修正技能回调在 Swift 6 下的并发捕获警告；最终源码再次通过 **214 项核心 + 1 项技能 UI**，`.build/FinalConcurrencyVerified.xcresult`。其他 UI 代码未再改动。最后无签名 iPhoneOS build 成功，`.build/final-device-build.log`；本次构建未出现编译警告。
- PA3 C 的 ASan/UBSan 协议／HID 夹具及 25 项本机 TCP 测试再次通过（`.build/final-protocol-tests.log`）；12 项 wire-contract 通过（`.build/final-wire-tests.log`）。固件源码未修改，不需本次升级。
- Xcode 附加诊断仍受本机默认 xcrun 路径影响，不能找到 simctl；测试结果为成功，截图以显式 DEVELOPER_DIR 导出。未更改系统 Xcode 选择或签名。
- 原 Page 有效实现及后续模型发现、输入区、共享附件存储、图片历史、原生附件发送、技能、缓存重试分别有本地提交。`Conversion error` 仍需真机原始调用栈；真实服务商／跨 App HID 闭环／iCloud 文件提供器，以及可选归档测试、旧 Host 全量未验收。Anthropic/Gemini 仍仅支持模型发现，未宣称原生推理可用。
- 历史私有 Library 交接包保留；本地暂停／交接快照已移除，不覆盖恢复开发后的状态。未启动云端执行或额度监控。当前额度不可读，未声称已触及 5%。

## B1：同一响应内多个工具（用户明确确认后）

授权依据：用户 2026-10-05 明确“B1 一条消息中允许多个工具调用”。从 `636f4b2` 继续，移除流式／非流式单调用拒绝及提示词限制。Chat Completions 兼容请求允许模型返回多个调用，Ollama 不发送其未声明的 parallel_tool_calls 字段；App 的 `parallelToolCalls` 仍为 false，按返回顺序串行执行，不并发操作设备。

完整响应校验后才释放工具：保留原始 tool_call_id，缺失／批内重复／跨轮复用均整批拒绝，无重试或重放。同步更新本地 SwiftAgentKit：按 ID 去重，允许 screenshot→tap→screenshot 这类参数相同但 ID 不同的显式步骤；每个结果保留对应 ID；停止或取消后剩余工具逐一返回未执行结果。普通校验错误可回传模型后继续，未知输入结果仍封锁本轮后续点击／拖动；原有逐动作或任务授权、单次审批、截图资格和断线释放不变。

新增合成 Agent 回归覆盖混合技能／设备工具、多次观察、授权顺序、中途未知结果、可恢复错误、取消、拒绝、重复 ID 和下一模型轮次收到全部结果。流式／非流式解析覆盖整批缓冲、原始 ID 和请求字段。首轮发现旧测试仍要求 parallel_tool_calls=false，按本次授权更新，未移除安全断言。31 项定向回归通过（`.build/MultiToolVerified.xcresult`）；模型发现／安全测试另 24 项通过（`.build/MultiToolProtocolVerified.xcresult`，包含重复复核的 12 项安全测试）。最终综合结果追加在后续验收。

## B6：服务商思考内容／摘要展示

授权依据：用户同次明确“B6 要支持思考消息展示”。在现有 Agent 事件→会话存档→SwiftUI 消息组件中贯通，使用与工具卡一致的原生 DisclosureGroup，默认折叠，显示接收中／已完成／已中断／生成失败。正文和思考分别保存；只有思考的工具轮次也保留，不用答复覆盖。停止、网络错误或重启后保留已收到部分，迟到事件不能写入其他运行／会话。旧存档可读；新任务上下文只使用公开正文，不自动回传历史思考。

| 当前推理路径字段 | 支持范围 |
| --- | --- |
| Chat Completions `choices[0].delta/message.reasoning_content`、`reasoning` | 仅字符串，流式增量及非流式完整响应 |
| `reasoning_details[].type == reasoning.summary` 的 `summary` | 可读摘要；流式／非流式均支持 |
| `reasoning_details[].type == reasoning.text` 的 `text` | 可读文本；同块拼接、不同块分段 |
| encrypted／opaque／signature／未知对象或类型 | 不展示、不存入思考正文；不解码为文本 |
| 普通 `content` 中的 `<think>` 等标签 | 仍是普通答复，不猜测或抽取为思考 |

同一响应固定使用首个有内容的可读通道；同时出现时优先 details，再 reasoning_content、reasoning，避免别名重复展示。字段依据本地固定版本 SDK 和 [OpenRouter 官方 reasoning_details 说明](https://openrouter.ai/docs/guides/best-practices/reasoning-tokens)。未新增 reasoning effort／预算参数，不要求服务商披露未提供的内容。OpenAI-compatible、OpenRouter、Ollama 的现有 `/v1/chat/completions` 路径按以上字段识别；没有字段就不显示区块。原生 Anthropic/Gemini、OpenAI Responses、Ollama 原生 `/api/chat` 以及需要签名／加密 reasoning 跨工具轮次回传的模式尚未接入，不能据此宣称这些模式兼容。

新增 9 项解析／历史／真实 Agent 合成回归，覆盖字段与别名去重、忽略加密内容、普通正文不抽取、取消／错误、旧存档／重启、跨会话迟到事件、思考→多工具→下一轮答复。初次 22 项定向单元测试通过（`.build/ReasoningInitial.xcresult`）；该次 UI 失败经层级证实是父 DisclosureGroup 标识覆盖正文标识，已把标识限定到标题，3 项 UI 随后全通过（`.build/ReasoningUIVerified.xcresult`）。已检查 `.build/reasoning-ui/` 中完成、失败、流式和暗色恢复的 4 张截图。包含追加的完整链路用例在内，231 项核心回归已全部通过；最终 UI／构建结果见后续验收。

## B1／B6 最终验收

- 本轮基于 `636f4b2`；B1 独立提交 `67a61ae`，B6 独立提交 `3411739`，沿用 `feature/project-todos` 独立 worktree。
- **231 项核心 + 16 项 UI 全部通过，0 失败**：`.build/validation/core.PdT8cE/Tests.xcresult` 及同目录 `test.log`。包括既有停止／授权／隔离／迁移、模型、附件和技能回归。
- 最终 iPhoneOS 无签名构建成功：`.build/b1-b6-device-build.log`，没有编译警告。UI 日志仍有基线已有的“Modifying state during view update”警告（旧 `.build/validation/core.dGj1mk/test.log` 同样存在）；Xcode 附加 simctl 诊断失败也仍存在，未把这两项误报为本次新增或已修的 Conversion error。
- 本轮没有固件或 USB wire 变更，未重跑已通过的 C/TCP/wire 夹具；可选归档／旧 Host 全量、真实服务商字段与签名兼容、真实多动作 HID／断线释放及跨 App 闭环未验收。未请求真实密钥、安装真机、刷写、合并或推送；主线原有签名改动与其他 worktree 保持原状。


## 2026-10-09：VPN 回环免 ESP32 模式

已新增 VPN 回环连接模式，作为首个选项及未保存偏好时的默认值；已有显式 ESP32 选择保留。两条路线共用 App 内系统配对身份与 CoreDevice 后端，切换或保存地址配置会释放旧会话并撤销旧截图/动作授权，运行中禁止修改。接口与对端 IPv4 可编辑，默认 10.7.1.1 / 10.7.0.1，发现或绑定失败不回落其他通道。新配对广播和协议中的授权名称为「执言」。

iPhone 15 Pro 真机已通过：复用已有身份、CoreDevice 认证、1179 × 2556 截图、真实点击计数 0 → 1、对端确认媒体释放；更新已安装并正常启动。最新默认 App 326 项、Swift/C/Rust 链路 40 项、Rust 45 + 176 项及 PA3 TCP 25 项通过；模式与地址 UI 用例通过。证据、测试入口及剩余拖动/后台验收边界见 [VPN 回环模式](ncm-coredevice/LOCALDEVVPN.md)。


## 2026-10-10 ProviderKit 迁移与离线验证

- 当前依赖图已移除 LLMProviderKit（包括 SwiftAgentKit 的间接依赖）。保留 SwiftAgentKit；仅适配 Provider 消息／响应／上下文与安全终态接缝，不扩大设备并发、授权或模型自动重试。
- 包目录及包名统一 `ios-app/ProviderKit`／`ProviderKit`；模块、target、product、Sources 目录为 `ProviderCore` 和 `OpenAIAdapter`。远程 SPM 固定 MacPaw/OpenAI 0.5.2，commit `975fff8a1e1ef92fc7fc04097b0cfe253b840cb7`；无 SDK vendoring、源码补丁或 fork。保留上游许可证与来源记录。
- ProviderCore 自有消息／图片／工具／原生有序输出／流事件／错误／作用域句柄；MacPaw 类型仅在适配器 codec 内。窄传输使用 ephemeral、禁重定向、有限缓冲与请求／响应大小上限；规避 SDK 0.5.2 streaming 独立 default session 和 DEBUG 原始载荷日志。
- Responses 默认无状态本地回放／store=false；OpenAI 响应链须明确选择 store=true，每轮仅提交新增输入并重发 instructions。任务作用域独立于 UI 历史。完成终态后先原子持久化 head、native replay 与 pending calls，再允许派发；EOF、item.done、incomplete、failed、cancelled、未知关键 item/event 不授权动作，不重复生成。StreamCheckpoint 与设备 RunLifecycle journal 独立，取消保存 epoch 并保全证据；不恢复授权或自动重放。
- 服务商 `ProviderKind`／端点配置 `ProviderProfile` 与 wire 选择 `InferenceAPI`／`OpenAIWireProtocol` 分离；旧 JSON `protocolKind` 字段和原始枚举值继续兼容。OpenRouter 原 Chat 配置、baseURL 前缀、模型 ID、Keychain 引用及已支持参数保留。显式 Responses 仅允许无状态；配置与 wire 边界均拒绝 store=true／previous_response_id。依据 [OpenRouter 官方 Responses](https://openrouter.ai/docs/api_reference/responses/overview)，不能把 OpenAI 服务端状态能力传播给 OpenRouter。
- OpenRouter Chat 按 [官方 reasoning 合约](https://openrouter.ai/docs/guides/best-practices/reasoning-tokens) 保全完整、有序 reasoning_details（含签名、opaque、扩展字段），通过自有 scoped replay state 续接工具结果；UI 仅展示既有可读投影。流末 usage 的非空 choices／相同重复 finish_reason 不再次派发工具；冲突终态拒绝。不能重建被服务商遮蔽的内容。
- 100 轮合成截图测试保留所有 call/result，只留最近设备图及用户附件。这是引用／编码不变量验证，**不是实机 RSS 或长时间内存测量**。请求超限显式失败；Responses 禁用旧消息数/token 静默剪链。

验证证据：

- `bash ios-app/scripts/test_core.sh 48D357F3-023C-41C1-8C07-EB0984733302`：**351 核心测试通过、0 失败**；`.build/validation/core.To9bSu/Tests.xcresult` 与 `test.log`。协议、单次授权、会话隔离、未知结果、防重放、checkpoint、停止覆盖留在默认 target。
- `CC=clang bash tools/test_usb_device.sh`：**25 测试通过**；`.build/validation/provider-usb.log`，仅 TCP 回环／协议夹具。
- 最终 unsigned iPhoneOS/Xcode 27 build：**BUILD SUCCEEDED**；`.build/validation/provider-iphoneos-final.log`。解析依赖图中无旧 Kit，只有远程 OpenAI 0.5.2 及其锁定的 swift-openapi-runtime／swift-http-types 等依赖。
- 首轮全 UI（重命名前构建）23 项中 20 通过、3 失败：模型发现后的 composer focus 未显示菜单、服务商会话用例最后断言 ESP32 标题、VPN 保存按钮状态。证据 `.build/validation/core.ENW26I/Tests.xcresult`／`test.log`。后两项涉及未修改的设备设置流程；尚未建立基线对照，不能归因或称为全量通过。服务商相关定向回归另记下方。
- 最后服务商定向 UI：**2 项通过、0 失败**；`.build/validation/provider-ui-recheck.xcresult`／`provider-ui-recheck.log`。新增 Responses 设置保存／切回 Chat 的状态重置；模型发现用例使用已有 composer-model 用例的两次点击完成焦点过渡，保留模型参数、缓存及会话选择断言。完整 UI 首轮剩余的 ESP32 标题／VPN 保存按钮两项仍待查，未修改设备流程来掩盖断言。
- Python 工程生成／source-check 脚本语法检查与 git diff whitespace 检查通过；可选 `check_source.py` 全检查因本机未安装 yaml/tree_sitter 依赖未运行，不以它替代实际编译。

边界：无真实模型收费调用、无真机端到端或实际内存测量；SDK 编译与 mock 通过不证明所有 OpenRouter 模型兼容。模型目录不证明 Responses 支持；显式已知不支持视觉／工具／生成的模型会拒绝，未知能力仍须后续真实验收。Conversations、background、compaction、hosted tools、远端 cancel/resume、新路由/session_id/provider-selection 和完整服务商扩展参数未接入。session_id 不作为会话存储。未由本任务执行提交、推送或清理他人暂存内容。


## 2026-10-11 OpenRouter Chat 末尾 usage 误判修复

用户反馈：使用 OpenRouter 地址、OpenAI-compatible + Chat Completions，正文返回后标记“回复未完成”，并显示通用服务商错误。定位到本地可复现兼容缺陷：[官方 Streaming 合约](https://openrouter.ai/docs/api_reference/streaming) 的最后 usage 帧包含非空 choices、`delta.role=assistant`、空 content 和重复 finish_reason；旧解析器把 role 元数据误判为完成后的新输出。此前 reasoning/usage 夹具只带空 content，漏测 role 字段；本次补齐完整官方形状。

修复仅在 Chat 终态后的内容判定中排除合法 assistant role 元数据。重复终态仍必须相同；非空文本／工具、冲突终态、错误 role、无成功终态的截断流和单独 [DONE] 仍拒绝，不自动重新生成。不修改 Responses、服务商配置、设备并发或权限。

离线回归：实际 URLSession/URLProtocol → SSE frame decoder → PrivateVisionProvider 的测试同时覆盖 OpenAI-compatible 和 OpenRouter 两种配置，确认正文只出现一次、只发布一个 completed 终态、usage=17 且仅一次请求；工具 reasoning 回放用例也加入 role/native_finish_reason 末帧。核心 **353 tests，0 失败**，证据 `.build/validation/core.H7kfP4/Tests.xcresult`／`test.log`；最终无签名 iPhoneOS build 通过，`.build/validation/openrouter-accounting-iphoneos.log`；USB 回环 **25 tests 通过**，`openrouter-accounting-usb.log`。仅协议解析改动，未新增 UI 改动，未重复完整 UI 回归。

没有读取密钥、发起收费模型请求或操作真实手机；尚未取得该次真实请求的脱敏帧，因此本地复现与修复吻合反馈，但仍需更新 App 后真实复验，不能称在线联调已经通过。保留已有未提交／暂存修改，没有执行提交或推送。

### 2026-10-11 服务商选项精简

按用户要求，服务商选择列表移除 Anthropic、Gemini、Ollama，只提供 OpenAI-compatible 和 OpenRouter。`ProviderModels.swift` 的 `selectableKinds` 与持久化枚举分离；保留旧 raw value 与底层兼容代码，以免旧条目导致整个配置归档无法解码。`ProvidersView.swift` 对旧类型显示选择提示，用户明确改选前不能获取模型或保存；不自动改类型、地址或密钥。原有配置条目仍可查看、移除／恢复。

`ModelDiscoveryTests.swift` 验证三种旧配置与 OpenRouter 混合归档恢复；`ConversationUITests.swift` 在既有上下文保存用例中验证菜单只有两个服务商、旧选项不存在且两种类型可切换。核心 **354 tests，0 失败**：`.build/validation/core.AglNAx/Tests.xcresult`；定向 UI **1 test，0 失败**：`.build/validation/provider-selection-ui.xcresult`／`provider-selection-ui.log`；无签名 iPhoneOS **BUILD SUCCEEDED**：`provider-selection-iphoneos.log`。本轮未重跑完整 UI、未调用线上 API；此前完整 UI 的两项设备设置失败仍未解决。未提交／推送，保留其他任务已有修改。

### 2026-10-11 DeepSeek 无状态 Responses 思考兼容

用户反馈 Responses 失败但 Chat 正常，确认选择本地回放。核对 [DeepSeek 官方 Responses 说明](https://api-docs.deepseek.com/guides/responses_api/)：官方支持 `https://api.deepseek.com/responses`，使用无状态历史回放，思考流为 `response.reasoning_text.delta/done`，reasoning 项可用 `content: [{type: reasoning_text, text: ...}]`，终态后没有 `[DONE]`。原 reducer 对这两个语义事件会进入 unsupported 分支；SDK 0.5.2 对 summary 必填，会拒绝未含 summary 的 plain-content reasoning 项。尚无实际失败请求的地址、模型 ID、完整提示或脱敏帧，不能确认这两个缺口是用户请求的全部原因。

`ResponsesReducer.swift` 接受这两个事件，保持地址、顺序、重复、终态及工具执行检查；`OpenAIWireCodec.swift` 检查 plain reasoning content，仅在 SDK 验证副本补缺省空 summary，原生 content 仍保留用于同域回放；`NativeItems.swift`／`ModelTypes.swift` 将明确返回的 plain reasoning 投影为可读思考，summary 与加密内容语义保持独立。未修改 HTTP 重试、终态成功规则、服务商地址、自动接口降级或设备授权逻辑。

新增两项回归覆盖 plain reasoning 增量、完成与回放、非法字段／地址拒绝，以及 URLSession/URLProtocol → SSE → Provider 无 `[DONE]` 完整流（单次请求、正文与思考分开、completed 终态）。核心 **356 tests，0 失败**：`.build/validation/core.ui9aJ7/Tests.xcresult`／`test.log`；最终无签名 iPhoneOS build 通过：`.build/validation/deepseek-responses-iphoneos.log`。本轮没有 UI 改动，未重跑 UI／USB；没有读取密钥或调用线上 API，需要更新 App 后真实复验。本轮修复尚未提交，保留已有 Xcode／Info.plist 工作区修改。

### 2026-10-11 供应商页面与添加流程

设置入口、供应商列表／编辑标题、会话入口及相关提示统一使用“供应商”。添加按钮先打开列表，按 OpenAI、OpenRouter、自定义供应商顺序显示；预设仅填写名称和 HTTPS 基础地址，自定义名称、地址、模型与密钥留空，仍使用已有 OpenAI 兼容协议边界。选择后进入编辑页，不再显示或允许切换供应商类型。API 选择器标题为“API格式”，选项为“OpenAI Chat Completions”和“OpenAI Responses API”；现有配置类型／地址／密钥及上下文规则保持原语义。旧已移除类型可读取，提示返回列表另行添加，不自动转换。

`ProvidersView.swift` 添加独立选择流程并移除编辑页类型 Picker；`SettingsView.swift`／`ConversationView.swift` 及提示文案同步更新，`ProviderModels.swift` 更新 API 标题；UI 新增三项预设／自定义选择与空白编辑检查，原恢复、上下文保存、模型发现用例适配新流程。核心 **356 tests，0 失败**：`.build/validation/core.jd5IcK/Tests.xcresult`；定向 UI **4 tests，0 失败**：`.build/validation/supplier-flow-ui.xcresult`／`supplier-flow-ui.log`；最终无签名 iPhoneOS build 通过：`supplier-flow-iphoneos.log`。已导出并检查新增列表与自定义编辑页截图，见 `.build/validation/supplier-flow-screenshots/manifest.json`。未重跑完整 UI／USB，未调用线上 API，未自动提交或推送；已有工程和 Info.plist 修改保留。

### 2026-10-11 供应商编辑页精简与模型列表

移除基础地址说明、上下文策略说明与 API格式说明行。删除独立“接口报告的能力”区域，改为模型行内图片／工具／思考／生成 chip；未知能力仍显示未知，不推断支持。每模型参数编辑暂时隐藏，存储与请求参数逻辑保留；同地址保存不清空原参数或其他模型 ID。移除多行其他模型编辑控件，保留手动默认模型 ID 输入。

模型 Section 标题右侧放刷新图标，刷新中显示进度与取消按钮，失败保留旧缓存。Section 内最多展示 5 个模型，点击设为默认模型并标记当前项；超过 5 个时底部显示“浏览全部模型”，复用会话中的 `ProviderModelPicker`，支持搜索与选择。共享浏览列表也显示相同 chip，搜索栏在顶部常驻。成功／失败状态放在 Section footer，不再单独占模型行；原缓存继续持久化。

核心 **356 tests，0 失败**：`.build/validation/core.P7nJjw/Tests.xcresult`。定向 UI 首轮三项通过（新增、移除恢复、上下文保存），模型浏览测试因 firstMatch 定位到背后会话搜索框失败；修正准确定位并常驻模型搜索栏后，模型浏览／保存／会话缓存选择单独复验通过：`supplier-compact-search-recheck.xcresult`，首轮证据 `supplier-compact-ui.xcresult`，对应日志同名。最终无签名 iPhoneOS **BUILD SUCCEEDED**：`supplier-compact-iphoneos.log`。已检查自定义空白页与模型 chip 截图，分别见 `supplier-compact-screenshots/manifest.json`、`supplier-compact-model-screenshots/manifest.json`。UI fixtures 增为 7 个合成模型以覆盖列表上限与搜索；未调用线上 API，未重跑完整 UI／USB，未提交或推送，保留已有用户修改。

### 2026-10-11 默认模型在列表内标记

移除独立默认模型输入行，选中模型仅以列表行右侧对号／“已选中”辅助功能状态表示。新增 `ProviderProfile.previewModels`：按原其他模型／有效目录顺序去重，展示前 5 个；选中项若不在前 5 个中，额外追加到末尾，放在“浏览全部模型”之前（最多 6 行），不将其移到顶部、不挤掉前 5 行。过期目录不参与列表，旧／手动选中项仍保留显示。标题栏“添加模型”弹窗保留手动 ID 输入，确认后添加到模型列表并选中；无独立默认行。

单测覆盖列表外选中、列表内不重复、手动 ID、空列表、目录顺序与失效目录。核心 **357 tests，0 失败**：`.build/validation/core.1dqyQo/Tests.xcresult`；定向 UI **2 tests，0 失败**：`selected-model-ui.xcresult`／`selected-model-ui.log`，验证第七个模型追加在第五行后且浏览全部前、对号对应状态、保存与会话选用，并验证新手动添加入口与供应商恢复。最终无签名 iPhoneOS build 通过：`selected-model-iphoneos.log`；选中末尾截图已检查：`selected-model-screenshots/manifest.json`。未调用线上 API，未重跑完整 UI／USB，未提交／推送，保留其他已有修改。


### 2026-10-11 未配置默认模型时自动选首项

`ProviderProfile.selectDefaultModelIfNeeded` 在默认 ID 为空／仅空白时，选用列表首个非空模型；保留已有默认 ID，空列表保持空，失效目录不参与。编辑页初始化与刷新目录后调用同一规则；保存、载入旧配置、恢复移除配置也应用该规则，避免未打开编辑页的旧配置继续缺少默认模型。加载只归一化内存中的配置，下一次持久化时写入，不直接重写原归档。界面继续用对应行对号表示选择。

新增单测覆盖列表顺序、保留手动选择、有效／失效目录、空列表、保存及旧配置加载。核心 **359 tests，0 失败**：`.build/validation/core.DUmX8g/Tests.xcresult`；定向 UI **1 test，0 失败**：`automatic-default-ui.xcresult`／`automatic-default-ui.log`，从无默认模型的合成供应商刷新，断言首项已选中，随后验证改选、保存与会话使用。无签名 iPhoneOS **BUILD SUCCEEDED**：`automatic-default-iphoneos.log`。`git diff --check` 通过；未调用线上 API、未重跑完整 UI／USB、未提交／推送；已有其他工作区修改保留。


### 2026-10-11 API 格式短名称与模型能力图标

API 格式选项移除 OpenAI 前缀，显示 `Chat Completions`、`Responses API`，存储值与协议路径不变。编辑页和全部模型选择页共用的 `ProviderModelRow` 改为在模型 ID 右侧显示小图标：图片输入 `photo`、工具调用 `wrench.and.screwdriver`、思考 `brain`、文本生成 `text.bubble`；仅明确 supported 时显示，unknown／unsupported／无元数据均隐藏，不再显示能力文字或胶囊背景。图标保留辅助功能与 help 说明。“生成”表示文本输出／回复能力；OpenRouter 取自 output_modalities 的 text，其他旧协议取自对应生成方法或 completion 能力，不表示图片生成。能力解析、推理校验与设备执行规则不变。

核心 **359 tests，0 失败**：`.build/validation/core.5KzYFS/Tests.xcresult`。定向 UI 首轮新增供应商、API／上下文切换两项通过；模型浏览测试因原 StaticText 定位在简化的按钮辅助功能结构中失效，新增稳定模型选项按钮标识并更新定位后复验通过：`model-icons-ui-recheck.xcresult`／`model-icons-ui-recheck.log`；首轮证据保留为 `model-icons-ui.xcresult`／`model-icons-ui.log`。共三项 UI 流程分别通过，验证未知能力隐藏、默认模型对号、模型搜索／改选／保存／会话选用与短 API 标签。最终无签名 iPhoneOS **BUILD SUCCEEDED**：`model-icons-final-iphoneos.log`。模型行截图导出并检查：`model-icons-screenshots/manifest.json`。未调用线上 API、未重跑完整 UI／USB，未提交／推送；保留其他已有工作区修改。


### 2026-10-11 能力图标紧邻模型 ID

共享模型行将 Spacer 移到能力图标后：模型 ID、能力图标紧邻左侧排列，默认模型对号继续保留在行尾。供应商编辑页与全部模型选择页同步生效，能力显示条件不变。

核心 **359 tests，0 失败**：`.build/validation/core.4r9HCV/Tests.xcresult`；无签名 iPhoneOS **BUILD SUCCEEDED**：`model-icons-inline-iphoneos.log`；`git diff --check` 通过。仅布局间距调整，未新增测试或重跑 UI／USB，未调用线上 API、未提交／推送，保留其他工作区修改。


### 2026-10-11 模型标题栏按钮间距与对齐

模型标题栏改为紧邻的双按钮组，去掉默认 HStack 额外间距；保留各自 44 点点击区域，补偿右侧图标在点击区域内的缩进，使刷新图标与下方模型行对号的可见边缘对齐。标题继续与模型 ID 左边缘对齐。加载中在原刷新按钮位置显示可取消的进度指示，不另插入第三个控件，避免按钮组宽度变化。

核心 **359 tests，0 失败**：`.build/validation/core.S42OFX/Tests.xcresult`；定向 UI **2 tests，0 失败**：`model-header-ui.xcresult`／`model-header-ui.log`，覆盖刷新模型、浏览／改选／保存、手动添加及移除恢复。无签名 iPhoneOS **BUILD SUCCEEDED**：`model-header-iphoneos.log`。已导出并检查截图，标题与模型 ID 左边缘一致，刷新与行尾对号对齐：`model-header-screenshots/manifest.json`。`git diff --check` 通过；未调用线上 API，未重跑完整 UI／USB，未提交／推送，保留其他工作区修改。


### 2026-10-11 API 密钥字段文案与已保存掩码

字段文案缩短为“API 密钥”。编辑已有供应商时，只检查同一配置 ID／规范化地址／供应商类型对应的钥匙串项目是否存在；`SecretStore.contains` 明确设置 kSecReturnData=false，只查询存在性，不将真实密钥回填到 UI。已保存且未输入替换值时显示固定 8 个圆点、正常 primary 文字色；聚焦后进入空白替换输入，未输入则失焦恢复掩码。显示圆点仅是覆盖层，不绑定到待保存值；空值保存继续保留原密钥，输入新值才替换，切换地址／类型不借用旧地址密钥状态。辅助功能分别报告未设置／已保存／已输入，不读取或朗读密钥内容。

为独立验证 UI 状态和保存规则，新增可注入的供应商密钥写入／存在性检查；生产默认仍调用系统 SecretStore。单元测试及 DEBUG 专用 `--ui-testing --ui-test-provider-key` 使用临时内存合成值，不访问真实凭据。首轮直接依赖钥匙串的新增用例在保存步骤失败，证据 `core.bLjVkE`；随后 DEBUG fixture 插入位置导致编译失败，已修正，证据 `core.IWvPCC`。最终核心 **360 tests，0 失败**：`.build/validation/core.ShPZBz/Tests.xcresult`；定向 UI **2 tests，0 失败**：`provider-key-mask-ui.xcresult`／`provider-key-mask-ui.log`，覆盖保存后样式、替换、空值保留、地址变更及新建供应商。最终无签名 iPhoneOS **BUILD SUCCEEDED**：`provider-key-mask-final-iphoneos.log`。合成密钥掩码截图导出并检查：`provider-key-mask-screenshots/manifest.json`。`git diff --check` 通过。真实钥匙串存在性显示未做签名真机验证；未调用线上 API、未重跑完整 UI／USB、未提交／推送，保留其他已有修改。


### 2026-10-11 聊天模型菜单与最后选择

输入框模型文字后紧邻下拉箭头（4 点间距）。菜单的供应商与模型选中对号放到文字右侧；原生菜单会将独立 Image 移到前方，因此使用文案末尾的对号，已通过截图验证。移除“其他模型…”和聊天内“管理供应商”入口，保留“浏览全部模型”。前 12 个模型以外的当前选择追加到菜单，避免最后选择未在目录预览中出现。

ProviderStore 的兼容 v1 归档新增可选 lastSelection，仅保存供应商 UUID 与模型 ID；显式切换后持久化，重启／新建会话继承，打开已绑定旧会话不覆盖偏好或旧会话选择。无记录或供应商已移除时回退到首个可用供应商；没有供应商时保持未选择。供应商默认模型配置不被会话改选覆盖，运行中及不存在的会话不能改写选择。旧版无该字段的归档保持可读，ChatGPT 订阅和其他现有配置逻辑保留。

核心 **397 tests，0 失败**：`.build/validation/core.lZgO7e/Tests.xcresult`，新增偏好持久化、重启恢复、删除／恢复回退、旧会话隔离及忙碌会话拒绝改选验证。最终定向 UI **2 tests，0 失败**：`chat-model-choice-ui-verified.xcresult`／`chat-model-choice-ui-verified.log`，覆盖右侧对号、移除入口、切换模型、新会话继承及浏览全部模型；截图导出并检查：`chat-model-choice-verified-shots/manifest.json`。最终无签名 iPhoneOS **BUILD SUCCEEDED**：`chat-model-choice-verified-iphoneos.log`。首轮／第二轮 UI 分别因空列表与有会话列表的新建按钮标识不同、输入框焦点过渡需要完成第二次点击而失败，已修正测试，保留 `chat-model-choice-ui.xcresult` 与 `chat-model-choice-ui-final.xcresult` 证据；第二轮截图也证实原生菜单会重排独立图标，最终方案已修正。现行控制页导航断言同步为默认 VPN 回环控制，不改设备控制行为。

`git diff --check` 通过。验证使用隔离模拟器与本地 fixture，未调用线上模型 API、未作签名真机或完整 UI／USB 验收，未提交／推送。


### 2026-10-11 ChatGPT 订阅登录按钮显示

订阅供应商编辑页仅在连接状态为 disconnected 时显示“使用 ChatGPT 登录”，已登录后隐藏。退出仍保留账号引用，但状态变为 disconnected，因此按钮重新出现；取消登录后同样可重新开始。未改账号、授权或请求逻辑。现有签名 mock 登录／退出 UI 用例更新为断言登录后按钮不存在、退出后恢复。

核心 **397 tests，0 失败**：`.build/validation/core.rdArEH/Tests.xcresult`。最终定向 UI **2 tests，0 失败**：`chatgpt-hide-login-ui-final.xcresult`／`chatgpt-hide-login-ui-final.log`，覆盖登录成功后隐藏、模型展示、退出后恢复及取消登录。无签名 iPhoneOS **BUILD SUCCEEDED**：`chatgpt-hide-login-final-iphoneos.log`。首轮使用 selected 账号引用判断，在退出后恢复按钮断言失败（`chatgpt-hide-login-ui.xcresult`）；检查确认退出保留该引用，已改为依据实际连接状态。`git diff --check` 通过。全部登录验证使用本地 mock，未进行真实账号授权、线上 API 或签名真机验证，未提交／推送，保留此前未提交改动。


### 2026-10-11 新建聊天在首次发送前保持临时草稿

聊天首页的新建入口改用 createConversationDraft。ConversationStore 内存 records 保存草稿与历史，公开 conversations 与所有归档写入仅包含正式历史，临时 draftIDs 不编码到磁盘；输入、供应商／模型切换、附件添加以及其他会话保存不会将未发送草稿落盘。首次 begin 原地转为正式会话，保持会话 UUID、模型选择、附件归属并保存首条用户消息。返回或导航替换时只丢弃未发送草稿并移除对应空闲运行容器；已经发送或运行中的会话保留。首次发送前的配置拒绝／取消不会留下正式会话。Siri prepare 的显式持久化路径和原有历史／授权／并发／checkpoint 行为保留。草稿附件在编辑期间纳入资源引用保护；返回丢弃后按现有孤立附件清理机制处理。

新增 3 项核心测试覆盖未发送草稿从历史／重启／Siri 原子写入中排除，首次消息保存时保持 UUID／供应商／模型／附件，避免重复 begin，以及重复打开／丢弃草稿、默认模型继承与运行容器释放。默认核心 **400 tests，0 失败**：`.build/validation/core.xpTZgz/Tests.xcresult`。定向 UI **2 tests，0 失败**：`transient-conversation-ui.xcresult`／`transient-conversation-ui.log`，覆盖空白返回、输入但未发送返回、新草稿清空、首条离线回复后只出现一条历史，以及模型选择与默认继承回归。截图导出并检查：`transient-conversation-ui-shots/manifest.json`。无签名 iPhoneOS **BUILD SUCCEEDED**：`transient-conversation-iphoneos.log`。`git diff --check` 通过。未调用线上模型 API、未做签名真机或完整 UI／USB 验收，未提交／推送。


## 2026-10-11 · Siri 后台新建会话

执行任务 Intent 改为 background + dynamic foreground，并关闭固定 openAppWhenRun。已在前台初始化过且实际媒体保活有效的 App 在后台或 Siri 引起的 inactive 状态直接提交新的独立会话；冷启动或保护数据不可用时请求前台继续。每次话语保留独立 commandID，相同请求重试不重复执行。普通 UI 发送仍要求前台。后台发起的新轮次独立申请执行资格，模型启动前等待有效 lease；设备工具仍校验后台能力、授权与 checkpoint，停止释放及未知结果不重放保持原行为。

新增覆盖后台新会话与重试去重、锁屏等待，以及后台启动默认拒绝／显式申请／lease 与工具能力门禁。真机 Siri 保持当前界面与冷启动切换尚待验收。

最终默认 App target **405 tests，0 失败**：`.build/validation/core.g16vpO/Tests.xcresult`。无签名 iPhoneOS **BUILD SUCCEEDED**：`.build/validation/siri-background-iphoneos.log`。`git diff --check` 通过；未调用线上模型、未做真机 Siri 或归档 UI 验收，未提交／推送。


## 2026-10-11 · 可选后台常驻

设置 → 后台执行新增“后台常驻”，默认关闭，保存到 backgroundResidentEnabled。开启后 StatusPiPController 的媒体需求为任务运行或常驻开启，空闲时也沿用所选音频／PiP 模式；最后一个任务结束不停止常驻，关闭常驻时仍保留正在执行任务的媒体，全部需求结束才释放。空闲常驻切换模式立即生效，执行中的任务保留本轮模式。不会为保活创建会话、运行 checkpoint 或启动模型。实际播放回执仍由 PiPExecutionActivity 管理，中断或失效不伪造后台执行资格。

修正 Siri 判断：曾进入前台不代表仍有后台资格；空闲后台无实际媒体保活时请求前台继续。有实际保活才直接后台新建会话。新增 handoffRequired/mediaActive 诊断。系统挂起／终止、Siri 音频中断、真机空闲常驻后接收任务仍需实体设备验收。

## 2026-10-11 · Siri 接入 LiveActivityIntent

执行任务入口采用 `LiveActivityIntent`，保留 background + dynamic foreground、现有保护数据／实际媒体资格与任务去重规则。成功提交任务后，在 Intent 返回前等待实时活动队列处理完成；等待期间被替换的首次状态也纳入队列等待，避免后台创建请求落在 Intent 执行结束之后。系统拒绝创建活动只保留现有诊断与提示，不重复提交任务。该接入不提供持续后台时间或 PiP 启动权限。

新增离线回归覆盖旧活动写入阻塞时等待新活动创建、命令重试不重复创建、活动拒绝不重放任务；编译约束确认执行入口遵循 `LiveActivityIntent`。默认核心 **411 tests，0 失败**：`.build/validation/core.F1xd1p/Tests.xcresult`；无签名 iPhoneOS **BUILD SUCCEEDED**：`.build/validation/siri-live-activity-iphoneos.log`。首轮 `.build/validation/core.SUt9aZ` 在测试进程启动前被系统终止，未产生用例结果；改用本次专用隔离模拟器后通过。`git diff --check` 通过。后台 Siri 新任务的实际灵动岛显示及媒体中断行为仍待真机验收，未调用线上模型、未提交／推送。

默认 App target **409 tests，0 失败**：`.build/validation/core.g1OAZV/Tests.xcresult`；常驻设置 UI **1 test，0 失败**：`.build/validation/background-resident-ui-reboot.xcresult`，验证实际开关点击、重启保存、关闭以及无自动任务，成功截图已导出并检查。首次 UI 点击整行空白导致断言失败，改点原生开关后，一次测试运行器启动异常／模拟器退出；重启专用模拟器后通过。无签名 iPhoneOS **BUILD SUCCEEDED**：`.build/validation/background-resident-iphoneos.log`。`git diff --check` 通过，未提交／推送。真机长时间常驻、Siri 音频中断与后台收任务尚未验收。

## 2026-10-11 · 常驻预建待命实时活动

开启后台常驻后，在前台预建一个“后台待命”实时活动；常驻已开启时重新进入前台也会补建。后台任务更新同一个活动，不依赖后台重新创建。可变 ContentState 保存当前会话／运行／演示标记，组件链接随任务切换；旧版本 payload 缺少字段时回退原 attributes，待命链接只打开首页，不创建会话或授权。连续任务及并行任务选用最新活跃状态，旧任务结束不覆盖新任务。后台完成状态保留结果提示，下一任务复用，回前台后恢复待命。关闭常驻时保留正在运行的任务，空闲或任务结束后释放；系统结束活动后前台可重新建立。实时活动只负责展示，执行资格继续取决于实际媒体保活。

默认核心 **415 tests，0 失败**：`.build/validation/core.RuY4i8/Tests.xcresult`，新增待命预建、后台复用、连续任务路由、开关竞争、关闭后活动释放及旧 payload 兼容覆盖。定向设置 UI **1 test，0 失败**：`.build/validation/resident-live-activity-ui-settled.xcresult`，覆盖开启、后台切换、重启持久化、关闭与无自动任务。无签名 iPhoneOS **BUILD SUCCEEDED**：`.build/validation/resident-live-activity-iphoneos.log`。系统日志 `.build/validation/resident-live-activity-system-events.log` 确认 standbyCreated、standby content 与 active 状态；已检查稳定主屏截图 `.build/validation/resident-live-activity-ui-settled-shots/manifest.json`，截图未显示灵动岛，因此不将请求成功作为可见展示证据。真机录屏／Siri 后台触发后的实际灵动岛展示仍待验收。`git diff --check` 通过，未调用线上模型、未提交／推送。

## 2026-10-11 · 弱化常驻待命展示

保留前台预建的待命活动，待命时锁屏组件改为透明、1 点高的空内容，移除标题／图标／说明／按钮；灵动岛 expanded／compact／minimal 均不绘制待命内容，keyline 透明。待命创建与更新 relevanceScore 为 0，任务更新仍为 100；该值只影响排序，不承诺隐藏活动。任务及结果状态沿用完整展示与当前会话链接。系统仍可能保留活动外框或灵动岛占位，实际弱化效果待真机验收，未将空布局当作系统隐藏 API。

默认核心 **415 tests，0 失败**：`.build/validation/core.aNsYCL/Tests.xcresult`；无签名 iPhoneOS **BUILD SUCCEEDED**（含实时活动组件）：`.build/validation/quiet-standby-iphoneos.log`。`git diff --check` 通过。未进行真机锁屏／录屏／Siri 展示验证，未提交／推送。

## 2026-10-11 · 后台任务开始时请求灵动岛展开

后台运行首次有效活动更新使用 AlertConfiguration 请求系统短暂展示 expanded 灵动岛；常驻预建活动复用与按任务创建两条路径均接入。每轮任务只请求一次，前台与待命不请求，重复或后续进度更新不重复提醒；完成提醒继续单独去重。提醒使用系统默认声音。展开持续时间与最终可见性由系统决定，不提供持续强制展开。展开概要从 compact 短词改为完整处理状态（思考／查看屏幕／点击等），另显示已完成工具步数，继续实时更新；活动 payload 不新增用户文本或工具参数。

新增覆盖后台首次更新、重复进度不重复展开、前台／待命不提醒及下一轮独立提醒。默认核心 **416 tests，0 失败**：`.build/validation/core.sLsGDP/Tests.xcresult`；无签名 iPhoneOS **BUILD SUCCEEDED**：`.build/validation/task-island-expansion-iphoneos.log`。首轮 `core.pvxcCS` 的完成时序用例沿用旧单次提醒断言，实际新增开始提醒后为两次，已更新断言并完整重跑。`git diff --check` 通过。尚未真机验证 Siri／录屏时的系统展开与概要可见效果，未提交／推送。

## 2026-10-11 · 合并实时活动密集进度更新

针对手动展开后更新即收起的反馈，只读复制已连接 iPhone 15 Pro 的后台诊断到 `.build/validation/island-collapse-device-events.log`，未安装／启动／停止设备 App。日志显示同一个 activity ID 持续更新，存在几十毫秒内 working／executing／thinking 切换和完全相同内容重复写入，未证实执行中重建；诊断不包含展开状态，无法证明每次收起由更新或屏幕触控造成。

更新层按可见 ContentState（忽略 updatedAt）去重，普通状态无变化时合并小于 15 秒的有效期延长，避免每个心跳刷新组件；到期续期仍保留，审批到期变更不延后，提醒与终态不去重。已有活动进度采用 300 毫秒合并窗口，替代后的旧进度不再写入，审批和终态不进入该合并等待。活动与会话身份、授权和执行 lease 不改变，不承诺系统保持 expanded。真实设备手动展开后是否改善仍需复测。

最终核心 **418 tests，0 失败**：`.build/validation/core.99el6N/Tests.xcresult`；无签名 iPhoneOS **BUILD SUCCEEDED**：`.build/validation/island-update-coalescing-iphoneos.log`。新增去重／续期／审批截止更新、密集状态合并与停止覆盖。首轮新增测试对不可变 snapshot 直接赋值导致编译失败（`core.c6jWUv`），改用重新构造快照后去重版本 **417 tests 全通过**（`core.0huTMU`）；加入合并窗口后短任务跳过了开始进度，旧提醒次数断言失败（`core.l7gULZ`），调整为保留完成提醒与 lease 时序约束后完整重跑通过。`git diff --check` 通过，未签名安装修正版／验证系统展开像素，未提交／推送。

## 2026-10-11 · 可选系统后台任务模式

设置 → 后台执行新增“系统后台任务”，保留音频默认值与已保存选择。每轮任务开始时读取选择，系统模式接入现有 ContinuedProcessingScheduler：申请 BGContinuedProcessingTask，使用真实短时 UIKit grant 衔接，实际持续任务到达后升级；提交接受不冒充持续任务已授予。保留到期停止、后台工具独立能力门禁、取消原请求 owner、checkpoint 与不重放。系统自带进度活动可能占用灵动岛，UI 明确说明；未尝试隐藏系统进度或强制 expanded。

系统模式不开常驻时不播放保活音频或启动 PiP；打开后台常驻仍使用音频等待新任务，空闲不反复申请系统持续任务。已有实际媒体仍可在系统任务结束后提供独立执行来源，原有多会话／媒体 fallback 逻辑保留；修正 RunExecutionScheduler 的系统组合调度以复用注入的同一媒体活动实例。无实际媒体的空闲后台 Siri 仍按原门禁请求前台继续，不把所选模式当作已获得执行资格。

默认核心 **420 tests，0 失败**：`.build/validation/core.4PVP91/Tests.xcresult`；定向设置 UI **1 test，0 失败**：`.build/validation/system-background-mode-ui.xcresult`，覆盖原生模式菜单、重启保存与恢复音频，截图导出并检查 `.build/validation/system-background-mode-ui-shots/manifest.json`。无签名 iPhoneOS **BUILD SUCCEEDED**：`.build/validation/system-background-mode-iphoneos.log`。新增系统 grant 在无媒体时支持后台、到期暂停、请求未授予禁止执行及常驻音频隔离测试。`git diff --check` 通过。尚未签名安装／真机验证系统授予与灵动岛占用效果，未提交／推送。

## 2026-10-11 · 移除活动卡片冗余执行文案

思考／处理状态 detail 改为空字符串，卡片与灵动岛展开布局沿用现有空内容隐藏规则，不再显示“任务执行中”。主状态标题、已完成步数以及审批／发送结果核对提示保留。默认核心 **420 tests，0 失败**：`.build/validation/core.DXNCAy/Tests.xcresult`；无签名 iPhoneOS **BUILD SUCCEEDED**：`.build/validation/activity-remove-running-copy-iphoneos.log`。`git diff --check` 通过，未提交／推送。

## 2026-10-11 · DeepSeek 快速工具流接收失败定位与修复

读取已配对 iPhone 15 Pro 的近期会话、供应商配置及限定时间设备日志；配置名为“DeepSeek Responses”，实际 wire 为 Chat Completions，地址 `https://api.deepseek.com`、模型 `deepseek-flash`。23:48:14 真机 LLM 诊断在 `stage=stream.receive` 报 `ModelError.protocolViolation` / `Stream consumer buffer exceeded`；事件结构为 `toolFragments=1`、`hasServerError=false`，随后包装为 providerRefused 并显示通用“模型请求失败”。这次中断发生在接收工具参数流阶段，未完成终态／未执行本批工具；后台媒体保活当时仍在运行。已确认这一条故障，不能据此把其它历史失败全部归为同一原因。

原 ResponsesTransport 的 SSE 生产任务用 bufferingOldest(32)，快速输出遇到消费调度延迟会丢弃帧并主动失败。改为 unfolding 按消费请求逐帧读取 URLSession.AsyncBytes，不再设置独立 32 帧生产队列；保留 4 MiB 流限制、256 KiB 帧限制、HTTP 检查、取消、EOF 检查及单次请求，不增加重试或提前释放工具。设备归档只用于提取 LLM 结构诊断，未读取密钥／输出任务正文；提取证据 `.build/validation/deepseek-llm.log`。

默认核心 **422 tests，0 失败**：`.build/validation/core.RGGGxg/Tests.xcresult`，新增快流慢消费保持 160 帧有序、500 多片工具参数仅在成功终态释放的回归；现有取消、HTTP 错误与 EOF／格式失败覆盖继续通过。无签名 iPhoneOS **BUILD SUCCEEDED**：`.build/validation/deepseek-stream-backpressure-iphoneos.log`。`git diff --check` 通过。尚未签名安装或真机重新执行 DeepSeek 任务，未提交／推送。

## 2026-10-12 · 后台任务结束返回会话的导航与刷新时序

用户报告自动回 App 后仅标题显示、消息为空，返回再进入恢复。源码确认 closeRun 在后台发布 activityNavigation、再请求前台，而 ContentView 原先立即修改 NavigationStack，不检查场景；ConversationStore 原先从 background 到 inactive 就发布累积消息，早于 active。修复为完成导航留待 active 后消费一次，显式首页链接取消待处理活动导航；消息展示只在 active 恢复集中发布。执行、落盘和后台资格仍走原路径。

隔离 iOS 27 模拟器修复前的已打开会话返回、后台自动导航两个用例均通过（`background-completion-before.xcresult`、`background-auto-route-before.xcresult`），没有稳定复现用户的真机空白，不能把上述时序隐患认定为已证实的唯一原因。修复后新增 background→inactive→active 的累积消息／展示适配器刷新回归，默认核心 **423 tests，0 失败**：`.build/validation/core.DIeElC/Tests.xcresult`；两条返回路径 UI **2 tests，0 失败**：`.build/validation/background-conversation-return-ui.xcresult`，覆盖消息可见、输入框和已消费导航不再次回跳。截图已导出并检查：`.build/validation/background-conversation-return-ui-shots/manifest.json`。仅 DEBUG 合成夹具填充 30 组工具和思考，在后台完成并可触发自动导航；不调用模型／真实设备。

最终无签名 iPhoneOS **BUILD SUCCEEDED**：`.build/validation/background-conversation-return-final-iphoneos.log`；`git diff --check` 通过。XcodeBuildMCP 默认 xcrun 未找到 simctl，使用显式 DEVELOPER_DIR 的已启动隔离模拟器完成验证。尚未签名安装或真机复测，未提交／推送。

## 2026-10-12 · 已复现消息滚动区后台完成后空白

用户补充输入框／发送按钮仍在，只有消息区空白。加入“在长执行过程中向上阅读两次 → 后台完成并折叠 → 直接返回”的 UI 用例，稳定复现最终回复不存在于可访问性树、ScrollView 无消息元素但标题与输入框仍在；证据 `.build/validation/background-collapsed-history-before.xcresult` / `.log`。前一轮导航门禁不足以修复这条路径。旧滚动容器在长过程切换成短完成摘要后未正确恢复懒加载内容；单纯限位、子视图／ForEach 行标识更新都未消除复现，已撤掉尝试（`background-collapsed-history-clamp`、`-layout`、`-row` 为失败诊断结果）。

最终只在运行轮次变化时用 activeTurnID 重建消息 ScrollView；完成时清掉旧 ScrollPosition、拖动标记和延期视口位移，恢复跟随最终回复。输入框位于滚动容器之外；不为流式片段反复重建，不修改消息归档／执行状态／模型请求。原空白用例在 `background-collapsed-history-container.xcresult` 首次通过。

最终默认核心 **423 tests，0 失败**：`.build/validation/core.tnqqNz/Tests.xcresult`；定向 UI **4 tests，0 失败**：`.build/validation/background-message-viewport-ui.xcresult`，覆盖阅读位置下完成后消息可见、已打开会话直接返回、后台自动导航与消费、历史工具／思考折叠顺序及最终答复保留。截图已导出并检查 `.build/validation/background-message-viewport-ui-shots/manifest.json`。无签名 iPhoneOS **BUILD SUCCEEDED**：`.build/validation/background-message-viewport-iphoneos.log`。`git diff --check` 通过。真机同场景仍待安装复测，未提交／推送。

## 2026-10-12 · 返回后延迟折叠导致消息消失

用户进一步确认返回时先有消息，几秒内自动消失。closeRun 先请求回前台，随后等待 coordinator.stop，最后 end 调用 sessions.finish；因此页面恢复时可能仍显示活动轮次，稍后才切换完成摘要。加入 DEBUG 延迟完成夹具，在回前台两秒后 finish，原先重建 ScrollView 的方案再次失败：`.build/validation/background-message-delayed-fold-before.xcresult` 显示回复先出现，随后折叠时失去可见命中点。此前仅覆盖后台已经完成的即时返回，不能覆盖该延迟变化。

最终撤掉 ScrollView 的 activeTurnID 标识重建；执行中保留 LazyVStack，已完成历史使用 VStack，避免长执行过程折叠后沿用懒加载视口几何。完成切换继续重置 ScrollPosition、拖动与延期位移并滚到最终回复；消息存储和执行清理顺序不变。此方案替代上一节的容器重建方案。通过合成场景确认这一布局路径；尚未取得用户真机现场的布局诊断，不能将 SwiftUI 内部缓存机制当作已观测事实。

默认核心 **423 tests，0 失败**：`.build/validation/core.tEEjdB/Tests.xcresult`；无签名 iPhoneOS **BUILD SUCCEEDED**：`.build/validation/background-message-stable-history-iphoneos.log`。六项 UI 批次中五项通过，延迟完成用例一次静态文本 isHittable 断言失败，但当时可访问性树的文字及坐标仍在可见区域（`background-message-stable-history-ui.xcresult`）。将该用例改为连续十秒检查文字存在、非零尺寸及导航栏和输入框之间的可见区域，并在第 1、3、10 秒截图，单独重跑通过：`.build/validation/background-message-delayed-visibility-ui.xcresult`。三张截图已逐张检查，最终回复和折叠摘要持续可见：`background-message-delayed-visibility-shots/manifest.json`。这些检查验证真实显示，不要求静态文本能点击；未声称整批六项原断言全部通过。真机同场景仍待安装复测，未提交／推送。


## 2026-10-14 · 后台设置独立页面与定位开关授权

后台执行改为独立设置子页面，音频、画中画、系统后台任务、定位及常驻各自分组，footer 说明用途、权限必要性和开启效果。移除“启用定位”“重试已选持续方式”和内部运行回执文案。新安装默认只开启音频，定位与常驻关闭；已保存选择保留。打开定位开关时尚未请求过权限则直接申请 WhenInUse，无需任务或常驻；曾拒绝时提供系统设置入口。授权不会启动无需求的定位，关闭后的迟到授权不重新启用选项或运行。

默认核心 **451 项，0 失败**（`.build/validation/core.dF6DHX/Tests.xcresult`）；配置／权限专项核心 **14 项，0 失败**；最终设置专项 UI **5 项，0 失败**（`.build/validation/background-settings/ui-final.xcresult`），另有 **1 项原生定位弹窗 UI 通过**（`ui.xcresult`）。最终无签名 iPhoneOS **BUILD SUCCEEDED**（`device-build-final.log`）。原生弹窗仅在隔离模拟器 `76236B0F-67DD-4348-AD83-8A2F4E401D43` 验证，其他定位 UI 用例使用 fake。默认、拒绝、原生弹窗截图已检查，记录见 [后台实施记录](background-execution/IMPLEMENTATION.md)。首轮两项失败与修正原因保留。

未重跑完整 UI，交接中的相册用途声明／生成器缺口及其他 UI 失败仍待处理。本次不代表真机定位或跨 App 后台持续运行验收，未操作真机、串口或其他 worktree，未提交／推送。


## 2026-10-15 · 画中画返回前台的生命周期竞争

保留画中画入口。两项可控回调测试复现旧实例尚未停止、同一显示层即创建新实例的缺陷（`pip-return/repro.xcresult`）。已串行隔离停止与重新创建，超时不当作停止证据，已终止回调不再次调用 stop，迟到回调保持对象身份并不影响新一轮；返回先恢复任务的前台状态，再撤销 PiP 后台凭据。音频所有权独立保留。

全部核心 **455 项 + 返回专项 UI 1 项通过**（`.build/validation/pip-return/final.xcresult`）；最后回调对象生命周期调整后 **5 项定向核心 + UI 1 项通过**（`callback-lifetime.xcresult`）；最终无签名 iPhoneOS **BUILD SUCCEEDED**（`device-build-callback-lifetime.log`）。截图已检查，细节见 [后台实施记录](background-execution/IMPLEMENTATION.md)。

模拟器不支持原生 PiP 窗口，控制器生命周期证据来自可控回调；未取得用户本次崩溃栈，不能据此确认真机崩溃已消失。未进行真机操作或提交／推送。
