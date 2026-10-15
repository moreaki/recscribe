import AVFoundation
import Foundation
import Testing
@testable import RecScribe

struct RecordingHealthTests {
    @Test func silenceIsNotMissingDataAndLateAudioRecovers() {
        var health = RecordingHealth(startedAt: 10)
        let policy = RecordingHealth.Policy(firstDataTimeout: 2, stallTimeout: 3)
        #expect(health.status(at: 11, policy: policy) == .waiting)
        #expect(health.status(at: 12, policy: policy) == .noData)
        health.lastReceivedAt = 20
        health.receivedFrames = 100
        #expect(health.status(at: 20, policy: policy) == .writing)
        health.lastWrittenAt = 20
        health.writtenFrames = 100
        #expect(health.status(at: 20, policy: policy) == .silence)
        health.peak = 0.25
        #expect(health.status(at: 20, policy: policy) == .audio)
        #expect(health.status(at: 23, policy: policy) == .stalled)
        health.failed = true
        #expect(health.status(at: 20, policy: policy) == .failed)
    }

    @Test func writeStallDoesNotCompareNativeFramesWithResampledOrPaddedFrames() {
        let health = RecordingHealth(startedAt: 10, firstReceivedAt: 10, lastReceivedAt: 24,
                                     lastWrittenAt: 20, receivedFrames: 100, writtenFrames: 200, peak: 0.4)
        #expect(health.status(at: 24) == .writeStalled)
    }

    @MainActor @Test func emptySessionIsPreservedForReview() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let recorder = AudioRecorder { _ in SessionWAVWriter() }
        try recorder.startRecording(to: directory.appendingPathComponent("empty.wav"), format: .wav)
        await #expect(throws: SessionError.self) { try await recorder.stopRecording() }
        let session = try RecordingSession.read(#require(recorder.sessionManifestURL))
        #expect(session.status == .needsReview)
        #expect(session.totalFrames == 0)
        #expect(!session.issues.isEmpty)
        #expect(!recorder.recording)
    }

    @MainActor @Test func silentPCMIsSuccessfullyWrittenAndZeroFramesDoNotCount() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let recorder = AudioRecorder { _ in SessionWAVWriter() }
        try recorder.startRecording(to: directory.appendingPathComponent("silent.wav"), format: .wav)
        let empty = AVAudioPCMBuffer(pcmFormat: AudioFormatNormalizer.canonical, frameCapacity: 1)!
        recorder.processAudioSample(empty)
        recorder.processAudioSample(SampleBufferFixtures.makePCMBuffer(channels: 2, frames: 128, sampleRate: 48_000, interleaved: false) { _, _ in 0 })
        try await recorder.stopRecording()
        let health = recorder.healthSnapshot
        #expect(health.receivedFrames == 128)
        #expect(health.writtenFrames == 128)
        let writtenAt = try #require(health.lastWrittenAt)
        #expect(health.status(at: writtenAt) == .silence)
        #expect(try AVAudioFile(forReading: #require(recorder.actualAudioURL)).length == 128)
    }
}
