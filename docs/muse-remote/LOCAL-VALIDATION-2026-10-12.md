# Muse × Actell 本机移植与验证 — 2026-10-12

本记录来自本机终端实际执行。实际 hostname 为 `Iris-MacBook-Pro.local`，ComputerName 为 `Iris‘ MacBook Pro`。本轮完成本地源码同步与调试准备；真实 Muse/iPhone 联动尚未验收。

## 文件与目录

- Actell worktree：`/Users/ja1chen/Developer/AI/actell-worktrees/muse-integration`，位于主仓库外。
- 分支：`feature/muse-integration`；基线及当前 HEAD：`e701786d1686823f9ab60524e689e387b7c3b904`。全部移植修改保持未提交。
- 独立 Muse 工程：`/Users/ja1chen/Developer/AI/muse-actell-bridge`。
- 原交付包：`/Users/ja1chen/Developer/AI/actell/.build/muse-delivery-v4/Muse-Actell-Avatar-Prototype-2026-10-12.zip`。
- Library：`libfile_50a773367cac819181c0cb8a19035bc2`，version **4**；file ID：`file_000000000720820c86d35ebec5e5b66e`。
- 本地实际大小：**10,188,801 bytes**；SHA-256：`1dcb4458dadacc7d538d940b17529c26c93acd71b8246c46415ea458e5ab49ea`。文件可读，Library ID/version 扩展属性也已确认。

已先读取主仓库 `AGENTS.md`、README、iOS README 与交付包 `开始阅读.md`、相关 README/验证说明。本仓库及检查到的上级目录没有 `.agents/skills`。主工作区保留原有 `.README.zh-CN.md.swp`；未切换主工作区、未 pull/merge，未改 `jev-control` 或 `chatgpt-subscription`。

最终只读核对额外发现主工作区 `ios-app/PhoneAgent.xcodeproj/project.pbxproj` 有 4 行未提交新增（各 target 的 `IPHONEOS_DEPLOYMENT_TARGET = 27.0`），文件修改时间为 2026-10-12 16:14:19 UTC。本任务没有在主工作区编辑该文件；已原样保留，未回退、移植或覆盖。原有交换文件也仍保留。

## 移植方式

交付包基线是 `7429967c47eb0f763bb14b95d68350ef2dc27f5c`。本地主线 `e701786…` 是它的后代，仅多命名和 VPN 文档更新，故选择该主线，不回退文档。先 `git apply --check`，再应用交付的 17 文件补丁；没有用旧源码快照覆盖仓库。应用后逐一字节核对 17 文件一致。此后只增加本机验证记录、更新两份云端说明的本机记录链接，并同步更新中英文主 README；15 个源码/测试/工程/脚本文件仍与交付补丁一致。

独立 Muse 工程保留原交付所有文件（含角色源文件和预览）的字节内容。新增 `delivery-v4/` 保存固定上游归档、原补丁和云端证据，`local-validation/` 保存本机证据与无 Pillow 依赖的 C 测试入口。两个 SDK 构建副本位于其 `.build/sdk-avatar` 与 `.build/sdk-headless`：前者只经官方 override 路径暂存角色，后者只应用独立 headless patch。旧 Actell `firmware-device/` 未修改。

## 本机通过

| 检查 | 实际结果 | 证据（相对对应工程根目录） |
|---|---|---|
| Xcode 27.0 / 27A266a 无签名 iPhoneOS build | `BUILD SUCCEEDED` | Actell `.build/validation/device-build-initial.log` |
| 默认完整 XCTest | **440 tests, 0 failures** | Actell `.build/validation/core.mzKiOi/Tests.xcresult` 与 `test.log` |
| 新远程用例 | 严格 JSON 4、transport/auth 11、NCM 截止时间 2，均通过；包含在 440 项内 | 同上 |
| PA3 协议、停止/释放 | C ASan/UBSan harness 通过；TCP **25 tests, 0 failures** | Actell `.build/validation/usb-device.log` |
| 新增静态检查 | **5 passed** | Actell `.build/validation/static.log` |
| 独立客户端/可选表现层 | **56 tests, 0 failures, 0 skipped**，包含 Node 顺序测试与 Python→C ABI | Muse `local-validation/python-tests.log` |
| 原始角色 C 与官方暂存单编译单元 | 分别通过 ASan/UBSan、1680 帧 × 8 尺寸、TTL/关闭/异常/strip 检查 | Muse `local-validation/avatar-host.json`、`avatar-host.log` |
| 官方角色暂存 | 上游 CMake 不变、拒绝覆盖已有皮肤 | Muse `local-validation/sdk-staging.json` |
| Headless patch | 干净 apply/check 与 reverse-check 通过 | 同上 |
| 网页 DOM stub / headless observer | 6 组 DOM stub 通过；C observer ASan/UBSan 通过 | 原 harness：Muse `delivery-v4/validation/console-dom-review.js`、`run-observer-review.py`，本机结果汇入 `local-result.json` |

