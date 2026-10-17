# SLAN/1 Actell implementation — 2026-10-17

This implementation replaces the previous proposed pairing transport. It changes
the Actell checkout; the approved discovery clarification also updates the Muse
source checkout. It does not modify the main Actell worktree. No Git
commit/push, firmware flash, account configuration or physical pairing occurred.

## Inputs and audit

- Actual branch `feature/muse-integration`, HEAD
  `e701786d1686823f9ab60524e689e387b7c3b904`. Existing dirty Muse/NCM work was retained;
  no old archive was unpacked or reset over it. The v6 ZIP was not supplied as a
  local baseline, so a byte comparison against that archive is not claimed.
- User-supplied Simple LAN handoff and contract from Downloads; the
  original baseline hash was `21afdf1832e10a29cfe893215237b4ba457db18ab5be0d316a76d2ee4c5048e9`.
  After the user-approved host and default-permission changes, both repositories share SHA256
  `cc15ccb045cf58448f86161cae6052f89e4b7fda64e1eab8ce35618c5562f0c0`.
- iOS 27 target, existing P-256 identity, device-only WhenUnlocked Keychain, local
  network privacy declaration and `_actell-muse._tcp` are reused. No new dependency.
- Public handoff dummy request/claim are in `slan-fixtures/`; request SHA256
  `10fb78b0779f29b6d17a37395de02c967943129bb45a997c053bce0beeb90e77` is asserted by XCTest.
  Dummy token is not a production credential. No real token/secret was logged.

## Change map

- `Remote/SimpleLANPairing.swift`: MainActor-serialized RAM request context, claim
  token/body hashes, local approval/rejection, bounded retired hashes, strict codec,
  120-second window, separate 300-second approval/ACK deadline, invalid-token and
  claim polling throttles, three accepted requests per window. No two-phase recovery.
- `RemoteConnectionStore.swift`: additive Codable pairing markers preserve older
  registrations. SLAN registration, secret, active state and scopes live together
  in one authoritative Keychain envelope; display metadata is mirrored separately.
  Startup strips all pending keys before they can be looked up. Unreadable/failed
  storage fails closed. A successful ACK writes active before responding. Legacy
  `recordHello`/manual authorization cannot promote pending SLAN registrations.
- `RemoteTransport.swift`: exactly two additional POST routes on the same listener;
  512-byte request limit, strict framing, no compression/chunking/proxy headers,
  no-store responses, RFC1918/Wi-Fi boundary. Existing RPC authentication is not
  shared with bearer-token routes. Bonjour adds/removes `pair=1` without creating
  another server. Existing developer exact-IP allowlists retain their semantics.
- `RemoteToolsService.swift`: dispatches pairing only while actually listening;
  the old authenticated hello gains `pairing_state:"active"` while retaining
  `state/scopes`. Business scopes still fail closed. Stopping during a key lookup
  cannot dispatch a later operation from that authentication attempt.
- `RemoteConnectionController.swift`: explicit first-use identity preparation and
  server switch, no client requirement for new LAN service, truthful service status,
  window lifetime, local approval, expiry/stop/revoke cleanup and authenticated ACK.
  Startup never turns the service/window on. Legacy imported configurations are not
  automatically converted or silently assigned a new identity.
- `App/MuseConnectionView.swift`: basic connection switch/status, Add Muse, incoming
  Allow/Reject, waiting for authenticated completion, independent permissions and
  removal. Approval shows only the name and Allow/Reject; completion shows the
  paired state and name. Permission-page data disclosure remains.

## Retired dedicated files and references

Removed the five prior `Muse/Pairing/` protocol/fragment/certificate/transaction/probe
files; `App/MuseBluetoothProbeView.swift`; its dedicated UI test; four dedicated
protocol/fragment/transaction/vector test files; the old generated fixture tool and
public fixture directory; and the two previous pairing protocol/implementation
Markdown documents. Removed the Debug hub's probe link and the added Bluetooth
privacy key/translations. No other app code uses CoreBluetooth, so no replacement
Bluetooth permission was added. No QR/camera pairing implementation was present.

The generic missing-identity guard test was retained as
`RemoteIdentityGuardTests.swift`; automatic TLS, shared strict JSON, Keychain,
legacy APIs, normal RPC security tests, licenses and source inventories remain.
The older noncompiled Muse SDK v5 reference remains provenance only; it is not
runtime onboarding and is not advertised as an implementation of this contract.
Current README pairs, iOS setup documentation and companion guidance now describe
Simple LAN. Dated historical validation records remain dated evidence.

## Verification and limits

Tests cover approval/claim/ACK, wrong token and same-ID body conflicts, repeated
claim material/decreasing deadline, rejection/window expiry, 300-second cleanup,
stop cleanup, restart pending removal/active scope preservation, Keychain failures,
legacy bypass denial, strict JSON/token encodings, IPv4 policy, framing and TXT.
The RPC test uses a real locally generated identity/listener restricted to loopback,
then injects the request at the pairing-route boundary and exercises real ACTELL1
signatures, wrong signing keys, repeated hello and stop. It is not live LAN TLS.

The UI fixture is Debug-only, requires explicit `--ui-testing` and
`--ui-test-muse-request`, uses an in-memory credential vault and a loopback-only
listener, injects a synthetic request and signs an actual hello after local approval.
It does not contact a Muse or load production credentials. Its temporary generated
TLS namespace is cleaned after the scenario.

