# 执言后台多选与定位：实施与验证记录

日期：2026-10-13。目标 checkout：`/Users/ja1chen/Developer/AI/actell`，`main`，基线 `e701786d1686823f9ab60524e689e387b7c3b904`。未切分支、未建 worktree、未提交或推送。

完整输入规格：[Actell-后台多选与定位-实施方案.md](Actell-后台多选与定位-实施方案.md)。Library `libfile_51ed5611a38081919f356543a9a32c79` v0，45,398 字节，通过当前 Library 正式 materialization 流程取得本机字节。规格为审阅过的旧快照设计，不是本次测试结果。

## 现行代码适配

- 主工程原有三项是 `audio`、`pictureInPicture`、`systemTask`，本次全部保留并增加 `location`。主工程没有 Muse 远程入口，未移植或修改另一个 worktree 中的 Muse 代码。Siri 的统一 `AgentViewModel` 入口、探针和普通任务均已检查。
- 改动前只有 Xcode 工程四处 target 级 iOS 27 设置和 `.README.zh-CN.md.swp` 未提交。保留了这些 target 设置和交换文件。生成器原本会清空已有签名团队，本次增加既有签名设置保留逻辑并恢复原值；没有更换账户或签名。
- Xcode 27.0 / 27A266a。系统默认 `xcode-select` 指向 CommandLineTools；验证使用命令级 `DEVELOPER_DIR`，没有更改系统选择。

## 实现边界

`BackgroundSettingsStore` 为共享配置入口；v2 稳定排序保存字符串集合。2026-10-14 调整为新装默认仅开启音频，定位与常驻默认关闭；已保存的选择不覆盖。旧持久域三项明确选择保留单项；仅有 resident key（true 或 false）或已有 `Application Support/PhoneAgent/conversations-v1.json` 文件的安装保持 audio。只检查存在性，不读取历史内容或 Keychain。完全无痕的旧安装无法与新装区分，按规格的新装分支处理。

显式空集重启后仍为空；已知 schema 的未知字符串保留；损坏配置不自动启权、原字节保留直到用户明确修改；未来 schema 的切换禁用，不覆盖。旧 key 保留。旧 systemTask + resident 不再隐式播放音频，界面说明此变化。

`BackgroundExecutionCoordinator` 持有每轮 demand 与独立 resident demand；新增项不加入现有轮次，取消项立即从所有旧轮次永久移除。每轮 `CompositeRunLease` 查询自己的 mask；系统执行资源只在本轮 lease 中，不能供其他运行借用。SCK 路线仍排他使用采集/USB health，没有绕过设备许可、锁屏、未知结果不重放或检查点。

普通系统申请拒绝/有限 UIKit 交接到期仅撤销系统来源；continued processing 的原生 expiration handler 可能表达用户取消，因此保守暂停整轮，包括前台且仍有媒体/定位的情况。失败或 scene 变化不自动申请新执行段。首次开始、显式继续和前台审批通过才产生申请机会；失败审批也不重提。后台等待首次来源证据最多五秒，scene 来回不重置截止时间；等待期间不允许 dispatch。

媒体来源分别记录音频播放回执和 AVKit didStart 回执。共享 `AudioSessionCoordinator` 用唯一 owner/generation token 串行 acquire/release；最后一个 owner 才 deactivate。使用 `.playback/.moviePlayback/.mixWithOthers`，待真机验证兼容性。PiP 实例按请求隔离，旧回调只收束旧实例；PiP UI stop 不停止音频；失败不每秒重试。设置中的手动重试入口已于 2026-10-14 移除，正常任务启动时的恢复逻辑保留。

2026-10-14 起，用户打开定位开关时可直接请求 WhenInUse，不要求当前任务或常驻；用途与耗电说明放在定位 section footer。授权本身不启动定位，仅有效任务或常驻需求驱动定位。曾拒绝时提供系统设置入口。原“启用定位”按钮已移除。前台主动任务仍可在需要重新授权时显示用途说明。后台/Siri 首次请求不发生；通知未发现主动请求点，现有照片保存权限接入同一无排队 gate。native 权限请求未完成时保持 gate，不在前一弹窗结束后自动排下一个。用户拒绝、全局定位关闭或授权撤销不影响其他来源。无 Always/临时精确定位请求。

