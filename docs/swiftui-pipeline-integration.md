# SwiftUI integration plan

The WAV CLI and its JSON contract are the first milestone. Keep recording and
processing as separate failure domains; this change does not modify capture code.

## Import and enqueue

Add a WAV-only `fileImporter` to the existing menu/popover. Resolve security-scoped
access for the selected URL and retain the scoped bookmark for the job lifetime.
Validate that the selected file exists and is finalized. Do not move or overwrite
it. A future managed import may make a byte-identical copy with matching hashes.

After a successful `RecordingController` stop/finalization, enqueue the finalized
URL. Do not enqueue when recording begins, during buffer delivery, on failed
finalization or during crash recovery until a file has been recovered successfully.
Use a source SHA-256 plus configuration digest to identify duplicate submissions;
the user may explicitly start another job.

## JobStore

Implement `actor JobStore` holding Codable job snapshots by UUID, with per-job
directories under Application Support/RecScribe/Jobs. Persist atomic manifests;
publish snapshots to a `@MainActor` observable view model. Validate schema versions
before reading results. Unknown versions must produce an actionable error rather
than a partially decoded transcript.

The CLI manifest is authoritative. Only `completed` and `completed_with_review`
allow opening exported results as complete. On app relaunch, nonterminal jobs with
no owned running process become interrupted and offer retry in a new directory.
Do not infer that a stale PID is still our worker. Avoid global process-name kills.
Store no transcript text in ordinary app diagnostics.

## PipelineCoordinator

Implement an actor owning one `Process` at a time, its progress pipe, termination
handler and cancellation request URL. Launch an explicitly configured local
interpreter/CLI with absolute argument paths and no shell. Keep all reads and
JSON parsing off the main actor. Drain stdout and stderr concurrently to avoid
deadlocks; parse the documented JSON stage events and retain unknown log lines
only in the private job directory.

Publish stage/progress/error snapshots to the UI. Cancel by atomically creating
`cancel.request` or sending SIGTERM to the owned CLI process. Await the CLI's
terminal manifest, with a bounded escalation path if it becomes unresponsive.
Show exit 130 as cancelled, exit 1 as failed, exit 2 as configuration error, and
exit 0 with `completed_with_review` as needing review, not verified accuracy.

## Capture priority

JobStore may queue imports while recording. PipelineCoordinator starts inference
only when capture is idle. Before a new recording, request cancellation of the
current worker and requeue it for a fresh job after recording ends. Capture start
must not wait on inference or its cancellation, and failed cancellation must never
prevent capture. Coordinate the actor state transitions so capture and inference
cannot race to start. The worker's nice level is an additional CPU preference;
Metal scheduling still needs measurements and cannot be guaranteed by QoS alone.

## UI and acceptance tests

Display imported filename, current stage, cancel/retry action and actionable local
asset errors. Offer raw/derived text separately, showing pending normalization or
translation and segment review markers. Anonymous channels are not named speakers.

Before wiring the UI, add injected-process tests for: import permission expiration,
successful finalized-file enqueue, failed finalization, simultaneous capture/import,
stage parsing, cancellation, worker crash, restart recovery, unsupported schema,
and absent binary/model. Run the existing capture suite and a manual recording
while processing is queued. Add model/GPU stress tests only after a local model is
explicitly configured. This is the gate for enabling automatic post-recording jobs.
