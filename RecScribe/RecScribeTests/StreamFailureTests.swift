import Foundation
import Testing
@testable import RecScribe

@MainActor struct StreamFailureTests {
    @Test(arguments: [false, true])
    func unexpectedStreamEndFinalizesOnlyAnActiveTake(active: Bool) async throws {
        let name = "stream-contract-\(UUID())"
        let storage = try #require(UserDefaults(suiteName: name))
        defer { storage.removePersistentDomain(forName: name) }
        let capture = MockAudioCapturing()
        let writer = MockAudioFileWriting()
        let source = MockAudioSourceProviding()
        let location = MockSaveLocationProviding(directory: FileManager.default.temporaryDirectory)
        let coordinator = RecordingController(captureManager: capture, audioRecorder: writer, saveLocation: location, audioSource: source)
        let model = RecorderViewModel(controller: coordinator, permissions: MockPermissionProviding(), clock: ManualClock(),
                                      saveLocation: location, audioSource: source, defaults: storage)
        if active { await model.startRecording(); #expect(model.isRecording) }
        capture.simulateStreamError("test-stream-interruption")
        if active {
            #expect(model.state == .error(.streamFailed("test-stream-interruption")))
            await model.waitForFailureFinalization()
        }
        #expect(writer.stopCount == (active ? 1 : 0))
        #expect(!model.isRecording)
        if !active { #expect(model.state == .idle) }
    }
}
