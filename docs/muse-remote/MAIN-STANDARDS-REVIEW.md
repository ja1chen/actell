# Main-branch standards review — 2026-10-17

Scope: resolve the user-started merge, then review Muse additions against the
merged `AGENTS.md`, `DESIGN.md`, localization audit, and background execution
architecture. This review does not initiate another merge or create a commit.

## Findings and changes

- Resolved seven conflicted paths by retaining Muse execution ownership,
  screenshot disclosure and TLS dependencies alongside main's localized UI and
  background coordination. Regenerated the Xcode project after removing the old
  Intents catalog; the app and widget use the shared catalog.
- Replaced 232 hardcoded display literals in 14 files with English localization
  keys, adding 193 paired English/Simplified Chinese entries. Existing main
  translations retain their contents and ordering. Dynamic messages use complete
  localized sentences; names, protocol identifiers and synthetic fixture values
  remain untranslated.
- Simplified ordinary setup hints and failures: removed a redundant device-list
  footer and internal execution/geometry terminology. Retained the data-recipient
  disclosure and direct-execution permission explanation. Technical connection
  configuration remains restricted to the explicit Debug entry.
- Migrated the independent remote runtime to the shared background coordinator's
  selected mechanisms and per-run demand. Remote requests do not initiate a
  location permission prompt or expand an existing run's allowed mechanisms.
  Cleanup releases demand. The remote runtime still creates no Agent conversation;
  foreground admission, delivered leases, locking, execution ownership, deadlines,
  screenshot validity and no-replay checks remain in place.
- Kept native credential error codes and underlying errors available to diagnostics
  while presenting localized recovery guidance. Diagnostic stages, error codes,
  hashes, JSON fields and the shared SLAN contract are unchanged.

## Validation

- Full core: 529 tests passed; both English and Simplified Chinese Muse setup UI
  tests passed in `.build/validation/Muse-Merge-Standards-Final.xcresult`.
- Localization audit: 1,248 paired entries; 4,738 Swift literals and 2,900 compiler
  entries checked across simulator/device intermediates.
- Seven source/security packaging checks and three diagnostic collector checks
  passed; the shared SLAN contract hash is unchanged.
- Final unsigned iPhoneOS build succeeded. All 18 follow-up credential,
  localization, connection and runtime tests passed in
  `.build/validation/Muse-Merge-Credential-Final.xcresult`, including localized
  NSError guidance with preserved native codes.

Testing uses the isolated simulator and unsigned iPhoneOS builds. No physical-device installation, remote
phone request or firmware operation is part of this review.

Git: all seven conflict paths are resolved. The merge remains uncommitted. The
pre-existing unstaged deletion of `Package.resolved` is preserved separately from
these changes.
