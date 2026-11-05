# Recording selection and bulk deletion (#94)

The Recordings library uses compact rows, persistent checkboxes and a selection
bar above the scrolling list. Select individual recordings, Shift-click a range,
use the mixed-state master checkbox, or use Cmd+A with focus in the list. Clear
and Escape clear selection. Refresh retains only surviving selected IDs; newly
discovered recordings are not implicitly selected.

Play and Transcribe remain direct row actions when nothing is selected. More
contains renaming, recording details, transcription/source-track actions, Reveal,
Export and individual Delete. The automatic verification introduced in #97 is
preserved; manual Verify/Recover actions are not reintroduced. Review notes stay
collapsed. Job counts are calculated in the deletion preview rather than by
continuously scanning Jobs for each row.

Delete opens a native sheet with a frozen selection and defaults to **Recordings
only**. This moves the selected recording manifests, audio, archives and linked
source recordings to macOS Trash while retaining transcription jobs. **Recordings
+ linked transcription data** additionally groups all unambiguously verified,
finished corresponding job folders, including raw/final transcripts, summaries,
edits and other outputs. The preview shows exact included job counts and selected
titles. Active, unverifiable or conflicting jobs are retained and can be revealed
for separate inspection. Raw Live drafts, external exports and remote provider
data are kept; the UI explicitly avoids promising complete erasure.

Preflight scans Jobs once, within the existing entry/reference byte limits.
It rejects shared recording files and holds an edit reservation while the sheet
is open. Background edits wait until dismissal. Discovery errors allow Retry or
an explicit audio-only preflight; they are never presented as zero linked jobs.
The sheet carries its selected entries as an identifiable request, avoiding the
empty-state timing of a separately toggled presentation flag.

The batch runs serially under the existing capture/live/shutdown gates. Each
recording/source lease and each planned manifest/job identity is rechecked before
movement. Cached URL resource values are not used to decide whether a planned
job is now a symlink. Unknown files and jobs discovered after confirmation are
not added to the destructive plan. Known unselected manifest identities are
protected against preview-to-execution changes. Playback of a selected source
stops; unrelated playback is retained.

Each recording keeps the existing rollback contract and grouped Trash layout.
A failure stops further deletions; failed/unattempted entries remain selected.
Stop after current recording finishes the current transaction and keeps the
remainder. Capture interruption uses cancellation/rollback, without stopping
capture. Results count only committed moves. Rollback failures retain the
recoverable staging path in the error. Persisted transcript pointers are cleared
only for successfully moved jobs. Refresh/queue resumption occurs once at the end.
Restore moved folders through macOS Trash; there is no speculative Undo button.

## Validation

Focused behavioral coverage is in `RecordingBulkDeletionTests`, alongside the
existing deletion, transcript-storage and library-work-status suites. It includes
range identity, both scopes, every matching job, newly created/unrelated jobs,
active/conflicting evidence, changed previews, shared audio and changed unselected
owners, linked source tracks, transactional failure, stop/capture interruption,
workspace pointer cleanup, canceled previews, job symlink replacement and an
actual macOS Trash-and-restore round trip using scoped synthetic fixtures.

Normal focused run: **32 tests passed**. Native core/frozen contracts: **51 tests
passed**. Source-boundary and PCM ownership checks passed. Native UI review and
focused sanitizer evidence are recorded in the implementation PR; do not infer a
full app-suite/CI or VoiceOver pass from the focused checks.

Installed candidates preserve bundle identity, signing requirement, certificate,
team and entitlements, with recoverable app copies in `Build/InstalledBackups`.
No user recording or transcription job is deleted during UI verification; only
synthetic fixture data is used for destructive correctness tests.
