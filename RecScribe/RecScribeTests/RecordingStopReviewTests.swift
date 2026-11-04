import AVFoundation
import CoreMedia
import Foundation
import Testing
@testable import RecScribe

@MainActor
struct RecordingStopReviewTests {
    private func packet(_ role: CaptureTrack, at time: Double) -> CapturedAudioSample {
        .init(track: role, presentationTime: time,
              buffer: SampleBufferFixtures.makePCMBuffer(channels: 2, frames: 480, interleaved: false) { _, _ in 0.4 })
    }

    @Test(arguments: ["clean", "clipping", "gap", "missing"], [false, true])
    func combinedStopSeparatesReviewFromFailureAndOptionalVAD(quality: String, vadFails: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let defaults = UserDefaults(suiteName: "stop-review-\(UUID())")!
        let audio = AudioServices(defaults: defaults)
        if quality == "clipping" { audio.levels.set("master", .init(decibels: 12)) }
        let capture = MockAudioCapturing()
        let source = MockAudioSourceProviding(selectedSource: .mixed(appBundleID: nil, deviceUID: "test"))
        let live = LiveTranscription(liveRoot: root.appendingPathComponent("Live"), work: { _, _, _, _, _, _ in
            throw SessionError.invalid("Synthetic invalid optional VAD configuration")
        })
        if vadFails { live.setEnabled(true) }
        let controller = RecordingController(captureManager: capture, saveLocation: MockSaveLocationProviding(directory: root),
            audioSource: source, liveTranscription: live, levels: audio.levels, monitor: audio.monitor)
        let recorder = RecorderViewModel(controller: controller, permissions: MockPermissionProviding(.granted),
            audioSource: source, installLocation: MockInstallLocationProviding(.applications), defaults: defaults, audio: audio)
        await recorder.startRecording()
        #expect(recorder.state == .recording)
        let file = try #require(recorder.lastRecordingURL)
        if vadFails { await waitUntil("optional VAD failure") { live.errorMessage != nil && !live.busy } }
        let now = CMClockGetTime(CMClockGetHostTimeClock()).seconds
        for index in 0..<10 {
            let time = now + Double(index) / 100 + (quality == "gap" && index >= 5 ? 0.05 : 0)
            capture.emit(packet(.playback, at: time))
            if quality != "missing" { capture.emit(packet(.microphone, at: time)) }
        }
        // Stop immediately: every admitted packet must drain before finalization.
        await recorder.stopRecording()
        #expect(recorder.state == .idle)
        #expect(!recorder.showError)
        #expect(!capture.capturing && capture.cleanupCount == 1)
        let session = try RecordingSession.read(RecordingSession.manifestURL(for: file))
        #expect(session.totalFrames >= 4800)
        #expect(!session.parts.isEmpty)
        if quality == "clean" {
            #expect(recorder.alerts.reviewMessage == nil)
            #expect(session.status == .finalized)
            #expect(!live.captureNeedsReview) // Optional ASR is not capture health.
        } else {
            #expect(recorder.alerts.reviewMessage != nil)
            #expect(session.status == .needsReview)
            #expect(live.captureNeedsReview)
        }
        for part in session.parts {
            #expect(try PCM16WAV.read(root.appendingPathComponent(part.path)).frames > 0)
        }
        // Cleanup released the gate and the next take has no stale review notice.
        await recorder.startRecording()
        #expect(recorder.isRecording)
        #expect(recorder.alerts.reviewMessage == nil)
        let secondTime = CMClockGetTime(CMClockGetHostTimeClock()).seconds
        capture.emit(packet(.playback, at: secondTime))
        capture.emit(packet(.microphone, at: secondTime))
        await recorder.stopRecording()
        #expect(!recorder.showError)
        await live.shutdown()
        await audio.shutdown()
    }

    @Test func captureShutdownFailureHasItsOwnMessageAndStillReleasesResources() async throws {
        let capture = MockAudioCapturing(), writer = MockAudioFileWriting()
        let controller = RecordingController(captureManager: capture, audioRecorder: writer,
            saveLocation: MockSaveLocationProviding(directory: FileManager.default.temporaryDirectory),
            audioSource: MockAudioSourceProviding())
        let recorder = RecorderViewModel(controller: controller, permissions: MockPermissionProviding(.granted),
            installLocation: MockInstallLocationProviding(.applications), defaults: UserDefaults(suiteName: UUID().uuidString)!)
        await recorder.startRecording()
        capture.stopError = NSError(domain: "SyntheticCaptureShutdown", code: 7)
        await recorder.stopRecording()
        if case .error(.captureStopFailed) = recorder.state {} else { Issue.record("Expected capture-shutdown diagnosis") }
        #expect(recorder.showError)
        #expect(recorder.errorMessage?.contains("shut down") == true)
        #expect(recorder.errorMessage?.contains("couldn't finish saving") == false)
        #expect(writer.stopCount == 1 && capture.cleanupCount == 1)
        #expect(!capture.capturing && controller.recordingURL == nil)
    }
}
