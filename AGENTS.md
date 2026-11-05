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

## Focused CI and full Thread Sanitizer requirements

Use the scope selected by `scripts/ci-scope.py` for the complete PR or push diff,
not just its latest commit. See [CI validation scope](docs/ci-validation.md).
Do not opt out of full validation using a PR label or a UI filename alone.

**Focused CI is sufficient** only when the classifier selects `focused`:

- At most five existing modified files and 80 added/removed lines.
- Only recognized literal labels, icons, help/accessibility text or simple
  spacing, frame, font, foreground, corner-radius and line-limit modifiers in
  `RecScribe/RecScribe/UI/*.swift` (including subdirectories), or Markdown in
  `docs/` and `README.md`.
- No change to callbacks, state, lifecycle, async work, disabled/safety gates or
  other behavior. Unrecognized visual syntax conservatively requires full CI.

For this path, direct native UI review plus justified focused local checks is
sufficient for the iteration; do not repeat the full local sanitizer suite for
presentation alone. Hosted CI runs the focused contract suites and rejects failed,
missing or zero-test results. Report TSan as **skipped by policy**, never passed.

**Full CI is required**, including the entire functional app suite and the entire
Thread Sanitizer suite, for recording/capture, buffering, concurrency,
cancellation, sessions/storage/deletion, transcription, permissions,
models/schemas, dependencies, tests, build or CI-policy changes. This also applies
to behavior changes inside UI files, mixed UI/backend changes, broad changes,
new/deleted/renamed/type-changed files, missing baselines and classification errors.
`AGENTS.md` is outside the focused allowlist and therefore uses full CI as well.
When in doubt, keep the full path; do not reclassify risky work as presentation.

On every path, keep the required `Unit tests` and `Release build` check names,
Release compilation, source-boundary/PCM ownership checks, native core tests and
frozen-reference contracts. Full runs must also pass the existing sanitizer
evidence gate: complete matching functional/sanitizer counts, no failures or
runtime diagnostics, and no unexpected test-host restart. A partial run or green
enclosing job is not evidence of a clean sanitizer pass.

Before merging, all applicable checks must be green on the current PR head.
Neither focused CI nor full CI replaces the manual UI review workflow above;
long-running checks must not delay availability of the local UI candidate.

## Preserve the installed app and recording data

Before replacing the installed app, inspect the exact running app and confirm
that no recording or audio test is active. Never interrupt active capture to
install an update. Retain a recoverable previous app, verify the staged update,
and verify normal startup after installation.

Preserve the installed app's bundle identifier, designated signing requirement,
team, and entitlements. Do not switch signing identities, reset/grant macOS privacy
permissions, or change provisioning to make a local UI preview work.

Changes to capture, buffering, concurrency, storage, schemas, or permissions require
full CI plus focused correctness validation appropriate to their risk; do not
classify them as presentation-only to avoid that validation. Preserve original
audio and raw transcripts, bounded background work, cancellation, and existing preservation
contracts. Keep mandatory frozen-reference checks and run them at the appropriate
validation stage; never rebaseline fixtures merely to obtain a pass.


## Bound disposable developer artifacts

Reuse `Build/DerivedData` (and the existing SwiftPM cache); do not create a new
DerivedData directory per ticket or visual iteration. Keep app products under
`Build/Products` and recoverable installed-app copies under `Build/InstalledBackups`.
These locations are never part of automatic retention cleanup.

Run temporary test, benchmark, diagnostic and scratch commands with:

```bash
python3 scripts/work-artifacts.py run --label issue-123 test -- command arguments
```

Write disposable outputs to `$RECSCRIBE_RUN_DIR`; the wrapper captures stdout/stderr
in `console.log`, records status and holds a process-inherited lease. Use the fixed
categories `test`, `benchmark`, `logs` or `scratch`, and labels for individual tasks.
Do not scatter logs, result bundles, copied source trees or synthetic audio into
new top-level Build directories or the project root. Use system temporary directories
with scoped cleanup for short-lived audio fixtures. Original audio/raw transcripts,
frozen reference captures and required test inputs belong outside this disposable
root; never enroll them for automatic deletion. Persistent CLI jobs and corpus
results belong under the app support directory or another explicit external
data location, not a new `jobs/` or results directory in the checkout. A `.pin` file retains a run explicitly.

Retention runs before/after managed jobs and local builds. It keeps the latest
completed run per category, at most five completed runs within seven days, plus
active, pinned and protected-data runs. Expired output is permanently disposable;
only opt-in marked runs with an unlocked lease are eligible. Unmanaged directories,
symlinks, fixtures, reference captures, audio/transcripts and app backups are excluded.
An incomplete unlocked run gets seven days of grace before crash-output cleanup.
Preview cleanup with `python3 scripts/work-artifacts.py prune`; use `--apply` to apply.
Do not add a scheduled/global cleanup or extend deletion to unknown folders without
reviewing the data-preservation contract.
