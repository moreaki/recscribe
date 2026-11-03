---
name: recscribe
description: Run the local RecScribe WAV transcription CLI and inspect canonical transcripts, exports and review markers. Use for finalized recordings or imported WAV files, not live recording control.
---

Use the native `RecScribeCore` implementation and `docs/swift-first-migration.md`
as the current capability contract. Check the repository location and selected
local whisper.cpp executable/models before real ASR. Build the native CLI with
`swift build --package-path core -c release`. Python and FFmpeg are not required
for WAV/session recognition; FFmpeg is optional for archive compression.
Do not download models or select a cloud service without user authorization.

Invoke `core/.build/release/recscribe-text transcribe` with a finalized source WAV
or `.recscribe.json` session manifest, a new
job directory and `--local-only`. Keep jobs and audio out of Git. Use the requested
language mode; `normalize` and `translate` currently produce pending derivations,
not transformed text until a separate native `derive` action runs. `verified`
requires `--verify-model` with a second distinct local model. Use `--threads 1..4`
to set the thread budget. Consult `recscribe-text --help` for supported arguments.

Watch the manifest's state and JSON progress. Use SIGTERM or `cancel.request` for
cancellation. Working/region WAVs are removed on terminal completion, including
failure/cancellation; hashes and raw JSON/logs remain as provenance. Never remove
originals or raw evidence as scratch cleanup. Do not treat export files as complete if the manifest is
failed, cancelled or nonterminal. Never alter source audio or raw ASR evidence.

Report the job directory, final state, actual engine/model, review reasons and
which requested stages remain pending. Synthetic contract tests do not establish
ASR accuracy. For comparison work, use `benchmarks/README.md` and retain provenance.
The old Python pipeline is retired. Run `swift test --package-path core` for
mandatory frozen-reference checks; use the native `benchmark` subcommand for local
corpus readiness and measured runs. Never rebaseline fixtures from Swift output.
