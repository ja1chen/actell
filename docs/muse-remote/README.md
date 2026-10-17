# Muse → Actell remote tools adapter

The [remote tools technical document](REMOTE-TOOLS.md) defines the direct Gadget interface, screenshot-independent normalized input, protected image retention, execution/background lifecycle, error recovery and remaining integration boundaries.

Current enrollment uses [SLAN/1](COMPANION-PAIRING.md). See [the current implementation record](SLAN-IMPLEMENTATION.md) for build/test evidence. The V1 patch history below retains the original provenance and RPC execution boundaries.

The settings/provisioning UI and its subsequent verification are recorded in [UI-VALIDATION-2026-10-13.md](UI-VALIDATION-2026-10-13.md). Earlier local Mac validation is recorded separately in [LOCAL-VALIDATION-2026-10-12.md](LOCAL-VALIDATION-2026-10-12.md). The cloud limitations below describe the original delivery; they are not current local build results.

Baseline: `ja1chen/actell` commit `7429967c47eb0f763bb14b95d68350ef2dc27f5c`.
This is source code and an applyable patch, **not a signed iOS app or an accepted hardware integration**.

## What is implemented

- A real, opt-in Network.framework HTTPS listener (`POST /v1/rpc` plus the two isolated SLAN pairing endpoints), TLS 1.2+, required locally supplied `SecIdentity`, exact numeric peer-IP allowlist, no plaintext fallback, Bonjour advertisement, forwarding proxy, automatic startup or bundled credentials.
- Raw-body CryptoKit HMAC authentication, clock window, monotonic nonce replay cache, live client-key lookup and explicit revocation hook. The independent Muse Python client shares the authentication fixture.
- `capabilities`, `runs.open/get/cancel`, `tools.call`, `calls.get`, `images.get` using the companion `protocol/v1.md` contract. Images are binary PNG/JPEG, not base64 JSON.
- An independent `RemoteToolRuntime` that uses `ActionCoordinator`, nonoptional-at-construction lifecycle, durable one-use authorization records and `NCMDeviceBridge`. The root model only admits and owns its device lease. It creates no Agent conversation, task history, chat messages or model/provider loop and never changes the selected chat.
- Process-wide remote/local exclusion plus an immediate NCM control reservation, one remote run and one in-flight call. Concurrent calls return `device_busy`; they are not silently queued. Local diagnostic actions use the existing NCM reservation fence too.
- Durable accepted identities/digests and terminal states. Restart converts unfinished calls to `unknown` and closes old runs; it never resumes or resends them. Accepted IDs are not deleted automatically. At 10,000 runs or calls the adapter fails closed until a separately reviewed local archive/reconciliation procedure exists.
- The coordinator validates the exact screenshot reference while its entire remote call is fenced. Input invalidates the observation generation conservatively, even on denial/uncertainty. The NCM pre-dispatch callback checks the deadline and image reference after asynchronous input preparation. Cancellation records its fence before transport teardown and holds the local/remote lease until teardown and call draining finish.
- The service is owned by `PhoneAgentRuntime.shared.remoteTools` but stays dormant. App lock and termination stop it. Listener failure stops its run.

## Important boundaries

1. **No Swift compiler, Xcode, Apple SDK or device was available in the cloud.** Swift compilation and XCTest are unrun. Static checks and patch applicability are not a build or security certification.
2. **Settings → Muse Connection uses Simple LAN pairing.** Explicitly turn on the service and open a short Add Muse window, then allow the incoming request. Initial enrollment uses the accepted trusted-Wi-Fi TOFU assumption; subsequent connections keep an exact certificate pin and per-client HMAC. All capabilities start off. Manual configuration is hidden behind the opt-in Debug development hub. Closing the service removes unfinished keys and preserves completed devices. See [SLAN/1](SLAN-1.md).
3. Remote V1 supports the existing connected NCM and VPN-loopback developer-service routes only. Existing capture/USB-HID and legacy TLS routes are deliberately refused, because their final-dispatch deadline behavior has not been integrated. No firmware, Muse Noise/NAPT tunnel or pairing identity is replaced.
4. Paired Muse clients execute permitted tools **without per-action prompts**. The policy is local to Actell; no RPC can upgrade it. Device scopes, lifecycle eligibility, deadlines, fresh observations, stop/release and no-replay rules still apply. This does not guarantee background residency.
5. The listener remains open across foreground/background transitions and remote-run cleanup. Tool execution still reuses the existing user-selected PiP/system-task policy and requires an actually delivered lifecycle lease in the background. Lease loss stops the run, not the listener. Unfinished pairing is cancelled on backgrounding; explicit service Off, protected-data loss and listener failures still stop listening. Every dispatch still checks `backgroundReady`, lifecycle generation and tool capability. **Cross-app launch, PiP lease transitions, network scheduling and approval return paths remain first-priority physical-device tests.** No promise of arbitrary or permanent iOS background execution is made.
6. Screenshots are bounded to 8 MiB and retained only in memory (one current retained image); a later capture or run close can make an older image unavailable. Mutation makes old observations unusable for coordinates. Actell's original model-call screenshot persistence is not used by the remote entry. The durable remote journal contains IDs, digests, statuses, safe results and app-list output, but no raw request arguments, credentials or image bytes.
7. The phone remains the HTTPS server; the Muse implementation must use the same SLAN contract. Physical interoperability is not established by this source change. Downloading an image on Muse does not by itself inject it into the model; the companion host must supply image input correctly.
8. A socket timeout, response loss, `unknown`, or even a later `not_found` does not prove an action never arrived. Query the same run/call; never automatically resubmit under a new ID. Delivery acknowledgment is not visual success.

