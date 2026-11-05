# Recordings: quick selection and bulk deletion

Design proposal, 5 November 2026. Scope: a cleaner Recordings library and safe,
explicit deletion of a few or all recordings, with an optional inclusion of
their linked transcription data. Native implementation is a separate task.

## Review the proposal

- Open [recordings.html](recordings.html) locally. It is self-contained, uses
  synthetic metadata and makes no network, audio, or filesystem calls.
- Mocks: [browse](browse.png), [a few selected](selected.png),
  [all selected](all.png), [confirmation](confirm.png),
  [exceptions](exceptions.png), [partial completion](result.png),
  [narrow selection](narrow.png), [narrow confirmation](narrow-confirm.png).
- Preview states additionally cover progress, active capture and an empty library.

Try individual checkboxes, Shift-click for a range, the master checkbox, Cmd+A,
Clear, Escape, a row's More menu and Delete. Confirming simulates removal of
sample rows in memory. Select another preview state to reset the sample.
Non-deletion actions are labeled placeholders; this is a focused interaction
proposal, not a working transcription client.

## Problem and proposed layout

The supplied screenshot shows tall rows with repeated timestamps, technical
audio metadata and five competing actions, including Delete, on every row.
There is no way to select multiple recordings and act once.

Use compact rows, with one persistent checkbox on the left, title and a single
metadata line, and Play / Transcribe / More on the right. The metadata combines
date, time, readable duration and linked transcript count. A recording without a
custom title retains a recognizable generated title. Put full PCM metadata and
source details in a row inspector or details disclosure, not the default list.
Keep existing Review notes collapsed, with a visible needs-review cue.

More contains Rename / Reset title where applicable, Transcribe & summarize,
source-track playback/transcription, Verify / Recover, Reveal, Export and Delete.
No existing capability should disappear. The mock shows Source tracks as a
placeholder and uses a representative list of actions. At narrow widths the
Transcribe shortcut moves to More, and full titles wrap rather than collide.

A pinned selection toolbar above the scrolling list contains the master
checkbox, library count, selected count, Clear and **Delete N…**. With nothing
selected, Delete selected is disabled. Once selection exists, row action groups
are hidden to reduce distraction; they return after clearing selection. Review
notes remain available. The toolbar stays put while browsing long lists.

## Selection contract

- Checkboxes are always visible; entering a separate selection mode is unnecessary.
- Clicking one checkbox toggles only that recording. Shift-click toggles the
  contiguous range in the current display order. Selection uses stable manifest
  identity, never row index or filename alone.
- The master checkbox has none / some / all states. Clicking a mixed master
  selects all recordings in the current library, including offscreen rows.
  Clicking a checked master clears selection.
- Cmd+A selects all when focus is in the recording list. Do not intercept text
  editing or modal shortcuts. Space toggles a focused checkbox. Escape clears
  selection when no sheet, menu, editor or other transient UI owns the key.
- Clear is explicit and always accessible. Refresh retains selected IDs that
  still exist, removes disappeared IDs and never selects newly discovered files.
- The current library has no search/filter control. If filtering is introduced,
  the master checkbox must explicitly say **Select all N results** and must not
  silently select hidden nonmatching records. Changing scope clears selection.
- Opening confirmation freezes the selected IDs and scope. A refresh or a new
  recording cannot expand the destructive target set.

## Delete confirmation

Use one native sheet for single and multiple deletion. The title contains the
number of recordings, and Cancel has initial keyboard focus. Two radio options:

1. **Recordings only** (default every time): move manifests, all associated audio
   parts, archives and linked source recordings together to macOS Trash. Keep
   transcription jobs and their data intact and explicitly accessible.
2. **Recordings + linked transcription data**: additionally move complete,
   verified finished job folders for the selected recordings and source tracks.
   Include all outputs in those folders: raw/final transcripts, summaries, edits,
   reports, snapshots and generated intermediates. Do not merely remove a visible
   transcript index entry or one latest job.

Before enabling **Move N to Trash**, perform a cancellable, bounded background
preflight and show the exact verified job count, selected recording list and
any retained exceptions. While scanning, show “Checking linked data…” and keep
Cancel available. An I/O or enumeration failure is a failed preflight, not zero
linked jobs. Offer Retry or an explicit switch to Recordings only.

Deletion remains recoverable; each recording and its selected job folders stay
grouped as in the existing Trash layout. Explain restoration through macOS Trash.
Do not show an Undo button unless a reliable in-app restore is implemented.
Return focus to the invoking action on cancel; preserve selection and scope
while the sheet is open. Escape cancels; Enter must not accidentally invoke the
destructive action just by opening the sheet. Use native modal focus behavior.

## What “all transcription data” can truthfully mean

The existing deletion service verifies jobs using session identity, or exact
source path plus recorded hash. It includes linked source sessions. A basename
match is insufficient. It deliberately keeps active/unverified jobs, unrelated
data and protected raw Live drafts. Keep those preservation contracts.

The requested complete cleanup is fulfilled for **all verified linked job data**,
including every finished matching job, rather than only the last transcript.
Copies exported elsewhere, cloud-provider records and independently retained
Live evidence cannot be claimed as deleted by a local managed-job operation.

