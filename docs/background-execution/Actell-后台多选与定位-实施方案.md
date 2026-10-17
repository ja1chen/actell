# 执言后台执行多选与定位机制：实施规格

状态：可交给 agent 实施的工程方案，尚未修改产品代码、运行 iOS 构建或完成真机验证。

## 0. 交付边界与先决核对

目标：保留音频、画中画、系统后台任务，增加定位；改为独立多选；新安装默认音频 + 定位。

代码依据是已有 Muse worktree 的云端快照。它不代表用户本机最新分支；快照包含未提交的 Muse 改动，不能把 HEAD 当作全部已检查内容的版本。不要根据该快照切换到 Muse 分支或替换当前分支。文中的路径以仓库根目录为基准，行号仅作定位线索，符号与实码优先。

实施 agent 开始前必须：

1. 读取当前 checkout 的 `AGENTS.md`、相关 `.agents/skills`、`README.md`、`ios-app/README.md`，必要时读取该执行环境明确允许的相关开发记忆。
2. 记录 `git branch --show-current`、`git rev-parse HEAD`、`git status --short`，阅读相关文件的现有 diff。不得 reset、clean、stash 或覆盖他人未提交改动，不从本快照整文件替换本机新版本。
3. 重新检索本文所有入口。若当前代码已拆分或加入机制，应映射到现有架构，保留所有现行选项；将差异写入实施记录。不能因快照只有三项就删除本机新增项。
4. 首先落地迁移与生命周期测试，再实现。未获授权不更换签名团队、不创建账户/证书、不安装到个人设备、不推送或发布。本文只提供交接文本，不会启动本地任务。

非目标：无限保活、绕过强制退出/锁屏限制、后台唤醒保证、以定位授权代替设备输入授权、上传定位、实现位置相关工具、改变配对 `.pairing` 系统任务、重写固件或 Muse 协议、改动当前最低 iOS 版本。

## 1. 真实代码发现

| 文件 / 符号 | 快照事实 | 必须处理的问题 |
| --- | --- | --- |
| `ios-app/PhoneAgent/Status/StatusPiPController.swift` / `BackgroundPlaybackMode` | raw 值 `audio`、`pictureInPicture`、`systemTask`；旧 key `backgroundPlaybackMode`；默认 `.audio` | 抽离多选配置；不要保留只返回一个值的 `selected` 或 `usesSystemProcessing` |
| 同文件 / `StatusPiPController.setBackgroundMode`、`updatePlaybackDemand`、`reconcileTask`、`stop` | `playingMode` 为单值；运行中冻结；常驻空闲时更新；systemTask + resident 隐式播放音频 | 删除单选互斥分支，明确多选与常驻语义；不得暗中启用未勾选音频 |
| 同文件 / `TaskAudioSession`、`SilentTaskAudioPlayback` | 音频 session 操作串行，但不是 owner/token 租约；audio 用 `.default`，PiP 用 `.moviePlayback` | 单纯串行不足以并存；一个 driver 的 stop 不能停掉整个 session |
| 同文件 / `executionOwner`、音频 `onStopped`、PiP delegate | 音频和 PiP 使用同一 owner UUID | 任一 false 会撤销另一机制；拆分来源、generation、owner |
| `ios-app/PhoneAgent/App/SettingsView.swift` | 单选 Picker + resident Toggle；footer 宣称 systemTask 常驻用音频 | 换成多选列表；展示独立状态与新语义 |
| `ios-app/PhoneAgent/App/PhoneAgentApp.swift` | AppStorage 单值；`.task`/`.onChange`、scenePhase、termination 管理；两个 debug `.audio` 强制入口 | 用共享 store/coordinator；fixture 显式仅音频，禁止意外位置弹窗 |
| `ios-app/PhoneAgent/Background/RunExecutionScheduler.swift` / `configure` | SCK context 优先且排他；普通路由按 bool 选 system+media 或 media-only；owners 按 identifier 取消原 backend | 改成选择集合并保留原路由/owner 隔离 |
| `ios-app/PhoneAgent/Background/PiPBackedRunScheduler.swift` | `PiPExecutionActivity` 只知总 active；`PiPBackedRunLease` 已尝试 system OR media；`MediaOnlyRunLease` 有 5 秒交接 | 改为按来源、订阅 mask 的 registry；聚合 source 不能把其他任务的系统 grant 借来 |
| `ios-app/PhoneAgent/Background/RunLifecycleCoordinator.swift` / `accept` | lease 失效且前台时立即 `requestSegment()` | 到期重提可能形成循环；必须改变重试边界 |
| `ios-app/PhoneAgent/Agent/AgentViewModel.swift` | 普通启动约 628 行、`beginRemoteTools` 约 1194 行均读旧单选；`commandNeedsForeground` 读全局 PiP activity；多处清理 configure | 本地、Muse、Siri 入口一致；不能漏掉后台新任务检查 |
| `ios-app/PhoneAgent/Intents/AgentIntents.swift` / `PrepareAgentTaskIntent.perform` | 记录 `PiPExecutionActivity.shared.active` | 更新新 registry 名称/语义；诊断不用误称 media |
| `ios-app/PhoneAgent/Status/StatusPiPPanel.swift` | 直接调用 PiP controller | 只操作 PiP 预览/展示，不停其他 driver |
| `ios-app/PhoneAgent/LiveActivity/AgentLiveActivityController.swift` | 独立 resident 待命活动 | 保留 UI 行为，不把活动卡片当运行 grant |
| `ios-app/PhoneAgent/Info.plist` | `UIBackgroundModes` 已有 `screen-capture`、`processing`、`audio`，没有定位用途文案 | 追加 `location` 与 WhenInUse 文案，保留现有条目 |
| `ios-app/scripts/generate_xcode_project.py` | 自动递归收集 Swift；最低 iOS 27；归档测试 opt-in | 新文件后生成工程，检查生成 diff，不手工造 entitlement |

