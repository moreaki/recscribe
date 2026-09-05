# Recorder hardening and performance record — 2026-09-06

Scope: recording/encoding only. Transcription, Whisper discovery/model installation,
AI providers and the unified settings window are deferred. No new dependency,
model download, cloud processing or change to the recorder's visual design.

## Changes

- Capture callbacks and the stateful normalizer now belong to one dedicated,
  non-MainActor output object per session. Stop drains that queue and seals it;
  late callbacks cannot feed the next take. Unsupported capture conversion is
  surfaced once, rather than merely logged while producing an incomplete file.
- Recorder admission is limited to **256 buffers and 4 MiB of Float32 PCM**,
  including the in-flight write. AAC's internal pending queue has the same
  limits. These are payload limits, not a claim that the entire app uses 8 MiB:
  capture/framework allocations, transient copies, object overhead and UI remain.
- Admission and stop submission share a short lock; no encoding, disk I/O or
  waiting occurs under it. The existing serial encoder queue is retained.
- A write error or overflow closes admission, reports once and remains an error
  at stop. Accepted audio drains after admission overflow; after a write failure,
  unwritten queued buffers are released without repeatedly calling a failed codec.
  Finalization is still attempted to preserve the recoverable partial recording.
- Stop awaits a queue barrier instead of blocking MainActor. Cancelling the
  caller does **not** discard audio. Overlapping starts/stops are rejected while
  draining. Setup/stop capture failures also clean up the encoder.
- Waveform delivery holds only the latest update and at most one main-queue
  delivery per session, rather than accumulating UI work.
- AAC uses one monotonic five-second deadline for pending drain and completion.
  It never reports success with unappended buffers. Do not use
  `AVAssetWriter.cancelWriting()` here: Apple's SDK documents that it deletes the
  output file and can itself block. Timeout releases our references and reports
  failure, retaining whatever recovery fragments were written; playability of an
  incomplete file is not guaranteed.
- WAV uses throwing file writes/seeks, reuses a single PCM payload, rejects
  non-finite samples and checks RIFF's 32-bit size before overflow (~6.21 hours
  at 48 kHz stereo PCM16). It stops with an explicit error, not automatic splitting
  or RF64. FLAC's cumulative frame counter is now 64-bit.

## Reproducible comparison

Run `./scripts/benchmark-recorder.sh my-label` from the local checkout. It refuses
to overwrite an existing result, records environment/source state and runs only
`RecorderBenchmarkTests` in optimized Release with `ENABLE_TESTABILITY=YES`.
This override enables test imports; it does not change shipped Release settings.
Results, diagnostics and the `.xcresult` bundle are in
`Build/RecorderBenchmarks/my-label/`. The script requires Xcode and `rg`.

The unchanged workload submits 100 synthetic stereo buffers of 4,800 frames
(10 seconds at 48 kHz), then finalizes. Three iterations per format, two Xcode
test runners. No waveform subscriber, capture hardware or ASR. Wall time includes
file creation, fixture allocation, submission, encoding and finalization.

Machine: MacBook Air, Apple M1, 16 GiB, macOS 26.6.2 (25G83), Xcode 26.6 (17F113).
Baseline production source: `5ad0930`; hardened source: `cc6145d`.
Raw samples: `benchmarks/recorder/baseline-5ad0930.json` and
`benchmarks/recorder/hardened-cc6145d.json` (also contains aggregate trace output).

| Format | Baseline warm median | Hardened warm median |
| --- | ---: | ---: |
| WAV | 5.44 ms | 5.71 ms |
| AAC/M4A | 105.27 ms | 96.97 ms |
| FLAC | 55.78 ms | 47.97 ms |

Warm median uses iterations 1 and 2 from both runners. First AAC iterations were
2.58–2.59 seconds at baseline versus 0.15–0.20 seconds afterwards; system codec
warm-up/cache state was not controlled, so **do not attribute that difference to
the fix**. These small samples are comparison evidence, not statistically proven
speedups or end-to-end live-capture latency measurements.

