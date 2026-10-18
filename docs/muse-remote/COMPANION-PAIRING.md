# Actell Simple LAN pairing — SLAN/1

The normative wire contract is [SLAN-1.md](SLAN-1.md), SHA256
`d1ecce424490d4f8e7ea3dc927619f04b7c3fe8b9b522ee2dcacd286c23cee75`.
This channel is independent of official Muse account/device setup. Credentials are
not official Muse tokens. See [implementation and validation](VALIDATION.md).

## User flow

1. Connect both devices to trusted Wi-Fi. In Actell → Settings → Extensions → Muse Gadget,
   explicitly enable **Muse Gadget Service**. The switch defaults off and the
   page shows actual service status. Opening this page never starts the service.
2. Once the listener is running, choose **Add Muse** to open a 120-second window.
   On Muse choose **Connect Actell**. One compatible device with an open pairing
   window is requested automatically; no service-name list is shown. If several
   compatible windows are open, Muse stops and asks the user to keep only the
   target phone’s Add Muse window open. It never randomly selects or fans out.
3. Actell shows the device name with **Allow** and **Reject**.
   The name is not a cryptographically verified identity. There is no additional
   user confirmation round.
4. After approval, Muse claims the new credential, persists it, then sends the
   existing authenticated `companion.hello`. Only then does Actell show **Paired**.
   Screenshot/app-list/control permissions default on after successful pairing;
   each can be disabled on the device permission page. Permitted Muse actions execute without per-action prompts.
5. Turning the service off closes connections and cancels unfinished pairing keys.
   Completed devices and their permissions remain. Re-enabling does not open a
   new enrollment window. Removing a device deletes its live key and fences work.

## Trust and network boundary

The first enrollment intentionally uses trusted-LAN TOFU. It does **not** protect
against an active attacker on the same LAN. Subsequent connections must retain the
exact leaf DER SHA256, stable `.local` SAN name, certificate validity checks and
per-client ACTELL1 HMAC. Bonjour names/TXT are locators, never trust or pin sources.
A new certificate must not replace a saved pin automatically.

The phone is always the HTTPS server, reusing the existing listener and app-owned
P-256 identity. The private key stays in Keychain. Muse is always the HTTPS client.
Normal companion admission requires Wi-Fi plus RFC1918 IPv4; public, loopback,
IPv6, link-local-only and proxy-forwarded pairing requests are rejected. There is
no public relay or port forwarding. Initial client-side TOFU and exact pin
verification belong to the corresponding Muse implementation and physical tests.

## Enrollment and RPC

- `POST /v1/pair/request`: strict JSON up to 512 bytes, RAM-only SHA256 claim token
  and original-body hashes, one pending request, at most three accepted requests
  per physical app window, local Allow/Reject. Identical requests are idempotent;
  a changed body/token for the same live ID cannot replace it.
- `POST /v1/pair/claim`: same bearer token and request ID. Approval first persists
  a new unique client/key as `pending_ack`, scopes empty. Repeated claims return
  the same material, with a decreasing 300-second deadline; no plaintext token is
  stored or returned. Responses are `Cache-Control: no-store`.
- `POST /v1/rpc`: unchanged raw-body ACTELL1 HMAC and nonce/time replay checks.
  A pending client can only send `companion.hello` with exactly `device_name` and
  `protocol:1`; ordinary operations fail. On a valid timely hello, the phone
  persists active state with all three default scopes before returning
  `pairing_state:"active"`. Retries preserve later user permission changes. Zero-scope
  `state:"pending_authorization"` remains correct and means permissions are off.
- Lost ACK responses are retried using the same client/secret with a fresh RPC
  request ID, nonce and timestamp. Already active clients return the same pairing
  state. The claim token is retired on the first successful activation.

Secret, state and SLAN permissions are authoritative in a single device-only
Keychain envelope; UserDefaults is only display metadata. All uncompleted
`pending_ack` records are removed when loading a store after restart. No claim
context is restored across process death. At 300 seconds, stop, cancel or revoke,
the pending key is removed before future requests can authenticate. Storage
failures fence the affected SLAN credential path and stop admission.

The service remains subject to iOS lifecycle, lock and network restrictions.
An enabled switch is not a background execution lease. Muse still needs valid
certificate/RPC time; this change does not solve offline cold boot. Source,
simulator and unsigned builds are separate from signed physical-device and Muse
interoperability acceptance.

Legacy exact-source developer APIs and provenance remain available separately;
they cannot promote a SLAN pending client through the older local confirmation
path. Screenshot generation/geometry, request journals, no replay of uncertain
control results and scope checks retain their existing rules; permitted Muse actions
use automatic task authorization with durable execution records.

## Discovery identity

TXT `host` advertises the existing stable certificate SAN, equal to claim.host.
Muse connects to SRV addresses/port and uses this host for TLS verification/SNI;
the stable host need not resolve. Claim must match the temporary host and leaf
pin. After pairing, broadcasts cannot replace saved host/pin; only the network
address can relocate. Missing host during new pairing requires an app update.

## Foreground restoration

The switch persists the user's explicit choice before startup admission, independently
of listener status. Entering the background without a delivered execution lease
still stops the runtime and cancels unfinished pairing. The switch stays on;
returning to an unlocked, idle foreground restores only the listener using the
same identity and active clients. An in-progress drain finishes first. Restoring
never opens a pairing window, restarts a run, replays an action, or changes scopes.
Manual Off cancels deferred restoration. A fresh installation defaults off; a
new process restores the last saved choice, including after a failed start. Runtime
failure is shown separately; enabling a switch does not promise iOS residency.

## Muse action confirmation policy

Paired clients with the relevant enabled scope execute without per-action prompts.
This is a local Muse policy using the existing task authorization path, including
approval/execution records and one-use dispatch guards. The remote request cannot
select or upgrade authorization mode. Device permissions, deadlines, fresh image
references, foreground/background execution eligibility, stop/lock handling and
no-replay semantics remain enforced. `capabilities.input_approval` is now
`not-required`; `approval` is `paired-device-scopes`. Initial pairing still needs
local Allow. Local non-Muse task behavior is unchanged.

## Presence display

Online means recent authenticated communication, not a persistent TCP socket.
The phone refreshes presence on an accepted hello or authorized RPC, using a
monotonic receipt time. It allows 90 seconds of silence to accommodate the
Gadget's 30-second post-probe interval, discovery/TLS time and one failed probe.
This grace period affects display only, not authentication or execution deadlines.
The UI reacts to receipt updates and reevaluates expiry every second, without
using the previous UI timer timestamp. Service stop and device removal clear
presence immediately; invalid authentication cannot extend it.

## Muse record retention

Muse Cancel stops transmission and preserves saved pending/active credentials.
Authentication, network or storage-read failures do not imply deletion. A rejected
hello retains the reconnect entry and suspends background retries until a user
retry or explicit action. Only explicit Forget deletes the local Muse record.
The phone still revokes expired/uncompleted keys and requires a valid authenticated
hello; retaining a Muse record does not restore a revoked phone credential.
