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
For a closing response the connection remains in `phase=drain` until peer EOF,
error, explicit stop or the original write deadline. Reusable responses instead
emit `http.connection.reusable` and wait for the next independently authenticated
request, with a bounded idle deadline. `http.peer.ended` during `read`, `handler`
or `write` can be an early half-close and does not establish response delivery.
`http.pipeline.rejected` identifies unsupported overlapping requests; a bounded
next request buffered during writing is parsed only after the prior send and
handler complete. `http.deadline` distinguishes read/idle/write/drain stalls.
Correlate these with the client's received length and digest when diagnosing image delivery.
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

For asynchronous tool failures, `tool.execution.failed` records the hashed run and
call IDs, delivery state and fixed error code before the terminal receipt is read.
`geometry_unavailable` means input geometry preparation failed, not that the
requested coordinate was out of bounds. `geometry_reason` distinguishes metadata
query/parse errors, missing or failed decoding, size mismatch, pending frames and
geometry changes. `native_stage` and `native_cause` retain protocol categories;
for metadata queries, cause 2 means timeout, 1 protocol failure and 3 invalid
metadata. No peer payload, coordinates, purpose or geometry credential is logged.
The same typed geometry failure is written to the background trace as
`input.geometry.failed ... connectionRetained=true`. It leaves the authenticated
phone-control session available. `control.operation.failed` with stage 12 or
`reason=closed` records
actual session closure and follows the normal disconnect path. Cancellation,
malformed ABI events and uncertain input delivery are not converted to recoverable
geometry errors. Geometry checks retain their existing deadlines and never replay
an input action. A failure before dispatch has `effect=not_sent`; later failures
continue to use the existing conservative delivery receipt.

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

## Screenshot performance correlation

`performance.*` rows contain `elapsed_ns`, `sample_uptime_ns`, `succeeded` and
optional `bytes`. The fixed stages are `control_preparation`, `discovery`,
`pair_socket`, `pair_verify`, `pair_validation`, `tunnel_listener`, `tunnel_socket`,
`tunnel_tls`, `service_socket`, `service_discovery`, `developer_readiness`,
`media_start`, `fresh_frame_wait`, `original_encoding`, `thumbnail_encoding`,
`cache_write`, `result_ready` and `release`. Result-ready includes execution and
journal persistence; it is not an additional delay to add to its child stages.
Recovery sample uptime is Swift's receipt time; elapsed duration is measured
inside Rust. Do not subtract phone and Gadget uptimes.

The validated 64-lowercase-hex `operation` field comes from optional
`X-Actell-Operation-Id`; it is an unsigned hint for matching Gadget events, not
proof of request ownership. `diagnostic` still hashes the individual request ID,
with hashed run/call fields identifying the original work. Native decoder spans
capture the same context across the decoder queue; accepted execution retains it
even when the waiting HTTP request times out. Never log image pixels, arguments,
HMAC headers or certificate material. See [the negotiated contract](REMOTE-TOOLS.md#optional-latency-capabilities).

Use these stage durations to distinguish fresh-frame waiting from encoding,
cache persistence, control recovery and release. Test-loopback success establishes
framing and state-machine behavior; only a separately authorized physical run can
establish the end-to-end screenshot-to-model latency improvement.

### Exact fields and analyzer export

The existing on-disk log is an array of event objects at
`Library/Application Support/PhoneAgent/Remote/muse-admission-v1.json` inside the
app container. Each object has `time`, `uptime`, `stage`, optional `diagnosticID`,
`client`, `run`, `code`, and `state`. `diagnosticID`/`client`/`run` are 16 lowercase
hex characters (first eight SHA-256 bytes of their original IDs). The raw request
UUID is not stored. `state.call` uses the same hash. Optional keys are omitted.

For `stage=performance.<stage>`, `state` contains these string-valued fields:

| Field | Format and meaning |
| --- | --- |
| `operation` | Optional 64 lowercase hex; validated unsigned Gadget correlation hint |
| `elapsed_ns` | Decimal unsigned integer; stage duration measured monotonically |
| `sample_uptime_ns` | Decimal unsigned integer; monotonic sample time on this phone, recovery samples timestamped on receipt |
| `succeeded` | `true` or `false`; stage outcome |
| `bytes` | Optional decimal nonnegative byte count |
| `call` | Optional 16 lowercase hex hash of original call ID |

Unified Logging uses category `MuseAdmission`, with the existing format
`stage=<stage> diagnostic=<hash-or-dash> run=<hash-or-dash> code=<code-or-dash> state=<Swift string dictionary>`.
Dictionary ordering is not significant. Both the native console and the structured
on-disk format are accepted by the same allowlisted collector:

```sh
python3 tools/muse-remote/collect_diagnostics.py \
  --input .build/validation/existing-muse-admission.json \
  --output .build/validation/actell-diagnostics.json \
  --performance-jsonl .build/validation/actell-timings.jsonl
```

The optional JSONL uses `source="actell"`, `operation_id`, `phase`, numeric
`elapsed_ms=elapsed_ns/1000000`, optional `ok` (0/1), `bytes`, `diagnostic_id`, `run`
and `call`. Rows without a valid operation hint are retained in the diagnostic
report but omitted from the cross-side JSONL. Output files are owner-only.

Main-stage names map to the Muse analyzer as follows: `control_preparation` →
`control_prepare`, `fresh_frame_wait` → `fresh_frame`, `original_encoding` →
`original_encode`, `thumbnail_encoding` → `thumbnail_encode`; `media_start`,
`cache_write`, `result_ready` and `release` keep their names. Recovery stage names
also stay unchanged. An analyzer must allowlist those additional recovery names
to include their distributions; they must not be inferred from the aggregate
`control_prepare` duration. Raw request UUIDs can be hashed with the same SHA-256
prefix rule to match `diagnostic_id` without logging them on Actell.
