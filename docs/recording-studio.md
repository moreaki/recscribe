# Recording Studio and opt-in live transcription

## UI and ownership

RecScribe 0.2.0 adopts Quantivane's compact icon navigation, grouped settings
cards and restrained mint/blue/violet accents, with Modex-style workspace
separation. Record/stop retains the existing red identity. Shared geometry and
chrome live in `WorkspaceStyle` and `AppWindow`; no image-generation dependency
or borrowed product logo was added.

- One reusable Studio window: capture controls and live opt-in on the left;
  Live, Transcript, Summary and Review on the right.
- Settings: Recording, Transcription, Models, Intelligence and Diagnostics.
  Existing paths and preferences are preserved by per-field migration.
- Recordings: playback, transcription, export and a More menu containing
  source-linked summary processing and recovery.
- Command-1 opens Studio, Command-O opens Recordings, Command-comma opens
  Settings. Closing Studio does not stop the recorder. The menu-bar panel
  retains independent record/stop and the same live switch.
- The live text bubble offers a native popover on hover **or click**, so hover
  is not the only access path. Text is selectable, has no web view and cannot
  inject links, scripts or remote images. Completed documents can be reopened
  with Open transcript by choosing their job folder.
- Follow live keeps the newest paragraph visible; it can be turned off while
  reading earlier text. Pipeline configuration/errors are visible in Studio.

High-frequency waveform observation stays inside the capture view. Disk and
ASR work are outside SwiftUI; `TranscriptPreview` is a read-only projection of
canonical JSON, not another transcription source.

## Live flow and guarantees

1. Recording continues through the existing PCM writer, format normalization,
   size rollover, disk-space checks and crash-recovery path.
2. Opt-in can be armed before capture or enabled while capturing. A cursor
   starts at frame zero, so enabling later catches up with already saved audio.
3. A utility worker snapshots complete persisted frames, checking file ownership,
   format and part continuity. It never updates headers or takes the writer's
   lease. Partial trailing frames are not read. The disk-backed source is the
   queue: slow ASR does not accumulate a second audio backlog in RAM.
4. Native `AVAudioConverter` creates disposable 16-kHz PCM channel copies.
   Identical channels share a run; different channels remain separate. Exact
   digital silence skips ASR. This is not probabilistic VAD or speaker detection.
5. One `whisper-cli` child at a time uses utility QoS and 1–4 configurable CPU
   threads (default 2). Metal is left enabled by the reference backend; hardware
   detection remains an explicit Settings action. There is no network fallback.
6. Chunks are 10, 20 or 30 seconds (default 20), with one second of left context.
   Context-only segments are omitted; straddling timestamps are clipped to the
   new range. Word-level duplication/truncation at seams still needs review.
7. A cursor advances only after a successful result. Disable cancels the owned
   worker; re-enable waits for its exit before resuming. New sessions invalidate
   old results. Errors disable only live ASR, never capture.
8. After stop, a short tail drains asynchronously. Verification/archive/full
   transcription wait for the live worker; a new recording still takes priority.
   Quitting cancels ASR and waits for owned work to exit.

## Evidence, privacy and performance

Each run gets a private `Application Support/RecScribe/Live/<UUID>` directory.
Attempt subdirectories retain unchanged channel raw JSON plus versioned
`chunk.json` (source manifest, model, frame range, detected language, channel,
timing and `needsReview`). `latest.json` is an atomic checkpoint of the last
successful worker output. Disposable PCM copies are removed on success/error.
Original recordings are never removed or modified by this path.

The UI retains at most 80 segments / 48,000 characters. Full chunk evidence
remains on disk; live evidence is **not** the canonical final transcript. There
is no automatic crash-resume of a live worker yet; use finalized session
processing/recovery for the authoritative result. Cancelled attempts may leave
raw evidence without a successful chunk checkpoint. Inspect before sharing.

Unified logs contain operation IDs, frame ranges, elapsed time and channel
counts, never transcript text. Process diagnostics use the existing bounded,
private runner. Queue lag is explicitly a snapshot, not a continuously measured
end-to-end latency. The UI shows the last chunk's measured processing time.