定位配置为 `.other`、百米期望精度、100 米距离过滤、禁止自动暂停、显示后台指示；只有确认 plist 模式与用途文本后才能启用后台开关。首次证据要求本轮开始之后、非未来、不超过五秒、有限非负 accuracy；不存 `CLLocation` 或坐标，适配器仅传内存中的时间戳/精度。静止无回调不做超时失效，`locationUnknown` 撤贡献等待自然恢复，不 stop/start 循环。普通 UI 测试与离线探针使用无 native 定位的 fixture；专用原生权限 UI 用例显式启用 native driver，仅在本任务隔离模拟器运行。

Apple SDK 头文件已核对：`allowsBackgroundLocationUpdates` 无 plist 配置会 fatal；`pausesLocationUpdatesAutomatically` 是系统可暂停开关；PiP 的 prohibit-background-audio 中 background 指 PiP 窗口状态，不等于 UIKit App 状态。本次返回 false 以免阻断用户选中的独立音频。相关官方依据保留在完整规格第 11 节。

## 验证

专用模拟器：`ActellBackgroundSelectionValidation`，iOS 27，UDID `76236B0F-67DD-4348-AD83-8A2F4E401D43`。没有使用已有 Muse 或其他任务的模拟器。

### 2026-10-14 · 后台设置与定位开关调整

后台设置改为独立子页面，每种方式与常驻各自一个 section，用途、权限必要性和开启效果放入 footer；移除“启用定位”和“重试已选持续方式”，不再展示内部运行回执。新安装定位关闭，已保存选择保留。打开定位开关直接参与共享权限 gate 请求 WhenInUse，即便没有任务、常驻关闭；授权不会凭空建立定位需求。迟到授权不能重新勾选已关闭的选项或启动已结束的需求，权限请求不排队。

- 默认核心：`bash ios-app/scripts/test_core.sh 76236B0F-67DD-4348-AD83-8A2F4E401D43`，**451 项，0 失败**；证据 `.build/validation/core.dF6DHX/Tests.xcresult`。包含新增 3 项定位开关授权测试，覆盖无任务授权、关闭后迟到授权、后台／已拒绝／权限 gate 忙时不弹窗且不排队。
- 权限／配置专项核心：**14 项，0 失败**，`.build/validation/background-settings/ui.xcresult`。
- 设置专项 UI：**5 项，0 失败**，`.build/validation/background-settings/ui-final.xcresult`，覆盖独立页面、常驻保存、多选及空集保存、旧 system-only 常驻提示、定位拒绝帮助和主设置导航。
- 原生定位权限 UI：`testLocationToggleRequestsNativePermissionWithoutTaskOrResidency` **通过**，`.build/validation/background-settings/ui.xcresult`；仅重置上述模拟器中 App 的定位授权，确认定位默认关闭、没有任务／常驻时开关触发真实 iOS 权限弹窗、拒绝后音频保留。普通用例继续使用 fake driver。
- 最终无签名 iPhoneOS：**BUILD SUCCEEDED**，`.build/validation/background-settings/device-build-final.log`。最终模拟器和 iPhoneOS 产物的 Info.plist 均含定位用途文本及 location background mode；没有重新生成工程。
- 导出并视觉检查默认页、拒绝页和原生弹窗：`.build/validation/background-settings/final-shots/manifest.json`、`first-shots/manifest.json`。分组与 footer 可读，定位系统设置入口可见。`git diff --check` 通过。

首轮专项 UI 六项中两项失败，日志及结果包保留：多选用例因新增的“不支持 PiP 时禁用开关”限制失败，已移除此限制并在 footer 说明支持情况；拒绝用例错误地按 Button 查找 SwiftUI Link，录像确认链接实际可见，改为按标识查找控件后复验通过。首轮原生定位弹窗用例通过。Xcode 附加 diagnostics 收集仍受系统 xcrun 指向 CommandLineTools 影响，与测试结果区分；没有修改全局 xcode-select。

