# 执言（Actell）iOS

最低 iOS 27，默认 Bundle ID 为 `com.ja1chen.PhoneAgent`，可在生成工程时配置前缀。截图与输入工具默认经 VPN 回环调用 CoreDevice 开发者服务执行；连接只在实际工具调用时校验，普通聊天不要求连接。手机操控支持在“设置 → 手机操控 → 连接模式”选择 VPN 回环（默认，免 ESP32）或 ESP32 NCM，在“连接与验证”中操作；首页和消息页不再显示设备入口。原 ScreenCaptureKit/PA3 HID 和 TLS 实现保留，暂未提供切换开关。NCM 任务在系统后台资格有效时可继续，无需启动录屏；各会话独立运行，同一手机控制按整轮排队。服务商管理位于“设置 → 服务商”，支持添加、编辑、确认移除及恢复。会话选择服务商/模型，当前运行不允许切换配置。现有单服务商配置与 Keychain 引用自动保留；修改服务地址不会转发旧地址的密钥。已保存的 API 密钥在编辑页以正常文字色的圆点显示，仅查询存在状态，不回填真实值；不输入替换值时保留原密钥。

真实模型使用 screenshot / tap / drag / wait 设备工具，最终文字回复结束本轮。启用用户导入的技能后，系统提示词包含已启用技能的名称、描述、id 和 revision；额外提供 load_skill，只按需读取该技能包的文本。同一响应可含多个工具，按返回顺序串行执行；每个动作仍须经过原有授权、截图与故障检查，ID 不得重复或重用。模型调用数、输入数、累计 token 与固定运行时长不再作为产品预算。图像/协议大小、网络故障、系统后台资格、锁屏、手动停止、未知动作不重放仍然生效。App 不保证系统无限后台执行。

输入区支持系统照片／文件选择、预览与移除；仅显式发送时传给所选模型。截图与消息图片可保存原图并在重启后查看；历史资源不恢复设备授权。设置内可管理用户主动导入的 SKILL.md／文本技能包，导入不执行脚本。服务商支持模型发现、能力缓存和每模型参数；添加时先选择 OpenAI、OpenRouter 或自定义供应商，预设填入名称和地址、自定义留空；编辑页固定供应商类型并可选择 Chat Completions 或 Responses API。未设置默认模型时，自动选用列表中首个模型；已有默认选择保留。模型行仅以小图标展示明确支持的图片输入、工具调用、思考和文本生成能力，未知或不支持时隐藏；图标保留辅助功能说明。旧 Anthropic、Gemini、Ollama 配置仍可读取，使用当前类型需另行添加供应商。聊天输入框的模型菜单将箭头放在文案右侧，仅保留供应商、模型和浏览全部模型；最后主动选择的供应商与模型会在本机保存，新会话默认使用该选择，已有会话保留自己的选择。新建会话在首条消息发送前仅作为临时草稿，不进入列表或磁盘历史；返回列表会丢弃未发送草稿。详细范围和验收见 [本次证据](../docs/PROJECT-TODOS.md)。

服务商明确返回的可读思考内容／摘要会在消息中单独折叠展示，支持流式状态、取消／失败后保留以及历史恢复。Chat Completions 解析 reasoning_content、reasoning 和可读 reasoning_details；Responses 展示明确返回的 summary 或 reasoning_text content（包括 DeepSeek 思考流事件），并将 encrypted_content 仅用于同域回放；不生成思考正文，不解释加密块，不从普通回复抽取，也不自动把历史思考发送到新任务。

## 构建

生成工程时使用 `ACTELL_BUNDLE_ID_PREFIX` 替换完整的默认 App ID `com.ja1chen.PhoneAgent`，extension 和测试 target 使用同一基础标识派生：

```sh
export ACTELL_BUNDLE_ID_PREFIX=org.example.Actell
export ACTELL_DEVELOPMENT_TEAM=ABCDE12345
python3 ios-app/scripts/generate_xcode_project.py
```

将示例替换为自己的完整 App Bundle ID 和 Apple Developer Team ID。示例生成 `org.example.Actell` 与 `org.example.Actell.LiveActivity`，App、extension 和测试 target 的 Debug/Release 均使用该团队。未设置或为空时，分别使用 `com.ja1chen.PhoneAgent` 和空团队。两个变量在生成工程时读取，后续生成时继续提供即可。

使用已安装 Xcode 27，不更改本机签名。新增源文件后运行 `python3 ios-app/scripts/generate_xcode_project.py`（在仓库根目录）。构建缓存放 `.build/`，可使用已解析依赖的独立副本。

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild \
  -project ios-app/PhoneAgent.xcodeproj -scheme PhoneAgent \
  -destination 'generic/platform=iOS' -derivedDataPath .build/DeviceBuild \
  -clonedSourcePackagesDirPath .build/SourcePackages \
  -disableAutomaticPackageResolution -skipPackageUpdates \
  CODE_SIGNING_ALLOWED=NO build
