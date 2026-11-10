# Manual passage corrections

In Studio, each passage offers **Edit text** and **Music only**. Overlapping
channels offer **Edit sources**, with a separate editor for each source. These
controls are also available alongside original recognition in the review panel.

Save a text correction to update the passage in place, or choose Music only to
display `[Music only]`. **Remove correction** returns to the transcript's previous
rendering, including any existing normalization or translation. Original
recognition remains available for comparison. Cancel discards only the open draft.

Corrections appear in Reading, All channels, and Studio's copied/shared plain text
and Markdown. Original audio, raw recognition, canonical `transcript.json` and
generated job artifacts are never rewritten. Revealing artifacts still shows
those originals. Existing summaries display a warning that they predate manual
corrections; the warning is included when copying/sharing them. AI text processing
of corrected text is not yet available. Transcribe again creates a separate job.

An edit or removal reopens the affected passage's existing review item and global
review notes. Other passages retain their checked status. A manual correction does
not change model confidence or original uncertainty flags.

Corrections and review status share one atomic, locked metadata record under
`~/Library/Application Support/RecScribe/Review`. Records are keyed by the job path
and exact SHA-256 revision of the canonical transcript. New revisions do not
inherit old corrections, and previous records remain recoverable. Legacy v1/v2
records remain readable; current v3 records preserve manual corrections and cloud
evidence references so older readers cannot silently discard provenance (see
[selected-passage cloud recognition](segment-cloud-recognition.md)). These are persistent user data,
outside disposable developer-artifact retention.

Saves are serialized, bounded to 10,000 segments/items and 1 MiB per metadata
record, with at most 64 KiB of UTF-8 text per corrected segment. Empty corrections,
unknown sources, changed revisions, conflicting edits, unsupported/corrupt files
and unavailable storage fail visibly. Only confirmed writes change the displayed
transcript. Failed saves retain the draft; stale drafts cannot overwrite a newer
correction. Copies and sharing stay unavailable if correction metadata cannot load.

Regression coverage checks original-file preservation, correction/music/restore
round trips, exports and summary warnings, review invalidation, migration, revision
isolation, concurrent/stale writes, size bounds, unsafe metadata and cancellation.
This behavior/storage change requires full functional and Thread Sanitizer CI.
