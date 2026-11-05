import Foundation
import Testing
@testable import RecScribe

private struct LifecycleFailure: LocalizedError {
    let payload: String
    var errorDescription: String? { payload }
}

@MainActor struct RecorderViewModelTests {
    @Test(arguments: [false, true])
    func captureLifecycleRequiresUserPermissionAndKeepsSharedSourceOwner(granted: Bool) async {
        let h = RecorderContractHarness(permission: granted ? .granted : .denied)
        defer { h.cleanup() }
        #expect(h.model.state == .idle && !h.model.isRecording)
        #expect(h.model.audioSource === h.source)
        #expect(h.model.showsSettingsShelf)
        await h.model.startRecording()
        if granted {
            #expect(h.model.isRecording && h.controller.startCount == 1 && !h.model.showsSettingsShelf)
            h.controller.onWaveformData?([0.25, -0.5])
            #expect(h.model.waveformSamples == [0.25, -0.5])
            await h.model.stopRecording()
            #expect(h.model.state == .idle && h.model.showsSettingsShelf)
            #expect(h.model.waveformSamples == [Float](repeating: 0, count: 200))
            #expect(!h.clock.isTicking && h.controller.stopCount == 1)
        } else {
            #expect(h.controller.startCount == 0 && !h.model.isRecording)
            #expect(h.model.showError && h.model.recoverySuggestion == .openSettings)
        }
    }
    @Test func permissionRecheckAndSettingsRecoveryAreExplicit() async {
        let h = RecorderContractHarness(permission: .denied, pollClock: ImmediatePollClock(), timeout: 0)
        defer { h.cleanup() }
        await h.model.requestPermission()
        #expect(h.model.showError && h.model.recoverySuggestion == .openSettings)
        h.model.performRecovery()
        await waitUntil("explicit Settings recovery") { h.permissions.openSettingsCount == 1 }
        #expect(!h.model.showError)
        h.permissions.status = .granted
        await h.model.checkPermission()
        #expect(h.model.permissionStatus == .granted && h.model.canRecord)
        #expect(h.controller.startCount == 0)
    }
    @Test(arguments: [0, 1, 2])
    func startFailuresHaveSpecificRecoveryWithoutExposingTechnicalDetails(kind: Int) async {
        let h = RecorderContractHarness()
        defer { h.cleanup() }
        let expected: RecorderError
        switch kind {
        case 0:
            h.controller.startError = LifecycleFailure(payload: "internal-start-detail")
            expected = .startFailed("internal-start-detail")
        case 1:
            h.controller.startError = RecordingControllerError.insufficientDiskSpace
            expected = .diskFull
        default:
            h.controller.startError = AudioSourceError.appNotRunning("test.player")
            expected = .sourceUnavailable(.appNotRunning("test.player"))
        }
        await h.model.startRecording()
        #expect(h.model.state == .error(expected))
        #expect(h.model.errorMessage == expected.message && h.model.recoverySuggestion == expected.recovery)
        #expect(h.model.errorMessage?.contains("internal-start-detail") == false)
        #expect(h.model.showsSettingsShelf && !h.clock.isTicking)
    }
    @Test(arguments: [0, 1, 2])
    func everyStopFailureClearsTransportAndPublishesTheSpecificDiagnosis(kind: Int) async {
        let h = RecorderContractHarness()
        defer { h.cleanup() }
        await h.model.startRecording()
        h.clock.advance(by: 5)
        h.clock.advance(by: 2.5)
        #expect(h.model.duration == 7.5 && h.clock.isTicking)
        let expected: RecorderError
        switch kind {
        case 0: h.controller.stopError = LifecycleFailure(payload: "stop-detail"); expected = .stopFailed("stop-detail")
        case 1: h.controller.stopError = RecordingControllerError.captureShutdownFailed(LifecycleFailure(payload: "stop-detail")); expected = .captureStopFailed("stop-detail")
        default: h.controller.stopError = SessionError.noAudio; expected = .noAudio
        }
        await h.model.stopRecording()
        #expect(h.model.state == .error(expected) && !h.model.isRecording)
        #expect(!h.clock.isTicking && h.model.waveformSamples.allSatisfy { $0 == 0 })
    }
    @Test func elapsedTimeWarningIsOncePerTakeAndDiskBoundaryIsExact() async {
        let h = RecorderContractHarness()
        defer { h.cleanup() }
        await h.model.startRecording()
        h.clock.advance(by: DiskSpace.longRecordingThreshold + 1)
        #expect(h.model.showLongRecordingWarning)
        h.model.showLongRecordingWarning = false
        h.clock.advance(by: 10)
        #expect(!h.model.showLongRecordingWarning)
        await h.model.stopRecording()
        await h.model.startRecording()
        #expect(h.model.duration == 0)
        h.clock.advance(by: DiskSpace.longRecordingThreshold)
        #expect(h.model.showLongRecordingWarning)
        await h.model.stopRecording()
        #expect(DiskSpace.hasEnoughSpace(availableBytes: DiskSpace.minimumBytesToRecord))
        #expect(!DiskSpace.hasEnoughSpace(availableBytes: DiskSpace.minimumBytesToRecord - 1))
        #expect(!DiskSpace.hasEnoughSpace(availableBytes: 10_000_000))
    }
    @Test func preferencePresentationPersistsOnboardingAndWarnsWithoutAbortingFallbackCapture() async {
        let h = RecorderContractHarness()
        defer { h.cleanup() }
        #expect(h.model.showOnboarding)
        h.model.completeOnboarding()
        #expect(!h.model.showOnboarding)
        #expect(!RecorderPreferences(saveLocation: h.location, defaults: h.defaults).showOnboarding)
        h.model.showOnboardingAgain()
        #expect(h.model.showOnboarding)
        #expect(h.model.saveLocationName == h.location.configuredDirectory?.lastPathComponent)
        h.model.resetSaveLocation()
        #expect(h.location.resetCount == 1 && !h.model.hasCustomSaveLocation && h.model.saveLocationName == "Desktop")
        h.location.isConfiguredLocationUnavailable = true
        await h.model.startRecording()
        #expect(h.model.isRecording && h.model.showError)
        #expect(h.model.recoverySuggestion == .chooseFolder)
        await h.model.stopRecording()
    }
    @Test func failureFinalizationRunsOnceAndBlocksAnEarlyRestart() async throws {
        let h = RecorderContractHarness()
        defer { h.cleanup() }
        var gate: CheckedContinuation<Void, Never>?
        h.controller.beforeFinalize = { await withCheckedContinuation { gate = $0 } }
        await h.model.startRecording()
        h.controller.emitStreamError("stream-ended")
        h.controller.emitStreamError("late-duplicate")
        #expect(h.model.state == .error(.streamFailed("stream-ended")))
        await waitUntil("failure drain to suspend") { gate != nil }
        await h.model.startRecording()
        #expect(h.controller.startCount == 1 && h.model.isFinalizingAfterFailure)
        let suspended = try #require(gate)
        gate = nil
        suspended.resume()
        await h.model.waitForFailureFinalization()
        #expect(h.controller.finalizeCount == 1 && !h.model.isFinalizingAfterFailure)
        h.controller.beforeFinalize = nil
        await h.model.startRecording()
        #expect(h.controller.startCount == 2 && h.model.isRecording)
        await h.model.stopRecording()
    }
    @Test(arguments: [false, true], [false, true])
    func microphoneRequestsUseTheirOwnPermissionScopeAndRepeatDeniedFeedback(screenGranted: Bool, microphoneGranted: Bool) async {
        let h = RecorderContractHarness(permission: screenGranted ? .granted : .denied, selection: .mic(deviceUID: "test.input"))
        defer { h.cleanup() }
        h.permissions.micStatus = microphoneGranted ? .granted : .denied
        #expect(h.model.canRecord)
        await h.model.startRecording()
        #expect(h.permissions.requestedPermissionKinds == [.microphone])
        if microphoneGranted {
            #expect(h.model.isRecording && h.controller.startCount == 1)
            await h.model.stopRecording()
        } else {
            #expect(h.model.state == .error(.microphoneDenied) && h.model.showError)
            #expect(h.model.recoverySuggestion == .openMicrophoneSettings)
            h.model.showError = false
            await h.model.startRecording()
            #expect(h.model.showError && h.controller.startCount == 0)
            #expect(h.permissions.requestedPermissionKinds == [.microphone, .microphone])
        }
        #expect(PermissionKind.microphone.settingsAnchor == "Privacy_Microphone")
        #expect(PermissionKind.screenCapture.settingsAnchor == "Privacy_ScreenCapture")
    }
    @Test func sourceNamesAreCachedAndShelfLockAgreesWithMenuLock() async {
        let h = RecorderContractHarness(selection: .app(bundleID: "test.player"))
        defer { h.cleanup() }
        #expect(h.model.captureSourceName == "test.player")
        h.source.knownAppNamesResult = ["test.player": "Known Player"]
        #expect(h.model.captureSourceName == "Known Player")
        #expect(h.model.statusText == "Ready to record Known Player")
        #expect(h.source.availableAppsCallCount == 0)
        await h.model.startRecording()
        #expect(h.model.statusText == "Recording Known Player")
        #expect(h.model.showsSettingsShelf == h.model.state.allowsCaptureSourceChange)
        #expect(OverflowMenu().captureSourceEntries(.init(allowsCaptureSourceChange: h.model.allowsCaptureSourceChange)).isEmpty)
        await h.model.stopRecording()
        #expect(h.model.showsSettingsShelf)
    }
    @Test("Meter publication preserves raw channels, muted contributions and source settings")
    func publishesCaptureMetersWithoutEditingAudio() throws {
        let suite = "compact-source-telemetry-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let controller = MockRecordingControlling()
        let provider = MockAudioSourceProviding(selectedSource: .multiple(appBundleID: nil,
            inputs: [.init(deviceUID: "interface", routes: [.init(channel: 31, placement: .right)])]))
        let recorder = RecorderViewModel(controller: controller, permissions: MockPermissionProviding(.granted),
            clock: ManualClock(), audioSource: provider, defaults: defaults)
        let track = CaptureTrack.input("interface")
        var meters = CaptureSourceMeters()
        meters.raw.update(Array(repeating: 0.4, count: 32))
        meters.processed.update(Array(repeating: 0, count: 32))
        controller.sourceMeters = [track: meters]
        let source = provider.selectedSource
        recorder.audio.levels.set("input:interface", .init(decibels: -6, muted: true, channelTrims: [31: -3]))
        let settings = recorder.audio.levels.snapshot(for: source)
        recorder.refreshCaptureHealth()
        #expect(recorder.telemetry.sourceMeters[track] == meters)
        #expect(recorder.telemetry.sourceMeters[track]?.raw.peaks.count == 32)
        #expect(recorder.telemetry.sourceMeters[track]?.processed.peaks.last == 0)
        controller.sourceMeters = [:]
        recorder.refreshCaptureHealth()
        #expect(recorder.telemetry.sourceMeters.isEmpty)
        #expect(provider.selectedSource == source)
        #expect(recorder.audio.levels.snapshot(for: source) == settings)
        #expect(controller.startCount == 0)
    }


}
