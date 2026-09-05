# Changelog

All notable RecScribe changes will be documented in this file.

## Unreleased

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