Not yet run: signed physical iPhone Keychain/lock behavior, real Bonjour TXT updates
on Wi-Fi, actual Muse TOFU/strict pin/hostname/time validation, real DHCP reconnect,
Muse NVS/write-failure/ACK-loss tests, official Muse coexistence and end-to-end
screenshot/control. This implementation does not claim first-use MITM protection,
offline cold boot or background residency. Both counterparts implement the clarified contract in source; actual device
interoperability still needs both updated artifacts and physical verification.

## Rollback

Turn the service off before replacing code. Use the scoped file changes rather than
resetting this dirty worktree. No production SLAN record was created during these
tests. Old binaries do not understand SLAN markers; remove new device registrations
before running an older app build, preserving unrelated user work and legacy records.
A temporary source-only pre-change snapshot was saved under `/tmp/actell-slan-before`;
it contains no runtime vault or account data and is not a durable Git checkpoint.

## Local validation (2026-10-17)

- Core target: 475 tests, zero failures, including the eight new SLAN cases.
  Evidence: `.build/validation/SLAN-Core-UI.xcresult`. That combined run also
  contained one UI assertion failure caused by status accessibility grouping;
  it is not an overall passing run. The explicit status accessibility value and
  assertion were corrected; the focused normal-screen rerun passed in
  `.build/validation/SLAN-Normal-UI.xcresult`.
- Current unsigned generic iPhoneOS build: `BUILD SUCCEEDED`.
- Final Muse UI suite: four tests, zero failures, `TEST SUCCEEDED` in
  `.build/validation/SLAN-Final-UI.xcresult`, after the accessibility fix and
  final system-form pairing layout. Covers default-off entry, local approval
  through authenticated hello with no scopes, independent permission persistence
  and device removal, and unconfirmed-device permission denial. Xcode emitted
  a post-test simulator diagnostic-collection warning; test execution passed.
- Offline packaging/security checks: six tests passed. The project version check
  accepts both Xcode's unquoted and the generator's quoted PBX serialization.
- `git diff --check` passed. Frozen contract and dummy request SHA-256 match the
  supplied files (`21afdf18…048e9` and `10fb78b0…0e77`).

Raw logs are copied to `.build/validation/slan/`. These are local generated
artifacts, not checked-in evidence or physical-device acceptance. No Git commit,
hardware flash, production credential enrollment or Muse source edit was made in
that initial Actell validation run. The approved follow-up below updates Muse source.


## Approved shared discovery clarification

The user approved TXT `host` on both sides. `RemoteConnectionController` passes
its existing identity-validated settings.host to the listener; TXT always retains
it, including outside the pairing window, and claim uses the same value. No TLS
identity is regenerated. Muse discovery now separates SRV network addresses from
TLS identity and checks saved host/pin before accepting relocation. Its existing
HTTP client passes this name via common_name (ESP-IDF uses it for certificate
verification and SNI), while its URL contains only the discovered address.

The shared contract now has the synchronized SHA-256 shown above. The supplied
dummy request bytes are unchanged. The original contract hash in the earlier
local validation section describes the original baseline, before this approved
clarification. Missing/invalid/duplicate host has an explicit incompatibility
message for new pairing. No user operation or ESP32 server was added.

New validation results are recorded below; physical LAN interoperability remains
unverified until both updated artifacts are installed and exercised.

### Host clarification validation

- Actell default core target: 475 tests, zero failures, `TEST SUCCEEDED` in
  `.build/validation/core.0Otrc8/Tests.xcresult`. TXT host remains present with
  pair on/off; its stable name is independent of the Bonjour SRV hostname.
- Current unsigned generic iPhoneOS build: `BUILD SUCCEEDED`.
- Focused pairing rerun after explicit TXT/claim host and pin equality assertions:
  seven tests passed in `.build/validation/SLAN-Host-Claim.xcresult`.
- Muse SLAN suite: ten tests passed, including production discovery under
  ASan/UBSan with synthetic mDNS/Wi-Fi. Different SRV/SAN names select the stable
  SAN host. Changing the IP and SRV hostname preserves the stored host/pin.
  Advertised replacement host/pin, missing/invalid/duplicate host, non-LAN
  address, claim-host mismatch and old-version UI state are covered.
- Muse complete development regression passed: 88 host tests, 16 font tests,
  seven board-control tests, Node syntax/DOM checks and observer validation.
- Native firmware leaf verifier and actual Mbed TLS handshake checks: 16 passed;
  the loopback TLS server also asserts SNI equals the stable SAN name although
  the network connection goes to a numeric address. Strict SAN/pin checks remain.
- Muse ESP32-S3 public configurations with extension enabled and disabled: both
  full builds exit 0.
- Muse Git-visible share check: 185 files, zero findings. Both worktrees pass
  `git diff --check`; the two shared contract files compare byte for byte.

Actell logs are under `.build/validation/slan/host-clarification/`; Muse logs are
under `local/logs/slan/host-clarification-*` in its checkout. These tests use
synthetic data and loopback only; real LAN DHCP, iPhone/Muse interoperability,
installation and flashing have not been performed. No Git commit was created.

## Simplified pairing and default permissions

The user requested a name-only approval screen and a minimal completion screen.
Request ID, the no-permission explanation and approval footer are removed.
A new SLAN client still has no business access while pending_ack. Only its first
successful authenticated hello atomically persists active state with screenshot,
list_apps and control enabled. Existing active clients and later hello/reconnects
preserve all user permission changes. Every control action retains per-action
approval. This supersedes the earlier zero-scope activation behavior described in
historical validation above. Both shared contract copies and hash are updated.

