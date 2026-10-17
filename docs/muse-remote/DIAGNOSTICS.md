# Muse diagnostics through native services first

The agent retrieves evidence itself. Copy Diagnostic Log is an optional manual
fallback, not the default prerequisite for investigation. Its output is not
automatically delivered to the agent.

Prefer native interfaces in this order:

1. Existing structured app/test logs and Xcode `.xcresult` console logs through
   `xcrun xcresulttool get log --type console --path <bundle>`.
2. macOS Unified Logging through `/usr/bin/log show` scoped to
   subsystem `com.ja1chen.PhoneAgent`, category `MuseAdmission`. This queries the
   Mac store; it is not an implicit remote query of an iPhone. An empty result
   does not prove there were no phone events. Sandbox access failure is distinct
   from an empty result.
3. Xcode's native MCP bridge (`xcrun mcpbridge`) when its service is already
   enabled. Discover the actual available tools before use and only invoke
   read-only logging tools. Do not enable new MCP/security access, attach a
   debugger or run the app merely to obtain old logs.
4. Computer Use/AX only when the native paths are unavailable or contain no
   current evidence. No user clipboard work is required before trying these paths.

The local CLI collector filters native console text/JSON to fixed stage fields:

```sh
python3 tools/muse-remote/collect_diagnostics.py \
  --result-bundle <existing-run-or-test.xcresult> \
  --output .build/validation/muse-native-diagnostics.json

python3 tools/muse-remote/collect_diagnostics.py --unified --last 30m \
  --output .build/validation/muse-native-unified.json
```

`--input <existing-text-or-json>` can parse a previously collected console.
Outputs are owner-only and contain no raw console/headers/body. `no_matching_events`
is an explicit empty result, not success; `source_unavailable` identifies a tool or
access failure. The collector never selects, contacts, launches or reconnects a
device. Run results may expose a console category with an empty items array, so
check actual event content before declaring the native path sufficient.

For this local investigation, Unified Logging returned zero matching Mac events;
five recent Xcode Run results had empty console items; the installed mcpbridge
reported that Xcode MCP access was disabled. No service was enabled to work around
that restriction. The earlier AX fallback supplied the actual clock_skew evidence.
Do not generalize that current limitation into using AX first on future tasks.

Use the already-running Xcode window for this checkout only as a fallback. Reading its existing
console does not require launching/installing the app, attaching another debugger,
querying a phone, or making an RPC. Do not click Run, Stop, Pause, Clear Console,
Reconnect or pairing actions to retrieve logs. Device actions still require the
user's current authorization. Never confuse simulator fixtures with phone output.

With the native Computer Use API, initialize a binding in its own first call:

```javascript
let xcode = await cua.getApp("Xcode");
```

Then read a full AX snapshot without printing the project/settings/source tree:

```javascript
let snapshot = await xcode.getAXState({ emit: false, disableDiffing: true });
let stages = snapshot.split("\n").filter(line => /^stage=/.test(line));
nodeRepl.write(stages);
```

Use the returned window path, running target and Console element to confirm the
checkout and process. A diff-only AX snapshot can contain no log lines even though
the existing console is populated; request a full snapshot for extraction. If the
console is hidden or filtered, inspect fresh AX state and reveal/adjust only the
existing console view. Keep raw snapshots local; they can contain unrelated source,
settings and signing information. Prefer the fixed Muse stage lines. Do not read
the general clipboard or use credential-bearing files as a logging shortcut.

Save a minimal evidence summary under ignored `.build/validation/`, with the source
(Xcode existing console), observation time and these fields when present:

- stage, diagnostic ID and fixed code;
- connection tag, HTTP route/status and response byte count;
- foreground/protected-data/service/journal/authenticated flags;
- local key_state and pairing approval/claim/ACK/expiry/stop stages.

Correlate request.parsed → authentication/operation result → response.queued →
response.processed → peer.ended → connection.closed using the connection tag.
`http.response.processed` means local stack processing, not complete peer receipt.
After that event the connection remains in `phase=drain` until peer EOF, error,
explicit stop or the original write deadline. `http.peer.ended` during `read`,
`handler` or `write` can be an early request-side half-close and does not establish
response delivery. `http.pipeline.rejected` identifies unsupported extra request
bytes; it never dispatches another RPC. `http.deadline` in `write` versus `drain`
distinguishes pending send processing from waiting for peer completion. Correlate
these with the client's received length and digest when diagnosing image delivery.
A queued reply alone is not delivery proof. A claim.prepared event is not proof Muse received it.
Authentication-rejected identities are unverified even though IDs are hashed.

For phone-control recovery, correlate `run.background_configured` with
`control.connection_wait`, `control.connection_ready` or `control.connection_failed`
using the hashed run ID. `control.connection_unavailable` identifies a setup
prerequisite failure; `control.connection_timeout` identifies the bounded connection
wait expiring. These stages contain no tool arguments, addresses or failure text.
`background_enabled` records the execution setting; `background_selected`,
`background_desired` and `background_effective` distinguish configured options,
continuous-driver demand and actual continuous-source receipts. An empty effective
value means no continuous source receipt, not an omitted field. Per-run system-task
leases are separate and are not included in that continuous-source field.
`background_continuity` identifies demand retained between invokes, without phone
ownership. Compare these with `control_route`, `control_ready`, `control_running`,
`control_reserved`, `control_has_record`, `control_background` and
`control_failure_present`; service/Wi-Fi connectivity alone is not phone-control
readiness. Request outcome events include the same state snapshot. Never infer
successful background execution from demand alone.

`run.release_started` and `run.release_complete` bracket actual owner cleanup.
The latter includes monotonic `release_elapsed_ms`; a missing completion event
distinguishes unfinished cleanup from repeated new-run busy rejections. These
events add no cooldown. `image.result_unavailable` retains the underlying fixed
cache error code locally while the original terminal call receipt stays readable
with unavailable pixels; do not replay the screenshot to repair its history.

Local pre-authentication 401 reasons are malformed, clock_skew, key_unavailable,
signature_mismatch, replayed, cache_full and monotonic_clock_unavailable. The
network response remains generic. clock_skew means the parsed request timestamp
failed the existing 60-second check; it occurs before key/signature/ACK validation.
Do not conclude those later checks succeeded. Do not relax the time window or
replay an action to diagnose it. A plausible board RTC/build date is not proof of
synchronization with the phone.

For key_unavailable, current metadata may identify service/storage/unknown-client
states. Unknown client does not prove historical expiry or revocation. Correlate
with pairing.expired/stopped when available. Successful local Allow is not final
pairing: Muse must receive claim, save its pending identity and complete the
existing authenticated hello before the phone marks active.

If current evidence is genuinely unavailable, report the inaccessible window,
missing process/history or actual tool error. Do not substitute old fixtures or
require user clipboard work before trying the accessible Xcode console.