## 2. 配置 v2 与迁移

### 2.1 唯一配置源

新增 `BackgroundMechanism: String, CaseIterable, Codable, Sendable`，raw 值保留旧三项并新增 `location`。UI 顺序固定：音频、画中画、系统后台任务、定位。不要把 enum 重命名顺带改变 raw 值。

新增 `@MainActor BackgroundSettingsStore`（可注入 UserDefaults suite）。App、Settings、各任务启动都读同一个实例；不在不同地方从 UserDefaults 各自推导默认值。

新 key 建议 `backgroundExecutionConfiguration`，存 JSON Data：

```json
{"version":2,"selected":["audio","location"]}
```

- `selected` 是字符串集合的稳定排序编码，去重；显式 `[]` 合法，代表不申请这组可选后台机制；现有 SCK 路由若另有合法执行依据按第 6 节，UI 不可一概承诺仅前台运行。不能把空集合回退成默认。
- 内部首次读取用 `Configuration?` 区分“没有已保存配置”和“已保存空集合”；nullable 不代表空选项。有效 v2 不写 `selected:null`。
- 缺失 key 才进入迁移。v2 `selected:null`、类型错误或缺字段视为损坏配置，保留原始数据，运行时采用空集合并显示需重新选择，不能自动启用定位。用户明确修改后才能覆盖已知 v2 损坏数据。
- 已知版本中的未知 raw 字符串原样保留并 round-trip，当前二进制不启动它们；UI 可显示“有此版本不支持的选项”。用户切换一个已知项不删除未知项。
- `version > 2` 不降级覆盖；本版本采取前台-only 安全运行并展示升级提示，禁止通用 Save 偷改未来 schema。需要重置时给用户明确操作。
- `backgroundResidentEnabled` 继续用独立既有 Bool key；默认 false。只有它决定是否存在空闲需求，不由“已选择选项”推断常驻。

### 2.2 初始化顺序与迁移表

必须在任何旧 `@AppStorage` binding 或 `register(defaults:)` 可能写入/掩盖默认值前运行一次迁移。检查应用持久域真实 key 是否存在，不用 `BackgroundPlaybackMode.selected` 或 `string(forKey:) ?? "audio"` 来推断用户显式选择；注册域中的默认值不算用户选择。写入完整 v2 后读回验证，失败保留旧 key 并报告，不删除旧数据。

| 已保存配置情况 | v2 选择 | 决策 |
| --- | --- | --- |
| 有效 v2，包括 `[]` | 原值 | 不再迁移 |
| 无 v2；持久域旧 raw 是三种已知值 | 该单项集合 | 保留旧用户显式选择，不擅自加定位 |
| 无 v2；旧 raw 未知/空串/类型异常 | 空集合 + 提示 | 不猜新权限，原值留存 |
| 无 v2、无旧 mode，但持久域有 resident key 或可靠已有安装标记 | `[audio]` | 旧版本可能从未写入默认 audio；保守保持旧有效默认，尤其 resident=true 不能因此突然定位 |
| 无上述背景配置痕迹且无可靠旧安装证据 | `[audio,location]`，resident=false | 当作首次配置；默认勾选不是权限或立即启动 |

安装标记应复用本机当前已有、无需读取敏感内容的可靠存在标记；不要随意扫 Keychain 或用注册默认当标记。完全无痕的旧安装与新安装无法完美区分，应在实施报告中说明采用上述确定性规则。

旧 `.systemTask + resident=true` 曾隐式使用音频。本次迁移保留 `[systemTask]`，不将这种实现副作用写成用户显式勾选 audio；UI 首次显示“系统后台任务不提供空闲常驻；如需音频待命，请勾选音频”。这是明确的行为变化，必须在更新说明中列出。

旧 key 至少保留一版用于诊断；v2 只读新 key，不双向写回单选。旧版本降级不会理解多选，不能承诺无损降级。

## 3. 产品语义与 UI

每项使用 Toggle/勾选行，稳定标识：`backgroundMechanism.audio`、`.pictureInPicture`、`.systemTask`、`.location`。保留 `backgroundResidentEnabled`。四项可全选、全不选，禁止 radio 行为。

每行至少独立显示：

- selected：用户配置。
- availability/authorization：构建是否支持；定位为 notDetermined / denied / restricted / authorizedWhenInUse / authorizedAlways；全局定位开关与 reduced accuracy 分开。
- runtime：idle / waitingForForeground / requestingPermission / starting / active / pausedBySystem / interrupted / failed / stopped。

不能把“已选择”“已授权”“调用 start 成功返回”显示为“后台执行有效”。多个机制的错误各自显示，不用一个 `message` 相互覆盖。概览示例：“已选音频、定位；音频运行中；定位待授权”。

运行中配置变更规则：新增机制对下一次任务生效；取消勾选立即停止该机制对全部需求的贡献。每轮持有开始时的 allowed set，取消项从这轮 set 永久移除，重新勾选不会悄悄扩权到旧任务；新任务可采用新集合。UI 明示“新增选项用于下一次任务，关闭立即生效”。空闲常驻直接采用当前选择，但 location 新授权仍须下述显式前台入口。

新增定位说明：使用系统定位服务尝试维持本次后台执行；位置坐标不写入历史、不上传；会有系统定位指示且增加耗电；可以拒绝，其他已选方式继续尝试；系统仍可暂停/终止。不能声称完全不接触位置数据，因为系统会实际把 CLLocation 交给 app。

### 3.1 授权入口

