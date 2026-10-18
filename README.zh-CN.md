# iPhone Use · Phone Agent · 执言

[English](README.md) | 简体中文

**Vibe Coding 项目，技术原型初期，用于思路分享。** 执言（Actell）探索让 iPhone 上的 Agent 通过 CoreDevice 获取屏幕画面并执行触控。默认使用 VPN 回环，也可选择 ESP32 USB NCM（Network Control Model）；尚不具备生产可用性或长期后台稳定性保证。

https://github.com/user-attachments/assets/2aefc1a7-bdf1-42e7-83b9-51bd879256c8

## 核心能力

- 可配置服务商与模型的会话、流式回复、服务商提供的可读思考、附件与用户导入的文本技能。
- 截图、点击、拖动和等待工具，按顺序执行；结果未知的输入不自动重放。普通聊天不要求设备连接。
- VPN 与 NCM 共用 App 的系统配对身份和 CoreDevice 后端。受控实机已获得截图与实际点击效果；完整任务、拖动和长期后台需要单独验收。
- 可选音频、画中画和定位后台方式。新安装默认开启音频及常驻，定位与待命实时活动默认关闭；保留已保存选择，仍受系统执行限制。
- 可选 [Muse 伴侣接口](docs/muse-remote/README.md)，支持独立设备权限与执行环境。通用 MCP 服务仍是后续方向。

## 准备与运行

使用 **Xcode 27 与 iOS 27 或更高版本**。真机安装需配置自己的有效签名。模型任务需配置兼容服务商与凭据；截图和显式发送的附件会传给该服务商。

1. 开启开发者模式和本地网络权限，按 App 提示在系统界面完成配对。
2. 准备匹配的 Personalized Developer Disk Image，通常由 Xcode 完成。后端只检查可用性，不下载、个性化或挂载镜像。
3. 在“设置 → 手机操控”选择路线，进入“连接与验证”：
   - [VPN 回环](coredevice/docs/LOCALDEVVPN.md)为默认路线：先启用支持本机数据包回注的外部 VPN。默认接口/对端地址为 `10.7.1.1` / `10.7.0.1`，需匹配 VPN 配置。App 不管理 VPN；建立连接时使用 Wi-Fi，蜂窝与网络切换存在独立限制。
   - [ESP32 NCM](devices/esp32/README.md)：将使用当前固件的 ESP32-S3 通过原生 USB 数据口连接手机，先核对[硬件条件](devices/esp32/docs/HARDWARE.md)。
4. 添加服务商、选择模型并创建会话。控制工具执行时检查连接和授权，运行中不能切换路线。

支持本机回环的 VPN App 可同时处理日常代理流量。已有兼容验证覆盖 LocalDevVPN、Shadowrocket 和 Clash；接口地址与需启用的设置各不相同，见[路线说明](coredevice/docs/LOCALDEVVPN.md)。

## 构建与测试

安装 Rust 及 `aarch64-apple-ios`、`aarch64-apple-ios-sim` target。后端锁定依赖；缓存完整时可设置 `COREDEVICE_CARGO_OFFLINE=1`。Xcode 自动构建对应 Rust 库。签名覆盖与依赖准备见 [App 构建说明](ios-app/README.md)。

```sh
python3 ios-app/scripts/generate_xcode_project.py
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild \
  -project ios-app/PhoneAgent.xcodeproj -scheme PhoneAgent \
  -destination 'generic/platform=iOS' -derivedDataPath .build/DeviceBuild \
  -clonedSourcePackagesDirPath .build/SourcePackages CODE_SIGNING_ALLOWED=NO build

# 可选 ESP32 路线，需安装 ESP-IDF 5.5.5；不自动烧录
bash devices/esp32/tools/build.sh ncm

# 回环协议测试与隔离模拟器测试
CC=clang bash devices/esp32/tools/test_usb.sh
SIMULATOR_ADHOC_SIGN=1 bash ios-app/scripts/test_core.sh <隔离模拟器-UDID>
```

固件产物位于 `.build/esp32-<mode>/`。App 测试使用合成服务商和临时存储，不代替实机验收；加 `RUN_UI_TESTS=1` 可运行 UI 测试。核心协议、授权、隔离、未知结果、迁移和停止释放覆盖保留在默认 target。

