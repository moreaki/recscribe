---
name: recscribe
description: Run the local RecScribe WAV transcription CLI and inspect canonical transcripts, exports and review markers. Use for finalized recordings or imported WAV files, not live recording control.
---

Use the repository's `pipeline` package and `docs/wav-vertical-slice.md` as the
capability contract. Check the current repository location, Python environment,
local FFmpeg and user-supplied whisper.cpp binary/model paths before real ASR.
Do not download models or select a cloud service without user authorization.

Invoke `pipeline/.venv/bin/recscribe` with an explicit finalized source WAV, new
job directory and `--local-only`. Keep jobs and audio out of Git. Use the requested
language mode; `normalize` and `translate` currently produce pending derivations,
not transformed text. `verified` requires a second local model. Consult
`docs/wav-vertical-slice.md` for supported arguments and limitations.

Watch the manifest's state and JSON progress. Use SIGTERM or `cancel.request` for
cancellation. Do not treat existing export files as completed if the manifest is
failed, cancelled or nonterminal. Never alter source audio or raw ASR evidence.

Report the job directory, final state, actual engine/model, review reasons and
which requested stages remain pending. Synthetic contract tests do not establish
ASR accuracy. For comparison work, use `benchmarks/README.md` and retain provenance.
