# iPhone Use · Phone Agent · Actell

English | [简体中文](README.zh-CN.md)

**An early technical prototype built through vibe coding.** Actell explores an iPhone agent that captures the screen and sends touch input through CoreDevice. VPN loopback is the default route; ESP32 USB NCM (Network Control Model) is optional. Long-running background operation and production readiness are not guaranteed.

https://github.com/user-attachments/assets/2aefc1a7-bdf1-42e7-83b9-51bd879256c8

## Capabilities

- Conversations with configurable providers and models, streaming replies, readable reasoning supplied by providers, attachments and imported text skills.
- Screenshot, tap, drag and wait tools. Tool calls run in order; uncertain inputs are never automatically replayed. Ordinary chat does not require a device connection.
- VPN and NCM share an App-owned system pairing identity and CoreDevice backend. Controlled device tests have demonstrated screenshots and actual taps; complete tasks, drag and long-running background operation need separate acceptance.
- Optional audio, picture-in-picture and location background sources. New installations enable audio and residency; location and standby Live Activities start off. Saved choices remain effective, and system execution limits still apply.
- An optional [Muse companion interface](docs/muse-remote/README.md), with per-device permissions and a separate execution runtime. A general MCP service remains future work.

## Setup

Use **Xcode 27 and iOS 27 or later**. Physical installation requires your own valid signing configuration. Configure a compatible provider and credentials for model tasks; screenshots and explicitly sent attachments are sent to that provider.

1. Enable Developer Mode and local network access. Complete the App's pairing flow in the system UI.
2. Prepare a matching Personalized Developer Disk Image, usually through Xcode. The backend checks availability; it does not download, personalize or mount images.
3. In Settings → Phone Control, select the connection route and open Connection & Validation:
   - [VPN loopback](coredevice/docs/LOCALDEVVPN.md), the default: enable an external VPN with local packet reinjection. Default interface/peer addresses are `10.7.1.1` / `10.7.0.1`; match your VPN configuration. The App does not manage the VPN. Use Wi-Fi when connecting; cellular operation and network switching have separate limitations.
   - [ESP32 NCM](devices/esp32/README.md): connect an ESP32-S3 with the current firmware through its native USB data port. Check the [hardware conditions](devices/esp32/docs/HARDWARE.md).
4. Add a provider, select a model and create a conversation. Control tools check connection and authorization when invoked; the route cannot change during execution.

VPN apps with built-in loopback can share the same connection with regular proxy traffic. Compatibility has been tested with LocalDevVPN, Shadowrocket and Clash; interface addresses and required settings vary. See the [route guide](coredevice/docs/LOCALDEVVPN.md).

## Build and test

Install Rust with the `aarch64-apple-ios` and `aarch64-apple-ios-sim` targets. The backend uses a locked dependency graph; set `COREDEVICE_CARGO_OFFLINE=1` when the cache is complete. Xcode builds the corresponding Rust library automatically. See [App build instructions](ios-app/README.md) for signing overrides and dependency setup.

```sh
python3 ios-app/scripts/generate_xcode_project.py
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild \
  -project ios-app/PhoneAgent.xcodeproj -scheme PhoneAgent \
  -destination 'generic/platform=iOS' -derivedDataPath .build/DeviceBuild \
  -clonedSourcePackagesDirPath .build/SourcePackages CODE_SIGNING_ALLOWED=NO build

# Optional ESP32 route; ESP-IDF 5.5.5 must be installed. Does not flash.
bash devices/esp32/tools/build.sh ncm

# Loopback protocol tests and isolated simulator tests
CC=clang bash devices/esp32/tools/test_usb.sh
SIMULATOR_ADHOC_SIGN=1 bash ios-app/scripts/test_core.sh <isolated-simulator-UDID>
```

Firmware outputs are in `.build/esp32-<mode>/`. App tests use synthetic providers and temporary storage; they do not replace device acceptance. Add `RUN_UI_TESTS=1` to include UI tests. Core protocol, authorization, isolation, unknown-result, migration and stop/release coverage stays in the default target.

