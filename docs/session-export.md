# Cancellable session export

Implements [cleanliness finding 1/8, issue #5](https://github.com/moreaki/recscribe/issues/5).

## Ownership and scheduling

`SessionLibrary` admits export into the same task slot and cancellation token used
by verification and transcription. A second export or transcription request is
rejected while that slot is occupied. Verification requests remain queued and
are considered when the active task finishes.

Cancel, caller-task cancellation, recording startup, and shutdown reach the owned
export worker. Recording startup only signals cancellation: it does not wait for
the worker. The slot remains occupied until the worker exits. Shutdown prevents
new admissions, clears pending requests, and awaits the owned task. An interrupted
export is not automatically restarted after recording; the user can retry.

The injected export operation and runtime-cancellation callback are narrow test
seams. They do not change production admission or completion rules. Broader service
composition and typed session states remain separate work in issue #2.

## File work and publication

`SessionExporter` runs synchronously on a utility-priority worker, not MainActor.
It holds the existing session lease, checks source SHA-256, copies in blocks, and
checks copied SHA-256 for every part and derived artifact. Files are opened without
overwriting; original audio and its manifest are never modified.

The staging directory is named `<session>-Export-<UUID>.partial`. The manifest is
written only after all copied files are verified. A same-parent directory move
removes the `.partial` suffix to publish the complete export. The final cancellation
check precedes that commit point; cancellation racing after publication does not
undo success. Failures and cancellations retain the explicitly incomplete directory
for inspection. No partial export is returned as a successful result or opened in
Finder as completed. Retrying creates a new, exclusive destination.

## Operational policy and limits

- `SessionExporter.defaultBlockBytes` is 1 MiB and is injectable for tests. Hashing
  and copying share the same bounded reader, with an autorelease pool per block so
  Foundation temporary objects do not accumulate for a whole recording.
- Cancellation checks occur before/after reads, between writes, before sync, and
  before publication. There are no polling sleeps or arbitrary grace periods.
- A synchronous filesystem call already in progress (including `synchronize` or
  directory publication) cannot be interrupted by this token. Consequently no
  fixed wall-clock cancellation/shutdown deadline is promised. Shutdown waits for
  safe worker exit rather than abandoning an owned writer after a timeout.
- Utility QoS and prompt cooperative cancellation do not guarantee disk latency
  or hard real-time scheduling. A stalled external volume can delay worker exit;
  recording admission itself remains non-waiting.
- Format constants remain owned by the existing session/WAV types. No user-facing
  settings or UI design values are introduced for this implementation detail.

## Diagnostics and verification

The `Export` unified-log category records a correlation UUID, monotonic elapsed
duration, copied bytes, block size, and completion flag. It does not log filenames,
audio, or transcripts. Library activity distinguishes success, failure, and
cancellation; cancellation is not presented as an error alert.

`SessionExportTests` use synthetic PCM sessions and checksum-only derived-artifact
fixtures. They cover multipart success, repeated exports, source/copy corruption,
injected ENOSPC, cancellation during source hashing/copying/copy verification,
all cancellation entry points, recording/transcription exclusion, admission after
failure, and shutdown waiting. Worker gates establish ordering without arbitrary
timing sleeps. Their 30-second wait is a test-failure safeguard only.

`SessionExportBenchmarkTests` compares the old `FileManager.copyItem` file-work
path from commit `85f1d0a` with the new worker on identical 8-MiB synthetic PCM.
It alternates strategy order over three pairs and reports wall time and process
lifetime peak RSS. Run it alone in Release: filesystem caches are warm, the old
copy may benefit from filesystem cloning, and RSS includes the entire test host.
These measurements are not an ASR benchmark or an export-latency guarantee.

```sh
xcodebuild -project RecScribe/RecScribe.xcodeproj -scheme RecScribe \
  -configuration Release -destination 'platform=macOS' \
  -derivedDataPath Build/TestDerivedData ENABLE_TESTABILITY=YES \
  -only-testing:RecScribeTests/SessionExportBenchmarkTests \
  -parallel-testing-enabled NO test
```

## Verified locally on September 6, 2026

- Release regression: 317 tests, 698 executions across two repetitions, zero
  failures (`Build/export-regression-final.log`).
- Signed local Release build succeeded with Swift 6, complete strict concurrency,
  and MainActor default isolation. Bundle `com.moreaki.recscribe`, team
  `CDS4KLP8GT`, arm64, Hardened Runtime; strict code-signature verification passed
  and `get-task-allow` is absent. This is Apple Development signed, not notarized
  or a Developer ID distribution build. No provisioning updates were requested.
- [Benchmark samples](../benchmarks/recorder/session-export-m1.json): median
  14.123 ms for the old path versus 13.494 ms for streaming on 8 MiB. Treat them
  as comparable small-fixture timings, not proof of a general speed improvement.
  The process-lifetime peak RSS reached approximately 186 MB for the test host;
  this cannot isolate the export's memory consumption.
- No private recordings, external model downloads, or cloud services were used.
