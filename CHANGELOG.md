# Changelog

All notable RecScribe changes will be documented in this file.

## Unreleased

### Added

- A standalone local WAV transcription CLI with streamed PCM inspection,
  per-channel working copies, cancellable jobs and the whisper.cpp adapter.
- Versioned canonical JSON, immutable raw-ASR evidence and deterministic Markdown,
  TXT, SRT, VTT and review exports. Unimplemented language/speaker stages remain
  explicit pending/review states; verified mode requires two distinct local models.
- Synthetic pipeline tests and documented CLI, benchmark and SwiftUI integration
  boundaries. Capture code and signing configuration remain unchanged.

### Changed

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
