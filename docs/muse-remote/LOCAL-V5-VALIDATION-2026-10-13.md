# Muse × Actell v5 本机应用与 Apple 验证 — 2026-10-13

在 `Iris-MacBook-Pro.local` 实际执行。目标：Actell `/Users/ja1chen/Developer/AI/actell-worktrees/muse-integration`，branch `feature/muse-integration`，HEAD `e701786d1686823f9ab60524e689e387b7c3b904`；独立 Muse `/Users/ja1chen/Developer/AI/muse-actell-bridge`，无 Git 仓库/HEAD。保留之前未提交改动，没有切换主工程、重置、提交或推送。

## 下载及应用

Library `libfile_50a773367cac819181c0cb8a19035bc2`，版本 **5**，file ID `file_000000003424820c88d933f7442b4019`；文件 `Muse-Actell-Cloud-Implementation-2026-10-13.zip`，**8,618,313 bytes**，SHA256 `802896e864f40b06ca0d87c750740ea9bac4a6f1f51da5b6f4377b7c9440ef1e`。通过当前 Library materialization helper 在本地 `/tmp/actell-muse-v5.m39QPX/` 下载、确认可读、大小与哈希一致。

读取开始阅读、manifest、配对与自动身份文档，执行 `git apply --check`；所有 37 个 Actell / 53 个 Muse before 哈希与当前一致，无并发冲突。各 patch SHA256 也一致。保存 before 字节后应用增量，立即确认全部 **90 个 after 哈希**。没有用整份源码快照覆盖目录。旧 BLE v5 草稿按 patch 重命名到非编译实验文档。嵌套 patch、上游许可证和日志原有空白警告保留，没有盲目清理。

主工程 `/Users/ja1chen/Developer/AI/actell` 的既有 project.pbxproj 和交换文件 before/after 校验未变；其他 worktree 未操作。已批准 v7 renderer `muse_pixel.c` SHA256 仍为 `d3731211b57e2e97e4606801533ba89555baa9459d5f7e5186917847172c6ec1`。

## 本地额外修复

1. **Xcode 27 链接问题**：X509 同时显式链接进 App 和 hosted unit-test target 时，Xcode 自动产品构建会尝试链接未生成二进制的 transitive Crypto framework。旧缓存和全新 `.build/V5DerivedData` 均复现同一缺产物错误；测试未开始。只在 App 链接 X509，hosted tests 从 App 的 BUNDLE_LOADER 解析符号，保持测试源码正常 import X509。重新生成工程后 App、完整测试和 device build 均通过。没有改 Swift Certificates、Crypto 或 ASN.1 上游源码/版本，没有换证书算法、信任策略或配对架构。
2. **锁定解析结果**：Package.resolved 新增 Swift Certificates **1.10.0** (`999fd70…`)、Swift Crypto **3.15.1**、Swift ASN.1 **1.7.3**。原有 package pins 没有升级。同步修正自动 TLS 文档中的 hosted-test 链接说明。
3. **真实 Keychain 测试入口**：默认脚本保持无签名行为。新增显式 `SIMULATOR_ADHOC_SIGN=1`，仅在该模拟器命令上指定 ad-hoc 签名，不选择 developer team 或更改项目签名设置。没有跳过自动身份测试；签名运行执行完整默认 target。
4. **文档**：ios-app README 的旧手工证书配对说明更新为实际 companion UI，记录可信 USB 首次材料交付、同 Wi-Fi Bonjour、独立授权和真实通信状态，不误称 BLE v5 是 Actell 授权。

上述改动与本记录另以 `extra-apple-fixes.patch`、changed/before 文件和 hash manifest 导出，基线是交付 v5 的目标字节，不是 git HEAD。它不含原来全部未提交改动，不应当作主线补丁盲目应用。

## 实际结果