Validation: 475 core tests and four Muse UI tests passed in
`.build/validation/SLAN-Default-Permissions.xcresult`; unsigned iPhoneOS build
succeeded. The real-HMAC test verifies all three initial scopes and that later
revocation survives repeated hello. The UI test opens the newly paired device
and checks all three switches are on. Six offline packaging checks and ten Muse
SLAN compatibility tests also passed. Raw Actell logs are under
`.build/validation/slan/default-permissions/`. No device install, flash or Git
commit was performed.

## Foreground/background connection choice

The original `RemoteToolsService.setBackground` stops an idle runtime without a
delivered execution lease. The switch previously used runtime `isActive`, so
ordinary backgrounding also visually switched off the user's opt-in.

The controller now keeps a separate process-local `isEnabled` choice. Runtime
pauses retain this choice and clear unfinished pairing; returning to an unlocked,
idle foreground restores the listener with the same identity and saved clients.
Restoration waits for a draining run to release ownership, respects later scope
changes, and never opens a pairing window or creates/replays a run. Explicit Off
cancels pending restoration; a fresh process is still off. The service retains
its existing background lease, protected-data, journal and stop/release fences.

Validation: 476 core tests and four Muse UI tests passed in
`.build/validation/Muse-Lifecycle.xcresult`; unsigned iPhoneOS build succeeded,
and six offline checks passed. The new lifecycle regression starts the actual
TLS listener with loopback-only admission and synthetic identity/storage, drives
background/inactive/foreground and idle transitions, and verifies opt-in,
pending-key removal, identity/scope preservation, no new pairing/run, manual-off
and cold-start behavior. It does not verify physical iPhone residency or live
Muse reconnection. Raw logs are under `.build/validation/slan/lifecycle/`.

## Muse Gadget settings and interruption diagnostics

Settings now places the icon-free Muse Gadget row immediately after Skills in
Extensions, with no separate Muse section. Its page title is Muse Gadget and
the switch is Muse Gadget 服务. The old 连接受限 label was a generic rendering
of any interruption/restoration error, not evidence of a specific permission
denial. It is now 服务未运行; listener failed/waiting errors are forwarded to
the existing footer instead of discarded. Background pause and explicit Off
retain their separate status and opt-in behavior.

476 core tests, four Muse UI tests, six offline checks and the unsigned iPhoneOS
build passed. The lifecycle regression also verifies an unexpected interruption
retains opt-in and that successful restoration clears the old issue. The UI suite
checks the new entry/title/switch labels and retains a settings screenshot for
layout review. Evidence: `.build/validation/Muse-Gadget-Settings.xcresult`; logs:
`.build/validation/slan/gadget-settings/`. No physical-device error was captured,
so the former generic label cannot establish that device's exact failure cause.

## Muse calls without per-action prompts

At the user's explicit request, Muse now uses the existing task authorization
path instead of presenting a confirmation for each input. The local policy
`MuseCompanionAuthorization.inputMode` configures both the worker's approval
recording path and its ActionCoordinator. RPC callers cannot select this mode.
Approval/execution records, single-dispatch guards, device scopes, authenticated
requests, image/deadline checks and stop/lock/release behavior remain enforced.
Other local tasks retain their previous policies. Initial pairing still requires
local Allow. This supersedes earlier per-action descriptions in this record.

The permission title is 操控手机 and its footer states that permitted operations
execute without per-action confirmation. Session/development copy, both current
READMEs, the companion guide, and the two shared contracts are synchronized.
Capabilities reports `approval: paired-device-scopes` and
`input_approval: not-required`.

477 core tests and four Muse UI tests passed; the final unsigned iPhoneOS build,
six offline checks and ten Muse pairing/contract tests passed. A new regression
uses the production remote coordinator and NCM bridge with synthetic I/O to
execute consecutive inputs under this policy and verify no action after Stop.
Existing per-action, permission-revocation and no-replay coverage remains.
Evidence: `.build/validation/Muse-No-Prompts.xcresult`; raw logs are under
`.build/validation/slan/no-prompts/`. Physical Muse/iPhone execution is unverified;
no device was installed/flashed and no Git commit was created.

## Stable peer presence

The prior 30-second presence lifetime collided with the Gadget's 30-second delay
after each probe, plus discovery/TLS time. The UI also evaluated a new receipt
against the previous five-second TimelineView timestamp, producing a negative
age and a false offline display until the next tick.

Presence now records monotonic receipt time in the controller and updates on
accepted authenticated hello/RPC. Both normal and development views use the same
predicate. The UI uses current time and a one-second expiry cadence. A 90-second
display grace covers normal probe jitter and one failed probe/retry; it does not
extend credentials, request deadlines, pairing windows or execution permissions.
Actual listener stop or device removal overrides the grace immediately. No
Gadget polling or wire-contract change is required.

477 core tests, four Muse UI tests, six offline checks and the unsigned iPhoneOS
build passed. The real-HMAC regression injects a monotonic clock and verifies
immediate hello presence, gaps of 30/42/84 seconds, strict 90-second expiry,
invalid signatures failing to renew presence, ordinary RPC renewal and immediate
offline after stop. Evidence: `.build/validation/Muse-Presence.xcresult`; logs:
`.build/validation/slan/presence/`. Real device connectivity remains unverified;
this corrects identified display misclassification rather than proving a stable
physical LAN connection. No Git commit or device installation/flash was made.

