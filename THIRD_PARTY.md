# Provenance and licenses

The combined v0.3 project is distributed under GPL-3.0-only; see LICENSE.
Original v0.1/new independent files retain their individual GPL-3.0-or-later
headers. The raw mux module conservatively retains GPL-2.0-only OR GPL-3.0-only,
so version 3 is the compatible choice for this combined distribution.

The protocol inspection reference is pymobiledevice3 commit
cd895d17ce8a97d883c10f87b26c7356d5e0ccb1 (2026-09-30),
https://github.com/doronz88/pymobiledevice3 . Its pyproject.toml declares
GPL-3.0-or-later. The full research checkout is not shipped. Four unchanged protocol
reference files are shipped under tests/upstream_reference for offline test
oracles, with provenance and SHA-256 manifest.

bridge_xpc.c, bridge_hid.c, bridge_requests.c, bridge_media_offer.c and
bridge_screenshot_stream.c selectively translate/use the pinned protocol
schemas and report/offer builders. Their source origins are identified in the
files; corresponding upstream references are GPL-3.0-or-later.

bridge_io.c implements the 4-byte big-endian length prefix described in
pymobiledevice3/service_connection.py. The bounded binary-plist view is new C
implementation; test fixtures are created by Python's standard plistlib.
No code/fixtures from real iPhones, pairing records, certificates or private keys
are included.

Hardware reference: `docs/hardware/xinlu-esp32s3-schematic.pdf` is the unmodified
vendor schematic linked from https://www.xinlucity.com/?s=resourcedetail/index/id/61.html,
retrieved on 2026-10-04. Its source URL and SHA-256 are recorded in
`docs/local-validation/esp32-bringup-summary.json`. It is third-party reference
material, not covered by this project's GPL grant; no redistribution license
was identified on the supplied schematic.

Build dependency: Espressif ESP-IDF v5.5.5, commit
b774170ff46c393eeb5e495ea37936038d3f4f4f,
https://github.com/espressif/esp-idf/tree/v5.5.5 . ESP-IDF is primarily Apache-2.0,
with component-specific notices; it is fetched separately, not vendored.
An eventual distributed firmware including ESP-IDF dependencies must retain their
applicable license notices. This source checkpoint is not a hardware-validated bridge.

Do not confuse LGPL libusbmuxd's daemon client with a standalone USB host transport.

## Raw USB mux and directional magic (v0.2)

Primary wire/state reference: libimobiledevice/usbmuxd
3ded00c9985a5108cfc7591a309f9a23d57a8cba, src/device.c, src/usb.c and src/usb.h.
Source headers permit GPL version 2 or version 3. The bounded implementation
bridge_usbmux.c retains that either-version notice and upstream author credits.

Directional magic cross-reference: hack-different/demuxusb
778f8cd0ffd1558be857c0d170ab5d8eacd89ba3, ext/usbmux.h.
SHA-256 a74d8f8bb21b3f9d15d51d7df9f73c72576bd8e5b975d777fc776d4a46cea4ad.
That header is GPL2-or3, despite the repository's MIT summary; no analyzer
implementation is copied or vendored. Device IN is FACEFACE, host OUT FEEDFACE.

bridge_usb_descriptors.c and bridge_usb_host.c are independent bounded API
implementations using USB descriptor/ESP-IDF public API contracts. QueryType
semantics were checked against libimobiledevice src/lockdown.c; no upstream
implementation was copied. No pairing records or keys are included.

## Authentication, networking and compression (v0.3)

New lockdown, CDTunnel, RSD and RemoteXPC implementations selectively follow the
pinned pymobiledevice3 wire schemas. Four unmodified Python files are test
oracles, not a runnable device tool; only selected pure methods execute in tests.
TLS changes the upstream authentication policy to an explicit exact device-leaf
pin; no upstream CERT_NONE fallback is provided.

ESP-IDF mbedTLS 3.6.6 source: 9d669eadb1955d348986b9280156710aaaadf79f.
Real TLS tests read already-public test identities from that separately obtained
checkout; no certificate or private-key fixture is included in this project or
firmware. License/provenance details are in tests/test_tls_README.md.

