# Recording foundation replacement status

Issue: #51. This is an **in-progress inventory**, not a declaration of source independence.
The required end state includes all legacy material from `melissa-pereira-deel` and
`Claude` (implementations, tests/fixtures, assets, tooling, and obsolete references).

## Evidence and limits

The original comparison snapshot is `2f9c42dd92dad72cb7e1d29ce555c2ee48967e53`.
The starting RecScribe snapshot is `5dda6302efc3a06490f19769004ef72949b16b25`.
A log scan finds 94 commits with Claude/Anthropic author or message references;
all are ancestors of the comparison snapshot. Commit names and unchanged lines
are evidence for review, not proof of authorship or independence. Modified or
copied material can have no surviving original lines.

Run `python3 scripts/audit-source-provenance.py --output /tmp/recscribe-provenance.json`
for a per-file inventory of the tracked tree, including exact binary matches,
source origins and content hashes. This is developer tooling only; the app and
native CLI do not acquire a Python runtime dependency.

## First replacement candidate

The public contracts and established test cases are retained for compatibility.
The following implementations have been replaced and require review:

- PCM decoder: explicit byte-level integer/float decoding, container/sign/endian
  handling, source-plane validation and payload bounds before reading samples.
- Normalizer: one converter session per source format, canonical pass-through,
  first-pair channel selection, and retained resampling history across callbacks.
- WAV sink: descriptor-owned positional writes, bounded payload arithmetic,
  checkpoint writes independent of payload offsets, and final sync without
  reopening a potentially replaced pathname. Established PCM quantization stays
  unchanged to preserve golden-file and session compatibility.
- Permission manager: explicit idle/pending/completed request state, shared
  in-flight screen probe, cached passive reads, and separate microphone requests.
- Permission watcher: finite observation runs with generation identities,
  cancellation, one grant callback and activity-assertion teardown.

Existing inherited test implementations remain as behavioral acceptance contracts
for this first candidate; retaining them does **not** satisfy the final removal
requirement. Original/raw data, schemas, stored session formats, signing identity,
entitlements and privacy permissions are not migrated by this candidate.

## Initial ancestry candidates

Before the documentation cleanup, the initial scan found 105 tracked files with direct original ancestry or exact
original content, including 52 entries under the production app directory. Some
are standard metadata, declarations, or trivial lines; each still needs review.
The 239 files without direct matches also need provenance review before closure.
These are starting-point counts; the table is historical audit evidence, not the
current remaining-file count. The scan excludes the five replacement implementation
files from these counts. Regenerate the JSON inventory for current file status.