## Local enrollment and activation

Use [the Simple LAN setup](COMPANION-PAIRING.md). The service defaults off and never opens a pairing window merely because a page was opened. Actell prepares or reloads its app-owned TLS identity when explicitly enabled, keeps its private key on the phone, and uses `pair=1` Bonjour TXT only during the new-enrollment window. The two pairing endpoints accept only bounded strict JSON with bearer claim-token hashes; ordinary RPC always uses existing ACTELL1 HMAC. Pending ACK clients can authenticate only their hello and receive no business capability.

Revocation removes the live key before fencing in-flight work. Scope reduction also fences existing work. The saved service switch is restored on relaunch and foreground return once unlocked and idle; restoration never opens pairing or restarts a cancelled run. Old exact-source/manual provisioning APIs remain developer-only and do not promote SLAN pending records.

## Build and test locally (not executed in the cloud)

The upstream baseline targets iOS 27 and documents Xcode 27 plus its Rust backend dependencies. This patch has no new third-party package dependency. The checked-in Xcode project includes the six new source/test files. Follow the upstream README for toolchain/dependency preparation; do not confuse a newer desktop's installed SDK with a successful build.

From the patched checkout, first do the unsigned device build:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild \
  -project ios-app/PhoneAgent.xcodeproj -scheme PhoneAgent \
  -destination 'generic/platform=iOS' -derivedDataPath .build/DeviceBuild \
  -clonedSourcePackagesDirPath .build/SourcePackages \
  CODE_SIGNING_ALLOWED=NO build
```

Then run the existing complete app regression suite on a deliberately isolated simulator:

```sh
bash ios-app/scripts/test_core.sh <isolated-simulator-UDID>
```

New tests are `RemoteTransportSecurityTests`, `RemoteStrictJSONTests`, and two remote-deadline cases in `NCMDeviceBridgeTests`. They cover the shared HMAC vector, tamper/replay/revocation/clock/cache cases, split HTTP framing and smuggling rejection, numeric IP matching, binary framing, duplicate JSON keys, disabled default, and pre-dispatch deadlines. **They are authored but unrun here.** Existing lifecycle/approval/cancellation/session tests remain in the default target and must not be skipped.

The existing build/test scripts can build the NCM Rust backend and resolve dependencies. Review their normal prerequisites before running locally; no upstream script was executed by this cloud task.

## First physical-device acceptance checklist

Use a harmless local test app and a dedicated test client, never real credentials, purchases or message-send targets.

- Confirm a new installation or a saved OFF opens no new listening port; saved ON restores only in the unlocked, idle foreground. Enable only after identity/key/source setup, and confirm trusted TLS succeeds; wrong CA/name, missing identity, other peer IP, wrong/revoked key, malformed/duplicate JSON and replay fail closed.
- Check capabilities, open a run, capture and fetch an image. Verify content type, bytes/hash/dimensions, image ID and generation. Confirm the screenshot is actually injected into the Muse model context before visual planning.
- Request a tap against a harmless counter: approve once locally, confirm one delivery and a fresh screenshot. Decline another request and verify zero inputs. Replay the same call ID and change its payload: respectively the same record and `idempotency_conflict`, never a second action.
- Try old generation/cross-run/cross-client images; reject. Concurrent screenshot/input calls and local runs must not race. Try local Settings diagnostic controls while remote owns the route.
- Test deadline expiry while waiting for approval and during delayed NCM preparation. Test cancellation before dispatch, during dispatch and during draining; a local run must remain blocked until old transport release.
- Drop the response/socket immediately after dispatch. Verify lookup of the same call and no client retry. Kill/relaunch the app before delivery acknowledgment; unfinished calls become `unknown`, old runs remain closed, and IDs are never replayed.
- Test `launch_app`, background with a delivered PiP/system lease, pending lease/no lease, lease expiration, return to Actell approval, a transient permission sheet, lock/unlock and termination. Confirm no background dispatch without a ready lease and no automatic restart after fencing.
- Test journal write/read failure and oversized images. Confirm fail-closed behavior and that a new failed capture never reports an old screenshot as its successful result.

## License and provenance

The complete upstream `LICENSE`, dependency licenses, source manifests and notices are preserved. The patch is based on the exact commit above and does not push or modify an upstream repository. The companion Muse client/mock is separate; its passing Python tests do not establish that this Swift adapter or an actual Muse/iPhone link works.