lwIP source: fd432e4ee2cfb7f7f1c7eb7227e0173412e7b84e, ESP-IDF v5.5.5 submodule.
The source is not vendored. Host tests compile the real stack and its Unix port;
a host-only critical-section shim addresses a test-port bookkeeping race without
modifying the stack. lwIP's BSD-style notices remain with its source.

The minimal unmodified zlib 1.3.2 deflate source subset is vendored under
firmware/components/bridge_zlib/vendor/zlib, with its LICENSE and complete
SOURCE_MANIFEST.json. Official archive SHA-256:
bb329a0a2cd0274d05519d61c667c062e06990d72e125ee2dfa8de64f0119d16.
Only adler32, deflate, trees and zutil translation units are built (Z_SOLO,
Z_PREFIX, NO_GZIP); no decompressor or upstream executable is shipped.

Additional research-only cross-reference: idevice
d32c8189c51c2789496b0768039419c3705498c3. No implementation copied or vendored.
Its display-stream client also uses global stopAll, not a verified stream-token
extraction rule.

## USB Device 实验工程

`firmware-device/main/idf_component.yml` 与锁文件固定 esp_tinyusb 2.2.0（Apache-2.0）及 TinyUSB 0.21.0~2（MIT）；许可证副本位于 `firmware-device/licenses/`。组件通过 Espressif 官方 registry 下载到忽略的 managed_components，没有下载商业控制器固件。ESP-IDF 5.5.5、lwIP 和 mbedTLS 沿用官方工具链及各自许可。宿主机协议夹具用系统 CommonCrypto 替换 mbedTLS API 以便测试，生产代码不依赖 CommonCrypto。

## Isolated NCM developer-service experiment

`ncm-dev/` adapts this repository's committed NCM interface/network code and
selectively implements the pinned pymobiledevice3 RemotePairing greeting schema
under GPL-3.0-or-later. The combined distribution's GPL-3.0-only choice is unchanged.
The existing bridge_core RSD/PNG operations and their provenance remain intact.
Device Hub’s pinned, patched idevice source and its PNG validator are now
vendored in `ncm-dev/rust` under their original MIT terms. Full notices are in
`ncm-dev/rust/DEVICE_HUB_LICENSE` and `vendor/idevice/LICENSE.txt`; exact hashes
and local adaptations are in `ncm-dev/rust/SOURCE_MANIFEST.json`. idevice_pair
and rPlayHub remain reference-only. Original reference hashes are recorded in
`docs/ncm-coredevice/SOURCES.json`, with reuse boundaries in `REUSE.md`.

The new build uses cJSON from the existing ESP-IDF checkout. cJSON is MIT,
Copyright (c) 2009-2017 Dave Gamble and cJSON contributors; its full license
remains at ESP-IDF `components/json/cJSON/LICENSE`. Existing ESP-IDF, lwIP,
esp_tinyusb and TinyUSB notices above apply to this independent target as well.
No Apple developer image or private framework is included.

## MacPaw/OpenAI

Remote Swift Package Manager dependency, fixed at 0.5.2 /
975fff8a1e1ef92fc7fc04097b0cfe253b840cb7. MIT license. No SDK source is
vendored or patched. Actell's own adapter uses public SDK request/output DTOs
plus a privacy-bounded local transport. The former model Kit is no longer a
direct or transitive runtime dependency; its existing license records remain
for historical attribution. See ios-app/ProviderKit/README.md.

## Apple Swift Certificates

Remote Swift Package Manager dependency, fixed at version 1.10.0, product
`X509`, from https://github.com/apple/swift-certificates. Apache-2.0;
see `ios-app/Licenses/SwiftCertificates-Apache-2.0.txt`
for the complete upstream notice. No SDK source is vendored or patched. The
optional Muse companion integration uses the package's public certificate
and Security framework interoperability APIs for an app-owned local TLS identity.
