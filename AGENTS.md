# RecScribe project instructions

## Fast feedback for small UI changes

For changes limited to layout, labels, menus, disclosure, or other presentation,
make the updated app available for manual review before running tests:

1. Make the smallest relevant change.
2. Use the existing build cache for an incremental local build. Do not clean the
   build or create a fresh DerivedData directory without a concrete need.
3. Install the signed candidate in `/Applications/RecScribe.app` and make it
   available to the user immediately. Target no more than three minutes from a
   small UI edit to a usable candidate. If building or installation is blocked,
   promptly explain the specific blocker instead of silently adding other work.
4. Check the actual changed UI directly. Do not wait for the complete local test
   suite, Thread Sanitizer, compatibility builds, or CI before this manual review.
5. Run justified focused tests afterward. Batch comprehensive regression runs
   across several small UI changes/PRs rather than repeating them for each visual
   iteration. Clearly distinguish manual verification, pending checks, and passed
   checks in reports.

Do not introduce OCR/text-recognition tests or depend on SwiftUI's internal native
view hierarchy to prove that a simple label/control is visible. Prefer direct
manual UI inspection for these presentation changes. Add regression tests when
they protect meaningful behavior, not merely to mirror a layout edit.

This workflow does not authorize disabling required CI checks, reporting pending
checks as passed, or merging against an existing green-check requirement. CI and
merge readiness must not delay availability of the local UI candidate.

## Preserve the installed app and recording data

Before replacing the installed app, inspect the exact running app and confirm
that no recording or audio test is active. Never interrupt active capture to
install an update. Retain a recoverable previous app, verify the staged update,
and verify normal startup after installation.

Preserve the installed app's bundle identifier, designated signing requirement,
team, and entitlements. Do not switch signing identities, reset/grant macOS privacy
permissions, or change provisioning to make a local UI preview work.

Changes to capture, buffering, concurrency, storage, schemas, or permissions need
focused correctness validation appropriate to their risk; do not classify them
as presentation-only to avoid that validation. Preserve original audio and raw
transcripts, bounded background work, cancellation, and existing preservation
contracts. Keep mandatory frozen-reference checks and run them at the appropriate
validation stage; never rebaseline fixtures merely to obtain a pass.