本次未重跑完整 UI 套件，不替代交接文档中的后台多选整体验收。相册用途说明回归、工程生成器缺口和其他 UI 失败仍需独立处理。真实后台持续定位、耗电与跨 App 控制仍未验收；未操作任何 iPhone、串口或其他 worktree，未提交或推送。

## 明确未验证

按照用户要求，本任务禁止对任何连接 iPhone 安装、启动、调试、配对、修改定位权限或发送 CoreDevice 操作。未访问串口、未干涉另一个分支正在使用的真机或 Muse 板。

Personal Team 签名/安装、真机 WhenInUse/Allow Once 系统交互、静止室内定位、步行/弱定位、低电量/耗电温度、音频中断与蓝牙路由、PiP 与音频共用会话、系统进度 UI 取消、真实 CoreDevice/VPN 后台持续效果均未验证。模拟器中的 fake receipt 证明状态机和隔离规则，不证明系统会持续给 CPU 或保持连接。

技术候选不等于符合 App Store 2.5.4 预期后台用途；本次不承诺无限保活、强制退出后唤醒、上架或免费签名能力完整可用。


## 2026-10-15 · 画中画返回前台的控制器生命周期修复

用户确认崩溃发生在开启画中画后从后台返回 App，按最新要求保留入口并尝试修复。读取当前主工程后发现：`setForeground(true)` 停止旧控制器后立即 reconcile，而旧控制器仍在等待 AVKit 停止回调；旧、新控制器可以同时使用同一个 AVSampleBufferDisplayLayer。原五秒超时还会把等待回执当作停止完成。

通过注入可控 PiP 控制器与离线音频会话复现生命周期缺陷：`.build/validation/pip-return/repro.xcresult` 的两项测试均失败，实际创建数为 2，预期旧实例停止前为 1。这证明控制器重叠，不等于在模拟器复现了用户的原生崩溃；本机仅找到 10 月 11 日无关的测试断言崩溃，尚无本次对应 .ips／调用栈。

修复：旧控制器停止／失败回调完成后才在下一次 MainActor 调度创建新控制器；五秒超时保留旧控制器和显示层隔离，不能以计时器作为安全释放证据。didStop／failedToStart 不重复向已终止实例发送 stop；返回前台恢复下一次启动机会；跨 actor 的回调保持原生对象存活，避免地址复用误匹配新实例，迟到回调不影响新一轮。停止前清除本地所有权再通知 registry 观察者，音频保持独立。App 先更新任务前后台状态，再停止 PiP 撤销其后台凭据，避免返回过程误暂停运行。

验证：

- 默认核心 **455 项，0 失败**：`.build/validation/core.zlawPL/Tests.xcresult`；随后包含场景交接调整的全部核心 **455 项 + 返回专项 UI 1 项，0 失败**：`.build/validation/pip-return/final.xcresult`。
- 最后回调对象生命周期调整后的定向核心 **5 项 + UI 1 项，0 失败**：`.build/validation/pip-return/callback-lifetime.xcresult`；其中 4 项新增 PiP 回调回归覆盖启动中／运行中返回、超时不释放、旧回调隔离、用户已关闭时不再等待第二个回调及独立音频保持。
- 最终无签名 iPhoneOS **BUILD SUCCEEDED**：`.build/validation/pip-return/device-build-callback-lifetime.log`。`git diff --check` 通过。
- 返回截图已核对：`.build/validation/pip-return/final-shots/manifest.json`。UI 用例覆盖开启 PiP 与常驻、Home、返回 App、返回设置并关闭；模拟器不支持原生 PiP 窗口，此项只证明设置及场景流程稳定。控制器实际启停竞态由可控回调测试验证。

尚未确认这处缺陷就是用户本次崩溃的唯一原因，也未进行原生 PiP 真机复测。未安装、启动或调试任何连接 iPhone，未改动其他 worktree，未提交／推送。全量 UI 和完整后台运行方案不在本次验收范围。
