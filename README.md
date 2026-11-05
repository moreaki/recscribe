# RecScribe

Local-first audio recording and multilingual transcription for macOS.

RecScribe combines native macOS audio capture with local transcription,
source-linked text processing and reviewable recording sessions.

## Status

RecScribe is in active development. The current codebase provides system-audio,
per-application, microphone, and simultaneous playback + selected-input recording.
Combined capture retains separate source tracks and a derived stereo mix with
per-source recording health; see [capture sources](docs/capture-sources.md).
WAV originals support FLAC, Opus and M4A archive export. The local
WAV/session transcription now runs in the shared native Swift core, with a
whisper.cpp adapter, versioned canonical JSON and deterministic text/subtitle
exports. The app and `recscribe-text transcribe` CLI require neither Python nor
FFmpeg for recognition. FFmpeg is optional for FLAC, Opus and M4A archive export.
Text normalization, translation and source-linked summaries use the same Swift
core, with opt-in Ollama or explicitly approved OpenAI text processing.
Diarization remains pending. See the [Swift migration](docs/swift-first-migration.md),
[WAV guide](docs/wav-vertical-slice.md) and
[architecture](docs/transcription-architecture.md).

No RecScribe release or automatic update channel exists yet. Development builds do not
contact an automatic update service.

## Principles

- Local-first processing: recordings and transcripts stay on the Mac by default.
- Accurate multilingual output with explicit source and target languages.
- A canonical, machine-readable transcript plus Markdown, TXT, SRT, and VTT exports.
- Fast Apple Silicon execution with quality profiles for draft and verified output.
- Clear separation between verbatim transcription, normalization, and translation.

## Saved transcripts

Studio restores the last transcript only when its recording and audio parts are
still readable. A missing recording leaves the app ready for a new take; its
retained transcript can still be opened with **Open transcript…**.

To delete a saved transcript, open it in Studio and choose **Delete transcript…**,
then **Move transcript to Trash**. This moves the entire RecScribe job folder,
including its summary and exports, to Trash and keeps the original recording.
Deletion is unavailable during capture/background work and for folders outside
RecScribe’s managed Jobs directory.

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

Builds are incremental by default and reuse `Build/DerivedData`. Request a clean
rebuild with `./scripts/build-app.sh --clean`; combine with `--ad-hoc` when needed.
`--help` lists the options. To build separately from the running app, set
`RECSCRIBE_BUILD_DIR` to another build-output directory before invoking the script.

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

Primary CI uses the Xcode minor version pinned in `.xcode-version` (currently
27.2) on GitHub's `xcode-27` runner. Debug tests and the independent Release build
use the same pin. CI validates this pinned toolchain; there is no separate
older-Xcode compatibility job or Intel-runner compilation check.
See GitHub's [standard runner labels](https://docs.github.com/en/actions/reference/runners/github-hosted-runners).
Image build numbers and host macOS versions can differ; each job reports Xcode,
Swift, SDK and OS versions. See the [official runner software inventory](https://github.com/actions/runner-images/blob/main/images/macos/xcode-27-arm64-Readme.md).

Before comparing local results with CI, verify the selected toolchain. Use
`DEVELOPER_DIR=/path/to/the/matching/Xcode.app/Contents/Developer` if needed;
the check does not change the system's selected Xcode. Then run the unit tests:

```bash
./scripts/check-toolchain.sh
xcrun swift test --package-path core
xcodebuild test \
  -project RecScribe/RecScribe.xcodeproj \
  -scheme RecScribe \
  -configuration Debug \
  -destination 'platform=macOS' \
  -only-testing:RecScribeTests
```

## Transcribe a finalized WAV locally

Build the native CLI and supply an installed `whisper-cli` and local ggml model.
The source can be a finalized integer PCM WAV or a `.recscribe.json` session.
No Python, virtual environment, pip installation or FFmpeg is needed.

```bash
swift build --package-path core -c release
core/.build/release/recscribe-text transcribe recording.wav \
  --whisper-cli /absolute/path/to/whisper-cli \
  --model /absolute/path/to/ggml-model.bin \
  --source-language de-CH --mode verbatim --threads 2 --local-only \
  --output jobs/first-recording
```

Jobs preserve original audio and exact per-channel ASR JSON/logs. Disposable
working/region WAVs are removed on success, failure or cancellation; their hashes
and preparation metadata remain in the manifest/raw indexes. Cancel with Ctrl-C
or a `cancel.request` file in the job directory. Use the terminal manifest state
to distinguish complete, reviewable, failed and cancelled results. See the WAV
guide for all modes, profiles, artifact contracts and current limitations.

`normalize` and `translate` retain pending derivations until a separate native
`derive` action or the app's configured local text step completes. `verified`
requires a second distinct model. The old Python pipeline has been removed.
Frozen synthetic reference fixtures now check canonical semantics and byte-identical
exports in every Swift test run. Corpus benchmarks also use the native CLI;
see [benchmark instructions](benchmarks/README.md).

## Source provenance

The recording foundation, interface controls, test fixtures and development tools
use the replacement implementations documented in the
[component assessment](docs/provenance/recording-foundation.md). The assessment
records compatibility contracts, validation, the final notice disposition and the
limits of historical line matching. The boundary guard checks every tracked file
and the built app without file exceptions. Development uses this repository's own
branches, CI and preserved Git history.

## Project layout

```text
RecScribe/                         SwiftUI application and Xcode project
core/                              Shared native audio/text jobs and Swift CLI
core/Tests/RecScribeCoreTests/Fixtures/ Frozen synthetic migration references
schemas/transcript.schema.json      Canonical transcript contract
benchmarks/                        Local corpus protocol and readiness manifest
skills/recscribe/                  Thin Codex wrapper for the CLI
docs/transcription-architecture.md Processing architecture and delivery plan
scripts/                           Development and packaging helpers
```

## Privacy

RecScribe performs no telemetry or analytics. Recording is local. Any future optional
cloud transcription backend must be explicit, disabled by default, and clearly visible
to the user before audio leaves the Mac.

## License and attribution

RecScribe uses the Apache License 2.0. Source attribution and the current
replacement status are recorded in [`LICENSE`](LICENSE),
[`NOTICE`](NOTICE), and [`docs/licensing.md`](docs/licensing.md).


Audio levels are available in the Studio and menu-bar popover: input/source gain,
channel trims, recording master and mute; separate playback and optional headphone
monitor volume/mute/output-device controls. Combined source tracks remain at unity
gain; single-source WAVs contain the applied gain. See
[recording gain and listening volume](docs/capture-sources.md#recording-gain-and-listening-volume-17--18)
for control scope, hardware-volume support and monitoring limits.

To capture multiple microphones/interfaces together with playback, expand **Capture
inputs** in Studio or the menu-bar popover and choose **Use multiple inputs +
playback**. Select up to eight devices and configure their mix channels. Each device
gets a separate synchronized source recording, gain controls and a derived stereo
mix. See [multiple-input recording](docs/multiple-inputs.md) for routing, failure
handling, resource limits and hardware verification status.

In **Audio Routing**, **Test audio** shows live source/channel and stereo-mix
meters while you adjust gain and mute. **Record 10-second sample** captures a
temporary take that you can play through the selected output, keep or discard.
Opening the window does not start capture. See the
[live audio test guide](docs/live-audio-test.md) for listening controls and sample
cleanup.