| 验证 | 通过 / 失败 / 跳过 | 证据（Actell 根目录，除非标注 Muse） |
|---|---|---|
| Rust 模拟器 release 静态库 | 构建通过 | `.build/validation/muse-v5-rust-simulator.log` |
| Rust iPhoneOS release 静态库 | 构建通过 | `.build/validation/muse-v5-rust-device.log` |
| host Swift/C ABI | 31 / 0 / 0 | `.build/validation/muse-v5-ncm-swift.log` |
| Rust 标准单元测试 | 49 / 0 / 0 | `.build/validation/muse-v5-rust-tests.log` |
| Rust offline-fixtures 单元测试 | 49 / 0 / 0 | `.build/validation/muse-v5-rust-fixtures.log` |
| 完整 App core（本地 ad-hoc 签名） | **466 / 0 / 0** | `.build/validation/muse-v5-signed-core-ui.xcresult` 与 `.log` |
| 自动身份真实 Keychain / 签名校验 | 6 / 0 / 0，包含在 466 内 | 同上 `RemoteGeneratedIdentityProviderTests` |
| 新 Muse UI | **1 / 0 / 0** | 同上 `MuseConnectionUITests` |
| 显式 ad-hoc 脚本入口 core | **466 / 0 / 0** | `.build/validation/muse-v5-core-script-signed.log`；完整结果 `.build/validation/core.GvmqFt/Tests.xcresult` 与 test.log |
| PA3 ASan/UBSan C harness / TCP | C harness 通过，TCP 25 / 0 / 0 | `.build/validation/muse-v5-pa3.log` |
| 打包/安全边界静态检查 | 6 / 0 / 0 | `.build/validation/muse-v5-static-final.log` |
| 独立 Python 客户端/扩展 | 64 / 0 / 0，包括编译并执行 C guard | Muse `local-validation/v5-python-tests.log` |
| 最终无签名 iPhoneOS build | **BUILD SUCCEEDED** | `.build/validation/muse-v5-device-final.log` |

默认无签名 core 也已完整执行：**466 项，6 个失败、1 项跳过**，结果 `.build/validation/core.CF76wG/Tests.xcresult` / test.log。失败来自新自动身份测试的 Keychain `-34018` 权限缺口，原真实 vault roundtrip 有显式 entitlement skip；没有删除或整体跳过这些覆盖。随后本地签名运行全部 466 项零失败、零跳过，包括持久化/重载、匹配密钥签名、self-signature、DNS/IP SAN、不同命名空间、主机变化/缺失私钥拒绝等。

首次链接失败证据 `.build/validation/core.dUYvi2/test.log`；全新缓存复现 `.build/validation/muse-v5-fresh-build.log`。它们是构建失败，不计作已运行的测试结果。

专用模拟器：`ActellMuseIntegrationValidation`，UDID `5945C0B1-C70A-4B2A-AE67-DA642E6F1F6E`。只使用本任务模拟器，没有清理其他 App 或其他模拟器。Keychain 用随机合成测试账户/证书标签/私钥 tag，测试按自己的精确命名空间清理；没有读取、导出或配置真实账号凭据、TLS 私钥或系统配对记录。

已导出并检查默认关闭的普通 companion 页截图，位于 `.build/validation/muse-v5-ui-screenshots/`，没有上传截图到 Library。新的 UI 用例只覆盖普通入口、默认关闭、手工字段不在主路径和故障排查入口，不代表实体配对、授权和连接全链路通过。以前完整旧 UI 的失败/干净基线对照仍见历史记录；本轮未重跑无关旧 40 项，也不宣称全部 UI 全绿。

诊断采集器仍报告找不到 simctl；本机显式 DEVELOPER_DIR 的 simctl 与 XCTest 实际运行正常，断言和 xcresult 已保存。未改全局 xcode-select（仍指 CommandLineTools）。工程保持 Swift 5 模式及严格并发检查，日志仍有 Swift 6 actor/concurrency 与弃用警告；不宣称 Swift 6 模式验收。Rust 的既有 fetch_update 弃用警告也保留。