On the local Apple M1 MacBook Air, a synthetic English `base` model smoke test
processed 10 seconds of audio in **1.47 s**, then the following chunk in
**0.81 s**, including native preparation. These are specific warm-system
measurements, not a promise for other models, languages, speakers or hardware.

## Boundaries and follow-up

- `whisper-cli` reloads the model for each chunk. Avoiding that cost requires a
  persistent/in-process adapter; it is deliberately not disguised as solved.
  More simultaneous GPU jobs are not assumed to improve throughput.
- Automatic language identification is per chunk/channel. Code-switching
  inside a chunk, silence/noise hallucinations and boundary words need review.
  There are no invented confidence values, speaker names or missing words.
- Normalize/translate and summary generation remain explicit **post-recording**
  local-AI stages. Live text is verbatim ASR draft, never silently rewritten.
- Summary requests require enabled local AI and an installed selected model.
  Missing configuration produces an actionable message; no automatic download.
- This does not implement simultaneous system/microphone multi-source capture
  (the separately scoped issue #1), persistent model residency or full diarization.

## Interruption handling — 0.2.1

ScreenCaptureKit ended a local test session at essentially the same time as a
display-sleep notification. The original error was redacted, so this is evidence
of correlation, not proof of the specific underlying error. All 68,267 accepted
buffers were written (zero rejected; peak queue 5 buffers / 38,400 PCM bytes;
maximum queue wait 4.62 ms). The 22:45.34 audio file's hash matched its manifest.
That proves the received audio was retained, not that capture lasted as intended.

- `RecordingActivity` scopes the native idle-system/display-sleep assertions to
  startup, capture and file finalization. They are released on stop, failed
  startup, interruption and owner teardown. They do not apply to subsequent ASR
  or change system power settings. The recorder explains this screen/battery
  tradeoff while capturing. See Apple's [activity options](https://developer.apple.com/documentation/foundation/processinfo/activityoptions).
- Forced system/display sleep is treated as an interruption. Workspace sleep
  notifications and ScreenCaptureKit failures share the existing finalization
  path. Duplicate failures do not finalize twice. Capture teardown drains queued
  callbacks even if macOS already stopped the stream; it does not issue redundant
  stop requests to a stopped stream. See Apple's [screen sleep notification](https://developer.apple.com/documentation/appkit/nsworkspace/screensdidsleepnotification).
- Closing the lid, forced sleep, power loss or a disconnected source are not
  prevented by an idle-sleep assertion. Teardown is best-effort if the OS suspends
  the process; existing per-part crash recovery remains necessary. There is no
  automatic recording restart after wake and no claim of gap-free sleep capture.
- Error headings and persistent details derive from `RecordingState`. The UI
  offers the recording library for verification, not an assumed permission fix.
  The displayed stop time is the UI timer; the library reports saved audio duration.
  Retry is blocked until interrupted-file finalization finishes; app termination
  also waits for that work. The capture rail scrolls at smaller window heights.
- Live work drains the available audio, but an interrupted/failed-finalization
  session retains a **partial draft / needs review** banner, including when live
  transcription is switched off. A new recording clears this session-specific
  state. Final canonical processing and summary remain separate opt-in stages.
- Chunk evidence/logs now include `asrRuns`: zero means verified digital silence,
  not merely an empty recognizer result. Older JSON without the optional field
  remains readable. UI timing distinguishes processing time from audio duration,
  shows milliseconds for short work, and explicitly labels skipped ASR. No timing
  is shown before a chunk completes; a new recording resets the previous timing.
- Release logs retain failure operation, NSError domain/code, power event,
  correlation IDs and elapsed time. Error descriptions remain private. A second
  finalization failure is logged and included in session review issues without
  replacing the original capture interruption. No transcript text is logged.

## Regression coverage

Synthetic tests cover live multipart byte continuity, unchanged original hashes,
stale active WAV headers, short final tails, channel equality/separation, native
resampling/EOF flushing, output collisions, missing/replaced/gapped parts,
cancellation, rapid opt-out/in, old-session results, bounded previews, preference
migration, literal Markdown safety and canonical text/summary provenance. A
real offline Whisper smoke test runs only when the existing base model and CLI
are available; it generates speech locally and downloads nothing.

## Local acceptance — 2026-09-08

- Release unit suite: **359 tests / 391 executions**, no failures or skips.
  Result: `Build/TestDerivedData/Logs/Test/Test-RecScribe-2026.09.08_21-52-45-+0200.xcresult`.
  Log: `Build/studio-all-tests.log`.
- Python pipeline: **38 tests passed** (`Build/studio-python-tests.log`).
- Real ASR passed in the focused run above and again in the full suite
  (1.17 s / 0.79 s per first/following synthetic chunk).
- Signed local Release: **0.2.0 (200), arm64, com.moreaki.recscribe,
  CDS4KLP8GT**, Swift 6 complete checking, Hardened Runtime, strict codesign
  verification; no get-task-allow entitlement. Apple Development identity,
  **not a notarized Developer ID distribution**. No Apple account mutations.
- Studio, Settings sections, saved runtime/model paths and the native live
  popover were inspected. A user-started live recording remained uninterrupted;
  its transcript is not included in this repository or report.
- The final Follow live / inline-error/accessibility UI polish was subsequently
  compiled and signed at `Build/StudioCandidate/RecScribe/RecScribe.app`
  (`Build/studio-candidate.log`). It was deliberately not launched or copied over
  the app executing the user's active recording. Quit normally after capture
  finishes before opening that candidate. The complete suite above predates
  only this presentation-only polish; its production audio code is unchanged.

## Interruption-fix acceptance — 2026-09-08

- Final Release suite: **370 tests / 402 executions**, zero failures or skips,
  including the enabled synthetic UI snapshots. Result:
  `Build/TestDerivedData/Logs/Test/Test-RecScribe-2026.09.08_23-07-24-+0200.xcresult`.
  Full log: `Build/capture-interruption-all-tests.log`.
- Regression tests simulate workspace sleep (including during startup), duplicate
  capture failures, writer/stop errors, delayed finalization and retry. They check
  assertion release on every exit/deinit, no automatic restart on wake, persistent
  partial-draft state, status reset, backward-compatible chunk evidence and true
  digital silence without launching the ASR executable.
- Synthetic Studio snapshots exercise the dismissed-error state at 1060×700 and
  940×600. Inspect `Build/CaptureFix/Snapshots/studio-interrupted.png` and
  `studio-interrupted-minimum.png`; no private transcript is used.
- The Python suite passes all 38 tests (`Build/capture-interruption-python-tests.log`).
- Real offline Whisper smoke: first 10-second chunk **1.28 s**, following chunk
  **0.81 s**, including native preparation, using the already installed base model
  on this M1 MacBook Air. This is comparable to the earlier smoke baseline, not a
  throughput improvement claim. No audio callback or PCM writer loop was changed.
- Signed local Release **0.2.1 (201)**: arm64 / 64-bit, bundle
  `com.moreaki.recscribe`, team `CDS4KLP8GT`, Swift 6 with complete concurrency
  checking, Hardened Runtime, valid strict code signature and no get-task-allow.
  Identity remains Apple Development; not notarized or distribution-ready.
  The signing skill's Developer ID audit appropriately rejects that authority;
  local codesign verification passes.
- The build used the project's Release settings and existing identity, omitting
  `-allowProvisioningUpdates` from the build script's equivalent Xcode invocation.
  No Apple account changes, cloud submission or model download took place.
- The app was started without Xcode at `Build/Products/Release/RecScribe.app`
  after confirming the previous instance was idle. The old 0.2.0 bundle is kept
  in `Build/PreviousRelease/RecScribe-0.2.0-20260908.app`; recordings and stashes
  were not changed. A physical lid-close/forced-sleep test was deliberately not
  performed on the user's active Mac; simulation does not guarantee that macOS
  will let finalization finish before suspending the process.