```

## 测试

```sh
CC=clang bash tools/test_usb_device.sh
bash ios-app/scripts/test_core.sh <隔离模拟器-UDID>
RUN_UI_TESTS=1 bash ios-app/scripts/test_core.sh <隔离模拟器-UDID>
```

测试使用合成模型、临时持久化目录和回环 USB peer；无真实凭据/设备动作。UI 模式会向指定的独立模拟器添加一张合成图片及 `ProjectTodosFixtures` 文件，用于系统选择器；只运行定向 UI 用例前可先执行 `python3 ios-app/scripts/prepare_ui_fixtures.py <UDID>`。默认 target 保留所有核心协议、审批、隔离、迁移、捕获和停止释放用例。可选归档用例与恢复方式见 [归档入口](../archives/README.md)。历史日期、旧测试计数不代表本次验收，最新结果见 [本次证据](../docs/PROJECT-TODOS.md)。

## 手机操控设置子页面

两种模式共用 App 内的系统配对身份；切换释放旧连接并重新认证，运行中禁止切换。VPN 回环在建立连接阶段需要处于 Wi-Fi 环境，需由用户先启用支持本机数据包回注的外部 VPN，控制页可编辑接口与对端 IPv4 地址（默认 10.7.1.1、10.7.0.1）；接口地址支持从下拉菜单选择 10.7.1.1 或 198.18.0.1，对端地址候选为 10.7.0.1；两个菜单均提供「自定义」，点击会激活对应输入框，也可直接编辑，有修改时导航栏右上角显示「保存」；App 不管理外部 VPN，已在 iPhone 15 Pro 验证复用身份、截图和实际点击，拖动/后台仍待单独验收，见 [使用与验证](../docs/ncm-coredevice/LOCALDEVVPN.md)。

页面提供系统配对、连接/停止、截图和真实点击计数验证；文件位于 `PhoneAgent/ESP32Control`。主 App 编译复用 `../ncm-dev/PhoneAgentNCM` 的 Swift/C ABI 和 Rust 后端，构建阶段自动生成当前平台的静态库，支持 arm64 真机和 arm64 模拟器。Probe 共用同一界面。

在“设置 → 后台执行”选择音频、画中画和定位。系统后台任务入口隐藏，已保存的开启状态也按关闭处理。音频和后台常驻默认开启，定位默认关闭，已保存的选择保持不变。实现与约束见[后台执行说明](../docs/background-execution/IMPLEMENTATION.md)。

定位默认关闭。打开定位开关时，尚未授权则直接请求 WhenInUse，无需先启动任务或常驻；已经拒绝时提供系统设置入口。授权本身不启动定位，任务或常驻需要时才启动。原“启用定位”和“重试已选持续方式”按钮已移除。Siri/后台入口不首次请求或新启定位，只能使用已生效的常驻来源并取得本轮租约。坐标不保存、不上传，不申请 Always 或精确定位升级。定位可能增加耗电、显示系统指示，首次新鲜有效回执才作为运行证据；静止时没有新回调不等于失效，也不保证持续运行。

音频和 PiP 使用独立资源 token 共享媒体会话，停止一方不误停另一方。常驻仅保留已选持续方式；旧 systemTask + resident 的隐式音频行为已取消。系统任务每个明确执行段最多申请一次，系统 UI 取消与到期无法区分时保守暂停本轮；普通拒绝/短时交接到期可依赖其他已生效方式，不自动续申请或重放动作。有效任务保留认证连接；后台资格到期、受保护数据不可用或连接故障时停止。空闲连接进入后台时关闭。主 App 沙盒中的身份随更新保留，不读取或导出 Probe 的身份。切换或退出会话页面不取消执行；各会话独立保存 Agent、模型请求、审批、检查点与实时活动。同一台手机的 NCM 控制任务按整轮排队，等待任务取消不撤销当前设备所有者。截图复用已有认证会话，状态维持“已连接”，仅截图按钮显示操作进度。

固件使用 `bash tools/build_usb_device.sh ncm`；主任务 screenshot/tap/drag 已切换到新开发者后端，旧链路保留在统一路由选择入口。详见 [主工程整合](../docs/ncm-coredevice/MAIN-INTEGRATION.md)。Siri 与旧系统集成历史见 [归档文档](../archives/history/ios-app/docs/SIRI-ENTRY.md)。

## Siri 执行任务

“执行任务” App Intent 收到任务文本后直接调用现有任务启动路径，不再等待 App 内确认。启动失败在 App 中显示具体原因，并保留草稿供检查；相同命令 ID 的已提交任务不会重放。设备授权、锁屏和停止机制继续生效。

该入口采用 `LiveActivityIntent`，支持后台执行并在需要时请求前台继续，为新会话绑定默认服务商。App 曾进入前台、保护数据可用且实际媒体保活有效时，可以直接在后台提交任务；否则请求前台继续。任务成功提交后，Intent 等待已排队的实时活动请求处理完再返回，以在 Intent 执行期间申请后台实时活动。实时活动创建失败不重复执行任务，也不提供额外后台执行时间或 PiP 启动权限。当前进程内的交接队列可在前台就绪后自动启动，不要求再次确认；重启不会自动启动旧草稿。Apple App Shortcut 的调用短语不支持任意自由文本参数，因此“用执言执行任务”缺少参数时仍由 Siri 询问任务内容。需要一句话执行固定任务时，可在系统“快捷指令”中新建快捷指令，添加执言的“执行任务”操作、预填任务文本，再通过该快捷指令名称唤起 Siri。

本次只做无签名构建和隔离模拟器验证，不安装或调试连接的 iPhone。Personal Team 签名、真实定位、静止和耗电、音频中断、PiP 共用会话与 CoreDevice 后台效果均不能据模拟器测试视为通过。定位技术可用不等于符合 App Store 后台用途要求，详见[实施记录](../docs/background-execution/IMPLEMENTATION.md)。

## Provider 边界

已用自有 ProviderCore 与远程 SPM MacPaw/OpenAI 0.5.2 替换旧 Kit。SDK 源码未复制入工程。设置可选择 Chat Completions 或 Responses；原配置保持 Chat 默认。Responses 默认本地回放/store=false，明确选择服务端响应链后才使用 store=true/previous_response_id；续接仅限当前任务，每轮重发 instructions。旧截图不再上传不等于远端历史已删除。OpenRouter 保留 Chat 默认，也可显式使用无状态 Responses；其 store=true/previous_response_id 在本地拒绝。服务商类型与 wire 协议独立。其他原生协议推理、Conversations、background、compaction 和 hosted tools 尚未启用。细节与验证边界见 [Provider 模块](ProviderKit/README.md)。

## ChatGPT 订阅配置与思考强度

新增供应商预设顺序为 OpenAI、OpenRouter、ChatGPT 订阅、自定义。订阅配置固定官方地址与无状态 Responses，不接收 API Key。Continue with ChatGPT 使用系统认证浏览器与 HTTP 回环授权，校验官方 JWKS 身份后保存账号隔离的本机 Keychain 凭据。仅获套餐授权的账号模型使用独立订阅流式 Responses；退出尝试官方 discovery 撤销端点并清理本地 token。全部开发验证只用本地 mock，真实账号授权、实体设备与订阅计费尚未验证。完整官方能力与验证边界见 [订阅整合说明](../docs/CHATGPT-SUBSCRIPTION.md)。

每服务商／模型可保存思考强度；仅显示明确报告或官方文档确认的档位，未知模型使用默认、不猜档位。Responses 映射 reasoning.effort，Chat Completions 映射 reasoning_effort。GPT-6.1 Sol 的文档档位只用于官方地址的 Responses 配置，不推广到代理或未知模型。

## Muse 伴侣连接

Muse Gadget 端代码独立维护于 [muse-gadget-actell-mods](https://github.com/ja1chen/muse-gadget-actell-mods)，本仓库提供 Actell 端实现。

设置 → 扩展能力 → Muse Gadget现采用 SLAN/1：显式开启服务，点“添加 Muse”开放 120 秒窗口，在 Muse 上选择“连接 Actell”，然后在手机允许或拒绝收到的申请。允许后自动交付独立凭据，收到正式 HMAC hello 才成为已配对设备；配对成功默认开启截图、应用列表和操控权限，之后可分别关闭，已开放的 Muse 操作无需逐次确认。关闭服务会撤销未完成配对，保留已完成设备；服务记住最后一次开关选择，重启后在解锁、前台且空闲时恢复；首次安装默认关闭。普通前后台切换和远程运行结束不主动停止监听，工具执行仍受已有后台租约约束；未完成配对在进入后台时关闭。系统挂起仍可能中断通信；手动关闭后不会恢复，不重开配对窗口或重放任务。

仅在可信 Wi-Fi 首次配对：首次 TOFU 不防同 LAN 主动中间人，后续严格固定 TLS 证书 pin 和每客户端 HMAC。仅支持 Wi-Fi 上的 RFC1918 IPv4，不承诺后台常驻或离线冷启动。官方 Muse 账号与设备 Wi-Fi setup 保持独立。真机配对、TLS/Bonjour、模型截图可见性和实际触控仍待验收。见[共同协议](../docs/muse-remote/SLAN-1.md)和[本端实施与验证](../docs/muse-remote/SLAN-IMPLEMENTATION.md)。

自动 TLS 身份测试需要签名的模拟器 App。普通无签名脚本保留原行为；可显式选择本地 ad-hoc 模式，使用随机测试命名空间，不配置开发者账号或真实凭据：

```sh
SIMULATOR_ADHOC_SIGN=1 NCM_CARGO_OFFLINE=1 bash ios-app/scripts/test_core.sh <隔离模拟器-UDID>
```
