# Changelog

All notable RecScribe changes will be documented in this file.

## Unreleased

### Added

- Studio can move a saved transcript and its job artifacts to Trash while keeping
  the original recording. Active jobs and arbitrary external folders are protected.

- A standalone local WAV transcription CLI with streamed PCM inspection,
  per-channel working copies, cancellable jobs and the whisper.cpp adapter.
- Versioned canonical JSON, immutable raw-ASR evidence and deterministic Markdown,
  TXT, SRT, VTT and review exports. Unimplemented language/speaker stages remain
  explicit pending/review states; verified mode requires two distinct local models.
- Synthetic pipeline tests and documented CLI, benchmark and SwiftUI integration
  boundaries. Capture code and signing configuration remain unchanged.

### Changed

- Replaced the native PCM decoder, streaming normalizer, WAV sink and permission
  request/watcher implementations. Existing recording contracts and quantization
  remain covered by the established suite. Native controls and independent test/
  tool contracts complete the source replacement. Superseded attribution is retired;
  the Apache license and applicable notices remain, and the source guard has no
  file exceptions.

- Stopping a finalized multi-source recording reports clipping/timing/coverage
  notes inline instead of misreporting them as a failed save. Genuine capture
  shutdown failures have a distinct diagnosis; recoverable audio remains intact.

- SwiftUI state uses per-property Observation. Capture telemetry and test meters
  update their leaf views without broadcasting to Settings or workspace chrome.
  Recorder commands, permissions, installation notices and preferences have
  separate owners. The menu-bar popover resizes to content within screen bounds
  with one scrolling area and a persistent Quit footer.

- Startup validates the saved transcript and recording before restoring Studio.
  Missing recordings or audio parts leave a clean workspace; retained transcripts
  can still be opened explicitly, with unavailable audio actions disabled.

- Final WAV/session recognition now runs in shared native Swift code in the app
  and `recscribe-text transcribe`, with configured whisper.cpp threads, verified
  passes, channel/window provenance and continuous multipart timelines. Python
  runtime setup and pipeline archive packaging are removed from the shipping app;
  FFmpeg is optional for archive compression. Disposable working/region WAVs are
  removed on terminal completion while raw ASR JSON/logs and hashes are retained.
- Live Whisper speech with a zero-duration timestamp is retained at the reported
  point with an explicit timing-review flag and visible warning. It no longer
  stops the chunk; no words are deduplicated or durations fabricated. Invalid
  negative, reversed or out-of-window speech times still fail explicitly.
- Live Whisper previews ignore known non-speech markers, including zero-length
  `[BLANK_AUDIO]`, without discarding valid speech in the same chunk. Malformed
  local recognizer output retries once at the committed cursor, then stops
  visibly without skipping audio. Cancellation and source/configuration failures
  are not retried; raw evidence and separate audio channels are preserved.
- Live source-language arguments now trim whitespace and normalize regional
  choices such as `de-CH` to `de`. Automatic detection remains per chunk/channel
  instead of silently locking later speech to an earlier language.
- Established the RecScribe application identity.
- Renamed the Xcode project, application target, test targets, source directories,
  product strings, diagnostics, and bundle identifiers.
- Configured automatic signing for Apple Developer Team `CDS4KLP8GT`.
- Migrated the application and test targets to Swift 6 language mode with complete
  concurrency checking.
- Added a command-line signed or ad-hoc Release build under
  `scripts/build-app.sh`.
- Reset the application version to `0.1.0` (`CFBundleVersion` 100).
- Removed the inherited automatic-update feed, signing key, update UI, and package
  dependency. RecScribe will add its own update channel before distributing releases.
- Added source attribution and licensing guidance.

Source replacement progress is recorded in
[`docs/provenance/recording-foundation.md`](docs/provenance/recording-foundation.md).