- 安装、App 初始化、打开设置、默认勾选不请求权限，不调用 startUpdatingLocation。
- 第一轮用户在前台主动启动任务，且该轮选择 location、授权 notDetermined、没有其他系统权限流程进行时，展示上述用途说明并进入 WhenInUse 请求。任务/其他 driver 不等待该授权结束；取消说明/拒绝均不取消任务。
- 用一个 `PermissionRequestGate` 串行协调定位与现有通知/照片/其他权限 UI，不连续自动弹多个；若启动流程还有别的权限请求，则定位显示“待授权”，留“启用定位”按钮让用户主动继续，不在前一个弹窗关闭后自动连弹。
- 显式开启 resident 时可通过“启用定位待命”前台操作进入同一流程；首次启用 resident 的普通设置 toggle 不应在没有用途说明时突然弹位置权限。
- 应用后台启动、Muse 指令、Siri 无界面入口不能首次申请位置权限或启动一个新的 WhenInUse session；使用已在前台启动且仍有效的 resident source，否则请求前台继续/仅用其他有效机制。
- 拒绝后不反复 request；显示手动去系统设置的入口。关闭全局定位或撤销权限立即移除位置 source。Allow Once 过期按实际授权处理，不持久化“已授权=true”。不请求 Always、不请求临时精确定位，不索要与功能不需要的权限。

## 4. 分层架构与伪接口

```swift
enum BackgroundMechanism: String, CaseIterable, Codable, Sendable {
    case audio, pictureInPicture, systemTask, location
}
struct BackgroundConfiguration: Equatable, Sendable {
    var selectedRawValues: Set<String> // 保留未知值
    var knownSelection: Set<BackgroundMechanism> { /* filter */ }
}
struct SourceToken: Hashable, Sendable {
    let mechanism: BackgroundMechanism
    let owner: UUID
    let generation: UUID
}
@MainActor protocol BackgroundDriver: AnyObject {
    var state: DriverState { get }
    func start(context: DriverStartContext) async
    func stop(generation: UUID)
}
@MainActor final class BackgroundExecutionRegistry {
    func publish(_ token: SourceToken, evidence: SourceEvidence)
    func revoke(_ token: SourceToken)
    func observe(allowed: Set<BackgroundMechanism>, callback: ...) -> ObservationToken
    func effectiveSources(allowed: Set<BackgroundMechanism>) -> Set<BackgroundMechanism>
}
@MainActor final class BackgroundExecutionCoordinator {
    func acquireDemand(runID: UUID, allowed: Set<BackgroundMechanism>) -> DemandToken
    func releaseDemand(_ token: DemandToken)
    func setResident(_ enabled: Bool, userInitiated: Bool)
    func applyConfiguration(_ configuration: BackgroundConfiguration)
    func setScene(_ scene: SceneState)
}
```

实现要点：

1. coordinator 是 app runtime 单例/单个 app owner，不按视图重复创建。状态修改统一 MainActor；native 回调 marshal 到 MainActor。阻塞的 AVAudioSession 操作仍放现有串行 worker；不在 MainActor 上同步等待。
2. audio、PiP、location 每个都有自己的 generation 与资源 token。systemTask 是每个 run/segment 的资源，绝不能放进“全 App active”让别的任务使用。
3. demand 为每轮 UUID 的集合，加一个可选 resident token；不要仅依靠 `hasBusySessions` bool 作为唯一 ownership。一个任务停止不应释放其他任务的 driver。
4. 每个 run 的 scheduler 订阅自身 allowed mask；registry 是 app 级来源，但订阅不得把另一任务选择的、自己未选择的 location 算作该轮 grant。
5. 停止时先使 token/generation 无效并撤销 registry，再停止原生资源；异步 late success 必须释放“那次启动”捕获的资源 token，不得执行会停掉新 generation 的全局 `stop()`。
6. 所有 callback 校验 owner+generation+resource identity；PiP 的 AVKit callback 不自带 generation，需要 controller 实例/一次请求状态映射。不能在旧停止回调未收束时给同实例假装新一轮已开启。允许构建 fresh PiP adapter/实例隔离，或串行等待旧 stop 后开始新请求。
7. `cancel`/`complete` 幂等；observer、Task、delegate token 清理可测试；使用事件级串行 reconcile 防止重入。driver 的错误只能撤销自己的 token。
8. 没有 active source 的 pending 状态不授予执行；前台任务仍可跑，后台到现有有限交接截止点则 checkpoint pause。恢复 source 不自动重放或复活已暂停 run，必须走已有手动继续与新 generation。

## 5. 三类持续 driver

### 5.1 Audio 与 PiP：共同 session，独立播放证据

保留现有音频循环和状态 PiP 能力，但抽离 session 仲裁器。`TaskAudioSession` 改为 `acquire(owner,generation) async throws -> AudioSessionToken` 与 `release(token)`，token 唯一且幂等释放。仲裁器统计 pending + ready owners，只有最后一个 owner 释放才 deactivate；所有 setCategory/activate/deactivate 顺序仍在同一个队列。

两项并选采用单一预定兼容配置：`.playback` category、`.moviePlayback` mode、`.mixWithOthers`。音频-only 可同样使用该配置以避免并发时重配；这属于待真机验证的实现决策，不声称所有路由均兼容。不要让两个 driver 分别 setCategory。若系统拒绝共同配置，各 driver 显示失败并保留其它非媒体 source；不能靠无限激活循环抢 session。

- Audio source 只有 AVAudioPlayer 确认 `isPlaying` 才 active，单有 session token 不算。
- PiP source 只有 `didStartPictureInPicture` 才 active；预览、prepare、自动启动开关、`isPictureInPicturePossible` 均不是开始回执。
- PiP 回前台关闭只撤销 PiP；audio 持续。用户关闭 PiP 后保留当次后台访问 dismissed 策略，scene 变化不能重开被用户关闭的窗口。
- 原 `pictureInPictureControllerShouldProhibitBackgroundAudioPlayback` 返回 true，必须纳入共同音频策略审计；多选时不要用它阻断主动选中的 audio。按官方 API 语义实现并真机验证，而不是只让测试 fake 通过。
- 音频中断开始撤销音频；媒体服务 reset 撤销受影响的 audio/PiP，各自保留选择。route change 不等于许可重启，先验证播放实态。
- 恢复策略：延续现有“同轮不因 scene 切换自动重播”的保守规则；提供前台显式重试，新 attempt generation。不会为了保活覆盖系统音频中断意图。PiP 失败也最多在用户明确重试/下一轮重新尝试，删掉每秒无界 start 失败重试。

