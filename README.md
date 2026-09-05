# RecScribe

Local-first audio recording and multilingual transcription for macOS.

RecScribe starts from the proven SwiftUI and ScreenCaptureKit recording foundation of
[Home Rec](https://github.com/melissa-pereira-deel/home-rec) and develops it into an
independent application for precise, private, high-performance transcription.

## Status

RecScribe is in active development. The current codebase provides system-audio,
per-application, and microphone recording with WAV, FLAC, and M4A output. The local
transcription pipeline described in
[`docs/transcription-architecture.md`](docs/transcription-architecture.md) is the next
major implementation phase.

No RecScribe release or automatic update channel exists yet. Development builds do not
contact the Home Rec update service.

## Principles

- Local-first processing: recordings and transcripts stay on the Mac by default.
- Accurate multilingual output with explicit source and target languages.
- A canonical, machine-readable transcript plus Markdown, TXT, SRT, and VTT exports.
- Fast Apple Silicon execution with quality profiles for draft and verified output.
- Clear separation between verbatim transcription, normalization, and translation.

## Requirements

- macOS 15 or later
- Xcode 16 or later
- An Apple Developer account for local signing
- Screen Recording permission for system or per-application audio
- Microphone permission when recording an input device

## Build locally

```bash
git clone git@github.com:moreaki/recscribe.git
cd recscribe
git config core.hooksPath .githooks
open RecScribe/RecScribe.xcodeproj
```

The project uses automatic signing with Apple Developer Team `VFABJ5RE5Q` and the
bundle identifier `com.moreaki.recscribe`. Select the **RecScribe** scheme and run it
from Xcode.

Run the unit tests from the command line:

```bash
xcodebuild test \
  -project RecScribe/RecScribe.xcodeproj \
  -scheme RecScribe \
  -destination 'platform=macOS' \
  -only-testing:RecScribeTests
```

## Upstream workflow

RecScribe is an independent repository, not a GitHub fork. `origin` belongs to
RecScribe; Home Rec is an optional `upstream` remote used only for deliberate manual
synchronization.

```bash
git remote add upstream https://github.com/melissa-pereira-deel/home-rec.git
git fetch upstream
git merge upstream/main
```

Review every upstream merge carefully: RecScribe owns its application identity,
signing, release process, update channel, and product direction.

## Project layout

```text
RecScribe/                         SwiftUI application and Xcode project
docs/transcription-architecture.md Processing architecture and delivery plan
docs/upstream-home-rec-changelog.md Historical changelog inherited from Home Rec
scripts/                           Development and packaging helpers
```

## Privacy

RecScribe performs no telemetry or analytics. Recording is local. Any future optional
cloud transcription backend must be explicit, disabled by default, and clearly visible
to the user before audio leaves the Mac.

## License and attribution

RecScribe currently remains under the Apache License 2.0. It includes software derived
from Home Rec, Copyright 2026 Melissa de Britto. See [`LICENSE`](LICENSE),
[`NOTICE`](NOTICE), and [`docs/licensing.md`](docs/licensing.md).