| Current path | Unchanged ancestral lines | Original path(s) |
| --- | ---: | --- |
| `.githooks/pre-commit` | 50 | `.githooks/pre-commit` |
| `.github/workflows/ci.yml` | 101 | `.github/workflows/ci.yml` |
| `.gitignore` | 83 | `.gitignore` |
| `CHANGELOG.md` | 2 | `CHANGELOG.md` |
| `LICENSE` | 160 | `LICENSE` |
| `NOTICE` | 12 | `NOTICE` |
| `README.md` | 8 | `README.md` |
| `RecScribe/.gitignore` | 22 | `HomeRec/.gitignore` |
| `RecScribe/RecScribe.entitlements` | 19 | `HomeRec/HomeRec.entitlements` |
| `RecScribe/RecScribe.xcodeproj/project.pbxproj` | 473 | `HomeRec/HomeRec.xcodeproj/project.pbxproj` |
| `RecScribe/RecScribe.xcodeproj/project.xcworkspace/contents.xcworkspacedata` | 7 | `HomeRec/HomeRec.xcodeproj/project.xcworkspace/contents.xcworkspacedata` |
| `RecScribe/RecScribe.xcodeproj/project.xcworkspace/xcshareddata/WorkspaceSettings.xcsettings` | 5 | `HomeRec/HomeRec.xcodeproj/project.xcworkspace/xcshareddata/WorkspaceSettings.xcsettings` |
| `RecScribe/RecScribe/App/AppDelegate.swift` | 6 | `HomeRec/HomeRec/AppDelegate.swift` |
| `RecScribe/RecScribe/App/Clock.swift` | 45 | `HomeRec/HomeRec/Clock.swift`, `HomeRec/HomeRec/PollClock.swift` |
| `RecScribe/RecScribe/App/Diagnostics.swift` | 84 | `HomeRec/HomeRec/Diagnostics.swift` |
| `RecScribe/RecScribe/App/DiskSpace.swift` | 19 | `HomeRec/HomeRec/DiskSpace.swift` |
| `RecScribe/RecScribe/App/InstallLocation.swift` | 139 | `HomeRec/HomeRec/InstallLocation.swift` |
| `RecScribe/RecScribe/App/Log.swift` | 18 | `HomeRec/HomeRec/Log.swift` |
| `RecScribe/RecScribe/App/MenuBarController.swift` | 126 | `HomeRec/HomeRec/MenuBarController.swift` |
| `RecScribe/RecScribe/App/OverflowContext.swift` | 62 | `HomeRec/HomeRec/OverflowContext.swift` |
| `RecScribe/RecScribe/App/OverflowMenu.swift` | 441 | `HomeRec/HomeRec/OverflowMenu.swift` |
| `RecScribe/RecScribe/App/PerAppMenuDelegate.swift` | 81 | `HomeRec/HomeRec/PerAppMenuDelegate.swift` |
| `RecScribe/RecScribe/App/PermissionKind.swift` | 61 | `HomeRec/HomeRec/PermissionKind.swift` |
| `RecScribe/RecScribe/App/PermissionProviding.swift` | 51 | `HomeRec/HomeRec/PermissionManager.swift`, `HomeRec/HomeRec/PermissionProviding.swift` |
| `RecScribe/RecScribe/App/RecScribeApp.swift` | 13 | `HomeRec/HomeRec/HomeRecApp.swift` |
| `RecScribe/RecScribe/App/SaveLocationProviding.swift` | 65 | `HomeRec/HomeRec/SaveLocationProviding.swift` |
| `RecScribe/RecScribe/Assets.xcassets/AccentColor.colorset/Contents.json` | 11 | `HomeRec/HomeRec/Assets.xcassets/AccentColor.colorset/Contents.json` |
| `RecScribe/RecScribe/Assets.xcassets/AppIcon.appiconset/Contents.json` | 68 | `HomeRec/HomeRec/Assets.xcassets/AppIcon.appiconset/Contents.json` |
| `RecScribe/RecScribe/Assets.xcassets/Contents.json` | 6 | `HomeRec/HomeRec/Assets.xcassets/Contents.json` |
| `RecScribe/RecScribe/Capture/AudioCapableProcesses.swift` | 78 | `HomeRec/HomeRec/AudioCapableProcesses.swift` |
| `RecScribe/RecScribe/Capture/AudioCapturing.swift` | 22 | `HomeRec/HomeRec/AudioCapturing.swift` |
| `RecScribe/RecScribe/Capture/AudioFormat.swift` | 64 | `HomeRec/HomeRec/AudioFormat.swift` |
| `RecScribe/RecScribe/Capture/AudioRecorder.swift` | 48 | `HomeRec/HomeRec/AudioFileWriting.swift`, `HomeRec/HomeRec/AudioRecorder.swift`, `HomeRec/HomeRec/WaveformDownsampler.swift` |
| `RecScribe/RecScribe/Capture/AudioSource.swift` | 23 | `HomeRec/HomeRec/AudioSource.swift` |
| `RecScribe/RecScribe/Capture/AudioSourceManager.swift` | 181 | `HomeRec/HomeRec/AudioSourceManager.swift` |
| `RecScribe/RecScribe/Capture/AudioTestController.swift` | 1 | `HomeRec/HomeRec/RecorderViewModel.swift` |
| `RecScribe/RecScribe/Capture/InputDeviceEnumerator.swift` | 31 | `HomeRec/HomeRec/InputDeviceEnumerator.swift` |
| `RecScribe/RecScribe/Capture/MonitorController.swift` | 217 | `HomeRec/HomeRec/MonitorController.swift` |
| `RecScribe/RecScribe/Capture/MultiSourceRecorder.swift` | 1 | `HomeRec/HomeRec/AudioRecorder.swift` |
| `RecScribe/RecScribe/Capture/RecorderCoordinators.swift` | 82 | `HomeRec/HomeRec/RecorderViewModel.swift` |
| `RecScribe/RecScribe/Capture/RecorderPreferences.swift` | 33 | `HomeRec/HomeRec/RecorderViewModel.swift` |
| `RecScribe/RecScribe/Capture/RecorderPresentation.swift` | 31 | `HomeRec/HomeRec/RecorderViewModel.swift` |
| `RecScribe/RecScribe/Capture/RecorderViewModel.swift` | 141 | `HomeRec/HomeRec/RecorderViewModel.swift` |
| `RecScribe/RecScribe/Capture/RecordingController.swift` | 140 | `HomeRec/HomeRec/RecordingController.swift`, `HomeRec/HomeRec/RecordingControlling.swift` |
| `RecScribe/RecScribe/Capture/RecordingState.swift` | 152 | `HomeRec/HomeRec/RecordingState.swift` |
| `RecScribe/RecScribe/Capture/ScreenCaptureAudioManager.swift` | 163 | `HomeRec/HomeRec/ScreenCaptureAudioManager.swift` |
| `RecScribe/RecScribe/Capture/SynchronizedCaptureWriter.swift` | 2 | `HomeRec/HomeRec/AudioRecorder.swift` |
| `RecScribe/RecScribe/DesignSystem/Adapters/RecorderWaveformAdapter.swift` | 83 | `HomeRec/HomeRec/DesignSystem/Adapters/RecorderWaveformAdapter.swift` |
| `RecScribe/RecScribe/DesignSystem/Core/Components/GlassWaveform.swift` | 71 | `HomeRec/HomeRec/DesignSystem/Vendor/Components/GlassWaveform.swift` |
| `RecScribe/RecScribe/DesignSystem/Core/Primitives/GlassBrandMark.swift` | 108 | `HomeRec/HomeRec/DesignSystem/Vendor/Primitives/GlassBrandMark.swift` |
| `RecScribe/RecScribe/DesignSystem/Core/Primitives/GlassHover.swift` | 39 | `HomeRec/HomeRec/DesignSystem/Vendor/Primitives/GlassHover.swift` |
| `RecScribe/RecScribe/DesignSystem/Core/Primitives/GlassIconButton.swift` | 65 | `HomeRec/HomeRec/DesignSystem/Vendor/Primitives/GlassIconButton.swift` |
| `RecScribe/RecScribe/DesignSystem/Core/Primitives/GlassPillButton.swift` | 415 | `HomeRec/HomeRec/DesignSystem/Vendor/Primitives/GlassPillButton.swift` |
| `RecScribe/RecScribe/DesignSystem/Core/Tokens/GlassColors.swift` | 262 | `HomeRec/HomeRec/DesignSystem/Vendor/Tokens/GlassColors.swift` |
| `RecScribe/RecScribe/DesignSystem/Core/Tokens/GlassMetrics.swift` | 96 | `HomeRec/HomeRec/DesignSystem/Vendor/Tokens/GlassMetrics.swift` |
| `RecScribe/RecScribe/DesignSystem/Core/Tokens/GlassMotion.swift` | 109 | `HomeRec/HomeRec/DesignSystem/Vendor/Tokens/GlassMotion.swift` |
| `RecScribe/RecScribe/DesignSystem/Core/Tokens/GlassTheme.swift` | 56 | `HomeRec/HomeRec/DesignSystem/Vendor/Tokens/GlassTheme.swift` |
| `RecScribe/RecScribe/DesignSystem/Core/Tokens/GlassTypography.swift` | 264 | `HomeRec/HomeRec/DesignSystem/Vendor/Tokens/GlassTypography.swift` |
| `RecScribe/RecScribe/Sessions/RecordingSession.swift` | 2 | `HomeRec/HomeRec/WAVWriter.swift` |
| `RecScribe/RecScribe/UI/FloatingPanelHost.swift` | 78 | `HomeRec/HomeRec/FloatingPanelHost.swift`, `HomeRec/HomeRec/PermissionGuidePanel.swift` |
| `RecScribe/RecScribe/UI/InstallLocationNoticeView.swift` | 31 | `HomeRec/HomeRec/InstallLocationNoticeView.swift` |
| `RecScribe/RecScribe/UI/MenuBarPopoverView.swift` | 20 | `HomeRec/HomeRec/MenuBarPopoverView.swift` |
| `RecScribe/RecScribe/UI/OnboardingView.swift` | 102 | `HomeRec/HomeRec/OnboardingView.swift` |
| `RecScribe/RecScribe/UI/RecorderView.swift` | 29 | `HomeRec/HomeRec/RecorderView.swift` |
| `RecScribe/RecScribeTests/AsyncWaiting.swift` | 84 | `HomeRec/HomeRecTests/AsyncWaiting.swift` |
| `RecScribe/RecScribeTests/AudioFileEncoderTests.swift` | 89 | `HomeRec/HomeRecTests/AudioFileEncoderTests.swift`, `HomeRec/HomeRecTests/GoldenFileTests.swift` |
| `RecScribe/RecScribeTests/AudioFormatNormalizerTests.swift` | 151 | `HomeRec/HomeRecTests/AudioFormatNormalizerTests.swift` |
| `RecScribe/RecScribeTests/AudioFormatTests.swift` | 42 | `HomeRec/HomeRecTests/AudioFormatTests.swift` |
| `RecScribe/RecScribeTests/AudioLevelsTests.swift` | 2 | `HomeRec/HomeRec/AudioRecorder.swift` |
| `RecScribe/RecScribeTests/AudioRecorderTests.swift` | 105 | `HomeRec/HomeRecTests/AudioRecorderTests.swift` |
| `RecScribe/RecScribeTests/AudioSampleConverterTests.swift` | 69 | `HomeRec/HomeRecTests/AudioSampleConverterTests.swift` |
| `RecScribe/RecScribeTests/AudioSourceManagerTests.swift` | 40 | `HomeRec/HomeRecTests/AudioSourceManagerTests.swift` |
| `RecScribe/RecScribeTests/AudioSourceTests.swift` | 29 | `HomeRec/HomeRecTests/AudioSourceTests.swift` |
| `RecScribe/RecScribeTests/BundledFontTests.swift` | 11 | `HomeRec/HomeRecTests/BundledFontTests.swift` |
| `RecScribe/RecScribeTests/CaptureSourceMenuTests.swift` | 486 | `HomeRec/HomeRecTests/CaptureSourceMenuTests.swift`, `HomeRec/HomeRecTests/Mocks.swift` |
| `RecScribe/RecScribeTests/DiagnosticsTests.swift` | 27 | `HomeRec/HomeRecTests/DiagnosticsTests.swift` |
| `RecScribe/RecScribeTests/EncoderFormatGuardTests.swift` | 68 | `HomeRec/HomeRecTests/EncoderFormatGuardTests.swift` |
| `RecScribe/RecScribeTests/GoldenFileTests.swift` | 86 | `HomeRec/HomeRecTests/GoldenFileTests.swift` |
| `RecScribe/RecScribeTests/InfoPlistTests.swift` | 158 | `HomeRec/HomeRecTests/InfoPlistTests.swift` |
| `RecScribe/RecScribeTests/InstallLocationTests.swift` | 287 | `HomeRec/HomeRecTests/InstallLocationTests.swift` |
| `RecScribe/RecScribeTests/MicrophoneFormatTests.swift` | 204 | `HomeRec/HomeRecTests/MicrophoneFormatTests.swift` |
| `RecScribe/RecScribeTests/Mocks.swift` | 277 | `HomeRec/HomeRecTests/Mocks.swift` |
| `RecScribe/RecScribeTests/MonitorControllerTests.swift` | 121 | `HomeRec/HomeRecTests/MonitorControllerTests.swift` |
| `RecScribe/RecScribeTests/OverflowMenuTests.swift` | 91 | `HomeRec/HomeRecTests/OverflowMenuTests.swift` |
| `RecScribe/RecScribeTests/PermissionGrantWatcherTests.swift` | 205 | `HomeRec/HomeRecTests/PermissionGrantWatcherTests.swift`, `HomeRec/HomeRecTests/PermissionGuideTests.swift` |
| `RecScribe/RecScribeTests/PermissionProbeTests.swift` | 283 | `HomeRec/HomeRecTests/PermissionGuideTests.swift`, `HomeRec/HomeRecTests/PermissionProbeTests.swift` |
| `RecScribe/RecScribeTests/RecorderViewModelTests.swift` | 539 | `HomeRec/HomeRecTests/RecorderViewModelTests.swift`, `HomeRec/HomeRecTests/SaveLocationTests.swift` |
| `RecScribe/RecScribeTests/RecorderWaveformAdapterTests.swift` | 119 | `HomeRec/HomeRecTests/RecorderWaveformAdapterTests.swift` |
| `RecScribe/RecScribeTests/RecordingControllerTests.swift` | 89 | `HomeRec/HomeRecTests/RecordingControllerTests.swift` |
| `RecScribe/RecScribeTests/RecordingInterruptionTests.swift` | 3 | `HomeRec/HomeRecTests/RecorderViewModelTests.swift`, `HomeRec/HomeRecTests/RecordingStateTests.swift` |
| `RecScribe/RecScribeTests/RecordingSessionTests.swift` | 4 | `HomeRec/HomeRecTests/M4AEncoderTests.swift` |
| `RecScribe/RecScribeTests/RecordingStateTests.swift` | 72 | `HomeRec/HomeRecTests/RecordingStateTests.swift` |
| `RecScribe/RecScribeTests/ReskinSnapshots.swift` | 269 | `HomeRec/HomeRecTests/ReskinSnapshots.swift` |
| `RecScribe/RecScribeTests/SampleBufferFixtures.swift` | 275 | `HomeRec/HomeRecTests/SampleBufferFixtures.swift` |
| `RecScribe/RecScribeTests/SaveLocationTests.swift` | 121 | `HomeRec/HomeRecTests/SaveLocationTests.swift` |
| `RecScribe/RecScribeTests/StreamFailureTests.swift` | 68 | `HomeRec/HomeRecTests/StreamFailureTests.swift` |
| `RecScribe/RecScribeTests/SynchronizedCaptureTests.swift` | 2 | `HomeRec/HomeRec/AudioRecorder.swift` |
| `RecScribe/RecScribeTests/SystemAudioRecorderTests.swift` | 25 | `HomeRec/HomeRecTests/SystemAudioRecorderTests.swift` |
| `RecScribe/RecScribeTests/WAVWriterTests.swift` | 220 | `HomeRec/HomeRecTests/WAVWriterTests.swift` |
| `RecScribe/RecScribeTests/WaveformDownsamplerTests.swift` | 46 | `HomeRec/HomeRecTests/WaveformDownsamplerTests.swift` |
| `RecScribe/RecScribeUITests/SystemAudioRecorderUITests.swift` | 29 | `HomeRec/HomeRecUITests/SystemAudioRecorderUITests.swift` |
| `RecScribe/RecScribeUITests/SystemAudioRecorderUITestsLaunchTests.swift` | 23 | `HomeRec/HomeRecUITests/SystemAudioRecorderUITestsLaunchTests.swift` |
| `docs/design-system.md` | 1 | `docs/design-system.md` |
| `docs/upstream-home-rec-changelog.md` | 366 | `CHANGELOG.md` |
| `scripts/verify-mic-rate.sh` | 115 | `scripts/verify-mic-rate.sh` |

