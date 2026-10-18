# Muse 连接 UI 本机实现与验证 — 2026-10-13

本轮按用户“开始”的授权实现本地配置 UI。沿用仓库外 worktree `/Users/ja1chen/Developer/AI/actell-worktrees/muse-integration`，分支 `feature/muse-integration`，HEAD `e701786d1686823f9ab60524e689e387b7c3b904`，全部修改未提交。独立客户端位于 `/Users/ja1chen/Developer/AI/muse-actell-bridge`。原 Library v4 包、下载哈希、基线移植和角色验证见 [上一轮记录](LOCAL-VALIDATION-2026-10-12.md)。当前源代码包含本轮 UI 增量，不再与原包逐字一致。

## 使用入口与行为

请从本 worktree 的 `ios-app/PhoneAgent.xcodeproj` 运行 App，进入 **设置 → Muse 连接**。主工作区工程没有本轮 UI，运行主工作区不会看到新入口。

1. 填写 Muse 客户端能够到达的 iPhone IP/域名、端口和具体来源 IP，保存配置；不接受通配符或网段。
2. 导入含服务器证书及私钥的 `.p12/.pfx`，输入密码。证书须有效且匹配连接地址；TLS 启动前检查证书链和服务器用途。导入失败保留原证书。
3. 添加客户端，显式复制/分享连接信息。该信息含独立随机 32 字节密钥；页面不显示密钥，剪贴板仅本机有效且 5 分钟后过期。关闭后不可再次导出，交付失败可撤销后重建。
4. 客户端使用系统信任链，或用户独立验证的公开 CA PEM；服务器指纹仅供人工核对，不替代 TLS 链与域名验证。Python `client_from_connection_info` 接收页面 JSON，并保持原 HTTPS/HMAC/去重/未知结果不重放行为。
5. 点击启动并确认截图、应用列表披露后才监听；启动状态不持久化、不自动恢复。证书/地址更改须先停止且任务空闲。客户端可单独撤销，删除密钥先于取消运行；删除失败会停止整体连接并明确报错，保留原记录。

可在导入证书前预先添加客户端，此时连接信息指纹为空，且启动仍禁用；证书准备好后需独立核对页面指纹。更改地址/证书不会自动更新已交付 JSON，重新交付应撤销后添加。

私钥、导入密码和客户端密钥仅保存在 `WhenUnlockedThisDeviceOnly` 钥匙串项。普通配置只保存非密钥元数据。证书解析为内存导入，不额外持久化系统身份。UI 测试隔离使用内存 vault；真实 vault 有独立本地 ad-hoc 签名模拟器验证。

## 验证证据

| 检查 | 最终结果 | 本地证据 |
|---|---|---|
| 默认核心 XCTest | 447 项，1 项跳过，0 失败 | `.build/validation/muse-ui/core-and-ui-confirmed.xcresult` 与同名 `.log` |
| 新 Muse UI | 1 项通过：默认关闭、保存配置、添加、导出页、撤销 | 同上；截图目录 `screenshots-confirmed/` |
| 真实 Keychain 定向（本地 ad-hoc 模拟器签名） | 1 项通过，0 跳过 | `.build/validation/muse-ui/keychain-signed-test.xcresult` 与 `.log` |
| 无签名 iPhoneOS 构建 | BUILD SUCCEEDED | `.build/validation/muse-ui/device-final.log` |
| PA3 C sanitizer / TCP | C harness 通过，TCP 25 项通过 | `.build/validation/muse-ui/pa3-final.log` |
| 静态打包检查 | 5 项通过 | `.build/validation/muse-ui/static-final.log` |
| Python 客户端/可选层回归 | 59 项通过 | 独立 Muse 工程 `local-validation/connection-ui-python-tests.log` |

核心跳过项仅为无签名模拟器缺少 Keychain entitlement 的真实 vault roundtrip；同一 API 流程已有上述独立本地签名实测。UI 已检查默认关闭与连接信息页截图，页面没有显示合成密钥。`git diff --check` 通过。

用户随后指出本地设备连接不应要求手工配置证书，已暂停继续修改产品流程。当前页应作为开发调试准备，不代表已实现日常“发现 → 确认 → 连接”的 Muse 设备配对；后续产品实现须先核实实际 Muse 运行时的本地连接接口。

