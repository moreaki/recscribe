# Cleanliness completion — 2026-09-08

Completes the remaining acceptance work from [the checkpoint](cleanliness-checkpoint.md).
All eight cleanliness items are implemented; multi-source capture (#1) remains a
separate, explicitly excluded feature. Original recordings, saved paths, recording
preferences and the pre-existing signing stash were preserved.

## Acceptance evidence

| Ticket | Completion and regression coverage |
| --- | --- |
| #4 — WAV | One PCM16 RIFF contract; strict header verification; streamed atomic repair; sparse 2-GiB fixture; over-RIFF rejection before copying; write-boundary ENOSPC fault injection; cancellation preserves originals; both recovery entry points covered. |
| #3 — Playback | View-free composition/validation; owned cancellation; capture gating; cancelled validation worker; delayed selection/close/capture/error tests; exact sample-based multipart composition and missing/unverified-part tests. |
| #2 — Dependencies/states | Explicit app composition and injected recording coordination; typed wire states; pending verification journal before cancellable work; repaired inode ownership persisted before hashing; archive cancellation/restart/failure and damaged-archive review tests without real subprocesses. |
| #6 — Manifest I/O | Bounded reads/decoding in a background actor; typed version/progress validation; visible read failures; owned polling with injectable scheduler; generation checks on success and error; 300-session, missing/corrupt/future-schema, concurrent-refresh and cancellation tests. |
| #7 — Processes | Separate runner; operation/process IDs, start/end and monotonic duration; bounded prefix/tail and post-exit drain; durable private launch/exit/timeout evidence; log-storage failures remain explicit without masking the process outcome; unrelated-process and inherited-pipe tests. |
| #9 — Settings | No checkout-derived defaults; explicit paths retained; independently validated nested migration with visible warnings; shared codec/size bounds; explainable discovery separate from persistence; Glass components; installer filesystem work moved to utility workers. |

#5 (owned export) and #8 (shared pipeline completion) were completed previously.
Contract constants live with their responsible types; technical format invariants
are not exposed as user settings. Test fixture values are intentionally explicit.

## Tests and local build

- Full Release unit-test target: **349 tests, 381 executions including parameterized cases, zero
  failures/skips**. `Build/finish-verified-tests.log`; result bundle:
  `Build/TestDerivedData/Logs/Test/Test-RecScribe-2026.09.08_21-04-30-+0200.xcresult`.
- Python pipeline: **38 tests passed** (`Build/finish-python.log`).
- Isolated comparison benchmark: passed (`Build/finish-benchmarks.log`).
- Release build: passed (`Build/finish-release.log`). No Swift concurrency warnings;
  Xcode's informational AppIntents metadata warning remains (no AppIntents dependency).
- Local app: `Build/Products/Release/RecScribe.app`, version **0.1.0 (100)**,
  **arm64 / 64-bit**, bundle **com.moreaki.recscribe**, team **CDS4KLP8GT**.
- Swift **6.0**, strict concurrency **complete**, default isolation **MainActor**,
  Hardened Runtime enabled; strict deep codesign verification passed;
  `get-task-allow` absent.
- Signing authority: **Apple Development: Roberto Nibali (6RA9887B6U)**.
  This is the requested local development-signed Release, **not notarized and not
  a Developer ID distribution build**. The distribution audit correctly rejects
  that authority. No Apple account resources or signing identities were changed.
- Built with the repository script's Release settings via `xcodebuild`, omitting
  `-allowProvisioningUpdates` to avoid authorizing Apple account mutations.

Manual UI verification on the rebuilt app: launch, recorder navigation, recording
library and refresh, Storage/Transcription/Models/AI/Diagnostics settings, preserved
500-MiB cap and explicit runtime/model paths. Local detection in the UI identified
`whisper-cli` and the **Apple M1 Metal backend**. That confirms backend loading,
not inference acceleration for an unmeasured job. No models were downloaded and
no recording/transcript was sent to any AI service. Settings layout was inspected
visually; no new installation, permission or configuration choice was applied.

## Measured comparison (this Mac only)

MacBook Air, Apple M1, macOS 26.6.2, Release build. Three same-machine synthetic
runs; recovery order alternated. Times include filesystem effects, are not a
universal performance guarantee and are not comparable to M2 Ultra ASR timings.

| Work | Before strategy | Current strategy |
| --- | --- | --- |
| 16-MiB synthetic WAV repair, median | Whole-file `Data`: **9.74 ms** | Streamed repair: **7.94 ms** |
| Largest recovery copy buffer | **16,777,260 bytes** | **1,048,576 bytes** |
| 300-manifest refresh, median wall time | MainActor: **8.84 ms** | Background actor: **10.23 ms** |

The manifest change removes disk/JSON work from the UI executor; it does not claim
lower total wall time. Thread assertions confirm the background path is off the
main thread. Whole-process lifetime peak RSS in the isolated comparison rose from
184,844,288 to 186,171,392 bytes across both strategies; this shared high-water mark
cannot isolate per-strategy memory use. The bounded buffer assertion is separate.

The separate **2-GiB** sparse-input recovery took **3.93 s**, with a **1-MiB** copy
block and whole-process lifetime peak RSS of **180,092,928 bytes**. Synthetic test
files were cleaned up; no private audio was used as benchmark data.

## Operational boundaries

- Process cancellation targets only the directly owned child PID, never global
  names or unrelated processes. Installer descendants may finish their current
  step; cancellation is not a rollback of package-manager side effects. Inherited
  output cannot keep the runner waiting indefinitely. No installers were actually
  run during this verification; their lifecycle contracts use synthetic children.
- Private diagnostics retain 20 UUID-named JSON files, each containing at most
  128 KiB of raw output before UTF-8/JSON escaping. Directory/file modes are
  0700/0600. Output may be sensitive: inspect before sharing. Unified logs contain
  IDs/status/timing, not argv or transcript text. Storage failure is reported.
- ENOSPC is injected at the actual write boundary; the user's disk was not filled
  to exhaustion. Originals survive the failure and no temporary repair remains.
- Unknown manifest states/versions are rejected, not guessed or migrated into a
  successful state. Preference migration is intentionally more tolerant and
  reports individual fallback fields; it does not relax manifest validation.
- No new ASR engine, cloud fallback or simultaneous system/microphone capture was
  introduced. Those remain separate from this completed cleanliness work.