### 5.2 Location：经典 CLLocationManager

新增 `LocationBackgroundDriver`，用可注入 `LocationManaging` adapter 包装 CLLocationManager，避免单测触发真实权限。

配置决策：

```swift
manager.activityType = .other
manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
manager.distanceFilter = 100
manager.pausesLocationUpdatesAutomatically = false
manager.showsBackgroundLocationIndicator = true
// 仅当目标构建 UIBackgroundModes 确认含 location 后：
manager.allowsBackgroundLocationUpdates = true
```

这里选 `pausesLocationUpdatesAutomatically=false` 是为了自签实验中降低系统主动暂停定位造成的任务中断，不是 Apple 对通用常驻的保证；它可能明显增加能耗，即使百米精度/距离过滤也不等于低耗电。不得伪装 fitness、navigation 等 activityType，不开最高精度/无距离过滤来刷回调。以后若改 true，必须处理 pause 回执撤销资格并更新测试/产品文案，不能默默改变有效状态定义。

WhenInUse 或已存在的 Always 均可满足本次前台启动条件，但从不主动升级 Always。先检查 `locationServicesEnabled`、usage string、后台模式；缺配置是 unavailable，不调用可能引起异常的 API。只在前台启动 standard updates；后台返回授权回调时若已离开前台，留 waitingForForeground，不偷启动。

证据状态：start 调用后为 starting；收到该 generation 的新鲜、有效位置更新后才可标记 active：记录 start 时刻，仅接受 `horizontalAccuracy.isFinite && horizontalAccuracy >= 0`、时间戳必须不早于本次 start，且与接收时刻的时间差绝对值不超过 5 秒的事件（这 5 秒容差不能放行启动前缓存；时间倒退则保持 starting 并用单调计时控制交接截止），不能把启动前缓存的位置当首次成功证据，系统回调中的坐标只在回调内用于必要有效性判断，不保存 CLLocation/坐标、轨迹、海拔、速度，不记录到日志、检查点、模型 prompt 或网络。可保存内存中的“已收到本轮事件”与单调时间，不序列化原始对象。由于 CLLocationManager 没有通用后台执行租约确认 API，这个 active 仅表示本轮定位服务已有运行证据，不是未来持续 CPU 的保证。

不能用“每隔 N 秒必须有坐标”作为存活判据：静止时 distanceFilter 可能长期无更新。首次 ready 前后台交接仍有有限截止，没回执就不放行。WhenInUse 模式发生自动暂停后应视为需要前台重新开始，不能假定后台自然 resume；本方案 false 降低此类主动暂停但仍处理回调。若 `didPauseLocationUpdates`、denied、restricted、全局服务关闭、严重错误、显式 stop，立即撤销 source。`locationUnknown` 作为暂不可用：保守将 source 设 starting/degraded、移除执行贡献，等待本轮系统自然更新恢复；不 stop/start busy loop，也不影响其他 sources。恢复不复活已暂停任务。

停止顺序：无效化 generation → revoke source → stopUpdatingLocation → 关闭本次 background flag/释放本次 manager delegate。选择 fresh manager/代理包装可以隔离晚到的旧 delegate 回调；不要把旧授权请求 completion 当作新任务授权命令。manager 权限状态变更可更新 UI，但能否 start 仍由最新 demand/scene 判定。

隐私文案建议（自签实验须如实）：`执言会在你启用定位后台执行时使用系统定位服务，尝试让当前任务在切换 App 后继续。坐标不会被保存或上传；定位会增加耗电并显示系统指示。你可以拒绝或随时关闭。` 加 `NSLocationWhenInUseUsageDescription`，不增加 Always usage key 来暗示需要 Always。

### 5.3 常驻语义

`desired mechanisms = union(所有有效 run demand, 显式 resident demand)`，但 systemTask 不属于空闲 driver。

- 默认 resident=false：最后一个任务完成、停止、失败或进入不再运行的 paused 状态后，释放所有 task demand；audio/PiP/location 全部停止。等待审批是否仍 busy 沿用当前生命周期，但不得绕过前台审批要求。
- resident=true：任务结束后，只保留用户当前已选且有效的持续 driver；不会自动创建新任务，不延长/重提 systemTask。
- 只选 systemTask + resident=true：显示“无可用于空闲待命的已选方式”；不偷偷开 audio/location。
- resident 从 true 改 false：只移除 resident demand；仍运行的任务继续持有自己的 source，最后结束再停。
- 单独取消 location 勾选：无论有无任务/常驻，立即停止该 source 并在必要时暂停无法继续的后台 run。
- 重新启动 app：不恢复旧任务执行；已保存 resident=true 且既有定位授权时，只有 app 实际进入前台、coordinator 完成配置恢复后可恢复所选 resident 服务。notDetermined 时保持待授权，不因重启自动弹窗。强制退出不能自动重启。

## 6. Scheduler 聚合、系统到期和安全边界

新增/重构 `CompositeRunScheduler` 与 `CompositeRunLease`，替换名不副实的 PiP/MediaOnly 组合类（可短期保留兼容 typealias，最终检索无生产旧依赖）。核心定义：

```text
backgroundReady(run) =
  run 未结束 && (
    本轮自身有效 system grant/有限 UIKit transition grant
    OR registry 中匹配本轮 allowed set 的有效 audio / PiP / location
  )
```