If any candidate cannot be verified, show **Some transcription data will be
kept**, with count, reason and a path to inspect it. Explicitly state that this
operation does not remove all transcription data. Raw Live drafts require a
separate deliberate evidence-management action and must not be silently enrolled
in this operation. Do not label partial cleanup “everything deleted.” If safe
discovery cannot determine whether data exists, show “Could not check” rather
than inventing a count. The exception mock's two retained items are synthetic.

## Batch behavior and correctness requirements

This includes storage and concurrency work, not just presentation. Do not wrap
the current single-delete async method in an uncoordinated loop: it starts
refresh/queued work after each invocation and offers no aggregate result.

- Introduce one batch coordinator with a frozen plan and one edit reservation.
  Inspect the jobs root once per bounded plan, deduplicate shared job paths and
  ensure no job belonging to an unselected source is moved. Preserve current
  traversal/reference byte limits and cancellation; hitting a limit is visible.
- Disable destructive execution during recording, audio testing, live work,
  shutdown or conflicting background edits. Show the reason and retain selection.
  Revalidate gates, source identity and file availability before every move;
  preflight is not a substitute for a lease. Never stop capture to perform deletion.
- Stop playback only when deleting its source. Prevent new playback of a source
  while it is being moved. Keep unrelated playback when possible.
- Process recordings serially with progress such as “Recording 2 of 5”. Keep each
  recording's existing transactional rollback. Batch semantics are per recording,
  not a promise of one all-or-nothing transaction across the whole library.
- “Stop after current recording” finishes the current transaction and retains
  remaining targets. Capture interruption uses existing cancellation/rollback
  rules. Do not claim canceled work was deleted.
- On any failure, stop further destructive work and report moved / failed /
  unattempted recordings plus moved / retained jobs. Keep failed and unattempted
  items selected. A retry must re-preflight and exclude completed targets.
- Rollback failure must show the recoverable staging location and the actual
  files remaining there; it must not claim all source files were restored.
- Refresh once at batch end. Forget workspace/persisted job pointers only for
  successfully trashed jobs; retained transcripts remain intentionally usable
  without their source audio, and startup must not resurrect a trashed job.

## Acceptance and validation for native implementation

- [ ] Quickly select one, several, a range or every recording, with a correct
  mixed master state and exact selected count, including offscreen rows.
- [ ] Compact, uncluttered rows retain every existing action and Review notes;
  long names, large text, light/dark appearance and narrow panes remain usable.
- [ ] Both deletion scopes, exact verified counts, selected-item review and
  preserved-data warnings are clear before a destructive action is available.
- [ ] Audio-only deletion retains all job data; linked-data deletion moves every
  verified matching job and its entire content, with no basename-only matches.
- [ ] Capture/live/background gates, leases, bounded planning, source-track
  inclusion, shared-job handling, cancellation, per-recording rollback, partial
  results and retries have focused behavioral coverage using isolated fixtures.
- [ ] Refresh races, vanished entries, preview-to-execution identity changes,
  multi-delete persistence cleanup and retained transcript access are covered.
- [ ] Actual installed native UI inspected for browse, some/all selection,
  both confirmation scopes, exceptions, partial completion, keyboard and VoiceOver.
  Counts, focus, mixed selection and disabled-state explanations are accessible;
  color alone never communicates selection, warnings or errors.
- [ ] Use existing build caches and artifact wrapper; preserve frozen reference
  checks, signing identity, privacy permissions, app backups and original evidence.
  For the future native preview, follow AGENTS.md installation and review order,
  while applying correctness checks appropriate to the deletion behavior.

## Evidence and limits of this proposal

Code inspected at local revision `b06ea7cfcaab68d722bd200517a74e3c583aafee`:
`RecordingLibraryView.swift`, `SessionLibrary.swift`, `SessionDeletion.swift` and
`SessionDeletionTests.swift`. The supplied screenshot is visual evidence of the
current presentation, not evidence of a reproduced storage defect.

`verify.cjs` checks only the synthetic browser prototype. Run with the managed
artifact wrapper and a locally installed Playwright package/Chrome:

```sh
python3 scripts/work-artifacts.py run --label recordings-bulk-delete-proposal test -- \
  env NODE_PATH=/tmp/recscribe-source-design-tools/node_modules \
  'CHROME_PATH=/Applications/Google Chrome.app/Contents/MacOS/Google Chrome' \
  node docs/design-proposals/recordings-bulk-delete/verify.cjs
```

Screenshots are generated in the managed run directory; copy the reviewed PNGs
here as durable design assets. Browser validation does not establish SwiftUI
behavior, real Trash/restore correctness, accessibility or native test success.
No application source, installed app, recordings or transcription data is changed
by this proposal.

Prototype validation passed on 5 November 2026: individual/range/all selection,
mixed checkbox state, clear/Escape, default scope, sheet focus/cancel, simulated
linked-data deletion, retained exceptions, partial result selection, capture
blocking and single-row deletion. Checked 620/760/1120 px layouts with no page
or control overflow and no script errors. Browse, selected, confirmation,
exceptions, partial-result and narrow confirmation images were visually reviewed.
Native implementation, real deletion/restore tests and VoiceOver review remain
pending; no native suite was run for these design-only files.