无签名 App 在 `.build/DeviceBuild/Build/Products/Debug-iphoneos/PhoneAgent.app`，不含有效安装签名。编译模式为工程既有 Swift 5 模式；日志仍有 Swift 6 严格并发警告，包括导入的远程回调/参数跨 actor 警告，以及原有弃用警告。因此成功构建不表示已通过 Swift 6 模式或生产安全验收。本轮未发现必须修改的 Swift 编译错误，未调整运行时行为或降低检查。

现行 UI 完整运行结束：**40 项，32 通过、8 失败**；同轮核心测试再次 **440 项、0 失败**。证据在 `.build/validation/core.CW2tjz/Tests.xcresult` 与 `test.log`。已完成同一专用模拟器、相同 Xcode/配置、相同 8 个失败选择器的干净基线对照。基线位于仓库外的临时 worktree，HEAD 同为 `e701786…`，测试前后源码均干净。复用缓存，只生成必要的基线模拟器产物，没有重做已通过的 iPhoneOS 构建。

| 初次 UI 失败 | 集成版断言 | 干净基线/定向复测 | 结论 |
|---|---|---|---|
| 原生文件导入 | `AttachmentPickerUITests.swift:63` | 基线同一断言失败 | 基线亦存在 |
| 原生照片选择 | `AttachmentPickerUITests.swift:31` | 基线通过；集成版定向复测通过 | 首次失败未持续复现 |
| 原生选择器取消 | `AttachmentPickerUITests.swift:13` | 基线 8 项对照通过；集成版组合复测仍失败；随后每版均清理测试 App 数据的独立单项 A/B 均通过 | 仍有状态/时序敏感性，未宣称修复 |
| Safari 后台回调 | `ConversationUITests.swift:684` | 基线通过；集成版定向复测通过 | 首次失败未持续复现 |
| 系统浏览器取消 | `ConversationUITests.swift:706` | 基线通过；集成版定向复测通过 | 首次失败未持续复现 |
| 多供应商会话选择 | `ConversationUITests.swift:491` | 基线同一断言失败 | 基线亦存在 |
| VPN 地址设置 | `ConversationUITests.swift:366` | 首次基线受上一轮地址状态影响，在 356 行失败；仅清理专用模拟器测试 App 数据后，基线在同一 366 行再次失败 | 已用匹配初始状态确认基线亦存在 |
| 技能文件导入 | `SkillUITests.swift:49` | 基线同一断言失败 | 基线亦存在 |

对照证据全部保存在本 worktree `.build/validation/`：`baseline-ui`、`baseline-vpn-clean`、`integration-ui-retry`、`baseline-cancel-clean`、`integration-cancel-clean` 各有 `.log`、`.xcresult`、`-command.json`。机器可读矩阵为 `ui-comparison.json`，精确原始选择器为 `ui-failed-selectors.json`。集成版组合重试为 **4 项、3 通过、1 失败**；随后单项干净 App A/B 各 **1 项通过**。这些结果不能合并宣传为一次完整 UI 全绿，也未修复或跳过无关 UI 用例。

执行对照时仅重置本任务专用模拟器内 `com.ja1chen.PhoneAgent` 的合成测试数据；系统照片/文件夹具保留，未清理其他 App 或其他模拟器。原始完整运行与失败对照的附加诊断采集器报告无法找到 `simctl`，但测试断言、运行日志和 xcresult 均已保留；未为此更改全局 Xcode 选择。导出的失败附件为文本层级说明，不含自动失败截图，因此未作失败界面的视觉验收。

临时基线目录在保存全部结果后清理。若要重新对照，先在仓库外用 `git worktree add --detach <temporary-path> e701786d1686823f9ab60524e689e387b7c3b904` 创建干净副本，使用记录中的选择器和同一模拟器配置；将命令记录里的工作目录/缓存路径改为新副本，并为 `-resultBundlePath` 指定尚不存在的路径。

## 失败与恢复

