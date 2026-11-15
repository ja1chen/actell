---
name: ios-operation
description: Operate an iPhone through screen observations and authorized device tools. Use for reading the screen, navigating Home, finding or launching installed apps, tapping, dragging, and inserting text.
version: 1.0.3
---

# iOS Operation

Device tools prepare and check their connection internally. Use their results to decide whether the requested operation can proceed.

## Observe and act

The `screenshot` tool can provide an image, accessibility content, or both, according to its current schema. When it offers a `mode` choice, prefer accessibility for text and structure, a screenshot for visual layout, or both when useful. If accessibility is unavailable or insufficient, choose a screenshot on the next call when supported. Coordinate units and bounds come from the tool schema and returned observation.

1. Observe when you need to read the UI or choose tap/drag coordinates. Use the latest device observation, never another image or attachment. The app binds the observation automatically; do not supply an image identifier.
2. Identify a visible target. Off-screen accessibility nodes and a requested app's tree do not prove a target is currently on screen. Use `tap` or a straight `drag` with a short public `description`.
3. Observe again when the next decision depends on unknown UI state. Observations have no time-based expiry; actions and waits retain the reference, and each new observation replaces it. Known sequences can use consecutive actions without mandatory captures between steps or after waiting.
4. `screenshot` handles acquisition internally; do not add a `wait` just to obtain a frame. Use `wait` when the app task needs time, such as waiting for a network result.

## Home and applications

- Use `home` to return to the Home screen; it does not unlock the phone.
- Find the requested app with `list_apps`, filtering by its name or identifier when possible. Use the returned exact `bundle_id` for `launch_app`; do not invent identifiers or enumerate unrelated apps unnecessarily.
- Send launch `arguments` only when the target app is known to support them and they serve the user's request. An already running app may ignore new arguments.
- These tools do not require a screenshot. Observe afterward only if the next decision needs the app's visible state.

## Text

Focus the intended editable field before `type_text`; observe and tap when needed to locate it. The tool pastes the exact text through the clipboard and does not submit it. iOS may request paste consent for dtpasteboardd: do not resend text; handle one consent only for the exact user-authorized text and target, otherwise ask the user to handle it. Verify acceptance when the next step depends on the entered text.

## Errors and interruptions

Preparation failures may leave observations available; do not assume every error disconnected the phone. After an uncertain input result, use an observation when it can resolve what happened before choosing the next action. A reconnect changes the session and invalidates old approvals and coordinate references; obtain a new observation before coordinate input.
