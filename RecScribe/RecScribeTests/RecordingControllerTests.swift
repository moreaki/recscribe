import Foundation
import Testing
@testable import RecScribe

@MainActor
struct RecordingControllerTests {
    private struct FinalizeFailure: Error {}

    @Test(arguments: ["success", "validation", "setup", "captureStop", "seal"])
    func coordinatesSourceWriterAndCleanup(failure: String) async throws {
        let capture = MockAudioCapturing(), recorder = MockAudioFileWriting()
        let source = MockAudioSourceProviding(selectedSource: .app(bundleID: "app.selected"))
        if failure == "validation" { source.validateError = AudioSourceError.appNotRunning("app.selected") }
        if failure == "setup" { capture.setupError = FinalizeFailure() }
        let controller = RecordingController(captureManager: capture, audioRecorder: recorder,
            saveLocation: MockSaveLocationProviding(directory: FileManager.default.temporaryDirectory), audioSource: source)
        #expect(controller.generateFilePath().pathExtension == "wav")
        if ["validation", "setup"].contains(failure) {
            await #expect(throws: (any Error).self) { try await controller.startRecording() }
            #expect(controller.recordingURL == nil && !recorder.recording)
            #expect(recorder.startCount == (failure == "validation" ? 0 : 1))
            #expect(capture.setupCount == (failure == "validation" ? 0 : 1))
            if failure == "setup" { #expect(recorder.stopCount == 1 && capture.cleanupCount == 1) }
            return
        }
        let url = try await controller.startRecording()
        #expect(url.pathExtension == "wav" && recorder.lastStartFormat == .wav)
        #expect(capture.lastSource == source.selectedSource && source.validateCount == 1)
        if failure == "captureStop" { capture.stopError = FinalizeFailure() }
        if failure == "seal" { recorder.stopError = FinalizeFailure() }
        if failure == "success" { try await controller.stopRecording() }
        else { await #expect(throws: (any Error).self) { try await controller.stopRecording() } }
        #expect(capture.stopCount == 1 && recorder.stopCount == 1 && capture.cleanupCount == 1)
        #expect(controller.recordingURL == nil && !recorder.recording && !capture.capturing)
    }

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

}