- 首次 Library 本机下载失败；同一受支持流程在本地执行环境获准网络访问后的一次重试成功，随后验证大小、哈希与元数据。没有猜 URL 或更换执行环境。
- 默认系统 developer directory 指向 Command Line Tools；命令使用 `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`，未更改系统全局设置。
- 首次 UI 夹具准备因专用模拟器已被上一轮 XCTest 关闭而退出。显式 boot/bootstatus 后重新执行；未修改或关闭其他模拟器。
- 主机 Python 没有 Pillow，未运行原预览生成脚本。新增 `local-validation/run-avatar-host.py` 直接复用原 C harness 和固定 SDK 头文件，完成完整主机 sanitizer 回归；已批准的图片和动画未重生成。

## 复现

以下依赖本机已有 Xcode 27、Rust targets/Cargo 缓存、已复制的独立 SPM 缓存。没有安装新工具或下载新的依赖版本。

```sh
cd /Users/ja1chen/Developer/AI/actell-worktrees/muse-integration
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
NCM_CARGO_OFFLINE=1 xcodebuild \
  -project ios-app/PhoneAgent.xcodeproj -scheme PhoneAgent \
  -destination 'generic/platform=iOS' -derivedDataPath .build/DeviceBuild \
  -clonedSourcePackagesDirPath .build/SourcePackages \
  -disableAutomaticPackageResolution -skipPackageUpdates \
  CODE_SIGNING_ALLOWED=NO build
python3 tools/muse-remote/check_static.py
CC=clang bash tools/test_usb_device.sh
NCM_CARGO_OFFLINE=1 bash ios-app/scripts/test_core.sh 5945C0B1-C70A-4B2A-AE67-DA642E6F1F6E
# UI 夹具需要模拟器已经 Booted；仅在 Shutdown 状态执行下一条 boot。
xcrun simctl boot 5945C0B1-C70A-4B2A-AE67-DA642E6F1F6E
xcrun simctl bootstatus 5945C0B1-C70A-4B2A-AE67-DA642E6F1F6E -b
RUN_UI_TESTS=1 NCM_CARGO_OFFLINE=1 bash ios-app/scripts/test_core.sh 5945C0B1-C70A-4B2A-AE67-DA642E6F1F6E
```

```sh
cd /Users/ja1chen/Developer/AI/muse-actell-bridge
python3 -m unittest discover -s tests -v
CC=clang python3 local-validation/run-avatar-host.py
node delivery-v4/validation/console-dom-review.js "$PWD"
CC=clang python3 delivery-v4/validation/run-observer-review.py "$PWD"
# 只有纯 loopback mock；自然语言接口返回尚未接入。
python3 -m muse_client.web_console --port 8766
```

SDK archive SHA-256 为 `0a7548404b4aa25ad0cc3ad0f9fee1ad3a3245a03a14b02293da3a83bde69359`，固定来源 commit 为 `812c46f9fe42b69d916613a9dc702cbac5ff7b54`；归档没有 Git 历史，不能把该目录声称为已 checkout 的 Git HEAD。暂存路径为 `.build/sdk-avatar/esp32/components/muse/avatar/`，只有 `muse_pixel.c` 与 `actell_avatar.h` 两个文件。移除这两个暂存文件后会恢复上游默认皮肤选择；不要删除原扩展源文件或改旧 NCM 工程。

## 未运行与真实链路依赖

- **ESP-IDF target**：PATH、配置环境和文档所指的安装位置均未发现可用 SDK。Muse 要求 **v6.0.1**，旧 NCM 文档要求 **5.5.5**。本轮未安装工具链、未编译 ESP32 target、未烧录；host C 通过不能替代板级编译。
- **账号访问**：用户补充，Muse 邮箱验证后进入地区候补名单；尚未确认可用账号或 SDK token。未重复注册、索取或配置密钥。
- **Actell TLS**：监听仍默认关闭；未配置身份、证书、密钥或安全策略，未验收真实 HTTPS 握手和完整凭据配置 UI。
- **Home Link 与模型视觉**：未取得 Muse VM 中实际的 `~/docs/devices/home_link.md`，未实现/验收真实 transport，未确认截图进入模型视觉。保存图像不等于模型看到了图像。
- **网页视觉**：本轮只跑 Python/Node DOM stub，未做实际浏览器视觉与交互验收。
- **硬件与运行时**：Waveshare AMOLED、无屏 N16R8、物理配对/GPIO、真实 VM→板卡表现事件、iPhone 截图/点击/拖动、跨 App/锁屏/后台/断线均未运行本次实体验收。
- 未提交、推送、付费、配置真实账号或刷板。无任务完成庆祝；附加动画默认关闭，旁路失败隔离保持交付原样。
