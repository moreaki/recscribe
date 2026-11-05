# Cleanup acceptance audit (#46)

Audit basis: `0cf7164` (merged #65), plus playback/acceptance implementation
`049ea7b` (playback) and the final WAV capture API cleanup. This records implementation evidence against the full
ticket scopes, including the original acceptance lists. A closed issue or a test
count alone is not acceptance evidence. The final audit identified the dormant
format API as an additional #38 gap after the playback follow-up; it is addressed
by the accompanying cleanup rather than waived. Merge/check results are recorded separately
below; this working audit does not close #13 or #46.

## Scope decisions retained

- #42: the owner explicitly accepted the **single centralized failure-only refresh**
  when Core Audio listener registration fails. Normal operation is event driven;
  this is not a claim of literal zero polling in every failure mode.
- #13: the November 2 lean rescoping removed the synthetic startup/disk-I/O/RSS
  benchmark and signpost matrix. Native file-backed AVFoundation buffering remains;
  neither a hard process-RSS cap nor measured cold/warm performance is claimed.
- #36: the original heterogeneous-segment mid-take stitching state machine was
  removed. #65 subsequently adds safe same-UID rejoining and newly discovered
  inputs without restarting unaffected sources, normalizes supported rate changes,
  and rejects channel-count changes. The old blanket statement “no source can ever
  rejoin this take” no longer describes the accepted implementation.
- #41/#44: #65 replaces the previously delivered native Settings scene with a
  **Settings peer tab in the unified window**. Command-comma and menu commands select
  that destination and reopen Studio. The old native-scene criterion is superseded
  by this accepted design, not reported as a newly passed native-scene test.
- #44: the owner chose **limit plus manual management**, replacing automatic deletion
  of old raw drafts. Optional live work pauses at 1 GiB or 100 drafts; recording
  continues. A final completed window can overshoot. Raw evidence is moved only by
  confirmed, recoverable manual Trash; active work and recordings are protected.
- Physical-device/headphone/live-call matrices remain owner-waived closure gates,
  **not executed or passed**. Synthetic tests do not establish speech recognition
  accuracy, driver quality, browser-call capture coverage or subjective listening.

## Stages 1–3

| Requirement | Current implementation and verification |
| --- | --- |
| Remove unused live M4A/FLAC encoders and skipped encoder suites | Only WAV live capture remains. Dormant `selectedFormat`/`setFormat` preferences/presentation state and the ignored `RecordingControlling.startRecording(format:)` argument are removed. Capture paths have no format-choice parameter. `WAVWriter` owns the encoder protocol; the two encoder implementations/tests and CI skip flags are absent. `RecordingControllerTests.obsoleteFormatPreferenceDoesNotAffectTheRealCaptureWriter` passes synthetic PCM through the real view-model/controller/WAV writer with old WAV/M4A/FLAC/invalid preference values and verifies the WAV header, frame count and independent FLAC archive policy. Obsolete preference-only mock tests are replaced, not counted as current coverage. The umbrella deliberately retains the active WAV-only `AudioFormat` guard and its encoder tests; #38's older request to delete that type entirely is superseded by this narrower Stage-1 contract. |
| Direct recovery workflow; active sessions protected (#38) | `AppServices` routes the recovery menu to `SessionLibrary.recoverUnfinalizedSessions`, then Recordings. `RecordingLibraryView` flags unfinished sessions and now exposes **Recover session** directly. Capture/live work hides the action; worker/lease and queue gates protect in-progress files. `RecordingSessionTests.libraryRecoversUnfinalizedSessionsInDirectory`, `libraryRecoveryRespectsActiveCaptureAndScanErrors`, `recovery`, and `OverflowMenuTests` cover processing/menu contracts. |
| Recovery I/O off MainActor; failures visible | `ManifestRepository` is an actor, performs bounded reads and checks cancellation. `SessionLibrary` injects its reader, rejects stale refresh generations, reports `readFailures` and rechecks capture gates before scheduling recovery. `FeatureLifecycleTests.manifestReadFailureIsVisibleAndCancellationIsOwned` and the recovery tests exercise failure/cancellation. No legacy recovery window/scanner remains. |
| Archive support survives encoder removal | `SessionProcessing.archive` retains finalized verified WAV/FLAC/Opus/M4A archives. `RecordingSessionTests.archive` covers the optional real encoder when installed; cancellation/failure tests retain original parts and refuse premature completion. An unavailable optional encoder is a skip, not an executed export. |
| Deduplicate file hashes without conflating domains | `RecordingSession.hash`, `SessionExporter` and `TextJob.inventory` call chunked `WAVAudio.hash` with cancellation/autorelease pools. `TextJob.hash(Data)` remains an in-memory digest; archive verification retains concatenated raw-PCM hashing. Strict canonical `PCM16WAV` repair and general RIFF `WAVAudio` parsing remain distinct, as do app `LocalProcessRunner` and Core process contracts. Their corresponding hash/WAV/process tests remain in the full suites. |
| Core readability and domain folders | `AudioJob.run` delegates to named session/channel/finalization helpers; listed Core files use expanded statements. `TranscriptAudioInput` avoids the capture-model name collision. App sources use App/Capture/Sessions/Transcription/Runtime/UI; active shared UI primitives remain under DesignSystem. File counts/LOC are not correctness criteria. |
| Remove unused UI/fonts while preserving transitive consumers (#39) | No bundled TTF/OTF or font-registration startup remains. `StudioTypography` uses native fonts; `WorkspaceStyle.TextRole` scales shared text. The later #51 replacement supplies native Studio brand/buttons/waveform/theme/metrics and Reduce Motion behavior; focus and pointer behavior use native controls. `BundledFontTests` checks bundle resources, font families, role scaling and actual long-name onboarding/notice/popover layouts. |
| Resource/signing/script effects of file moves | Synchronized Xcode groups discover domain subfolders. Build/release scripts reference the project/product/resources, not deleted flat Swift files. Debug app/tests, independent signed Release/strict codesign and CI app-and-tests compatibility compilation verify the actual resulting target. No raw recording/model resources are added. |

## Stage 4 — every capture/lifecycle/workspace acceptance area

Paths below are relative to `RecScribe/RecScribe` and `RecScribe/RecScribeTests`.

### #40 — composable sources and input-only capture

| Requirement | Evidence |
| --- | --- |
| One `{ playback, inputs }` model with valid channel routing | `Capture/AudioSource.swift`, `InputSelection` validation; `AudioSourceTests`, `MultipleInputTests`. Legacy system/app/mic/mixed/multiple JSON migrates with identities/routes intact; invalid input falls back safely. |
| Mic/inputs-only requires no Screen Recording/SCStream | `requiresScreenCapture` gates `PermissionCoordinator`, recording and preview. `ScreenCaptureAudioManager.setupCapture/setupMultiCapture` return through the direct `DeviceInputCapture` path when playback is none, before ScreenCaptureKit enumeration/configuration. `micOnlyRecordingDoesNotRequireScreenRecordingPermission`, `inputsOnlyPreviewAndSampleBypassScreenRecordingPermission`, source tests and injected capture factories cover this without granting/resetting TCC. |
| Playback capture still permission-gated | Source-aware permission tests retain denied system/app behavior and actionable guidance. No automatic permission retry loop is restored. |
| No SC microphone engine; lean single source; all configurations routable | Playback SCStream captures audio only; input acquisition always uses device inputs. A simple single input uses `SessionWAVWriter`; mixed/routed sources use `MultiSourceRecorder` with preserved source tracks. No `legacySource` UI gate or redundant Settings input list remains. Presets, routing and automatic-source tests exercise configurations. #65's newly available real/virtual inputs respect saved manual choices and feedback-safe default mute. |

### #42 — event-driven hardware graph

| Requirement | Evidence |
| --- | --- |
| One app-owned graph, cached snapshots and no routine per-view device/default/volume loops | `AppServices`/`AudioServices` inject the same `AudioHardwareObserver` into capture, preview, playback and routing. `DeviceVolumeView` subscribes only while expanded. The accepted failure-only fallback is centralized and explicitly tested. |
| Hotplug/default/rate/volume/aggregate updates; stable UID across AudioDeviceID changes | `AudioHardwareObserverTests.observerCoalescesEventsAndScopesDeviceListeners`, `perDeviceEventsRefreshSnapshotForRateChannelAndAggregateChanges`, `highNumberedChannelVolumeElementsAndTeardown`, `observerGuardsStaleCallbacksAndHandlesFailedListenerRegistration`. Registration/removal counts and stale callbacks are asserted, including element 32 and changed numeric IDs. |
| Clean shutdown | `appOwnedAudioGraphSharesHardwareAndUnregistersOnShutdown`, `WorkspaceRegressionTests` and per-device listener tests verify teardown; late callbacks do not restart stopped observation. |

### #41 — Observation, startup, decomposition and popover

| Requirement | Evidence |
| --- | --- |
| Startup/menu/quit independent of any Studio appearance | `AppDelegate` owns start/termination; `AppServices` installs menu/actions. `WorkspaceRegressionTests.startupAndShutdownAreInstalledWithoutAnyStudioView`, `repeatedQuitWaitsForCleanupAndRepliesOnlyOnce`, `nativeWindowCommandsWorkWithoutAStudioOrCapturedEnvironment`. |
| High-frequency state does not invalidate unrelated views | Observable `RecorderTelemetry` is separate from capture commands/preferences; leaf status/waveform/meter views read it. `recorderTelemetryIsolationAndUnifiedStudioCaptureControls` tests Observation dependencies under repeated telemetry changes; `routingMeterRepaintsOnTelemetryWithoutInvalidatingRecorder` checks actual rendered meter updates and unrelated observation counts. This is deterministic dependency/render coverage, not a profiler performance measurement. |
| No mutable OverflowMenu static callbacks/audio singleton ownership | Immutable instance actions are injected from `AppServices`; levels/monitor/playback are owned by `AudioServices`. Production roots pass dependencies. No `AudioLevels.shared`, `PlaybackLevels.shared` or `CapturedAudioMonitor.shared` remains. |
| ViewModel split, permissions/translocation/state machine retained | `PermissionCoordinator`, `InstallLocationMonitor`, recorder preferences/presentation/telemetry separate responsibilities. `RecorderViewModelTests`, `InstallLocationTests`, `PermissionProbeTests`, `RecordingStopReviewTests`, `ObservationLayoutTests.subcontrollersReleaseNotificationObserversWithRecorder` verify behavior/lifetime; LOC alone is not evidence. |
| Popover bounded content sizing, one scroll area, persistent Quit | `PopoverLayout`/`PopoverFrame` and hosting preferred sizing replace a fixed content-size assumption. `ObservationLayoutTests.popoverHostingResizesAndKeepsFooterOutsideBoundedScroll` exercises expand/collapse, long content, enlarged footer and shorter screen; `BundledFontTests` covers accessible text growth. |
| Settings navigation | #65's accepted embedded Settings replaces the separate scene. `StudioNavigation`, native command actions and `WorkspaceRegressionTests.destinationIsSelectedBeforeOpeningAndSurvivesWindowRecreation` retain destination, command-comma and menu behavior. |

### #13 — shared file-backed transport

| Original acceptance group | Evidence |
| --- | --- |
| Consistent compact UI, identity and all states | `UI/AudioLevelViews.swift` shares source/status/playback/output chrome across transcript, Recordings and retained test samples. `WorkspaceStyle`/`StudioSpacing`, semantic detail font, monospaced digits and standard audio icons remain consistent. Preparing/buffering/paused/playing/scrubbing/ended/failed are explicit `PlaybackPhase` values. Runtime item/player failure and failed-to-end notifications surface actionable errors; Stop/Dismiss clears them. |
| Keyboard, narrow layouts and value announcements | Compact alternate layout preserves controls/timecodes at 280/360 points and accessibility-size text; wide layout is tested at 900. Native `PlaybackPositionSlider` exposes numeric AX bounds/value separately from its spoken elapsed/total description and uses bounded ±15-second adjustable actions. `SessionPlaybackAcceptanceTests.narrowTransportHasSpokenPositionAndKeyboardControlsWithoutDuplicateActions` exercises native AX methods and actual keyboard equivalents; `longTimelineAndEveryStatusWrapWithinCompactAccessibleLayout` renders all statuses and a 100-hour timecode. Human VoiceOver listening remains distinct from these automated checks. |
| File and session path; single owner | `SessionPlayback.playFile/play/playSource`, app-owned `SessionPlaybackCoordinator`; existing cross-surface ownership/source-selection tests. No subprocess player or second transport framework. |
| On-demand structure and continuous multipart timeline | Builder validates canonical headers/lengths/status/order on a utility worker, then references AVURLAssets directly for one part or via a sample-timed composition for multiple parts. No whole-file Data/PCM, hash pass, conversion or concatenated playback file. `multipartCompositionUsesExactSampleTimeAndRejectsMissingParts`, `singlePartFastPathSeekSkipFormatTimeAndObserverTeardownOnDeinit` cover these distinctions. |
| Seek ordering, clamps, intent, cancellation, EOF and resources | `SessionPlaybackTransportTests` tests latest-wins/cancelled completion ordering and EOF restart. New acceptance tests prove no periodic snap-back between completed drag seeks, paused/playing intent through the final queued seek, pause during drag, source/capture preemption, sticky runtime failures and old-item notification teardown. Existing tests retain load cancellation, missing/corrupt/unverified safeguards, coordinator ownership, deinit/stop observer cleanup and recording priority. |
| Central policy and clean separation | `Sessions/PlaybackPolicy.swift` names skip interval/icons, cadence/timebase, seek tolerance/timebase and native automatic buffering (`preferredForwardBufferDuration = 0`). Persisted typed `ListeningLevel` retains user output/volume/mute preferences; fixed capture formats are not preferences. SwiftUI/native control presentation does not prepare assets or perform I/O. |

### #16 — browser/meeting source selection

| Requirement | Evidence |
| --- | --- |
| Idle browsers selectable before a call; helpers resolve to parent; all instances included | `AudioSourceManager` keeps regular running apps regardless of current audible state, using Core Audio only to badge/sort. `AudioCapableProcesses.enclosingAppBundleIDs` resolves enclosing app bundles; `ScreenCaptureAudioManager.matchingApplications` filters all matching SCK instances rather than just the first. Dedicated process/source tests cover nested helpers, idle visibility and multiple instances. An application filter is not limited to only the initially audible helper. |
| Explicit system/app plus chosen input routes, actual identities and status | Composable source/routing model, source health and source-track metadata; `MultipleInputTests`, `MultiSourceLifecycleTests`, routing tests. Browser application capture can include other audible tabs/windows and is not advertised as meeting-only capture. |
| Avoid duplicate remote sound/monitor feedback, keep ordinary listening stable | Duplicate/loopback routing validation and independent monitor/output controls remain; #65 defaults newly discovered virtual sources mix-muted and pauses monitoring for audible feedback risks. Unity source tracks remain independent of mix mute. No virtual driver install, meeting-device reconfiguration or silent default microphone substitution is performed. |
| Guide and backend choice | `docs/capture-sources.md` documents idle pre-call selection, app-wide scope, acoustic recapture, routing and coverage limits. SCK remains the backend; no demonstrated gap justifies a process-tap rewrite. Real WebEx/browser listening remains within the unexecuted hardware/live-call matrix, not a synthetic coverage claim. |

### #36 — hardware identity, interruptions and lifetime

| Requirement | Evidence |
| --- | --- |
| Availability/format storms, UID/ID distinction, stale generations | `DeviceInputConfigurationTests`, `AudioHardwareObserverTests`, `LiveInputContinuityTests` exercise healthy queued notifications, bounded initial recovery, same UID with changed ID, different UID with same name, stale callbacks and stop during suspended preparation. |
| Same-size aggregate reorder detected before wrong channels can be used | Ordered aggregate members and channel labels form input identity. `aggregateSubDeviceChangesAreDetected` rejects the same UID/channel-count selection after membership order changes and produces `.aggregateChanged`; snapshot tests cover aggregate/rate/channel revisions. |
| Preview recovery, recording isolation and safe new take | Preview retries verified same UID without substituting defaults; #65 joins supported inputs without restarting unaffected engines and retries failed opens only on hardware events. `previewRebuildWaitsForSameUIDAndHardwareEventsNeverRestartHealthyOrRecordingCapture`, `LiveInputContinuityTests`, `midRecordingInterruptedSourceAndStopAndStartNewTake`, `MultiSourceLifecycleTests` cover these separate paths. A changed channel count is an explicit failure, not heterogeneous stitching. |
| Headphone unplug never enables speakers silently | `CapturedAudioMonitor` disables monitoring on unavailable explicit output; `headphoneUnplugDisablesLiveMonitoringWithoutSpeakerFallback` asserts no speaker configuration. Playback output fallback is a separate, visibly explained contract. |
| Repeated preview/sample/record/stop cleanup | `AudioTestTests.previewStopSamplePlaybackKeepAndDiscardStaySeparateFromRecording`, `cancellingSuspendedSetupWaitsForCleanupBeforeAnotherCapture`, `failedEmptySampleAndPreviewFailureReleaseAllResources`, `repeatedHandoffToRealRecordingControllerHasOneCaptureAndNoTestFiles`; input stop fences and normalizer admission/drain tests retain all accepted buffers. |

### #43 — transcript interactions

| Requirement | Evidence |
| --- | --- |
| Timestamps load/seek shared player, highlight active group and optionally follow | `TranscriptWorkspace`, `TranscriptSourceView`, `TranscriptReadingView` share the transport/pending seek; reading view supplies Follow audio and active group scrolling. Completed live timestamps use valid intervals and are disabled during recording. `TranscriptReadingTests`, `TranscriptInteractionTests.completedLiveTimestampsSeekWhileRecordingAndUnknownIntervalsRemainSafe` cover timing/active ranges. |
| Copy Markdown/plain text and Share honor selected Transcript/Summary/Review | Core renderers feed header actions; copy confirmation has bounded lifetime. `clipboardExportHasConfirmationAndNeverClearsOnEmptyContent` verifies actual pasteboard behavior on a private test pasteboard, without sending content anywhere. |
| No hover-open preview or redundant Studio trigger | `LiveTranscriptionControl` opens by explicit button/keyboard action; Studio passes `showsPreview: false`, while menu-bar preview remains. This is inspected in the production view wiring; no hover handler reintroduces activation. |

### #44 — workspace, metadata and storage

| Requirement | Evidence |
| --- | --- |
| One workspace, keyboard destinations, capture controls always available | `StudioView` has Studio/Routing/Recordings/Settings peer destinations and a persistent recorder rail. `StudioNavigation`, AppWindow/command dispatch and workspace tests preserve selection before opening/recreation and switch Transcribe back to Studio. See the explicit Settings decision above. |
| Backward-compatible inline title; clean fallback; immutable audio/schema extensions | Shared `SessionTitleView` is used in Recordings/source header. Title writes run through leased utility work and preserve unknown extension fields, part names and hashes. Generated timestamp stems now display a localized readable recording/date title with collision suffix; custom filenames remain meaningful. `sessionTitleRenameAndLiveDisposableTempCleanup`, `generatedSessionTitlesAreReadableWithoutRenamingFilesOrReplacingCustomNames` cover these distinctions. |
| Terminal job cleanup preserves raw/provenance | Core terminal cleanup removes only disposable working/region WAVs after success/failure/cancellation; raw JSON/logs/audio reports/canonical outputs remain. Core frozen-reference/CLI/job tests and app transcript-storage tests cover this. |
| Bounded live storage and safe manual derived-artifact Trash | `LiveDraftStorage`, `LiveDraftManagementView` and approved quota policy above. `LiveDraftStorageTests` covers bounded metadata-only inventory, quota pause independent of recording, symlinks/original manifests, active/cross-process leases, changed contents, raw evidence and forgetting only trashed hints. `SessionDeletionTests.relatedJobsAreOptInIdentityCheckedAndRestoredOnFailure`, `cancelledOrOverLimitScanLeavesRecordingInPlace` verify exact identity matching, default retention, bounded cancellation and rollback. |

## Validation record

- Base `0cf7164`: remote Unit tests (including functional/Core and advisory TSan
  steps), independent Release build, and Xcode 26.3 app-and-tests compatibility build
  all passed in [run 41885286629](https://github.com/moreaki/recscribe/actions/runs/41885286629).
- Follow-up validation is recorded in the associated PR and the [#13 completion
  record](https://github.com/moreaki/recscribe/issues/13): exact revision, actual
  Debug/Release/Core/TSan results, signed product verification and all three remote
  checks. This code mapping alone does not establish a test pass or authorize
  closure while checks are pending. Intermediate failing UI-harness attempts and
  zero-test filter runs are not counted as passing evidence.
- No physical capture, real-call listening, private audio access, permission reset,
  model download, cloud fallback or installed-app replacement was used in this audit.
