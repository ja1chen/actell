# Remote tools

This document defines the direct Muse Gadget tool interface, the Actell execution contract and the implementation boundaries. Pairing and transport authentication remain governed by [SLAN/1](SLAN-1.md) and [companion pairing](COMPANION-PAIRING.md).

## Tool interface

| Tool | Parameters | Behavior |
| --- | --- | --- |
| `actell.screenshot` | None | Capture a screenshot and return its image result. |
| `actell.tap` | `x`, `y`, `purpose` | Tap normalized display coordinates. |
| `actell.drag` | `from_x`, `from_y`, `to_x`, `to_y`, `duration_ms`, `purpose` | Drag between normalized display coordinates. |
| `actell.home` | `purpose` | Request the Home action. |
| `actell.list_apps` | None | Query available applications. |
| `actell.launch_app` | `bundle_id`, `purpose` | Launch an application. |
| `actell.type_text` | `text`, `purpose` | Paste text through the clipboard and Command-V path; no implicit tap or Return. System paste consent can still apply. |
| `actell.wait` | `duration_ms` | Wait locally in Gadget without opening a phone run or sending input. |
| `actell.call_status` | `operation_id` | Query the original call and any retained image without replaying it. |

`actell.rpc`, `actell.image` and `actell.view` are not model-facing tools. The authenticated RPC operations remain `capabilities`, `runs.open`, `runs.get`, `runs.cancel`, `tools.call`, `calls.get` and `images.get`.

Optional application launch arguments are not exposed by Gadget until platform array transport is verified. Internal Actell support does not establish platform transport support.

## Contract negotiation

`capabilities` preserves the legacy pixel-based `tools` schema and additionally returns:

- `input_contracts`: `image-pixels-v1`, `normalized-display-v1`.
- `independent_input`: `true`.
- `input_tools.normalized-display-v1`: schemas with integer coordinates from 0 through 1000. Other tool limits retain their existing validation.
- `image_retention_seconds`: `1800`.

Open a run with `input_contract: "normalized-display-v1"` and `image_contract: "thumbnail-v2"`. Omitting the input contract preserves legacy pixel behavior; unknown contracts are rejected. Reopening an existing run ID with a different contract or deadline is an idempotency conflict.

The input contract is fixed for the run and included in the resolved execution digest. Coordinate magnitude never determines the contract. Independent input rejects `observation`; callers cannot supply private underscore-prefixed execution fields. Legacy observation ownership, generation, geometry and 60-second admission checks remain separate from historical image retention.

## Coordinates and input authorization

`tap` and `drag` use integers in the inclusive range 0–1000, endpoint aligned to the current full interactive display. They require no image ID or prior screenshot. Mapping to the existing HID range uses `(value * 65535 + 500) / 1000` with integer division. Local Actell model tools retain their pixel interface.

The developer-service backend queries authenticated `getdisplayinfo` through a read-only native command (action 12, result kind 15), then verifies the size against current decoder geometry and the native geometry generation. The query performs no capture or JPEG encoding. Existing media preparation and decoding are still required for the current CoreDevice input route. Missing or inconsistent geometry returns `geometry_unavailable`; dimensions are never guessed from UIKit, a model table or an old screenshot.

Paired-device scopes permit execution without a separate authorization prompt for every call. Internally, each one-use authorization still binds the run, raw arguments, mapped coordinates, route/session and geometry token. Geometry is checked after authorization and at the native dequeue/Down fence. `geometry_changed` is preserved when raised. Changes after Down cannot be atomically excluded; uncertain delivery remains unknown and is never replayed.

## Execution ownership and background behavior

A run is an internal execution ownership scope. Remote calls use the shared action coordinator and execution lifecycle without creating an Agent conversation or task-history entry.

The current Gadget SDK supplies an invoke ID but no platform task identity, task-end event or cancellation notification. The fallback is one run per invoke. The owner closes it after the call reaches a terminal state. Task-level run reuse and immediate platform cancellation are not implemented.

Authenticated requests reaching the active service enter the shared execution pipeline without requiring a foreground scene, previous foreground invocation, matching continuation client or preexisting background-source receipt. Protected data, live client permissions, process-wide ownership and durable-state checks still apply. The runtime uses the actual scene and current background selections. Connection readiness, selected background mechanisms and ordinary deadlines determine execution outcomes.

