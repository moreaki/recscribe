import AppKit
import Testing
@testable import RecScribe

@MainActor
struct RecordingInterruptionTests {
    @MainActor final class PowerProbe {
        let center = NotificationCenter()
        var starts = 0
        var ends = 0
        func activity() -> RecordingActivity {
            RecordingActivity(center: center, beginActivity: { self.starts += 1; return NSObject() },
                              endActivity: { _ in self.ends += 1 })
        }
    }

    private func controller(_ activity: RecordingActivity, capture: MockAudioCapturing = .init(),
                            writer: MockAudioFileWriting = .init(), live: LiveTranscription? = nil) -> RecordingController {
        RecordingController(captureManager: capture, audioRecorder: writer,
            saveLocation: MockSaveLocationProviding(directory: FileManager.default.temporaryDirectory),
            audioSource: MockAudioSourceProviding(), liveTranscription: live, activity: activity)
    }

    @Test func sleepProtectionIsScopedIdempotentAndReleasedOnDeinit() async {
        let probe = PowerProbe()
        var activity: RecordingActivity? = probe.activity()
        var interruptions = 0
        activity?.onInterruption = { _ in interruptions += 1 }
        #expect(RecordingActivity.options.contains(.idleSystemSleepDisabled))
        #expect(RecordingActivity.options.contains(.idleDisplaySleepDisabled))
        activity?.start()
        activity?.start()
        #expect(probe.starts == 1)
        probe.center.post(name: NSWorkspace.screensDidSleepNotification, object: nil)
        probe.center.post(name: NSWorkspace.willSleepNotification, object: nil)
        #expect(interruptions == 1)
        #expect(activity?.interrupted == true)
        activity?.stop()
        activity?.stop()
        #expect(probe.ends == 1)
        probe.center.post(name: NSWorkspace.willSleepNotification, object: nil)
        #expect(interruptions == 1)
        activity?.start()
        #expect(activity?.interrupted == false)
        activity = nil
        await waitUntil("power assertion released on deinit") { probe.ends == 2 }
        probe.center.post(name: NSWorkspace.willSleepNotification, object: nil)
        #expect(interruptions == 1)
    }

    @Test func everyRecordingExitReleasesPowerProtectionAndMarksFailedDrafts() async throws {
        for failure in ["none", "setup", "stop", "finalize", "stream"] {
            let probe = PowerProbe(), activity = probe.activity()
            let capture = MockAudioCapturing(), writer = MockAudioFileWriting()
            let live = LiveTranscription()
            let recorder = controller(activity, capture: capture, writer: writer, live: live)
            let error = NSError(domain: "SyntheticCapture", code: 1)
            if failure == "setup" { capture.setupError = error }
            do {
                _ = try await recorder.startRecording(format: .wav)
                #expect(activity.active)
                writer.onStop = { #expect(activity.active) } // Released after draining/finalizing.
                if failure == "stop" { capture.stopError = error }
                if failure == "finalize" { writer.stopError = error }
                if failure == "stream" { await recorder.finalizeAfterFailure() }
                else { try await recorder.stopRecording() }
                #expect(failure == "none" || failure == "stream")
            } catch { #expect(["setup", "stop", "finalize"].contains(failure)) }
            #expect(!activity.active)
            #expect(probe.starts == 1 && probe.ends == 1)
            #expect(live.captureNeedsReview == ["stop", "finalize", "stream"].contains(failure))
            await live.shutdown()
        }
    }

    @Test func sleepDuringStartupCannotPublishASuccessfulRecording() async {
        let probe = PowerProbe(), activity = probe.activity(), capture = MockAudioCapturing()
        let writer = MockAudioFileWriting()
        capture.onStart = { probe.center.post(name: NSWorkspace.willSleepNotification, object: nil) }
        let recorder = controller(activity, capture: capture, writer: writer)
        await #expect(throws: ScreenCaptureAudioError.self) { try await recorder.startRecording(format: .wav) }
        #expect(writer.stopCount == 1)
        #expect(capture.cleanupCount == 1)
        #expect(recorder.recordingURL == nil)
        #expect(!activity.active)
    }

    @Test func forcedSleepFinalizesOnceAndPreservesTheReviewState() async throws {
        let probe = PowerProbe(), activity = probe.activity()
        let capture = MockAudioCapturing(), writer = MockAudioFileWriting(), live = LiveTranscription()
        let recorder = controller(activity, capture: capture, writer: writer, live: live)
        let clock = ManualClock()
        let viewModel = RecorderViewModel(controller: recorder, permissions: MockPermissionProviding(.granted),
            clock: clock, audioSource: MockAudioSourceProviding())
        await viewModel.startRecording()
        clock.advance(by: 65)
        probe.center.post(name: NSWorkspace.willSleepNotification, object: nil)
        capture.simulateStreamError("secondary stream stop")
        #expect(viewModel.isFinalizingAfterFailure)
        #expect(viewModel.state.heading(duration: viewModel.formattedDuration) == "Recording interrupted")
        #expect(!viewModel.statusText.contains("Something went wrong"))
        #expect(viewModel.formattedDuration == "01:05")
        await viewModel.waitForFailureFinalization()
        #expect(writer.stopCount == 1)
        #expect(!viewModel.isFinalizingAfterFailure)
        #expect(!activity.active)
        #expect(live.captureNeedsReview)
        probe.center.post(name: NSWorkspace.didWakeNotification, object: nil)
        #expect(writer.startCount == 1) // Never silently resume a new recording.
        await live.shutdown()
    }

    @Test func retryAndTerminationWaitForFailureFinalization() async {
        let recorder = MockRecordingControlling()
        var continuation: CheckedContinuation<Void, Never>?
        recorder.beforeFinalize = { await withCheckedContinuation { continuation = $0 } }
        let viewModel = RecorderViewModel(controller: recorder, permissions: MockPermissionProviding(.granted),
            clock: ManualClock(), audioSource: MockAudioSourceProviding())
        await viewModel.startRecording()
        recorder.emitStreamError("synthetic interruption")
        await waitUntil("blocked finalization") { continuation != nil }
        await viewModel.startRecording()
        #expect(recorder.startCount == 1)
        #expect(viewModel.isFinalizingAfterFailure)
        continuation?.resume()
        await viewModel.waitForFailureFinalization()
        await viewModel.startRecording()
        #expect(recorder.startCount == 2)
        #expect(!viewModel.showError)
        #expect(viewModel.errorMessage == nil)
    }

    @Test func headingsRepresentEveryLifecycleState() {
        let headings: [(RecordingState, String)] = [
            (.idle, "Ready when you are"), (.starting, "Starting recording…"), (.recording, "12:34"),
            (.stopping, "Saving recording…"), (.recovering, "Recovering recording…"),
            (.error(.streamFailed("private")), "Recording interrupted"),
            (.error(.stopFailed("private")), "Recording needs review"),
            (.error(.startFailed("private")), "Recording unavailable")
        ]
        for (state, heading) in headings { #expect(state.heading(duration: "12:34") == heading) }
    }
}
