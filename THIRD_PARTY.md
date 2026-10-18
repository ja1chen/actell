# Provenance and licenses

The combined project is distributed under GPL-3.0-only; see [LICENSE](LICENSE).
Independent source files retain their GPL-3.0-or-later headers. Third-party
components retain their own licenses and authorship notices.

## ESP32 firmware

The protocol reference is [pymobiledevice3](https://github.com/doronz88/pymobiledevice3)
commit `cd895d17ce8a97d883c10f87b26c7356d5e0ccb1`, GPL-3.0-or-later.
`bridge_io.c` implements its length-prefixed service framing; the bounded plist
reader is an independent C implementation with Python plistlib-generated tests.
Lockdown QueryType semantics were cross-checked against libimobiledevice; its
implementation was not copied. NCM discovery and RemotePairing greeting schemas
retain their source notices. No real pairing records or private keys are shipped.

[Original firmware source hashes](devices/esp32/licenses/SOURCE_MANIFEST.json) and
[import source hashes](devices/esp32/licenses/IMPORT_SOURCES.json) identify the
original imported baseline, including retired files; they are provenance records,
not the current build graph. Source inventories and the zlib license from removed
reference code are retained in the same directory for attribution only.

ESP-IDF v5.5.5 (`b774170ff46c393eeb5e495ea37936038d3f4f4f`) is fetched separately
and is primarily Apache-2.0 with component-specific notices. Its lwIP, mbedTLS
and cJSON notices remain applicable. cJSON is MIT, Copyright (c) 2009-2017
Dave Gamble and cJSON contributors; its license is in the SDK component source.

The [component manifest](devices/esp32/firmware/main/idf_component.yml) and lockfile
pin esp_tinyusb 2.2.0 (Apache-2.0) and TinyUSB 0.21.0~2 (MIT). License copies are
in [devices/esp32/licenses](devices/esp32/licenses/). Downloaded components and
SDKs are not committed. Firmware distribution must retain applicable dependency notices.

The unmodified vendor schematic at `docs/hardware/xinlu-esp32s3-schematic.pdf`
comes from https://www.xinlucity.com/?s=resourcedetail/index/id/61.html.
It is third-party reference material, outside this project's GPL grant; no
redistribution license was identified on the supplied schematic.

## CoreDevice backend

Device Hub's pinned, patched idevice source and PNG validator are vendored under
their original MIT terms in [coredevice/rust](coredevice/rust/). Full notices are
in `DEVICE_HUB_LICENSE` and `vendor/idevice/LICENSE.txt`; exact hashes and local
adaptations are in `SOURCE_MANIFEST.json`. Reference revisions and reuse boundaries
are in [SOURCES.json](coredevice/docs/SOURCES.json) and [REUSE.md](coredevice/docs/REUSE.md).
idevice_pair and rPlayHub remain reference-only. No Apple developer image or
private framework is included.

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