## 产物、入口与复现

无签名 iPhoneOS App：`.build/DeviceBuild/Build/Products/Debug-iphoneos/PhoneAgent.app`。它不含可直接安装的有效设备签名。请从本 worktree 的 `ios-app/PhoneAgent.xcodeproj` 运行，**设置 → Muse 连接**；主工程没有本轮更新。

```sh
cd /Users/ja1chen/Developer/AI/actell-worktrees/muse-integration
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
python3 ios-app/scripts/generate_xcode_project.py
NCM_CARGO_OFFLINE=1 bash tools/build_ncm_rust.sh simulator
NCM_CARGO_OFFLINE=1 bash tools/build_ncm_rust.sh device
NCM_CARGO_OFFLINE=1 bash tools/test_ncm_swift.sh
bash tools/with_ncm_rust.sh cargo test --locked --offline --manifest-path ncm-dev/rust/Cargo.toml
bash tools/with_ncm_rust.sh cargo test --locked --offline --manifest-path ncm-dev/rust/Cargo.toml --features offline-fixtures
# 默认无签名脚本有上述真实 Keychain 权限缺口。显式选 ad-hoc：
SIMULATOR_ADHOC_SIGN=1 NCM_CARGO_OFFLINE=1 bash ios-app/scripts/test_core.sh 5945C0B1-C70A-4B2A-AE67-DA642E6F1F6E
NCM_CARGO_OFFLINE=1 xcodebuild \
 -project ios-app/PhoneAgent.xcodeproj -scheme PhoneAgent \
 -destination 'platform=iOS Simulator,id=5945C0B1-C70A-4B2A-AE67-DA642E6F1F6E' \
 -derivedDataPath .build/DerivedData -clonedSourcePackagesDirPath .build/SourcePackages \
 -disableAutomaticPackageResolution -skipPackageUpdates -parallel-testing-enabled NO \
 -only-testing:PhoneAgentUITests/MuseConnectionUITests \
 CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=YES test
python3 tools/muse-remote/check_static.py
CC=clang bash tools/test_usb_device.sh
NCM_CARGO_OFFLINE=1 xcodebuild \
 -project ios-app/PhoneAgent.xcodeproj -scheme PhoneAgent \
 -destination 'generic/platform=iOS' -derivedDataPath .build/DeviceBuild \
 -clonedSourcePackagesDirPath .build/SourcePackages \
 -disableAutomaticPackageResolution -skipPackageUpdates CODE_SIGNING_ALLOWED=NO build
```

```sh
cd /Users/ja1chen/Developer/AI/muse-actell-bridge
python3 -m unittest discover -s tests -v
```

## 仍未验证

- 本机 ESP-IDF 不可用，没有本机 ESP32 target 重建或刷板。随包四组 S3 构建是云端记录，不计为本机验证。
- 未做真实 iPhone 安装/运行、可信 USB 引导/按键、板卡 NVS、冷启动 SNTP、TLS 握手/Bonjour/DHCP 实体互通或真实触点映射。
- 未配置 Muse 真实账号或 SDK token，未验收官方 Noise /link-control 命令在 Muse VM → gadget → LAN TLS/HMAC → iPhone 的实际调用。
- 当前 v5 gadget 桥直接通过局域网访问 iPhone，不需要此前缺失的 VM Home Link socket adapter 或 /link-tunnel；旧文档中的缺口只属历史架构。仍未验证模型实际看到 JPEG，实验图像功能默认关闭。
- 180°方向信号、真实跨 App/锁屏/后台、网络断开和实际执行仍待设备验收；主机几何围栏测试不能替代它们。
- 未开启真实凭据的远程工具 listener、未进行真实设备配对/操控、付费服务、网络/安全设置修改；无提交、push 或刷写。测试使用本地合成材料，ad-hoc 签名没有使用开发者团队账号。