新的 composite/driver lease 必须显式实现 `backgroundReady`，不能沿用 `RunBackgroundLease` 协议扩展默认 true 而把 pending 当有效。

UIKit transition 必须真实获得非 invalid ID、有有效期限，单纯 request 已提交不算。明确区分 pending、transition-granted、continued-granted、expired，不把一个全局 Bool 当所有任务许可。

保留 5 秒前后台交接窗口仅用于等待已请求的 driver 回执，期间后台 `awaitExecution` 不 dispatch。截止后若无真实 source，pause；不得为每个失败 driver 或每次场景事件无限重置窗口。前台运行资格不依赖位置回执。

systemTask 与任意持续来源可组合，只有 selected 包含 systemTask 且该 run 路由允许，才创建一次 system segment 请求。每个显式执行段限一次请求；原 `RunExecutionScheduler.owners` 对旧 identifier 的取消定向保留。取消 run 只完成自己的 aggregate/system lease，不能取消其他 run 的 app driver token。

现有 `waitForApproval → endSegment → resumeApproved → requestSegment` 可以沿用同一 run generation。为避免预算矛盾，新增独立 segment-attempt token：首次任务、显式手动继续、前台用户审批通过分别产生一次预算；scene 变化/自然恢复/expiry/失败不产生新预算。后台审批回执不能无条件创建新的 system 申请，待合法前台入口后处理。预算只覆盖一次请求而非失败重试循环。

到期路径：

1. 可明确识别的普通 system 申请拒绝或 UIKit transition 到期 → 标记该 run 当前 segment-attempt 的 system exhausted；立即完成该系统资源一次，释放 pending submission/registration bookkeeping；更新 UI。
2. 仍有其他实际 source → aggregate 继续有效，不触发整个 lifecycle expiration，不停音频/PiP/定位。
3. 没有其他 source 且后台 → aggregate expiration 一次；沿现有 checkpoint pause/unknown-result/no-replay 机制收束。
4. 没有 source 但前台 → 继续普通前台任务，清理后台 lease，状态提示离开将暂停；**删除 `RunLifecycleCoordinator.accept` 在此情形无条件 requestSegment 的循环**。
5. scene 回前台/离开、driver 失败、旧 system 晚回调不重提系统任务。只有新任务、用户明确继续，或本轮在前台明确审批通过后进入新执行段才可申请一次。系统晚授予已取消的 identifier 立即 complete(false)。

**重要例外：BGContinuedProcessingTask.expirationHandler 与用户在系统进度 UI 取消共享回调。根据 Apple 官方长任务说明，不能把该回调一概当作普通 source 丢失并借音频/定位继续用户可能已取消的任务。当前实现采用保守策略：该回调暂停当前 run、停止其模型/工具执行并释放该 run 的所有 demand，不自动切源续跑、不自动 renew；其他 run 与显式 resident 的独立 demand 不受影响。App 内明确停止则进入 stopped。只有当前 SDK 提供并验证可区分的纯到期原因后，才允许将那一种原因按上述普通 source-loss OR 规则处理。测试必须分别注入 UIKit transition expiry、request rejection、continued-task ambiguous expiry/user cancel。**

### 6.1 旧 SCK 路由保持约束

`ScreenUSBExecutionContext` 存在时，继续沿现行 SCK + USB health 的排他调度路径，不因 audio/location 活跃就绕过采集/USB validity，不额外请求 systemTask。本次多选的组合执行调度适用于默认 VPN 回环/NCM/普通模型路线；SCK 设置项可保留选择但显示当前路线未使用，不能假装生效。显式 resident 可独立存在，但不得让 SCK 任务借其跳过 ScreenUSBExecutionContext 校验。

NCM/VPN 工具继续检查设备健康、锁屏/受保护数据、动作单次许可；location 只提供进程执行来源，绝不是输入授权。`commandNeedsForeground` 用新 registry 查询适合新任务配置的、已经有效的 resident 持续来源；不能借其他 run 的 system grant。保留 hasActivatedScene、commandCanStart、protectedData 检查；后台新任务最终仍须自己 acquire lease。

## 7. 文件变更清单

以下是建议新文件名；当前 checkout 若已有等效结构应复用，不复制第二套框架。

