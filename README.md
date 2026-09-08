# RecScribe

Local-first audio recording and multilingual transcription for macOS.

RecScribe starts from the proven SwiftUI and ScreenCaptureKit recording foundation of
[Home Rec](https://github.com/melissa-pereira-deel/home-rec) and develops it into an
independent application for precise, private, high-performance transcription.

## Status

RecScribe is in active development. The current codebase provides system-audio,
per-application, and microphone recording with WAV, FLAC, and M4A output. The local
WAV transcription CLI now provides a tested local vertical slice with a
whisper.cpp adapter, versioned canonical JSON and deterministic text/subtitle
exports. Text normalization, translation and source-linked summaries now use a
shared native Swift core, with opt-in Ollama or explicitly approved OpenAI text
processing. Diarization remains pending. See the [Swift migration](docs/swift-first-migration.md),
[WAV guide](docs/wav-vertical-slice.md) and
[architecture](docs/transcription-architecture.md).

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
- Xcode 26 or later (Swift 6.2 toolchain for the shared core)
- Swift 6 language mode
- An Apple Developer account for local signing
- Screen Recording permission for system or per-application audio
- Microphone permission when recording an input device

## Build locally

```bash
git clone git@github.com:moreaki/recscribe.git
cd recscribe
git config core.hooksPath .githooks
app_path="$(./scripts/build-app.sh | tail -n 1)"
open "$app_path"
```

The script creates an optimized Release build under `Build/Products/Release` without
opening Xcode. It uses automatic signing with Apple Developer Team `CDS4KLP8GT`, the
bundle identifier `com.moreaki.recscribe`, hardened runtime, and provisioning updates
managed by Xcode's command-line build tools. Xcode must be installed, but its GUI does
not need to be open.

For an offline build that does not require an Apple identity, use:

```bash
./scripts/build-app.sh --ad-hoc
```

An ad-hoc build is intended for local development and may require macOS permissions
again after rebuilding. The signed build is the normal development path.

RecScribe, RecScribeTests, and RecScribeUITests compile in Swift 6 language mode with
complete concurrency checking. The application target uses Main Actor isolation as
its default; the test targets retain their nonisolated XCTest-compatible default.

You can still open `RecScribe/RecScribe.xcodeproj`, select the **RecScribe** scheme,
and build with Command-B when working in Xcode.

Run the unit tests from the command line:

```bash
swift test --package-path core
xcodebuild test \
  -project RecScribe/RecScribe.xcodeproj \
  -scheme RecScribe \
  -destination 'platform=macOS' \
  -only-testing:RecScribeTests
```

## Transcribe a finalized WAV locally

The separate pipeline requires Python 3.12+, FFmpeg, a local `whisper-cli` and an
existing ggml model. It never downloads a model or uses a cloud fallback.

```bash
python3 -m venv pipeline/.venv
pipeline/.venv/bin/python -m pip install -e ./pipeline
pipeline/.venv/bin/recscribe recording.wav \
  --whisper-cli /absolute/path/to/whisper-cli \
  --model /absolute/path/to/ggml-model.bin \
  --source-language de-CH --mode verbatim --local-only \
  --output jobs/first-recording
pipeline/.venv/bin/python -m unittest discover -s pipeline/tests -v
```

Jobs preserve original audio and exact per-channel ASR JSON. Cancel with Ctrl-C
or a `cancel.request` file in the job directory. Use the terminal manifest state
to distinguish complete, reviewable, failed and cancelled results. See the WAV
guide for all modes, profiles, artifact contracts and current limitations.

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
pipeline/                          Standalone local WAV CLI and synthetic tests
schemas/transcript.schema.json      Canonical transcript contract
benchmarks/                        Local corpus protocol and readiness manifest
skills/recscribe/                  Thin Codex wrapper for the CLI
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
