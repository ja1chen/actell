# iOS Agent tools

The normal Agent registers screenshot, tap, drag, home, list_apps, launch_app,
type_text and wait. The demo keeps its synthetic screenshot/tap/drag/wait/finish
set. The retained local capture bridge reports unsupported capabilities through tools;
normal conversation has no device-connection preflight requirement. App startup
attempts to restore an existing paired connection without requiring the Settings
page. Device tools share connection preparation and wait up to 20 seconds while
verification/reconnection is pending; unpaired devices still need system pairing.
Explicit cancellation interrupts the wait. A new connection generation clears
old images/action grants, but fresh reads and newly authorized system actions can
bind to it without restarting the Agent run. Failed dispatched input is never
retried by connection preparation. Scene backgrounding does not close transport;
returning to foreground schedules a liveness check when maintenance is idle.

Home, launch and typing use an independent single-use action authorization,
approval digest, authenticated session generation and per-run operation ownership.
They do not require a screenshot. Tap/drag additionally require current screenshot
coordinates and consume a single-use approval before dispatch, retaining the coordinate
reference for subsequent newly authorized actions. Successful actions and waits do
not force another capture. An uncertain action is journaled as outcomeUnknown;
reconnects, process recovery and fresh images never replay it. App queries are
read-only and expose only name, bundle identifier and version. New DDIs use
advertised streamapplist rather than the non-responsive older listapps endpoint.

The C ABI adds actions 7 Home / 8 list / 9 launch / 10 text. The command API copies
bounded JSON synchronously; pending input bytes are zeroized on drop. Swift and
Rust both validate text and launch argument bounds. Errors expose numeric local
categories rather than remote payloads. Home and keyboard HID use the existing
owned DisplayService session. All text now uses the general pasteboard and Command-V, replacing clipboard
contents. Whole input is validated before I/O: at most
8192 UTF-8 bytes, nonempty and without NUL. No old clipboard is read and no extra
Return, retry or partial prefix is sent. Paste may require iOS consent; pending
consent must not cause text to be resent. Previously registered remote virtual
keyboards are not blindly removed by guessed service ID; closing the old session
and checking software-keyboard restoration still requires device verification.
Observations are chosen according to the task, rather than required after every
action. Tool receipts describe the operation without prescribing another capture. Tool failures, including uncertain input delivery, return to the
Agent loop without pausing the run or disabling all later inputs. The failed
call remains outcomeUnknown in the durable journal, its image is consumed, and
no transport resend occurs. The Agent chooses its next step from available evidence; uncertain actions are
never blindly repeated. Lost connection generations are tool errors;
explicit run cancellation still stops execution. Process recovery never resumes
an old dispatch.

Screenshot service connection, response and PNG validation failures are scoped to
that read-only request. Swift retains the authenticated native handle and App
session generation, reports the stage/cause, and clears the previous frame's
input authorization. A later screenshot is a new explicit tool call; no capture
or input is automatically resent. This does not prove a failed tunnel is healthy:
worker closure, cancellation, malformed ABI events and failed connection
maintenance still revoke it. When disconnected, tools retain the recorded cause
instead of replacing it with a generic Settings instruction.

launch_app accepts up to 32 process arguments. It does not kill an already running
app, and such an app may ignore new arguments. Arguments are not URL parameters;
the target must implement their meaning. The protocol does not by itself provide
checkpoint restoration or background permission.

## Built-in skill

PhoneAgent/BuiltinSkills/ios-operation/SKILL.md is shipped as an immutable bundle
resource. Its stable ID and content revision participate in the existing skill
catalog and paginated load_skill path, without entering user-imported archives.
Only metadata is attached initially. The system prompt retains authority and
safety rules and requests the relevant skill before UI operations. Tool schemas
continue to describe parameters and results. Skill text cannot expand permission.

## Video and cleanup

Screenshots reuse the owned DisplayService stream and decode to JPEG. Frame freshness, content rectangles, queue limits and recovery follow [VIDEO-GEOMETRY.md](VIDEO-GEOMETRY.md). Media cleanup uses the negotiated stream identifier and validates the remote reply; abrupt transport loss remains unconfirmed. See [stop and release](../../docs/CONTROL-SESSION-TEARDOWN.md).

## Independent recovery

The ESP32 firmware only relays bytes. It cannot authenticate or relaunch the controlling App independently after that App stops. `launch_app` requires a live authenticated controller and does not restore checkpoints or grant background execution time.

Device acceptance and remaining limits are in [COMPATIBILITY.md](COMPATIBILITY.md).