| 路径 | 变更 |
| --- | --- |
| `ios-app/PhoneAgent/Background/BackgroundConfiguration.swift`（新） | enum、v2 Codable DTO、unknown raw 保留、迁移纯函数 |
| `ios-app/PhoneAgent/Background/BackgroundSettingsStore.swift`（新） | 唯一持久化入口、初始化迁移、注入 suite、错误状态 |
| `ios-app/PhoneAgent/Background/BackgroundExecutionRegistry.swift`（新） | source token/evidence、带 mask 观察、generation 隔离 |
| `ios-app/PhoneAgent/Background/BackgroundExecutionCoordinator.swift`（新） | run/resident demand、per-driver reconcile、scene/权限 gate |
| `ios-app/PhoneAgent/Background/LocationBackgroundDriver.swift`（新） | manager adapter、授权/运行状态、无坐标持久化 |
| `ios-app/PhoneAgent/Background/AudioSessionCoordinator.swift`（新或抽离） | 共享 session token 仲裁，替换无 owner activate/deactivate |
| `ios-app/PhoneAgent/Status/StatusPiPController.swift` | 删除单选 enum/调度责任，保留 PiP UI adapter；音频实现可抽离；独立 token，关闭/中断不互伤 |
| `ios-app/PhoneAgent/Status/StatusPiPPanel.swift` | 只管理 PiP preview/display；显示新状态，不 stop 全局 |
| `ios-app/PhoneAgent/Background/PiPBackedRunScheduler.swift` | 替换为 composite 文件或改名；迁移全局 activity、per-run aggregate 与有限交接 |
| `ios-app/PhoneAgent/Background/RunExecutionScheduler.swift` | configure 接受 selection/snapshot，普通路线 composite；SCK 排他保留 |
| `ios-app/PhoneAgent/Background/ContinuedProcessingScheduler.swift` | 保留有限 transition；补 exhausted/晚授予取消/一次完成证据，避免重复请求；顺手修用户可见旧名称须小范围 |
| `ios-app/PhoneAgent/Background/RunLifecycleCoordinator.swift` | 去掉前台 expiry 自动重提；状态文案包含位置；不削弱 checkpoint/no-replay |
| `ios-app/PhoneAgent/Agent/AgentViewModel.swift` | 普通启动、Muse remote start/stop/失败清理绑定 run demand；新任务 foreground 判定；所有 configure 清理调用一致 |
| `ios-app/PhoneAgent/App/PhoneAgentApp.swift` | shared store 初始化顺序、scene、configuration/resident 同步、termination、debug fixture 单项 override |
| `ios-app/PhoneAgent/App/SettingsView.swift` | 多选、独立权限/状态、说明、手动授权/重试入口 |
| `ios-app/PhoneAgent/Intents/AgentIntents.swift` | 新 activity 查询/诊断，不直接请求位置权限 |
| `ios-app/PhoneAgent/SessionCommands/PhoneAgentRuntime.swift` 与 `ios-app/PhoneAgent/ESP32Control/PairingFlow.swift` / `runBackgroundProbeIfRequested` | makeModel 中直接构造旧 scheduler 的 debug probe、ActivityOnlyProbeScheduler 与配对后台 probe 迁移；不要漏编译测试入口 |
| `ios-app/PhoneAgentTests/SessionCommandTests.swift`、`NCMDeviceBridgeTests.swift`、`ProjectTodoTests.swift`、`ScreenUSBBackgroundTests.swift` | 全局 activity 清理隔离；NCMTestLease、RecoveryScheduler、SystemSchedulerSpy 等 conformer 随协议改变更新 |
| `ios-app/PhoneAgent/LiveActivity/AgentLiveActivityController.swift` | 通常无需结构修改；待命文案据真实有效状态调整，不声称常驻保证 |
| `ios-app/PhoneAgent/Info.plist` | 追加 location、WhenInUse 文案；保留原模式/identifier |
| `ios-app/scripts/generate_xcode_project.py` / `PhoneAgent.xcodeproj` | 通过生成器纳入新源文件；核对配置，无新位置 entitlement/账户权限 |
| `ios-app/PhoneAgentTests/RunLifecycleTests.swift` | 迁移旧单选断言、去掉隐式音频常驻预期，保留原安全覆盖 |
| `ios-app/PhoneAgentTests/BackgroundConfigurationTests.swift`（新） | 迁移/空值/未知版本/持久域测试 |
| `ios-app/PhoneAgentTests/BackgroundExecutionCoordinatorTests.swift`（新） | 16 组合、demand、generation、共享 session、聚合故障 |
| `ios-app/PhoneAgentTests/LocationBackgroundDriverTests.swift`（新） | fake manager 授权、启动/停止、旧回调、无坐标泄漏 |
| `ios-app/PhoneAgentUITests/ConversationUITests.swift` | 替换 `testSystemBackgroundModePersistsAndCanReturnToAudio`，扩展 resident UI |
| `archives/tests` 中相关 PiP tests | 按检索更新编译兼容，必要时 opt-in 跑，不删除默认安全测试 |
| `README.md`、`README.zh-CN.md`、`ios-app/README.md` | 同步多选/迁移/常驻改变/定位能耗和限制 |

检索完成标准（仓库根目录）：

```sh
rg -n 'BackgroundPlaybackMode|backgroundPlaybackMode|playingMode|preferredMode|PiPExecutionActivity|usesSystemProcessing|useSystemProcessing|TaskAudioSession' ios-app archives/tests
rg -n 'setBackgroundMode|setBackgroundResident|audioActive|executionActivity|commandNeedsForeground|backgroundResidentEnabled' ios-app/PhoneAgent ios-app/PhoneAgentTests ios-app/PhoneAgentUITests
rg -n 'AVAudioSession|startUpdatingLocation|requestWhenInUseAuthorization|requestAlwaysAuthorization|CLLocation' ios-app/PhoneAgent
```

旧名称只允许出现在迁移代码、兼容测试或清楚标记的历史文档；生产入口不能绕过统一 store/registry。权限请求点必须唯一可追踪。

## 8. 实施顺序与阶段退出条件

1. 基线对照：记录本机分支/dirty diff、SDK/工具链与现行 tests；形成映射表，确认没有新增旧选项遗漏。
2. schema/store/UI：先迁移纯测试和 16 组合编码，替换 UI 但暂不让 location 自动激活；确认空集合可持久化。
3. registry + demand：保留旧单机制行为完成迁移；多会话取消隔离测试通过后才移除旧 bool ownership。
4. 共享 AVAudioSession：先 fake 验证串行时序、token acquire/release、晚完成清理，再连接 audio/PiP 双机制；没有这一步不要开启并选播放。
5. location driver + PermissionRequestGate：fake 全状态测试；添加 Info.plist；所有 fixtures 明确权限禁用/注入。
6. composite scheduler：普通 source-loss OR 聚合、continued-task 无法辨因取消保守暂停、一次请求预算、前台 expire 无循环；SCK 原安全路径回归。
7. 所有入口：普通任务、Muse、Siri、多会话、explicit stop、scene/锁屏/termination；任务结束 stop 与 resident 保留实测。
8. UI/文档同步、完整 core/UI/无签名 device build。真机阶段用户授权后验证 Personal Team 与真实系统行为。记录 passed / failed / not run，不能把模拟器跑通当真机有效。

## 9. 测试规格

### 9.1 单元测试（默认 target 必须纳入）