## Repository cleanup in this candidate

The optional upstream Git remote has been removed from the development checkout.
Existing clones can run `git remote remove upstream` if they still have it; the
command affects local Git configuration rather than source history. README no
longer instructs developers to merge another application's branches. The archived
upstream changelog and stale assistant-tool exclusions/comments are retired.
Current architecture, interface, security and distribution documentation no longer
presents an upstream merge workflow. LICENSE, NOTICE and source attributions remain
because active inherited code and tests still exist.

## Closure gates

- Replace every inherited implementation and independently review modified/copied
  files even when no unchanged lines survive. Interfaces and standard file-format
  constants may coincide; document that distinction rather than renaming alone.
- Replace inherited test/fixture/tool implementations while preserving their
  behavioral coverage and all mandatory frozen reference checks.
- Review assets and non-source metadata, including exact-match files above.
- Remove the obsolete upstream integration, developer remnants and historical
  upstream document from the current tree; update current architecture docs.
- Resolve applicable source notices against the final inventory. Existing notices
  remain while inherited material is present. Other dependency notices remain.
- Add a final reference guard with documented, reviewed notice exceptions.
- Validate functional/Release/appropriate concurrency checks and the owner's
  manual test before marking the PR ready. Do not auto-close #51 from a partial PR.

Git history and existing releases/discussions are outside the current-tree rewrite.