A service continuation demand can retain the user's selected continuous mechanisms—audio, PiP and location—between calls while releasing phone execution ownership. A background request can establish that demand. It requests no additional permission and enables no unselected mechanism. Service shutdown, revocation, lock, explicit stop, setup failure or external execution stop releases it. Per-run system tasks and execution leases remain managed by the shared lifecycle. Local service activation and configuration retain their unlocked-foreground setup checks; those are separate from incoming run admission.

An unready control route can create a run so that the runtime establishes background demand before tools attempt `connectIfNeeded`. In-flight connection setup is awaited. Existing busy/reserved ownership and session fences remain; route changes are blocked while the bridge is retained. Connection recovery sends no input and never replays an action.

### Completion and release

`runs.get` and `runs.cancel` return `execution_released: boolean` for the queried run. A terminal or closed run may still be draining asynchronous input/media cleanup. The flag does not promise global idleness or erase a confirmed action result.

Actell serializes cleanup on the main actor. Draining remains set across asynchronous release; owner, active run and draining state are cleared together without an intervening suspension. Cancellation records its durable fence before transport cleanup and waits for draining. Late callbacks cannot replace an unknown or cancelled result.

Gadget closes its owned screenshot run after capture reaches a terminal state, then downloads the historical image. Image transfer therefore does not retain phone ownership. Failure, unknown and malformed-receipt paths also perform ownership-aware cleanup. A busy response or a different run ID never authorizes cancelling another run. Historical status queries neither acquire nor release execution ownership.

If `runs.open` loses its reply, recovery queries the original run ID read-only. Cleanup requires confirmed ownership. Neither `runs.open` nor `tools.call` is resent as a recovery action.

### Timing

There is no new 60-second run maximum or five-second idle-release rule. Existing explicit run/call deadlines and the one-hour run admission ceiling remain.

| Mechanism | Current bound or interval |
| --- | --- |
| Control connection recovery | Existing 20-second bounded wait. |
| Gadget queued work | 40-second budget from queue entry. |
| Phone deadline | Remaining Gadget budget minus five seconds for result/cleanup handling. |
| Platform tool registration | 60-second timeout. |
| Asynchronous call-state query | 500 ms polling interval. |
| Release-status query | 100 ms interval, at most 20 polls, ending immediately on confirmed release. |

These are deadlines and polling intervals, not mandatory sleeps or cooldowns. Release polling is not a two-second total HTTP timeout: network requests share the remaining job budget. Explicit `actell.wait` is local to Gadget. Connection recovery and fresh-frame preparation are actual I/O waits.

## Receipts and recovery

Call receipts preserve `run_id`, `call_id`, `state`, `result` and `error`. `effect` supplements state:

| Effect | Meaning |
| --- | --- |
| `not_sent` | No input dispatch was recorded. |
| `acknowledged` | The input service acknowledged delivery; visual goal completion is not established. |
| `may_have_occurred` | Dispatch or delivery is uncertain; do not replay. |
| `not_applicable` | Screenshot, read or wait rather than an input effect. |

Legacy entries can omit `effect`; omission is not proof of nonexecution. Interrupted durable entries are restored as unknown. Transport timeout and `not_found` are also not proof of nonexecution. Preserve original error codes and operation identity through result forwarding so callers can reconcile the original call.

Gadget durably binds each platform invoke to original run/call IDs and an argument digest before submitting an action. Duplicate invokes query those IDs instead of creating replacements. Restart retains identity and does not resume or replay unfinished work. Storage-capacity and persistence failures reject new actions; the ledger is not automatically reset.

Screenshot results retain `image_id`, `generation`, `width`, `height`, `geometry`, `image_contract`, `mime_type`, `byte_count`, `captured_at_ms`, `expires_at_ms` and `image_status`. A normalized run also returns `coordinate_space=normalized-display-v1`. Capture success and image delivery are separate outcomes: metadata alone must not be presented as successful image delivery.

`calls.get` refreshes `image_status` without capturing again. If cached pixels are unavailable, it preserves the original terminal state and effect while reporting `image_status=unavailable`. `images.get` returns `image_unavailable`, and local diagnostics retain the underlying cache error. Neither path implicitly recaptures or replays.

