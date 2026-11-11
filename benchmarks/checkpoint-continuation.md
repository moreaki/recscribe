# Continue unattempted benchmark cells

Recording and other explicitly prioritized local work still take precedence. Stop
and reap the previous owned runner before taking its checkpoint hash. Follow
[the recording-priority guard](recording-priority-guard.md), obtain a fresh native
idle/live-off check, and declare a bounded execution window before any new model
initialization. Checkpoint recovery does not grant admission or extend a budget.

The native matrix runner can import a measured checkpoint into a **new output
directory**. Supply the exact original corpus/configuration and the SHA-256 of
the stopped `matrix.json`. For a newer coordinator, explicitly retain the
transcription executable used by the original plan:

```bash
NEW_COORDINATOR benchmark /protected/corpus.json \
  --experiment /protected/experiment.json --output /protected/NEW_RESULT \
  --resume-from /protected/ORIGINAL_RESULT --resume-sha256 CHECKPOINT_SHA256 \
  --transcription-cli /protected/retained/recscribe-text
```

Use the managed benchmark wrapper for execution logs, keeping persistent results
in the existing external research location. Do not write them into disposable
artifact storage. The destination must not exist; the original is read-only.

Import verifies the exact grid and configuration, corpus, profile, freeze,
model, source/reference, transcription/Whisper binary, decoding, language,
channel, repeat and scoring identities. Successful measurements must agree with
their retained case reports and effective engine provenance. The original
checkpoint bytes are copied to `checkpoint.original.json`, retaining the original
host/software metadata, source times, outcomes and prior continuation provenance.
Evidence pointers in the derived matrix resolve to their original directories.

Only a `queued` cell with no evidence directory, measurement or other attempt
evidence can run. Completed, failed, cancelled and pending outcomes stay intact.
A `running` cell, or a queued cell with possible attempt evidence, becomes pending
with an explicit uncertainty reason. It never becomes a retry. New attempts are
persisted as `running` before invocation, so a crash cannot silently make them
eligible again. Import and execution remain cancellable; checkpoint input is
bounded to 64 MiB and the existing 20,000-cell matrix limit still applies.

The report distinguishes the retained transcription executable (`runner_sha256`)
from a new orchestration/scoring executable (`coordinator_sha256`). Retain both
build receipts and verify unchanged scorer source/version and frozen-reference
contracts before combining quality counts across coordinator revisions. Binary
identity alone does not prove unchanged scoring semantics.

Every missing first outcome remains missing for the original quality gate. A
later repeat cannot replace it, and a continuation does not reduce the required
paired source count. Keep the original interrupted budget outcome and all
failure/cancellation evidence. A matrix containing inherited failures still
returns failure after saving its derived report. A successful process exit does
not establish corpus completeness, human review or a quality-gate pass.

Continued calls span different execution windows. Timing/RSS are uncontrolled
and cannot support resource acceptance; use a separately controlled panel for
those claims. This recovery mechanism changes no model artifact, candidate,
decoding policy, lexical threshold, reference, default or installed app.