### Admission diagnostics

`runs.open` no longer rewrites every setup failure as “App must be unlocked…”.
It preserves distinct admission codes (`not_foreground`, `protected_data_unavailable`,
`local_task_busy`, `control_setup_busy`, `control_not_connected`, `control_busy`,
`control_reserved`, checkpoint/journal failures) and adds a hashed request diagnostic
ID to the error message without changing the wire schema or retry/replay policy.

After HMAC verification, the service synchronously saves a request-time snapshot
and a result/rejection snapshot. This captures scene/foreground/protected-data,
root and worker setup occupancy, remote lease, control route/readiness/reservation,
and service/journal state. Native checkpoint/journal errors retain domain/code.
Service start/stop and background transitions are also recorded. IDs are hashed;
no request body, tool parameters, screenshot, key, certificate or network address
is included. Invalid HMAC traffic does not enter the admission log.

The last 300 events live in `Application Support/PhoneAgent/Remote/muse-admission-v1.json`,
excluded from backup and protected until first user authentication. Atomic writes
survive restart; filesystem failures are reported in OSLog (`MuseAdmission`) and
in the current in-memory log. Logging failure does not grant execution permission
or weaken the fully protected execution journal. Export via Muse Gadget's More →
Copy Diagnostic Log; the existing USB diagnostic export includes the same history.
The USB ring itself remains process-local. Historical failures before this change
cannot be reconstructed from a later settings screen.

Validation (2026-10-17, source/build evidence): 480 core tests and 4 Muse UI tests
passed in `.build/validation/Muse-Admission-Diagnostics-Final.xcresult`; unsigned
iPhoneOS build passed (`/tmp/actell-muse-admission-device-final.log`), as did all
6 packaging/static checks and `git diff --check`. The simulator tests cover real
HMAC `runs.open` rejection/correlation and persisted snapshots, cancelled-run
retention, no leaked lease, bounded restart history and filesystem errors. Control
spies cover disconnected/busy/reserved rejection without acquiring the device.
The simulator does not expose iOS file-protection attributes; the protection
attribute assertion is device-only. No physical-device installation or historical
failure reproduction was performed in this change.

### Saved service switch (2026-10-17)

Supersedes the earlier process-local/cold-start-OFF policy above. The controller
loads the last user-selected service switch from the store's separate local
`actell.muse.service-enabled.v1` preference (absent means OFF). A successful
explicit start saves ON; explicit OFF saves OFF immediately, including while
restoration is pending. Runtime stop, listener failure, lock, background and
termination do not change this preference. Restoring ON waits for an active,
unlocked and idle app and uses the existing configured identity and credentials.
It opens no pairing window, changes no scopes and never replays cancelled work.
Initializers only load the choice; the existing initial scene/unlock/idle hooks
perform restoration. Isolated tests use their own defaults suite or nil defaults.

Saved-switch validation: 481 core tests and 4 Muse UI tests passed in
`.build/validation/Muse-Saved-Service-Switch.xcresult`; unsigned iPhoneOS build
passed (`/tmp/actell-muse-saved-switch-device.log`), plus all 6 static checks.
The new lifecycle test reloads the store/controller using isolated persisted
preferences and the same credential vault: ON survives runtime loss, waits for
foreground/unlock/idle, preserves identity/client scopes and opens no pairing
window; explicit OFF survives another store/controller reconstruction. No
physical-device installation or relaunch acceptance was performed.

### Device-list appearance (2026-10-17)

The Add Muse row uses an explicit 6-point icon/text gap and retains blue tint.
Paired-device rows use plain button styling with primary device names, secondary
trailing status and tertiary disclosure indicators. The full row remains tappable.
Pending-device rows share the trailing status layout and retain the remove action.

Validation: 481 core tests and 4 Muse UI tests passed in
`.build/validation/Muse-List-Layout.xcresult`; unsigned iPhoneOS build passed
(`/tmp/actell-muse-list-layout-device.log`), plus all 6 static checks. The exported
`muse-device-list-alignment` simulator attachment was visually inspected for
neutral device/indicator colors and trailing status. No physical-device install
or device UI acceptance was performed.

The existing pairing UI test was rerun with an additional pre-pairing screenshot
in `.build/validation/Muse-Add-Row-Visual.xcresult` (passed). The exported
`muse-add-row-spacing` attachment was visually checked: the plus and Add Muse
text are blue and adjacent with the explicit compact gap.

### Local device display names (2026-10-17)

The device details sheet includes an editable Name row and uses its existing Save
button. Names are trimmed, must contain 1–64 characters and cannot contain control
characters; Cancel discards edits. Names and scopes are saved together by the
store. Active SLAN records persist in the authoritative credential envelope and
are mirrored to settings; legacy registrations retain their settings persistence.
No credential, client ID or original authenticated `requestedDeviceName` changes.
Authenticated reconnects cannot replace the user-selected local name.

A name-only save preserves authenticated presence and does not fence remote work.
Actual permission changes retain the existing execution fence, local admission
checks and presence invalidation. Storage failures continue to stop the service.

Core validation: 482 tests passed, including SLAN rename/reload, original-name
reconnect, scope/name persistence failure, invalid-name rejection, unchanged key
and authenticated online presence. Unsigned iPhoneOS build passed. No physical
Gadget rename or firmware change is involved; this is an Actell-local display name.

