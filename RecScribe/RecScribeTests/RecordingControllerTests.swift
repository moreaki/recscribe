//
//  RecordingControllerTests.swift
//  RecScribeTests
//
//  BL-015: the controller threads the chosen AudioFormat into both the file
//  path (extension) and the recorder (encoder). Uses the injectable mock seams.
//

import Testing
import Foundation
@testable import RecScribe

@MainActor
struct RecordingControllerTests {

    private func makeController(
        recorder: MockAudioFileWriting? = nil,
        capture: MockAudioCapturing? = nil,
        audioSource: MockAudioSourceProviding? = nil
    ) -> RecordingController {
        RecordingController(
            captureManager: capture ?? MockAudioCapturing(),
            audioRecorder: recorder ?? MockAudioFileWriting(),
            saveLocation: MockSaveLocationProviding(directory: FileManager.default.temporaryDirectory),
            audioSource: audioSource ?? MockAudioSourceProviding()
        )
    }

    @Test("generateFilePath uses the format's extension", arguments: [AudioFormat.wav, .m4a])
    func filePathExtensionFollowsFormat(_ format: AudioFormat) {
        let url = makeController().generateFilePath(format: format)
        #expect(url.pathExtension == format.fileExtension)
    }

    @Test("startRecording threads the format into the recorder and the file URL")
    func startThreadsFormat() async throws {
        let recorder = MockAudioFileWriting()
        let controller = makeController(recorder: recorder)

        let url = try await controller.startRecording(format: .m4a)

        #expect(recorder.lastStartFormat == .m4a)
        #expect(url.pathExtension == "m4a")
        #expect(controller.recordingURL?.pathExtension == "m4a")
    }

    @Test("startRecording threads the selected AudioSource into capture setup (BL-100)")
    func startThreadsAudioSource() async throws {
        let capture = MockAudioCapturing()
        let audioSource = MockAudioSourceProviding(selectedSource: .app(bundleID: "com.apple.logic10"))
        let controller = makeController(capture: capture, audioSource: audioSource)

        _ = try await controller.startRecording(format: .wav)

        #expect(capture.lastSource == .app(bundleID: "com.apple.logic10"))
        #expect(audioSource.validateCount == 1)
    }

    @Test("An unvalidatable source fails before any file is created (BL-100 pre-flight)")
    func invalidSourceFailsBeforeFileCreation() async {
        let recorder = MockAudioFileWriting()
        let capture = MockAudioCapturing()
        let audioSource = MockAudioSourceProviding(selectedSource: .app(bundleID: "com.apple.logic10"))
        audioSource.validateError = AudioSourceError.appNotRunning("com.apple.logic10")
        let controller = makeController(recorder: recorder, capture: capture, audioSource: audioSource)

        await #expect(throws: AudioSourceError.self) {
            try await controller.startRecording(format: .wav)
        }

        #expect(recorder.startCount == 0)
        #expect(capture.setupCount == 0)
        #expect(controller.recordingURL == nil)
    }

    // MARK: - BL-016 teardown ordering

    private struct FinalizeFailure: Error, Equatable {}

    @Test("Capture setup failure closes the encoder")
    func setupFailureClosesEncoder() async {
        let recorder = MockAudioFileWriting()
        let capture = MockAudioCapturing()
        capture.setupError = FinalizeFailure()
        let controller = makeController(recorder: recorder, capture: capture)
        await #expect(throws: FinalizeFailure.self) { try await controller.startRecording(format: .wav) }
        #expect(recorder.stopCount == 1)
        #expect(capture.cleanupCount == 1)
        #expect(!recorder.recording)
    }

    @Test("Capture stop failure still finalizes and cleans up")
    func captureStopFailureFinalizes() async throws {
        let recorder = MockAudioFileWriting()
        let capture = MockAudioCapturing()
        let controller = makeController(recorder: recorder, capture: capture)
        _ = try await controller.startRecording(format: .wav)
        capture.stopError = FinalizeFailure()
        await #expect(throws: FinalizeFailure.self) { try await controller.stopRecording() }
        #expect(recorder.stopCount == 1)
        #expect(capture.cleanupCount == 1)
        #expect(controller.recordingURL == nil)
    }

    /// The regression this guards: a finalize failure must not skip teardown.
    /// Rethrowing straight out of `stopRecording()` would leak the SCStream and
    /// strand a stale recording URL — a worse outcome than the error itself.
    @Test("A finalize failure still tears down capture, then rethrows")
    func finalizeFailureStillTearsDown() async throws {
        let recorder = MockAudioFileWriting()
        let capture = MockAudioCapturing()
        let controller = makeController(recorder: recorder, capture: capture)

        _ = try await controller.startRecording(format: .wav)
        recorder.stopError = FinalizeFailure()

        await #expect(throws: FinalizeFailure.self) {
            try await controller.stopRecording()
        }

        // Teardown completed despite the throw.
        #expect(capture.stopCount == 1)
        #expect(capture.cleanupCount == 1)
        #expect(controller.recordingURL == nil)
    }

    @Test("A clean stop tears down and does not throw")
    func cleanStopTearsDown() async throws {
        let recorder = MockAudioFileWriting()
        let capture = MockAudioCapturing()
        let controller = makeController(recorder: recorder, capture: capture)

        _ = try await controller.startRecording(format: .wav)
        try await controller.stopRecording()

        #expect(recorder.stopCount == 1)
        #expect(capture.cleanupCount == 1)
        #expect(controller.recordingURL == nil)
    }
}