Maximum observed test-host **lifetime** peak RSS was 119.59 MiB before and
126.67 MiB after. This includes SwiftUI/test-host/framework state; it neither
isolates encoder RAM nor proves a memory reduction. The tested improvement is
bounded application-owned backlog under a stalled writer, not lower total RSS.

## Logging and tracing

Unified logging subsystem: `com.moreaki.recscribe`, categories `recorder` and
`capture`. Start/end summaries use `.notice`, retained in Release subject to
macOS log retention. No audio, transcript or file path is included. Failure
descriptions are private. Each recording and capture output has its own UUID;
start/end recorder IDs match, capture IDs identify the associated output lifetime.

```sh
log show --last 15m --style compact \
  --predicate 'subsystem == "com.moreaki.recscribe" AND (category == "recorder" OR category == "capture")'
```

`Recording` and `DrainAndFinalize` are `OSSignposter` intervals for Instruments.
Use the Logging instrument's signpost view, or add signposts to a Time Profiler
trace. Trace capture is opt-in; the app does not continuously save trace files.

Summary fields:

- `accepted`, `written`: buffer counts. Their difference exposes accepted but
  unwritten audio. `rejected` counts the admission-overflow trigger; subsequent
  callbacks after admission closes are ignored, not counted as separate errors.
- `peak_buffers`, `peak_pcm_bytes`: admitted high-water marks including in-flight
  encoding; AAC separately reports `peak_pending_pcm_bytes`.
- `max_queue_ms`: longest submission-to-write-start delay among successful writes.
- `write_ms`, `max_write_ms`: sum/max synchronous encoder-write time (AAC may
  continue encoding internally afterwards).
- `drain_ms`: stop request to finalize entry. `finalize_ms`: codec finalization.
- Capture `callback_ms`, `max_callback_ms`: total/max conversion, normalization
  and hand-off time, excluding delivery delay inside ScreenCaptureKit.

No per-buffer logging or unbounded timing history is retained.

## Validation

- Release unit suite: **299 tests, 325 executions**, zero failures/skips.
- Focused Debug Thread Sanitizer: **15 tests, 16 executions**, zero failures/skips.
- Regression coverage: both queue limits with a stalled encoder; one-shot write
  failure; MainActor responsiveness while finalize blocks; cancelled stop preserving
  accepted audio; overlapping start/stop; capture drain and late callback; setup
  and stop failure cleanup; AAC backpressure/never-completing finish with zero
  test deadlines; RIFF boundary without multi-GB fixtures; non-finite PCM.
- Existing WAV golden bytes, format guards, codec and recorder tests still pass.
- `./scripts/build-app.sh` succeeded; signature verified, bundle
  `com.moreaki.recscribe`, team `CDS4KLP8GT`, Swift 6.0, strict concurrency complete,
  Hardened Runtime. Apple Development signed, not a notarized distribution.
- Standalone Release app launched without Xcode and recorded/finalized a real
  **17.32-second system-audio WAV** with a quiet generated tone. All **866/866**
  buffers written, no rejection/conversion failure, peak queued PCM **60 KiB**,
  maximum queue wait **2.01 ms**, drain **0.048 ms**, finalize **0.349 ms**.
  Decode/metadata checks passed. Recording remains local, outside Git.

## Boundaries and follow-up

This does not promise finite latency for an arbitrary stalled filesystem or
Apple framework call, or bound ScreenCaptureKit/codec-internal allocations.
Long wall-clock capture, external/network storage, hardware sample-rate changes,
resampler end-of-stream tail behavior, and memory/thermal pressure still deserve
dedicated soak/hardware tests; the RIFF-limit test is arithmetic, not a six-hour
recording. File creation still uses the existing synchronous start contract.

Keep the saved recording as the hand-off boundary for future optional processing.
No transcription worker retains capture buffers in this change. The next phase
is the unified native configuration window inspired by Quantivane/Modex: Whisper
engine detection, explicit model installation/verification, transcription and
translation settings, and optional AI providers. Do not couple any of them to
the capture/encoder hot path.