## Repository

| Path | Purpose |
| --- | --- |
| `ios-app/` | App, tests, resources and project generation |
| `coredevice/` | App-side Swift/Rust backend |
| `devices/esp32/` | Firmware, configurations, shared platform modules and tests |
| `tools/` | Backend and cross-module build/test tools |
| `docs/` | Current behavior, constraints and diagnostics |

## Dependencies and sources

| Project | Current usage |
| --- | --- |
| [SwiftAgentKit](https://github.com/ayman3000/SwiftAgentKit) | Local source snapshot of the agent core and macros, with iOS storage compatibility patches; does not include the upstream MCP module |
| [MacPaw/OpenAI](https://github.com/MacPaw/OpenAI) | Swift Package dependency for model API integration |
| [MarkdownUI](https://github.com/gonzalezreal/swift-markdown-ui) | Swift Package dependency for Markdown message rendering |
| [idevice](https://github.com/jkcoxson/idevice) / [Device Hub](https://github.com/JaviSoto/device-hub-ios) | Reuses the patched idevice source and PNG validator pinned by Device Hub, with local adaptations; does not integrate the entire Device Hub app |
| [ManifoldKit](https://github.com/ManifoldKit/ManifoldKit) | Selected and adapted tool-call presentation components, not a package dependency on the entire framework |
| [ESP-IDF](https://github.com/espressif/esp-idf/tree/v5.5.5), [esp_tinyusb](https://github.com/espressif/esp-usb), [TinyUSB](https://github.com/hathach/tinyusb) | ESP32 firmware toolchain and USB components; pinned to ESP-IDF 5.5.5, esp_tinyusb 2.2.0, and TinyUSB 0.21.0~2 |
| [pymobiledevice3](https://github.com/doronz88/pymobiledevice3) | Protocol schema reference and selective translation; not a Python service running on the phone or ESP32 |
| [LocalDevVPN](https://github.com/jkcoxson/LocalDevVPN) | Verified external VPN loopback implementation; its Network Extension implementation is not copied into this repository |

Pinned Swift packages are recorded in [Package.resolved](ios-app/PhoneAgent.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved); Rust dependencies are in [Cargo.toml](coredevice/rust/Cargo.toml) and [Cargo.lock](coredevice/rust/Cargo.lock). Firmware components are pinned by the [manifest](devices/esp32/firmware/main/idf_component.yml) and [lockfile](devices/esp32/firmware/dependencies.lock). See [licenses and provenance](THIRD_PARTY.md), [iOS notices](ios-app/Licenses/) and [reuse boundaries](coredevice/docs/REUSE.md) for attribution and local adaptations.

[Known limits and remaining work](docs/PROJECT-TODOS.md) · [CoreDevice compatibility](coredevice/docs/COMPATIBILITY.md) · [Background execution](docs/background-execution/IMPLEMENTATION.md) · [Stop and release](docs/CONTROL-SESSION-TEARDOWN.md)

## Muse companion

Enable Muse Gadget Service, choose Add Muse, then Connect Actell on Muse and approve the incoming request. Pairing creates independent credentials; screenshot, app-list and control permissions can be changed per device. The service remembers its switch setting; unfinished pairing closes on backgrounding, while an existing listener still depends on system execution availability.

Pair on trusted Wi-Fi: first-use trust does not prevent an active LAN attacker; later connections pin the certificate and authenticate each client. Physical pairing has been observed, while complete model tasks and long-running behavior need separate acceptance. The Gadget code lives in [muse-gadget-actell-mods](https://github.com/ja1chen/muse-gadget-actell-mods).

[Pairing](docs/muse-remote/COMPANION-PAIRING.md) · [Remote tools](docs/muse-remote/REMOTE-TOOLS.md) · [Diagnostics](docs/muse-remote/DIAGNOSTICS.md) · [Validation boundaries](docs/muse-remote/VALIDATION.md)
