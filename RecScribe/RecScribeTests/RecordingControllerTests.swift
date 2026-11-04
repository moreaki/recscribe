//
//  RecordingControllerTests.swift
//  RecScribeTests
//
//  WAV capture, source configuration, and teardown through injected capture/encoder seams.
//

import Testing
import Foundation
@testable import RecScribe

@MainActor
struct RecordingControllerTests {
    @Test func injectedRecorderCoordinatesCaptureAndFailureWithTheLibrary() async throws {
        for shouldFail in [false, true] {
            let capture = MockAudioCapturing(), recorder = MockAudioFileWriting()
            var runtimeCancellations = 0
            let library = SessionLibrary(cancelRuntime: { runtimeCancellations += 1 })
            if shouldFail { capture.setupError = FinalizeFailure() }
            let controller = RecordingController(captureManager: capture, audioRecorder: recorder,
                saveLocation: MockSaveLocationProviding(directory: FileManager.default.temporaryDirectory),
                audioSource: MockAudioSourceProviding(), sessionLibrary: library)
            do {
                _ = try await controller.startRecording()
                #expect(library.recordingActive)
                try await controller.stopRecording()
            } catch { #expect(shouldFail) }
            #expect(!library.recordingActive)
            #expect(runtimeCancellations == 1)
            await library.shutdown()
        }
    }

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

    @Test("Live capture paths always use the canonical WAV extension")
    func filePathAlwaysUsesWAV() {
        #expect(makeController().generateFilePath().pathExtension == "wav")
    }

    @Test("Capture always uses lossless WAV, independently of archive preference")
    func startAlwaysUsesWAV() async throws {
        let recorder = MockAudioFileWriting()
        let controller = makeController(recorder: recorder)

        let url = try await controller.startRecording()

        #expect(recorder.lastStartFormat == .wav)
        #expect(url.pathExtension == "wav")
        #expect(controller.recordingURL?.pathExtension == "wav")
    }

    @Test("Legacy format defaults cannot change WAV capture or its independent archive policy",
          arguments: ["wav", "m4a", "flac", "garbage"])
    func obsoleteFormatPreferenceDoesNotAffectTheRealCaptureWriter(_ legacyFormat: String) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let suite = "wav-capture-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(legacyFormat, forKey: "selectedFormat")
        let capture = MockAudioCapturing()
        let source = MockAudioSourceProviding(selectedSource: .systemAll)
        let location = MockSaveLocationProviding(directory: directory)
        let audio = AudioServices(defaults: defaults)
        let controller = RecordingController(captureManager: capture, saveLocation: location,
            audioSource: source, levels: audio.levels, monitor: audio.monitor,
            storageOptions: { .init(archiveFormat: .flac) })
        let viewModel = RecorderViewModel(controller: controller, permissions: MockPermissionProviding(.granted),
            clock: ManualClock(), saveLocation: location, audioSource: source,
            installLocation: MockInstallLocationProviding(.applications), defaults: defaults, audio: audio)
        do {
            await viewModel.startRecording()
            let output = try #require(controller.recordingURL)
            #expect(output.pathExtension == "wav")
            #expect(viewModel.isRecording && capture.capturing)
            capture.emitPCM(SampleBufferFixtures.makePCMBuffer(channels: 2, frames: 480, interleaved: false) { _, _ in 0.125 })
            await viewModel.stopRecording()
            let manifest = RecordingSession.manifestURL(for: output)
            let session = try RecordingSession.read(manifest)
            let part = try #require(session.parts.first)
            let wav = try PCM16WAV.read(RecordingSession.safeURL(part.path, beside: manifest))
            #expect(wav.frames == 480 && wav.sampleRate == 48_000 && wav.channels == 2)
            #expect(session.options.archiveFormat == .flac)
            #expect(session.artifacts.isEmpty) // Conversion does not run during capture.
            #expect(defaults.string(forKey: "selectedFormat") == legacyFormat)
            #expect(!capture.capturing && !viewModel.isRecording)
            await audio.shutdown()
        } catch {
            await viewModel.stopRecording()
            await audio.shutdown()
            throw error
        }
    }

    @Test("startRecording threads the selected AudioSource into capture setup (BL-100)")
    func startThreadsAudioSource() async throws {
        let capture = MockAudioCapturing()
        let audioSource = MockAudioSourceProviding(selectedSource: .app(bundleID: "com.apple.logic10"))
        let controller = makeController(capture: capture, audioSource: audioSource)

        _ = try await controller.startRecording()

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
            try await controller.startRecording()
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
        await #expect(throws: FinalizeFailure.self) { try await controller.startRecording() }
        #expect(recorder.stopCount == 1)
        #expect(capture.cleanupCount == 1)
        #expect(!recorder.recording)
    }

    @Test("Capture stop failure still finalizes and cleans up")
    func captureStopFailureFinalizes() async throws {
        let recorder = MockAudioFileWriting()
        let capture = MockAudioCapturing()
        let controller = makeController(recorder: recorder, capture: capture)
        _ = try await controller.startRecording()
        capture.stopError = FinalizeFailure()
        do {
            try await controller.stopRecording()
            Issue.record("Expected a capture-shutdown failure")
        } catch RecordingControllerError.captureShutdownFailed(let cause) {
            #expect(cause is FinalizeFailure)
        } catch { Issue.record("Unexpected stop error: \(error)") }
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

        _ = try await controller.startRecording()
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

        _ = try await controller.startRecording()
        try await controller.stopRecording()

        #expect(recorder.stopCount == 1)
        #expect(capture.cleanupCount == 1)
        #expect(controller.recordingURL == nil)
    }
}