## 工程结构

| 路径 | 用途 |
| --- | --- |
| `ios-app/` | App、测试、资源和工程生成 |
| `coredevice/` | App 内 Swift/Rust 后端 |
| `devices/esp32/` | 固件、配置、平台共享模块及测试 |
| `tools/` | 后端与跨模块构建、测试工具 |
| `docs/` | 现行功能、约束和诊断说明 |

## 依赖与来源

| 项目 | 当前用途 |
| --- | --- |
| [SwiftAgentKit](https://github.com/ayman3000/SwiftAgentKit) | 本地保留 Agent 核心与宏的源码快照，并适配 iOS 存储；不包含上游 MCP 模块 |
| [MacPaw/OpenAI](https://github.com/MacPaw/OpenAI) | Swift Package 依赖，用于模型 API 接入 |
| [MarkdownUI](https://github.com/gonzalezreal/swift-markdown-ui) | Swift Package 依赖，用于 Markdown 消息渲染 |
| [idevice](https://github.com/jkcoxson/idevice) / [Device Hub](https://github.com/JaviSoto/device-hub-ios) | 复用 Device Hub 固定的补丁版 idevice 源码与 PNG validator，并进行本地适配；未整合完整 Device Hub App |
| [ManifoldKit](https://github.com/ManifoldKit/ManifoldKit) | 选取并适配部分工具调用展示组件，不依赖完整框架 |
| [ESP-IDF](https://github.com/espressif/esp-idf/tree/v5.5.5)、[esp_tinyusb](https://github.com/espressif/esp-usb)、[TinyUSB](https://github.com/hathach/tinyusb) | ESP32 固件工具链与 USB 组件，分别固定为 ESP-IDF 5.5.5、esp_tinyusb 2.2.0 和 TinyUSB 0.21.0~2 |
| [pymobiledevice3](https://github.com/doronz88/pymobiledevice3) | 参考协议结构并选择性转译相关行为；手机与 ESP32 均不运行其 Python 服务 |
| [LocalDevVPN](https://github.com/jkcoxson/LocalDevVPN) | 已验证的外部 VPN 回环实现，其 Network Extension 未复制到本仓库 |

Swift 包版本见 [Package.resolved](ios-app/PhoneAgent.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved)；Rust 依赖见 [Cargo.toml](coredevice/rust/Cargo.toml) 与 [Cargo.lock](coredevice/rust/Cargo.lock)；固件组件由[清单](devices/esp32/firmware/main/idf_component.yml)和[锁文件](devices/esp32/firmware/dependencies.lock)固定。来源归属与本地适配范围见[许可与来源](THIRD_PARTY.md)、[iOS notices](ios-app/Licenses/)和[复用边界](coredevice/docs/REUSE.md)。

[待办与限制](docs/PROJECT-TODOS.md) · [CoreDevice 兼容性](coredevice/docs/COMPATIBILITY.md) · [后台执行](docs/background-execution/IMPLEMENTATION.md) · [停止与释放](docs/CONTROL-SESSION-TEARDOWN.md)

## Muse 伴侣

开启 Muse Gadget 服务，选择“添加 Muse”，再在 Muse 选择“连接 Actell”并允许手机收到的申请。配对生成独立凭据；每个设备可分别修改截图、应用列表和操控权限。服务记住开关选择，未完成配对在进入后台时关闭；已建立监听仍受系统执行条件限制。

仅在可信 Wi-Fi 首次配对：首次信任不能防御局域网主动攻击，后续固定证书并验证客户端。已有实机配对证据，完整模型任务与长期运行仍需独立验收。设备端代码在 [muse-gadget-actell-mods](https://github.com/ja1chen/muse-gadget-actell-mods) 维护。

[配对](docs/muse-remote/COMPANION-PAIRING.md) · [远程工具](docs/muse-remote/REMOTE-TOOLS.md) · [诊断](docs/muse-remote/DIAGNOSTICS.md) · [验证边界](docs/muse-remote/VALIDATION.md)