最终无签名 iPhoneOS 产物：`.build/DeviceBuild/Build/Products/Debug-iphoneos/PhoneAgent.app`。无签名产物不能直接代表真实设备安装通过。工程保持既有 Swift 5 模式；日志包含已有 Swift 6 严格并发与弃用警告，没有宣称 Swift 6 模式验收。

恢复过程：最初测试证书误把 CA 当服务器身份，服务器 TLS 校验拒绝；改为合成 CA + CA:FALSE、ServerAuth、SAN 为 `.invalid` 的服务器叶证书后通过。无签名模拟器真实钥匙串访问出现 `-34018`，且操作范围随运行变化；测试仅在此明确缺少 entitlement 时跳过，真实 API 另用本地 ad-hoc 模拟器签名验证。生产代码仍传播钥匙串失败，撤销失败停止服务。所有测试身份均为合成测试材料，仅编入测试 target，没有配置真实凭据。

上一轮完整旧 UI 的失败对照仍见历史记录，本轮只验收新增 Muse UI；不将其宣称为全部 UI 全绿。

## 可复现命令

```sh
cd /Users/ja1chen/Developer/AI/actell-worktrees/muse-integration
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
NCM_CARGO_OFFLINE=1 bash ios-app/scripts/test_core.sh 5945C0B1-C70A-4B2A-AE67-DA642E6F1F6E
python3 tools/muse-remote/check_static.py
CC=clang bash tools/test_usb_device.sh
NCM_CARGO_OFFLINE=1 xcodebuild \
  -project ios-app/PhoneAgent.xcodeproj -scheme PhoneAgent \
  -destination 'generic/platform=iOS' -derivedDataPath .build/DeviceBuild \
  -clonedSourcePackagesDirPath .build/SourcePackages \
  -disableAutomaticPackageResolution -skipPackageUpdates CODE_SIGNING_ALLOWED=NO build
# 新增 Muse UI；resultBundlePath 每次须选尚不存在的目录。
NCM_CARGO_OFFLINE=1 xcodebuild \
  -project ios-app/PhoneAgent.xcodeproj -scheme PhoneAgent \
  -destination 'platform=iOS Simulator,id=5945C0B1-C70A-4B2A-AE67-DA642E6F1F6E' \
  -derivedDataPath .build/DerivedData -clonedSourcePackagesDirPath .build/SourcePackages \
  -disableAutomaticPackageResolution -skipPackageUpdates -parallel-testing-enabled NO \
  -only-testing:PhoneAgentUITests/MuseConnectionUITests CODE_SIGNING_ALLOWED=NO test
# 真实 Keychain 定向验收使用独立模拟器产物目录；无需开发者账号。
NCM_CARGO_OFFLINE=1 xcodebuild \
  -project ios-app/PhoneAgent.xcodeproj -scheme PhoneAgent \
  -destination 'platform=iOS Simulator,id=5945C0B1-C70A-4B2A-AE67-DA642E6F1F6E' \
  -derivedDataPath .build/MuseSignedSimulator -clonedSourcePackagesDirPath .build/SourcePackages \
  -disableAutomaticPackageResolution -skipPackageUpdates -parallel-testing-enabled NO \
  -only-testing:PhoneAgentTests/RemoteConnectionStoreTests/testKeychainVaultRoundTripForUniqueTestAccount \
  CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=YES test
```

```sh
cd /Users/ja1chen/Developer/AI/muse-actell-bridge
python3 -m unittest discover -s tests -v
```

## 未运行与真实链路缺口

Muse 板卡账号和 Wi-Fi 配对仍在官方 Muse App 完成，此页为 Actell HTTPS 工具客户端授权，不实现账号登录/BLE 配对。Muse 账号地区候补、SDK token 和物理配对仍需用户操作。尚无 Muse VM 实际 `~/docs/devices/home_link.md`，没有编造运行时代理或声称模型看到了截图。

未进行真实身份导入、真实远程 TLS 监听、iPhone 安装/设备操作、Muse VM→板卡事件传输或实体屏幕验收。未安装 ESP-IDF、未构建 ESP32 target、未刷板。旧 NCM 固件与已批准九状态角色没有改动；扩展表现仍默认关闭。未改变网络安全配置、全局 Xcode 选择、开发者账号/团队；未提交、推送或调用付费服务。主工作区已有工程改动与交换文件、其他 worktree 原样保留。