- 修正现有 `testDefaultMediaModesDoNotSubmitSystemRequests`：其循环必须实际把 selection 传入 scheduler，不能仅枚举名字形成空覆盖。
- schema：16 个已知组合 round-trip；`[]` 重启不变；unknown raw 保留；v2 null/损坏 fail-closed；未来版本原样保留；旧 3 raw 各迁移；registered defaults 不伪造持久存在；仅 resident true/false 的旧安装保留 audio；迁移重入/写失败不破坏旧值。
- selection：默认 audio+location，resident false；新增下一轮生效，取消立即移除所有旧 run，重新选不让旧 run 复活；多 run mask 不互相借未选 source。
- 状态：selected 不等于 active，authorized 不等于 active，session activated 不等于 audio playing，PiP preview 不等于 active，定位 start 返回不等于 ready。
- session：audio+PiP acquire 顺序两种；一方 stop 仍不 deactivate；最后 release 一次；重复 release；stop-before-start；pending acquire 被取消后晚成功；旧 release 晚到不能影响新 token；中断后某 source 恢复不误改其他 source。
- registry：不同 mechanism/owner/generation；旧 revoke 不撤新 token；observer 删除；单 driver 失败其它保持；16 组合逐一剔除来源直到零；system grant 永远 per-run。
- location：notDetermined 不在 init/settings/背景弹；前台任务 gate 一次；已有系统弹窗则 defer 不连弹；denied/restricted/全局关闭；Allow Once 重启；reduced accuracy 可用；回调前停止；授权成功但任务已完结；授权成功时已入后台；旧 manager 回调；过期缓存/无效 accuracy/未来时间戳不能 ready；pause/error/resume；静止无更新不 busy loop；last demand stop；坐标不进入诊断/模型/存储。
- lifecycle：普通 UIKit transition expiry/可识别 source 失效 + audio 或 PiP 或 location 有效仍执行；continued-task ambiguous expiration 则暂停本 run，即使其他 source 活跃也不继续；所有 source 失效后台只 pause 一次；前台到期不自动新建 segment；旧 grant 释放；每个显式执行段请求次数上限；request 提交成功无实际 grant 不算 ready；UI transition 到期正确收束；有限交接不无限续期。
- resident：默认无空闲服务；任务结束 resident false 全停；true 只保留所选持续来源；system-only 常驻不偷开音频；关 resident 不停运行任务；停止一会话不影响另一会话。
- 安全回归：`ScreenUSBBackgroundTests`、单次动作授权、锁屏/保护数据、未知结果不重放、checkpoint 迁移、远程 perAction、stale generation 与停止释放保留。

### 9.2 UI 测试

使用隔离 UserDefaults/fixture，不在开发者真实配置中 reset。新用例建议：

- `testBackgroundDefaultSelectionDoesNotRequestLocationOnLaunchOrSettings`。
- `testBackgroundSelectionAllowsMultipleAndEmptyAndPersists`。
- `testLegacyModeMigrationPreservesExplicitChoice`。
- `testLocationDeniedLeavesAudioSelectedAndTaskUsable`。
- `testResidentSystemOnlyExplainsNoIdleSource`。
- `testLocationPermissionGateDoesNotChainSystemPrompts`。
- `testBackgroundSettingsShowSelectedAuthorizedAndRunningSeparately`。
- `testStopTaskClearsNonResidentSources`。

覆盖返回/关闭设置、重启、快速连续切换、任务运行中取消选择、进后台时授权 UI 未完成。截图包括四项多选默认态、拒绝定位降级、全不选、resident system-only 提示。不要只断言 toggle 值而忽略真实行为。

### 9.3 命令与证据

先按本机 README 核对命令，以下对应快照：

```sh
python3 ios-app/scripts/generate_xcode_project.py
bash ios-app/scripts/test_core.sh <隔离模拟器-UDID>
RUN_UI_TESTS=1 bash ios-app/scripts/test_core.sh <隔离模拟器-UDID>
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild \
  -project ios-app/PhoneAgent.xcodeproj -scheme PhoneAgent \
  -destination 'generic/platform=iOS' -derivedDataPath .build/DeviceBuild \
  -clonedSourcePackagesDirPath .build/SourcePackages \
  -disableAutomaticPackageResolution -skipPackageUpdates \
  CODE_SIGNING_ALLOWED=NO build
```

默认安全测试不能为缩短时长移出 target；如新 API 导致归档 PiP 用例编译变化，可临时 `INCLUDE_ARCHIVED_TESTS=1 python3 ios-app/scripts/generate_xcode_project.py` 做专项验证，结束再恢复默认生成。记录 `.xcresult` 与日志路径、实际编译 commit/dirty 状态。

### 9.4 真机矩阵（必须保留未验证项）

- 使用用户明确授权的设备/既有签名，核对 iOS/Xcode、设备型号、供电、低电量模式。不要为了验证自动改账户、安全设置或签名。
- Personal Team 定位-only 最小 smoke：构建含 location 模式；首次前台允许 WhenInUse；首次回执；切换 App/锁屏后观察；任务结束确认 stop 和指示消失。只有这一步通过才能说“此设备/签名实测可用”。
- 默认 audio+location：允许/拒绝/约一次定位；观察两个来源真实证据；拒绝不阻塞音频。
- audio+PiP、audio+PiP+location、四项全选：分别关闭 PiP、外部音频中断、撤销定位、UIKit transition 到期，确认只撤各自 source；continued-task 到期/用户取消则暂停对应 run；视频/蓝牙/耳机拔出路由变化。
- system-only、system+location：记录 UIKit transition 与 continued grant 区别；系统拒绝/到期不能无限重提；continued-task 无法辨因回调暂停对应 run，App 内停止真正收束。
- resident false/true、全不选、两会话并行、一轮先结束；开关 resident 不制造会话。
- 定位在静止室内、步行、弱定位环境与低电量模式下分别记录 10–15 分钟观察，并记录实际能耗/温度而不是只看 log；这只证明观测窗口，不证明无限运行。更长可靠性由明确后续实验决定。
- Muse/Siri 后台新任务：已运行 resident 定位可作为候选 source，但新 run lease、设备授权仍校验；没有现有定位 session 时回前台，不能后台首次弹权限。
- 强制退出、重启、系统撤权限、锁屏：不自动复活旧任务、不重放未知动作、不保证网络指令唤醒。