Device-details UI verification passed in
`.build/validation/Muse-Device-Rename-UI-Final.xcresult`: replace the name, save
alongside a scope change, check the updated list label, reopen and verify the
exact saved name and independent scopes, then remove the device. Its exported
permissions screenshot was visually inspected. The initial combined run
`.build/validation/Muse-Device-Rename.xcresult` passed all 482 core tests and the
other three Muse UI cases; the device-details case initially failed because the
test cleared a right-aligned text field from the beginning, then passed after
correcting the test caret position. No App behavior changed for that correction.
All 6 static checks and `git diff --check` passed. No physical installation was
performed.

### Remote runtime separated from Agent conversations (2026-10-17)

Supersedes the earlier visible AgentViewModel run projection. `runs.open` now
claims the app-wide remote device lease and constructs `RemoteToolRuntime`
directly; it never creates/selects a conversation, starts a ConversationStore run,
projects tool messages, inserts TaskRecords or publishes Agent conversation Live
Activity links. Rejected setup also leaves no empty conversation. Existing chat
history is not rewritten or deleted by this change.

The runtime uses the existing ActionCoordinator and lifecycle coordinator, with
persistent checkpoints in `PhoneAgent/Remote/Execution` rather than `Sessions`.
The shared RunIdentity is only an internal grant/checkpoint correlation key, with
no corresponding ConversationStore entity. The remote RPC journal remains the
source for `runs.get`/`calls.get` results and restart reconciliation. No model or
provider is constructed for remote work. The local Agent chat path remains separate.

One-use action grants still require durable register/resolve/claim/finish. The
same input mode, geometry checks, deadlines and dispatch checkpoints apply.
Scene, lock and control-health changes propagate to the independent runtime;
cancellation fences the RPC journal before revoking the bridge. The app-wide lease
remains claimed through execution and asynchronous bridge release, so no local or
new remote task can overlap draining input. Only matching run IDs can release it.

### Listener/HTTP/read-only RPC trace coverage (2026-10-17)

The prior admission log only covered authenticated `runs.open`. Absence of such
records could not establish that hello/capabilities/calls.get never reached the
phone. Trace coverage now includes every supported authenticated RPC operation
(received/result/rejected/failed), with hashed request/client/run/call correlation
and a task-local HTTP connection tag. Invalid HMAC does not create an authenticated
RPC record; request bodies, text, device names, credentials and addresses are not
logged. Existing run-open error codes and the bounded 300-event store remain.

Transport events cover listener configuration/readiness/waiting/failure/cancel/stop,
accepted TLS connections, connection readiness/failure, parsed HTTP route category,
response status/body size, network-stack content processing, close and deadline.
Native errors retain domain/code only. A listener-ready event is not a separate
Bonjour-registration acknowledgment. A contentProcessed event is not evidence that
the ESP32 or platform received a response. Missing RPC traces can now be compared
with pre-auth transport stages, while absence of all traces still needs external
network evidence; it does not prove any original action was unexecuted.

Static lifecycle review: Bonjour `_actell-muse._tcp`, instance `Actell`, uses the
system default domain; TXT v/kind/identity/host are always configured in companion
mode, pair=1 exists only during enrollment. Exact-source/manual mode does not
advertise. Companion mode requires Wi-Fi. Background without an execution lease,
lock/termination, manual OFF and NWListener waiting/failed/cancelled stop the
listener and remove the advertisement. Saved ON restores on scene-active, unlock,
idle or explicit resume. There is currently no same-foreground network-recovery
trigger after waiting; this is a source-level path, not a proven physical failure
cause. No network monitoring/recovery behavior or trust contract was changed here.

