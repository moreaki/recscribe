import AVFoundation
import CoreMedia
import Foundation
import Testing
@testable import RecScribe

@MainActor
struct MultiSourceLifecycleTests {
    private var descriptors: [RecordingSession.SourceTrack] {
        [.init(role: .playback, name: "Playback"), .init(role: .microphone, name: "Microphone", deviceUID: "test")]
    }
    private func folder() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
    private func packet(_ role: CaptureTrack, at time: Double) -> CapturedAudioSample {
        .init(track: role, presentationTime: time,
              buffer: SampleBufferFixtures.makePCMBuffer(channels: 2, frames: 480, interleaved: false) { _, _ in role == .microphone ? 0.2 : 0.4 })
    }
    @Test func stopDrainsBothSourcesEvenWhenCallerIsCancelledAndLateSamplesCannotAppend() async throws {
        let directory = try folder(); defer { try? FileManager.default.removeItem(at: directory) }
        let recorder = MultiSourceRecorder(onError: { _ in Issue.record("Unexpected error") })
        try recorder.start(at: directory.appendingPathComponent("test.wav"), descriptors: descriptors, options: .init(), epoch: 100)
        for index in 0..<10 {
            recorder.accept(packet(.microphone, at: 100 + Double(index) / 100))
            recorder.accept(packet(.playback, at: 100 + Double(index) / 100))
        }
        let stop = Task { try await recorder.stop() }
        stop.cancel()
        try await stop.value
        recorder.accept(packet(.playback, at: 101))
        let session = try RecordingSession.read(#require(recorder.manifestURL))
        #expect(session.totalFrames == 4_800)
        #expect(session.status == .finalized)
        #expect(recorder.sourceHealth.allSatisfy { $0.health.receivedFrames == 4_800 && $0.health.writtenFrames == 4_800 })
    }
    @Test func admissionBudgetStopsExplicitlyAndPreservesTheSession() async throws {
        let directory = try folder(); defer { try? FileManager.default.removeItem(at: directory) }
        let recorder = MultiSourceRecorder(onError: { _ in }, maximumBytes: 8)
        try recorder.start(at: directory.appendingPathComponent("test.wav"), descriptors: descriptors, options: .init(), epoch: 100)
        recorder.accept(packet(.playback, at: 100))
        await #expect(throws: AudioRecorderError.bufferLimit) { try await recorder.stop() }
        let session = try RecordingSession.read(#require(recorder.manifestURL))
        #expect(session.status == .needsReview)
        #expect(session.totalFrames == 0)
    }
    @Test func selectedMissingSourceFailsStopWithoutDiscardingTheOtherTrack() async throws {
        let directory = try folder(); defer { try? FileManager.default.removeItem(at: directory) }
        let recorder = MultiSourceRecorder(onError: { _ in })
        try recorder.start(at: directory.appendingPathComponent("test.wav"), descriptors: descriptors, options: .init(), epoch: 100)
        recorder.accept(packet(.playback, at: 100))
        await #expect(throws: SessionError.self) { try await recorder.stop() }
        let session = try RecordingSession.read(#require(recorder.manifestURL))
        #expect(session.status == .needsReview)
        #expect(session.totalFrames == 480)
        #expect(session.issues.contains { $0.contains("microphone") && $0.contains("no data") })
    }
    @Test func controllerConfiguresCombinedSourceAndWritesBothTracks() async throws {
        let directory = try folder(); defer { try? FileManager.default.removeItem(at: directory) }
        let capture = MockAudioCapturing()
        let source = AudioSource.mixed(appBundleID: "test.browser", deviceUID: "test.mic")
        let controller = RecordingController(captureManager: capture, saveLocation: MockSaveLocationProviding(directory: directory),
            audioSource: MockAudioSourceProviding(selectedSource: source))
        let audio = try await controller.startRecording(format: .wav)
        let now = CMClockGetTime(CMClockGetHostTimeClock()).seconds
        for index in 0..<10 {
            capture.emit(packet(.playback, at: now + Double(index) / 100))
            capture.emit(packet(.microphone, at: now + Double(index) / 100))
        }
        try await controller.stopRecording()
        #expect(capture.lastSource == source)
        #expect(capture.cleanupCount == 1)
        let session = try RecordingSession.read(RecordingSession.manifestURL(for: audio))
        #expect(session.sourceTracks?.count == 2)
        #expect(session.totalFrames >= 4800)
    }
    @Test func combinedSelectionPersistsAndMissingMicrophonePermissionPreventsCapture() async throws {
        let source = AudioSource.mixed(appBundleID: nil, deviceUID: "test.mic")
        #expect(try JSONDecoder().decode(AudioSource.self, from: JSONEncoder().encode(source)) == source)
        let permissions = MockPermissionProviding(.granted); permissions.micStatus = .denied
        let capture = MockRecordingControlling()
        let defaults = UserDefaults(suiteName: "multi-source-\(UUID())")!
        let viewModel = RecorderViewModel(controller: capture, permissions: permissions,
            audioSource: MockAudioSourceProviding(selectedSource: source), defaults: defaults)
        await viewModel.startRecording()
        #expect(viewModel.state == .error(.microphoneDenied))
        #expect(permissions.requestedPermissionKinds.contains(.microphone))
        #expect(capture.startCount == 0)
    }
}