## 10. 验收清单

- [ ] 原有选项全部保留，并且 location 与 audio 是真正新装默认；空集合合法。
- [ ] 旧用户选择未被“默认”覆盖；旧 resident 不因升级新增定位；损坏/未来配置不静默启权。
- [ ] 默认勾选不请求权限、不启动位置；只有明确前台上下文触发首次授权。
- [ ] 各机制独立显示选择、授权、真实运行状态；拒绝定位不撤销音频。
- [ ] audio/PiP 共用 owner-aware session；单 driver stop 不影响其他 source。
- [ ] 任务/常驻 demand 正确释放；不暗开未勾选项；system-only 常驻限制可见。
- [ ] 普通系统来源失效与媒体/定位失效采用 OR 聚合；continued-task 无法辨因的取消/到期保守暂停本 run；前台/后台都无无限申请/重试。
- [ ] 停止、取消、late callbacks、并发任务通过 generation/owner 测试。
- [ ] 坐标不写日志、不写历史、不传模型、不上传；权限文案如实说明使用目的。
- [ ] SCK/NCM/VPN 的设备健康、锁屏、动作许可及不重放不被弱化。
- [ ] 默认 core/UI/无签名构建证据齐全；真机与 Personal Team 未测项清楚列明。
- [ ] README 中英文同步；不宣称通用后台常驻或 App Store 审核保证。

## 11. 平台依据与验证限制

1. [后台位置更新](https://developer.apple.com/documentation/corelocation/handling-location-updates-in-the-background) 与 [allowsBackgroundLocationUpdates](https://developer.apple.com/documentation/corelocation/cllocationmanager/allowsbackgroundlocationupdates)：位置后台模式与 manager 开关需配套。现代文档也介绍新 API；本方案为可细粒度控制的经典 CLLocationManager 路线。
2. [位置授权说明](https://developer.apple.com/documentation/corelocation/requesting-authorization-to-use-location-services) 与 [requestWhenInUseAuthorization](https://developer.apple.com/documentation/corelocation/cllocationmanager/requestwheninuseauthorization())：WhenInUse 应前台申请，前台已启动且启用后台位置的服务可继续进入后台；不是终止后的重启保证。
3. [pausesLocationUpdatesAutomatically](https://developer.apple.com/documentation/corelocation/cllocationmanager/pauseslocationupdatesautomatically)：暂停策略影响运行与能耗。本文 false 为实验取舍；此次网页抽取仅取得 JavaScript 占位，实施时应在 Xcode 官方 API 文档再次核对当前 SDK 行为。
4. [Apple DTS：iOS Background Execution Limits](https://developer.apple.com/forums/thread/685525)：iOS 无通用无限后台机制，强制退出表达停止意图，不能承诺定时或任意网络唤醒。
5. [Apple 开发者账户与 Personal Team](https://developer.apple.com/help/account/basics/about-your-developer-account)：免费账户可通过 Xcode 在个人设备测试，Personal Team 有重签/配置到期等限制。经典 Core Location 路线不需要本方案新增专属付费 entitlement，故可作为免费签名实验候选；这不等于本工程所有现有 capabilities 都支持 Personal Team，更不等于此方案已在免费团队真机验证。
6. [长任务与系统取消](https://developer.apple.com/documentation/BackgroundTasks/performing-long-running-tasks-on-ios-and-ipados)：系统 UI 的取消会进入 expiration handler；当前旧包装未提供独立原因。必须保守暂停本轮，不能借别的来源忽略用户取消。
7. [App Review Guidelines 2.5.4](https://developer.apple.com/app-store/review/guidelines/#software-requirements)：后台服务须用于其预期目的。仅用静音播放或不消费位置的定位来维持通用 agent，不能据自签实验推断可上架；若以后商店发布，需先单独审查正当使用场景与实现。

本次只做源码阅读和方案设计。当前本机最新代码、iOS 构建、模拟器、音频与 PiP 共同 session、Personal Team 签名、真实后台运行/耗电均未验证。不能在实现报告中把本文列出的预期写成已通过。

## 12. 可直接交给实施 agent 的提示词

> 请在我指定并授权的本地 Actell/执言仓库中实施本文件。先读 AGENTS.md、现行 README 和相关技能，报告当前 branch、HEAD、dirty changes，核对本方案基于的旧快照与当前代码差异；不要覆盖其他修改，不改签名/账户或自动推送。将“后台执行模式”单选改为多选，保留所有现行选项，新增 location，新装默认 audio+location、resident=false；旧用户按迁移表保留选择，空集合与未知值不能丢失。按本文先做配置与生命周期测试，再实现 source registry、run/resident demand、共享 AVAudioSession token、经典 CLLocationManager driver、前台授权 gate 与每轮 composite scheduler。必须做到拒绝定位不影响其他机制、stop 不互伤、晚回调不复活、普通 system source 到期不误全停、continued-task 无法区分用户取消时保守暂停该 run 且不无限重试、不保存或上传坐标、不弱化设备工具许可与 checkpoint/no-replay。补齐普通任务/Muse/Siri/debug fixture/归档引用，更新中英文文档。运行当前工程要求的 core/UI/无签名真机构建；需要设备安装或权限操作时按现有授权范围办理，缺授权先报告。交付文件变更、关键决策、测试证据、失败和未测项，尤其如实标注 Personal Team 与真实后台运行是否验证。本文是规格，接口名可与当前架构合理对齐，但不能省略上述不变量。
