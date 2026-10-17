# Validation record — 2026-10-12

For the subsequent Mac build and regression results, see [local validation](LOCAL-VALIDATION-2026-10-12.md). This file preserves the original cloud evidence.

## Passed in the dot cloud workspace

- Downloaded complete upstream source at fixed commit `7429967c47eb0f763bb14b95d68350ef2dc27f5c` from GitHub's fixed-commit archive.
- Upstream archive SHA-256: `79ae9b2681f5a6fba03af09caef7e8a230d5cd131b25604c14b870b06efe4f3e`.
- `python tools/muse-remote/check_static.py`: **5 passed**. These are source/packaging invariants and an independent Python HMAC calculation, not Swift execution.
- `git diff --check`: passed.
- New source/test references registered in the committed Xcode project; six new Swift files are included. Existing upstream tests and licenses remain present.
- Independent read-only review of the transport, identity binding, call ledger, cancellation, screenshot observations, deadline fencing and background lifecycle led to concrete fixes. Review is not runtime verification.
- The final patch is applied/checkable against a freshly extracted copy of the exact upstream archive; changed files are byte-compared with the working tree as part of packaging.

## Authored, not run

- `RemoteTransportSecurityTests`: CryptoKit HMAC vectors, replay/cache/time/identifier/key revocation, framing/smuggling/size boundaries, numeric peer-IP matching and binary response framing.
- `RemoteStrictJSONTests`: duplicate/escaped keys, malformed/deep JSON and disabled service default.
- `NCMDeviceBridgeTests`: deadline expiry before dispatch and after asynchronous input preparation.
- Existing complete Actell lifecycle, approval, session, bridge and UI regression suites.

## Not verified and not claimed

Swift compilation, Apple SDK API compatibility, Xcode build, XCTest, simulator behavior, real HTTPS handshake, certificate provisioning, Keychain UI, Muse model-image injection, hardware connectivity, actual tap/drag, cross-app execution, PiP/system task lifecycle, network reachability through Muse NAPT, power/latency, lock/unlock and crash races.

No Swift/Xcode toolchain was present. No upstream build script was executed, no listener was started, no credential or identity was generated/imported, no real device/API was used, and no repository was pushed. A clean patch application is not evidence of a compiled or deployable iOS binary.

The explicit activation API is integrated with the App runtime, but a completed Settings provisioning UI is not included. See README.md for the required local setup and first device-acceptance sequence.
