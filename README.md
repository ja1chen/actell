# iPhone Use · Phone Agent · Actell

English | [简体中文](README.zh-CN.md)

**A vibe-coded project in its early technical prototype stage, shared to explore ideas.** Actell (执言) explores how an agent running on an iPhone can call CoreDevice services to capture the screen and perform taps and drags. The current default uses an external VPN loopback route without an ESP32; ESP32-S3 USB NCM forwarding is also available. Production readiness and reliable long-running background execution are not guaranteed.

https://github.com/user-attachments/assets/2aefc1a7-bdf1-42e7-83b9-51bd879256c8

The app uses [SwiftAgentKit](https://github.com/ayman3000/SwiftAgentKit), [MacPaw/OpenAI](https://github.com/MacPaw/OpenAI), and [MarkdownUI](https://github.com/gonzalezreal/swift-markdown-ui). Its developer-services backend reuses the patched version of [idevice](https://github.com/jkcoxson/idevice) used by [Device Hub](https://github.com/JaviSoto/device-hub-ios), with protocol references from [pymobiledevice3](https://github.com/doronz88/pymobiledevice3). The reuse boundaries are described below.

## From ESP32 peripherals to CoreDevice

The initial idea was to emulate peripherals such as keyboards and mice with an ESP32, control the iPhone through its standard peripheral support, and eventually expose a standard MCP interface for other agents. Exploration revealed limitations: inefficient Chinese text entry through keyboard/mouse input, demanding hardware requirements for USB-C DP Alt Mode capture, and app-based screen recording occupying the recording channel. The current approach therefore uses CoreDevice services for screen capture and touch input.

The ESP32-S3 currently provides USB NCM networking, discovery, and restricted bidirectional data forwarding. The app handles pairing identities, authentication, and control protocols; iPhone system services provide the screen content and execute touch input. CoreDevice access also allows exploration of a local connection through Network Extension, so an ESP32 is not required for that route. The app now supports VPN loopback, verified with LocalDevVPN, sharing the same pairing identity and CoreDevice backend. This repository does not implement or manage its own Network Extension. A standard MCP interface remains planned and is not implemented.

## Current capabilities and limits

- Supports OpenAI Chat Completions-compatible providers and an explicitly selectable native Responses path, using the `screenshot`, `tap`, `drag`, and `wait` tools to execute tasks. Settings → Suppliers starts with OpenAI and OpenRouter presets, followed by a custom supplier with blank fields. The supplier type is fixed in the editor; API format is selectable. Legacy Anthropic, Gemini and Ollama configurations remain readable, but a replacement must be added to use a current supplier.
- Imports Markdown/TXT skill packages and reads their text on demand; importing does not execute scripts. Supports conversation history, image attachments, tool approval, and manual stopping. Control tasks for the same phone are queued by whole agent turn, and actions with uncertain outcomes are not automatically replayed.
- Control sessions continuously receive a display stream, decode it with VideoToolbox, and cache the latest complete frame. The screenshot tool takes an image from that stream, removes padding, and encodes it as JPEG; it does not call the system's separate screenshot service for each request by default. Each call still waits for a newly decoded frame or a sender progress report received after the request begins to confirm that the cached image is complete. The wait can take up to eight seconds; this does not mean immediately returning any old cached frame. The standalone PNG screenshot implementation remains available in the source, but is not an automatic fallback.
- The ESP32 route has recorded real screenshots and increases in a test button's tap counter. In an iPhone 15 Pro test on 2026-10-09, the VPN loopback route reused the pairing identity, produced a 1179 × 2556 screenshot, increased the actual tap counter from 0 to 1, and confirmed media release. Complete model-driven tasks, dragging, and sustained background execution over VPN loopback still require separate acceptance testing.
- Background execution supports independent audio, picture-in-picture, system-task, and location selections, including selecting none. New installations default to audio with location and idle residency off; existing explicit choices migrate unchanged. Background options are grouped on a dedicated Settings → Background execution page. Turning on location requests When In Use permission if it has not yet been requested; a previous denial is handled through system Settings. Permission alone does not start location updates: a task or idle residency must need them. Location coordinates are not saved or uploaded; the system indicator and increased battery use still apply. Location permission status is shown separately from the selection. System suspension, termination, screen locking, or connection failures can still stop tasks. The older ScreenCaptureKit/PA3 USB HID and TLS implementations remain in the repository; there is currently no switch to select the older route.

Enabling idle residency retains only selected continuous sources; system-task-only residency no longer implicitly plays audio. Removing an option stops its contribution immediately and vetoes it for current runs; added options apply to the next run. A system continued-task cancellation/expiration pauses that run even if another source is available. This is an experimental execution mechanism, not a promise of indefinite background operation or App Store eligibility. Physical-device location, Personal Team signing, stationary behavior, audio interruptions, and CoreDevice background reliability have not been verified for this change. See the [implementation and validation record](docs/background-execution/IMPLEMENTATION.md).

These statements reflect the current source and validation records in the project. Results from different routes, devices, and historical stages are not interchangeable. See [project tasks and validation](docs/PROJECT-TODOS.md), [video geometry and frame completeness](docs/ncm-coredevice/VIDEO-GEOMETRY.md), and [VPN loopback setup and validation](docs/ncm-coredevice/LOCALDEVVPN.md).

Idle residency includes a separate **Show Live Activity while waiting** switch, enabled by default. It reserves a minimal star activity so tasks received in the background can update the Dynamic Island. Turning it off removes the idle activity without disabling task activities. System task subtitles describe current or recent work instead of counting responses or tool calls.

## Setup and running

The current minimum deployment target is **iOS 27**, and builds use **Xcode 27**. Configure your own valid signing for a physical device; the unsigned build below only produces artifacts and cannot be installed directly. Model-driven tasks require your own compatible provider, model, and credentials. Screenshots and explicitly sent attachments are transmitted to the selected model.

Prerequisites for device control:

1. Enable Developer Mode on the iPhone and allow local network access for the app. Follow the app's pairing flow and complete trust/PIN pairing in the system UI. Both routes share the RemotePairing identity stored in the app sandbox.
2. Prepare a matching Personalized Developer Disk Image (DDI), usually through Xcode. The current backend only checks Developer Mode and image availability; it does not download, personalize, or mount the image. This repository does not include Apple developer images, and initial setup cannot be guaranteed to work entirely without a Mac.
3. Choose a route under Settings → Phone Control → Connection Mode, then open Connection & Validation to connect, capture a screenshot, and verify an actual tap:
   - **VPN loopback (default, no ESP32 required):** Enable a VPN on the same iPhone that supports reinjecting local packets; this has been verified with [LocalDevVPN](https://github.com/jkcoxson/LocalDevVPN). Edit the interface and peer addresses on the control screen. Their defaults are `10.7.1.1` and `10.7.0.1`, respectively, and must match the external VPN configuration. The app does not install, start, or stop the VPN. See the [route documentation](docs/ncm-coredevice/LOCALDEVVPN.md).
   - **ESP32 NCM:** Use an ESP32-S3 with native USB Device support and a data cable. Install the current NCM firmware and connect its native USB port to the iPhone. Verify USB roles, board wiring, and power against the actual hardware. See the [firmware documentation](firmware-device/README.md) and [hardware notes](docs/hardware/ESP32-S3-USB.md).
4. Add a provider in Settings and create a conversation. Regular chat does not require a device connection; control tools still check identity, connection, and authorization when executing. The control route cannot be switched during execution.

### Using loopback with your regular VPN

If LocalDevVPN replaces your regular VPN connection, you can instead use a proxy/VPN app with built-in local loopback support. This feature may need to be enabled manually, allowing the same VPN connection to handle both regular proxy traffic and local loopback without a separate LocalDevVPN connection. Shadowrocket and Clash have both been tested with this app.

The interface address may differ between VPN apps. This app includes presets for some known interface addresses that you can try.

**Cellular limitation:** In [LocalDevVPN issue #31](https://github.com/jkcoxson/LocalDevVPN/issues/31), project collaborator **CelloSerenity** replied on **2026-09-10** that LocalDevVPN does not work over cellular, calling it “an Apple-enforced issue that we can't get around,” and closed the issue as **not planned**. Establish the control connection while connected to Wi-Fi. Compatibility with other VPN apps does not establish that the cellular limitation is bypassed or that switching to cellular after connecting will keep the session working.

### Build

Run all commands below from the repository root. The scripts reuse a local toolchain and are not ready-to-use installers:

- Install Rust with the `aarch64-apple-ios` and `aarch64-apple-ios-sim` targets (`rustup target add aarch64-apple-ios aarch64-apple-ios-sim`). The script discovers Rust through PATH or the standard Cargo installation; `NCM_RUST_TOOLCHAIN` optionally selects an installed toolchain. It does not depend on a sibling project. Backend builds use `--locked` and the standard Cargo cache (or `CARGO_HOME` / `NCM_CARGO_HOME`); the first build can download dependencies. Set `NCM_CARGO_OFFLINE=1` for cached offline builds. The package uses edition 2024; versions are in [Cargo.lock](ncm-dev/rust/Cargo.lock).
- Firmware uses ESP-IDF 5.5.5. Set `IDF_PATH` and `IDF_TOOLS_PATH` to an installed environment as needed. Component versions are pinned by the [manifest](firmware-device/main/idf_component.yml) and lockfile.
- The Xcode project is checked in. After adding source files, regenerate it with `python3 ios-app/scripts/generate_xcode_project.py`. Allow Swift Package Manager to resolve dependencies on the first build. An Xcode build phase generates the Rust static library for the current platform.

To customize the Bundle ID and signing team when generating the project:

```sh
export ACTELL_BUNDLE_ID_PREFIX=org.example.Actell
export ACTELL_DEVELOPMENT_TEAM=ABCDE12345
python3 ios-app/scripts/generate_xcode_project.py
```

Replace these examples with your full App Bundle ID and Apple Developer Team ID.
The example produces `org.example.Actell` and `org.example.Actell.LiveActivity`;
test targets and both build configurations use the same base ID and team.
Unset or empty values default to `com.ja1chen.PhoneAgent` and an empty team.
Keep both variables exported for subsequent project generations.

```sh
# Unsigned iPhoneOS build; does not install or change signing
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild \
  -project ios-app/PhoneAgent.xcodeproj -scheme PhoneAgent \
  -destination 'generic/platform=iOS' -derivedDataPath .build/DeviceBuild \
  -clonedSourcePackagesDirPath .build/SourcePackages \
  CODE_SIGNING_ALLOWED=NO build

# ESP32 route: build NCM firmware only; does not flash automatically
bash tools/build_usb_device.sh ncm
```

To install on a physical device, select signing and the device in Xcode, then run. See the [iOS documentation](ios-app/README.md) for additional app configuration and build commands using cached dependencies. Firmware artifacts are under `.build/device-ncm/`; verify the serial port and hardware before flashing.

### Validation

```sh
CC=clang bash tools/test_usb_device.sh
bash ios-app/scripts/test_core.sh <isolated-simulator-UDID>
RUN_UI_TESTS=1 bash ios-app/scripts/test_core.sh <isolated-simulator-UDID>
```

Protocol tests use loopback networking. App tests use synthetic models and temporary storage, and do not replace physical-device acceptance testing. UI tests add test images and files to the specified isolated simulator. Coverage for core protocols, one-time authorization, session isolation, no replay of uncertain outcomes, checkpoint migration, and stop/release behavior remains in the default target.

## Dependencies and sources

| Project | Current usage |
| --- | --- |
| [SwiftAgentKit](https://github.com/ayman3000/SwiftAgentKit) | Local source snapshot of the agent core and macros, with iOS storage compatibility patches; does not include the upstream MCP module |
| [MacPaw/OpenAI](https://github.com/MacPaw/OpenAI) / [MarkdownUI](https://github.com/gonzalezreal/swift-markdown-ui) | Swift Package dependencies for model calls and Markdown message rendering, respectively |
| [idevice](https://github.com/jkcoxson/idevice) / [Device Hub](https://github.com/JaviSoto/device-hub-ios) | Reuses the patched idevice source and PNG validator pinned by Device Hub, with local adaptations; does not integrate the entire Device Hub app |
| [ManifoldKit](https://github.com/ManifoldKit/ManifoldKit) | Selected and adapted tool-call presentation components, not a package dependency on the entire framework |
| [ESP-IDF](https://github.com/espressif/esp-idf/tree/v5.5.5), [esp_tinyusb](https://github.com/espressif/esp-usb), [TinyUSB](https://github.com/hathach/tinyusb) | ESP32 firmware toolchain and USB components; pinned to ESP-IDF 5.5.5, esp_tinyusb 2.2.0, and TinyUSB 0.21.0~2 |
| [pymobiledevice3](https://github.com/doronz88/pymobiledevice3) | Protocol schema reference and selective translation; pinned reference files support offline tests. It is not a Python service running on the phone or ESP32 |
| [LocalDevVPN](https://github.com/jkcoxson/LocalDevVPN) | Verified external VPN loopback implementation; its Network Extension implementation is not copied into this repository |

Other direct and transitive Rust dependencies are listed in [Cargo.toml](ncm-dev/rust/Cargo.toml) and [Cargo.lock](ncm-dev/rust/Cargo.lock). Pinned Swift versions are in [Package.resolved](ios-app/PhoneAgent.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved). [idevice_pair](https://github.com/jkcoxson/idevice_pair) and [rPlayHub](https://github.com/rPlayAI/rPlayHub) are protocol research references, not current runtime dependencies. Historical USB Host sources likewise do not imply dependencies of the current NCM backend.

Existing license and attribution records are in [LICENSE](LICENSE), [THIRD_PARTY.md](THIRD_PARTY.md), [iOS licenses](ios-app/Licenses/), [SwiftAgentKit snapshot notes](ios-app/Vendor/SwiftAgentKit/README.md), [ManifoldKit extraction notes](ios-app/Vendor/ManifoldPresentation/README.md), and [CoreDevice reuse boundaries](docs/ncm-coredevice/REUSE.md).

## Repository layout and further reading

| Path | Purpose |
| --- | --- |
| `ios-app/` | Actell app, tests, and project generation scripts |
| `firmware-device/` | Current USB Device NCM firmware and retained HID mode |
| `ncm-dev/` | Shared Swift/C/Rust CoreDevice backend, protocol modules, and standalone probes |
| `tests/usb_device/` | Local test fixtures for the production USB Device protocol |
| `tools/` | Build and validation scripts |
| `docs/` | Current route documentation, diagnostics, and validation records; read historical descriptions in their dated context |
| `archives/` | Historical documentation and archived non-core tests |
| `firmware/` | Retained older USB Host experiments, not the current default firmware |

- [Main project integration](docs/ncm-coredevice/MAIN-INTEGRATION.md) · [System pairing records](docs/ncm-coredevice/PAIRING.md)
- [Background execution diagnostics](docs/BACKGROUND-RUN-RECOVERY.md) · [Control session stop and release](docs/CONTROL-SESSION-TEARDOWN.md)
- [PA3 protocol](docs/usb-device/PROTOCOL.md) · [Historical archive index](archives/README.md)

## Muse remote tools prototype

The optional [Muse adapter](docs/muse-remote/README.md) lets Muse plan while Actell executes tools in an independent remote runtime using paired-device scopes and its existing lifecycle, mutual-exclusion and screenshot freshness checks. Remote calls do not create Agent conversations or change the selected chat. Settings → Extensions → Muse Gadget now contains a device list, an add-device entry, and an explicit allow-connection switch. Each paired device supports a saved local display name, independent screenshot, app-list and control permissions, plus removal. Identity material and client secrets remain in the device-only Keychain; the service remembers the last switch setting and restores it when the app is unlocked, in the foreground and idle. Technical connection configuration is hidden from normal navigation.

### Independent Muse companion

The normal connection flow uses [Simple LAN pairing (SLAN/1)](docs/muse-remote/COMPANION-PAIRING.md): turn on **Muse Gadget Service**, choose **Add Muse**, then choose **Connect Actell** on Muse and allow the incoming request on the phone. Muse automatically requests the single compatible open pairing window; if several are open, keep only the target phone’s window open and retry. Actell reuses its stable app-owned P-256 TLS identity, delivers a device-specific credential, and marks the device paired only after its authenticated `companion.hello`. Bonjour TXT `host` identifies the existing certificate SAN and TLS SNI; Muse connects to the discovered SRV address, so IP changes retain the saved identity. Successful pairing enables screenshot, app-list and control permissions by default; each remains independently configurable, and permitted Muse actions execute without per-action prompts. Switching the service off cancels unfinished pairing and retains completed devices and permissions. Ordinary backgrounding and remote-run cleanup keep the listener open and retain authenticated peer presence; tool execution still requires its existing background lease. Unfinished pairing closes on backgrounding. System suspension can still interrupt communication; returning to the unlocked, idle foreground restores a stopped listener without reopening pairing or replaying work. Relaunching the app restores the last switch setting; new installations start off. The choice is saved before startup admission, so a failed start keeps the switch on while reporting that the service is not running. Network listener failures also retry automatically in the unlocked, idle foreground with a 1–32 second backoff; switching off or leaving the foreground cancels retries. Permission and storage failures remain stopped.

Muse admission failures now carry a diagnostic ID and a specific rejection code. For agent-led troubleshooting, prefer native log services, Xcode APIs and CLI using the [diagnostic workflow](docs/muse-remote/DIAGNOSTICS.md); manual copying is not a prerequisite. **Muse Gadget → More → Copy Diagnostic Log** remains an optional export of request-time scene, protected-data, execution ownership and control-route state. The last 300 Muse diagnostic events persist across app launches; raw request bodies, tool arguments, credentials and screenshots are excluded. Export uses the live log instance so events and storage errors remain visible even when the latest disk write failed. Local diagnostics also distinguish pre-authentication HTTP 401 causes (format, clock, credential availability, signature, replay and nonce capacity), while the remote response stays generic.

Pair only on trusted Wi-Fi: the initial TOFU enrollment does not protect against an active attacker on the same LAN. Later connections must retain the exact certificate pin and per-client HMAC. The app does not use official Muse account/setup tokens. Physical iPhone/Muse interoperability and long-running background behavior remain unverified. See [implementation, cleanup and validation](docs/muse-remote/SLAN-IMPLEMENTATION.md). Legacy manual configuration is available only in Debug builds explicitly launched with `--muse-development`.

The [remote tools technical document](docs/muse-remote/REMOTE-TOOLS.md) defines the direct Gadget interface, screenshot-independent normalized input, 30-minute protected image results, execution lifecycle and remaining integration boundaries.

Remote calls can start in the background without a prior foreground invocation or a separate continuation-receipt admission gate; the existing execution lifecycle, connection and deadlines determine readiness. The Muse service can retain already-selected continuous background sources between operations, while releasing phone execution ownership after each operation. Closing the service, revoking permissions or locking/stopping execution releases that demand; no unselected background option is enabled.
