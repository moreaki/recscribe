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
- Established RecScribe as an independent application based on Home Rec.
- Renamed the Xcode project, application target, test targets, source directories,
  product strings, diagnostics, and bundle identifiers.
- Configured automatic signing for Apple Developer Team `CDS4KLP8GT`.
- Migrated the application and test targets to Swift 6 language mode with complete
  concurrency checking.
- Added a command-line signed or ad-hoc Release build under
  `scripts/build-app.sh`.
- Reset the application version to `0.1.0` (`CFBundleVersion` 100).
- Removed the inherited Home Rec Sparkle feed, signing key, update UI, and package
  dependency. RecScribe will add its own update channel before distributing releases.
- Added explicit Home Rec attribution and licensing guidance.

The inherited Home Rec release history is preserved in
[`docs/upstream-home-rec-changelog.md`](docs/upstream-home-rec-changelog.md).