This historical baseline used one POST per TLS connection. The current optional
connection reuse and bounded-wait contract is in [REMOTE-TOOLS.md](REMOTE-TOOLS.md#optional-latency-capabilities). The baseline used Content-Length and Connection: close, with
10s request / 30s handler / 10s write deadlines. Normal RPC and authenticated
business errors use HTTP200 with ok/result or ok/error; invalid HMAC uses401,
pre-auth malformed envelopes400. Calls.get is read-only and not_found is not proof
of nonexecution. Capabilities only returns schemas and does not acquire device
control. Tests and review are restricted to source, stored logs, isolated simulator
and synthetic loopback TLS; no physical phone calls, discovery, install or flash.

Final evidence for the runtime/trace changes:

- `.build/validation/Muse-Runtime-RPC-Trace.xcresult`: 485 core cases passed,
  including all 3 independent-runtime cases and signed read-only RPC trace checks;
  all 4 Muse UI cases passed. The additional loopback trace case initially received
  HTTP400 because URLSession's default request did not use the protocol-required
  Connection: close header. No production parser/TLS rule was relaxed.
- `.build/validation/Muse-HTTP-Trace-Final.xcresult`: that loopback case passed
  after explicitly setting Connection: close in the test. The synthetic client
  anchors only its own generated certificate and validates the stable DNS SAN
  while connecting to 127.0.0.1. TLS, parsed HTTP, response processing and close
  stages share one connection tag; payload/address exclusion is asserted.
- Thus all 486 distinct core cases and 4 Muse UI cases passed across these runs.
  Unsigned iPhoneOS build passed (`/tmp/actell-muse-runtime-rpc-trace-device.log`),
  as did all 6 packaging/static checks and `git diff --check`.

All testing remained on the isolated simulator and synthetic loopback bridge.
Nothing was installed on, discovered from or invoked against a physical phone.
The source findings and diagnostic coverage were shared with the Muse integration
chat under the user's explicit cross-chat authorization. No Git commit was made.

## 2026-10-17 — Review fixes: listener recovery and live diagnostic export

The controller now retries a network listener failure in the enabled, unlocked,
idle foreground with exponential delays of 1, 2, 4, 8, 16 and at most 32 seconds.
It cancels pending retries on explicit opt-out or a non-active scene, and resumes
through the existing foreground/unlock/idle admission checks. It restores only
the listener; pending pairing is cancelled, saved identity/scopes stay intact,
and cancelled runs and calls are never replayed. Non-network service stops do
not trigger automatic recovery. A journal/permission/identity failure during a
restore leaves the service stopped rather than retrying through a safety fence.

The remote service and diagnostic export share the live MuseDiagnosticsLog
instance, retained across listener restarts. If writing fails while an older
file remains readable, export includes the newest in-memory events and the
storage error instead of silently showing the old file with storage=ok. The
existing 300-event limit, backup exclusion, file protection and payload/secret
exclusion remain in place. Unwritten events cannot survive process termination.

Validation of final Actell source:

- `.build/validation/core.PHtTMf/Tests.xcresult`: all 487 core tests passed.
  The lifecycle regression covers automatic same-foreground recovery without
  user action, saved certificate/key preservation, locked deferral, non-network
  stops, journal write failure, background cancellation and explicit opt-out.
  The export regression makes the temporary log directory unwritable after a
  successful write, verifies the stale on-disk snapshot remains readable, and
  verifies export still includes the new event and storage error.
- Unsigned iPhoneOS build passed:
  `/tmp/actell-muse-four-fixes-device-final.log`.
- All 6 `tools/muse-remote/check_static.py` checks and `git diff --check` passed.

Only the designated isolated simulator, synthetic credentials and loopback
services were used. No phone discovery, connection, query, installation,
hardware operation or Git commit was performed.

Coordinated Muse adapter fixes were completed in the companion repository,
without merging or extracting code between branches:

- Completed duplicate invokes return `invoke_result_unavailable` synchronously
  instead of an async marker with no future completion. This conveys neither a
  cached result nor confirmation of delivery/nonexecution. The caller reconciles
  original run/call IDs using a new read-only transport invoke ID.
- The 64 work slots recycle only finished entries. Read-only queries no longer
  exhaust the session after 64 completions. Mutating invoke IDs retain separate
  SHA-256 fences for the full control generation, even after work-slot recycling
  or if a duplicate changes its operation. There are 1024 write fences: ordinary
  writes stop at 992, preserving 32 for runs.cancel. Reads continue at full write
  capacity. This bound is explicit; writes never use LRU eviction or automatic
  reconnect/replay to bypass protection. Fences are not persistent across control
  generations or device restart; original business IDs and the phone journal
  remain essential. No historical large-result cache is promised.
- Reviewed the actual adapter/guard and sanitizer harness. Companion evidence is
  under `local/validation/actell-receipt-fix/{build,acceptance}.json` in that repo:
  114 local regressions passed; adapter ASan/UBSan covers 2000 sequential reads,
  dropped result delivery, unknown actions, duplicate completion, operation
  changes, queue rollback and generation isolation. Portable guard sanitizer
  tests cover 4094 reads and all 64 work slots in flight. Final target firmware
  compilation passed; no hardware was used or flashed.

The phone RPC and SLAN fields were unchanged. Existing runs.open identity and
parameter matching, tools.call receipt/digest matching and idempotent runs.cancel
remain the authoritative business-state boundary. These fixes do not establish
that the historical physical-device timeout had any one proven root cause.

## 2026-10-17 — Save the service choice before startup admission

The previous preference implementation saved enabled=true only after start()
passed identity, journal and activation checks. That covered successful startup
and later suspension, but a failed start could discard the user's last ON choice.
The controller now saves ON before those checks, retains ON with a visible failure
if startup is rejected, and saves OFF only for an explicit controller stop. It
does not bypass lock, scene, busy, identity or journal admission to start a listener.

New diagnostics record service.preference.loaded/enabled/disabled and
service.start.rejected with saved_enabled, version/build and safe state/error
codes. They do not record credentials or raw error descriptions. A newly added
unit regression recreates the preference store/controller after failed startup,
checks that ON survives scene changes, and checks that explicit OFF is retained.
A Debug-only process-relaunch UI fixture uses a unique real UserDefaults suite
with admission deliberately blocked: it opens no listener, provisions no identity
and never contacts a device. This exercises the actual switch and separate app
processes, including the failed-start alert and subsequent saved OFF.

This source defect is confirmed; it has not been established as the cause of the
reported installed-phone state. No physical app version or settings were queried,
and this fix has not been installed on a phone by this task.

Preference-fix validation: all 488 core tests passed in
`.build/validation/core.OpePep/Tests.xcresult`; unsigned iPhoneOS build passed in
`/tmp/actell-muse-preference-device.log`. All 6 packaging/static checks passed.
The actual app-process relaunch UI test passed in
`.build/validation/Muse-Preference-Relaunch.xcresult` (64.288 seconds): OFF on a
fresh isolated preference suite, ON despite a rejected startup, ON after process
termination/relaunch, and OFF after an explicit opt-out and another relaunch.
The fixture removed its preference suite afterwards. No device was accessed.

## 2026-10-17 — Single-candidate Muse pairing contract synchronization

Reviewed the companion working checkout's `docs/protocol/slan-v1.md` text changes
and synchronized the normative `SLAN-1.md` byte for byte. Current SHA256:
`d1ecce424490d4f8e7ea3dc927619f04b7c3fe8b9b522ee2dcacd286c23cee75`.
This supersedes the earlier cc15ccb contract reference above. The companion flow
automatically requests the single compatible open pairing window after the user
chooses Connect Actell. Multiple compatible windows stop selection without random
choice, serial attempts or fan-out; incompatible candidates do not count. Phone
approval remains required. Bonjour instance names remain service labels only.

The contract also documents Muse's saved-record retention on rejection/cancel,
explicit Forget semantics and the existing default-three-scopes first activation
versus preservation of user-modified scopes on active reconnect. Phone expiry,
revocation, request/claim/hello fields and TLS/HMAC/host/pin checks are unchanged.
Updated the companion guide and bilingual READMEs and added an offline normative
contract digest check. All 7 static/packaging checks and git diff --check passed.
Only documentation and its digest check changed here; no branch code extraction,
merge, commit, phone record change or hardware operation was performed. Muse's
new implementation/build acceptance remains owned by the companion task.

## 2026-10-17 — Default Muse name and pending ACK diagnosis

The displayed initial name comes from the Muse pairing request. The current Muse
adapter hardcodes device_name="Muse gadget" in both actell_pairing.c request
construction and actell_bridge.c authenticated companion.hello; claim carries no
name. Actell retains the received name and allows a local display alias after
activation. No device-model discovery supplies this default. Normal-path names
match, so the name alone does not establish a cause for the reported pending UI.

The phone pending_ack UI means local Allow has persisted the pending credential,
not that Muse received claim, saved it, completed authenticated hello or persisted
its own active state. Current retained companion logs do not cover the reported
manual re-pairing, so no specific live failure cause is established. The companion
agent reran real C hello parsing and SLAN worker tests; success, lost ACK, rejection
and storage failures behave conservatively. No product-firmware change was made
for this review, and no phone/board was accessed.

Actell now emits pairing.request.accepted, pairing.approved,
pairing.claim.prepared, pairing.ack.completed/active/rejected,
pairing.expired and pairing.stopped. Claim preparation is not delivery proof.
Rejected ACK reasons distinguish unavailable, missing client/context, name
mismatch, expired admission and storage failure. Only hashed request/client IDs
and fixed stage/reason codes enter the bounded log; no names, tokens or secret
material. An actual state-machine regression checks that claim alone does not
activate a client, a name mismatch is logged without activation, and the correct
ACK alone transitions to active. Authentication and activation rules are unchanged.

Validation: all 489 core cases passed in
`.build/validation/core.u5o9gh/Tests.xcresult`, including the new pairing-stage
regression. Unsigned iPhoneOS build passed
(`/tmp/actell-muse-pairing-stages-device.log`), as did all 7 offline packaging
checks and git diff --check. These are source/simulator/build results, not a
reproduction or resolution of the reported physical-phone pairing stall.

## 2026-10-17 — Pre-authentication HTTP 401 diagnostic reasons

RemoteRequestAuthenticator now retains a fixed local rejection reason for the
immediate synchronous verification attempt: malformed, clock_skew,
key_unavailable, signature_mismatch, replayed, cache_full, or
monotonic_clock_unavailable. Every attempt clears the previous reason first.
The original public Failure cases, time window, signature validation, live-key
lookup, nonce insertion and fail-closed cache limit are unchanged.

RemoteToolsService persists these as rpc.authentication.rejected with
`authenticated=false`, the connection tag and hashed unverified request/client
IDs. These events never impersonate authenticated companion.hello traces. HTTP
401 still exposes only the original generic Authentication failed message and
unauthorized/replay code; local reasons and key metadata never enter the response.
Headers, signatures, raw body, device name, key material and raw IDs are excluded.

For key_unavailable only, the controller can supply current metadata:
service_inactive, storage_unavailable, unknown_client, credential_missing,
pending_credential_present, active_credential_present, bootstrap_expired or
legacy_credential_unavailable. This does not reread the Keychain. An unknown ID
is not labelled expired or revoked without evidence; correlate its hash with
pairing.expired/stopped history when present. Diagnostic metadata neither restores
nor deletes credentials and does not change pending expiry or key retention.

Regression coverage checks distinct authenticator reasons (including nonce cache
capacity), reason reset on success, persistent rejection events for format/time/
key/signature/replay, unchanged generic 401 replies, and exclusion of raw IDs and
headers. All credentials and network admission are synthetic and loopback-only.

Validation of the final 401 diagnostic source: all 491 core tests passed in
`.build/validation/core.DPscJS/Tests.xcresult`; unsigned iPhoneOS build passed
(`/tmp/actell-muse-auth-reasons-device.log`). All 7 packaging/static checks and
git diff --check passed. No phone connection/query/install, credential deletion,
firmware flashing, Git commit or merge was performed. The newly recorded reasons
have not been observed on the reported physical request, whose cause remains
unproven until a current matching diagnostic event is available.

## 2026-10-17 — Actual rejection read from Xcode without user export

Following the user's instruction, the agent read the already-open Xcode Console
through native accessibility. No run, install, pause, reconnect, phone query or
remote action was triggered. The real request's connection trace shows parsed
RPC, local rpc.authentication.rejected with clock_skew, HTTP401/154-byte reply,
processed completion and connection close. The phone was foreground/unlocked with
an active service and healthy journal. This establishes the timestamp-window
rejection for that request, before key/signature/name/ACK checks; it does not
establish success or failure of those later checks or identify which wall clock
was wrong on its own.

A minimal private evidence summary is kept in ignored
`.build/validation/muse-xcode-console-2026-10-17.json`. No full Xcode tree, signing
metadata or unrelated console content was saved. The Muse agent received only
fixed stage/reason data and hashed correlation tags, and reported defects in
clock-readiness/SNTP initialization and timestamp sampling order. Companion fixes
and validation are tracked by that task; the phone time window remains unchanged.

Added DIAGNOSTICS.md and the AGENTS.md diagnostic entry: future investigations
first retrieve existing Xcode output themselves, request a full AX snapshot when
diff output contains no lines, keep device actions separately authorized, and
never substitute simulator fixtures or require user clipboard steps before
trying accessible evidence. Bilingual README entry points now reflect this.

## 2026-10-17 — Native diagnostic interfaces take priority over UI

The user clarified that autonomous extraction should prefer system services and
structured native interfaces, minimizing Computer Use. Updated AGENTS.md,
DIAGNOSTICS.md and both READMEs accordingly. Added a local read-only CLI collector
for existing xcresult console logs, Mac Unified Logging or existing text/JSON
console files. It stores only whitelisted stage/state fields in owner-only private
output, reports empty/unavailable sources explicitly, and never contacts a device.

Native capability checks on this host: scoped Mac log show returned zero matching
MuseAdmission events after obtaining local read access; five recent Xcode Run
bundles advertised console logs but returned empty items. xcresulttool get log
--type console is available. Xcode's installed mcpbridge returned that MCP access
is disabled; no service/security access was enabled. These observations explain
why the prior real-time console required fallback AX here, rather than establishing
that native diagnostics are generally unavailable. A current native console result
must contain the actual event before it replaces the prior clock_skew evidence.

Three collector privacy/empty-result tests, all seven static checks and diff check
passed. Native source checks were local-only; no phone operation, app change,
installation, pairing change, Git commit or merge occurred in this adjustment.

## 2026-10-17 — Authorized clock-fix firmware deployment and pairing completion

The human explicitly authorized flashing the prepared Muse firmware. The companion
agent verified the target and wrote only the application at 0x20000 (3,084,288
bytes), with readback verification. Wi-Fi/NVS/pairing records, partition table,
resources and the alternate slot were retained. Root did not access the serial
port or trigger phone RPC/tools. The firmware requires actual SNTP synchronization
this boot and samples the request time after readiness and discovery.

Initial passive observation had no clock or Actell HTTP event; it was not treated
as success or failure. The subsequent observation recorded one synchronization,
one successful Actell HTTP response, no new 401 and no panic. A read-only check of
the existing phone Xcode Console then found newly appended companion.hello.received
→ pairing.ack.completed → companion.hello.result authorized → HTTP200. This supplies
application-level pairing/authorization evidence beyond HTTP success alone. Old
clock_skew entries still present in the console were not labelled post-flash.

The native Run result still had no current console entries, so AX was used solely
as an existing-output fallback, without UI/device actions. A minimal owner-only
summary is in ignored `.build/validation/muse-clock-fix-flash-confirmed.json`;
companion observation is `local/validation/actell-clock-fix/observe.json` there.
This validates pairing/hello after clock correction. Screenshot, touch and remote
tool execution were not attempted or accepted by this check. No Git commit/merge.

## 2026-10-17 — Minimal pairing status layout

Removed the keep-Muse-online helper, centered pairing waiting/confirmation/
completion/ended/error content, and shortened the normal service footer to
“与 Muse 处于同一局域网。” Device-list status remains right aligned. Corrected
SwiftUI Label separator indentation after centering. No pairing/service behavior
changed. All 491 core tests passed (`core.NZLHNa/Tests.xcresult`); the two existing
Muse setup/pairing UI cases passed (`Muse-Centered-Status-UI.xcresult`), followed
by a passing final pairing UI check after separator alignment
(`Muse-Centered-Status-Final-UI.xcresult`). Native xcresult attachments confirmed
footer copy and centered completion content. Final unsigned iPhoneOS build and
diff check passed. Validation used only the isolated simulator; no phone install
or Git commit was performed for this UI change.

## Background listener retention (2026-10-17)

Ordinary backgrounding no longer stops the Muse listener or clears authenticated peer presence. Remote-run cancellation/lease loss also releases only the run, leaving listening enabled. Unfinished pairing still closes on backgrounding and is available again in the foreground without reopening its window. Manual Off, protected-data loss, transport failure and execution/storage fences remain effective. Keeping a listener does not grant a background execution lease or prevent system suspension.

Validation: all 491 core tests passed in `.build/validation/core.cJfLXA/Tests.xcresult`, including background authenticated hello/presence retention, background run cancellation with listener retention, foreground-only run admission, unfinished-pairing cleanup and manual Off. Seven packaging/security checks passed; unsigned iPhoneOS build succeeded. No physical-device installation, firmware flash or Git commit was performed.