## Historical screenshot storage

`thumbnail-v2` results are retained for 30 minutes from the original capture time. Repeated reads do not extend expiry. The protected, atomic, backup-excluded disk cache survives run closure, later captures and process restart.

`images.get` uses the original run ID, image ID and generation with live authentication and screenshot permission checks. It does not acquire execution ownership. Each record validates client/run/image identity, generation, dimensions, geometry and JPEG SHA-256. Identity-derived filenames are compared using standardized filesystem paths; raw URL object equality can reject equivalent paths.

Storage limits are 64 unexpired records, 256 KiB per JPEG and 16 MiB total JPEG bytes, with JSON/base64 metadata overhead additional. Thumbnail maximum edge length is 1280 pixels. Capacity is checked before capture. Expired records are removed on access/admission; unexpired results are never silently evicted to admit a new one. Full storage returns `image_storage_full`. Revocation clears the client's cached results and permission changes use the existing revocation fence.

Malformed historical records are isolated so one damaged entry does not prevent unrelated screenshots or service startup. Such records still consume a slot and their maximum byte budget until expiry or authorized deletion. Invalid bytes are never returned.

Binary responses retain JPEG identity/hash headers and include `X-Actell-Captured-At-Ms` and `X-Actell-Expires-At-Ms`. Historical availability does not extend action authorization, execution deadlines or legacy observation validity.

## Implementation and validation entry points

- [RemoteToolsService.swift](../../ios-app/PhoneAgent/Remote/RemoteToolsService.swift): authenticated RPC, durable call state, ownership and cached-image access.
- [RemoteToolRuntime.swift](../../ios-app/PhoneAgent/Remote/RemoteToolRuntime.swift): shared execution lifecycle and action dispatch without Agent sessions.
- [NCMDeviceBridge.swift](../../ios-app/PhoneAgent/Bridge/NCMDeviceBridge.swift): control recovery, session ownership and geometry/dispatch fences.
- [RemoteImageGeometry.swift](../../ios-app/PhoneAgent/Remote/RemoteImageGeometry.swift): coordinate mapping, thumbnails and protected cache.
- [RunExecutionScheduler.swift](../../ios-app/PhoneAgent/Background/RunExecutionScheduler.swift): shared background execution demands.
- [RemoteImageGeometryTests.swift](../../ios-app/PhoneAgentTests/RemoteImageGeometryTests.swift), [RemoteToolRuntimeTests.swift](../../ios-app/PhoneAgentTests/RemoteToolRuntimeTests.swift), [SimpleLANRPCTests.swift](../../ios-app/PhoneAgentTests/SimpleLANRPCTests.swift) and [NCMDeviceBridgeTests.swift](../../ios-app/PhoneAgentTests/NCMDeviceBridgeTests.swift): cache, RPC, background, connection recovery and one-use input regressions.
- [iOS validation instructions](../../ios-app/README.md) and [diagnostics](DIAGNOSTICS.md): build/test and structured error/release correlation workflows.

Regression coverage must preserve contract conflicts, schema validation, zero-capture input, one-use grants, geometry changes, ownership exclusion, background demand before connection recovery, cancellation/draining, unknown-result nonreplay, restart, cache corruption isolation, capacity accounting and original image retrieval after run closure. Gadget coverage must include persistent deduplication, write faults, ownership-aware cleanup, lost receipts and image-result serialization bounds.

Source checks, host/simulator tests and unsigned builds establish different evidence from deployment and end-to-end operation. Runtime acceptance separately verifies image visibility, physical input and orientation, route changes, visual task completion, real timeout/lease behavior, cancellation, storage capacity and interrupted persistence. Private logs, deployment inventories and per-run test artifacts do not belong in this shared contract.

## Remaining boundaries

- The platform recovery route is unconfirmed when the entire initial receipt is lost before the caller learns the operation ID.
- Platform task identity/end/cancellation events are unavailable in the current Gadget SDK; per-invoke ownership remains the fallback.
- Optional application launch argument transport remains unverified.
- Actell's durable journal retains accepted identities with 10,000-entry run/call bounds. Long-term archival must preserve rejection of retired identities. Neither the Actell journal nor Gadget's bounded durable ledger provides indefinite capacity; silently clearing accepted identities is not a migration strategy.
