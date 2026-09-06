import AVFoundation
import Foundation
import Testing
import os
@testable import RecScribe

@MainActor
struct RecorderReliabilityTests {
    private nonisolated static func wait(_ semaphore: DispatchSemaphore) -> Bool {
        // Framework/file failure tests share MainActor and may stall it for
        // several seconds. These deadlines protect the test harness, not a
        // production latency budget; the fake encoder must stay blocked until
        // the test explicitly releases it.
        semaphore.wait(timeout: .now() + 15) == .success
    }
    /// Only the encoding queue mutates counters; assertions read after stop.
    private nonisolated final class Encoder: AudioFileEncoder, @unchecked Sendable {
        struct WriteFailure: Error, Equatable {}
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let blockWrite: Bool
        let blockFinalize: Bool
        let failWrite: Bool
        var writes = 0
        var finalizes = 0
        init(blockWrite: Bool = false, blockFinalize: Bool = false, failWrite: Bool = false) {
            self.blockWrite = blockWrite
            self.blockFinalize = blockFinalize
            self.failWrite = failWrite
        }
        func createFile(at url: URL, sampleRate: Double, channels: Int) throws {}
        func writeBuffer(_ buffer: AVAudioPCMBuffer) throws {
            writes += 1
            if blockWrite && writes == 1 {
                entered.signal()
                _ = release.wait(timeout: .now() + 30)
            }
            if failWrite { throw WriteFailure() }
        }
        func finalize() throws {
            finalizes += 1
            if blockFinalize {
                entered.signal()
                _ = release.wait(timeout: .now() + 30)
            }
        }
        func waitUntilEntered() async -> Bool {
            await Task.detached { RecorderReliabilityTests.wait(self.entered) }.value
        }
    }

    private func buffer(_ frames: Int = 8) -> AVAudioPCMBuffer {
        SampleBufferFixtures.makePCMBuffer(channels: 2, frames: frames, sampleRate: 48_000, interleaved: false) { _, _ in 0.25 }
    }
    private func url(_ ext: String = "wav") -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("reliability-\(UUID()).\(ext)")
    }

    @Test("Slow encoder cannot exceed either queue bound; accepted audio drains", arguments: [true, false])
    func boundedAdmission(byCount: Bool) async throws {
        let encoder = Encoder(blockWrite: true)
        defer { encoder.release.signal() }
        let recorder = AudioRecorder(maxBuffers: byCount ? 2 : 100, maxBytes: byCount ? 1_024 : 128) { _ in encoder }
        try recorder.startRecording(to: url(), format: .wav)
        recorder.processAudioSample(buffer())
        #expect(await encoder.waitUntilEntered())
        for _ in 0..<1_000 { recorder.processAudioSample(buffer()) }
        encoder.release.signal()
        await #expect(throws: AudioRecorderError.bufferLimit) { try await recorder.stopRecording() }
        #expect(encoder.writes == 2)
        #expect(encoder.finalizes == 1)
        #expect(recorder.lastMetrics.peakBuffers == 2)
        #expect(recorder.lastMetrics.peakBytes == 128)
        #expect(recorder.lastMetrics.rejected == 1)
        #expect(!recorder.recording)
    }

    @Test("First write failure surfaces immediately and remains the stop result")
    func writeFailure() async throws {
        let encoder = Encoder(failWrite: true)
        let recorder = AudioRecorder { _ in encoder }
        let notified = DispatchSemaphore(value: 0)
        var errors = 0
        recorder.onWriteError = { _ in errors += 1; notified.signal() }
        try recorder.startRecording(to: url(), format: .wav)
        recorder.processAudioSample(buffer())
        #expect(await Task.detached { Self.wait(notified) }.value)
        for _ in 0..<100 { recorder.processAudioSample(buffer()) }
        await #expect(throws: Encoder.WriteFailure.self) { try await recorder.stopRecording() }
        #expect(errors == 1)
        #expect(encoder.writes == 1)
        #expect(encoder.finalizes == 1)
        #expect(recorder.lastMetrics.written == 0)
    }

    @Test("Async stop frees MainActor; cancellation drains and prevents overlapping starts")
    func cancelledStopStillFinalizes() async throws {
        let encoder = Encoder(blockFinalize: true)
        defer { encoder.release.signal() }
        let recorder = AudioRecorder { _ in encoder }
        try recorder.startRecording(to: url(), format: .wav)
        recorder.processAudioSample(buffer())
        let stop = Task { try await recorder.stopRecording() }
        #expect(await encoder.waitUntilEntered())
        // Reaching these MainActor assertions while finalize is blocked proves
        // the UI executor is free. There is no sleep or timing assertion.
        #expect(recorder.recording)
        #expect(throws: AudioRecorderError.alreadyRecording) { try recorder.startRecording(to: url(), format: .wav) }
        await #expect(throws: AudioRecorderError.notRecording) { try await recorder.stopRecording() }
        stop.cancel()
        recorder.processAudioSample(buffer()) // sealed, not appended behind stop
        encoder.release.signal()
        try await stop.value
        #expect(encoder.writes == 1)
        #expect(encoder.finalizes == 1)
        #expect(!recorder.recording)
        #expect(recorder.lastMetrics.finalizeMS >= 0)
    }

    @Test("WAV RIFF limit is checked before overflow, without a multi-GB fixture")
    func riffLimit() throws {
        let limit = UInt32.max - 36
        #expect(try WAVWriter.checkedDataSize(current: limit - 4, adding: 4) == limit)
        #expect(throws: WAVWriterError.sizeLimit) { try WAVWriter.checkedDataSize(current: limit, adding: 1) }
        #expect(throws: WAVWriterError.sizeLimit) { try WAVWriter.checkedDataSize(current: 0, adding: -1) }
    }

    @Test("Non-finite PCM is rejected without trapping or inventing samples")
    func nonFinitePCM() throws {
        let target = url()
        defer { try? FileManager.default.removeItem(at: target) }
        let writer = WAVWriter()
        try writer.createFile(at: target, sampleRate: 48_000, channels: 2)
        let pcm = buffer()
        pcm.floatChannelData![0][0] = .nan
        #expect(throws: WAVWriterError.invalidFormat) { try writer.writeBuffer(pcm) }
        try writer.finalize()
        #expect(try Data(contentsOf: target).count == 44)
    }

    @Test("AAC never succeeds with pending audio; not-ready storage stays bounded")
    func aacBackpressure() throws {
        let target = url("m4a")
        defer { try? FileManager.default.removeItem(at: target) }
        let encoder = M4AEncoder(pendingByteLimit: 64, pendingBufferLimit: 1, finalizeTimeout: 0, isReady: { _ in false })
        try encoder.createFile(at: target, sampleRate: 48_000, channels: 2)
        try encoder.writeBuffer(buffer())
        #expect(throws: M4AEncoderError.bufferLimit) { try encoder.writeBuffer(buffer()) }
        #expect(throws: M4AEncoderError.timedOut) { try encoder.finalize() }
        #expect(throws: M4AEncoderError.notOpen) { try encoder.finalize() }
        #expect(FileManager.default.fileExists(atPath: target.path))
    }

    @Test("AAC completion that never calls back has a finite deadline")
    func aacFinishTimeout() throws {
        let target = url("m4a")
        defer { try? FileManager.default.removeItem(at: target) }
        let encoder = M4AEncoder(finalizeTimeout: 0, finish: { _, _ in })
        try encoder.createFile(at: target, sampleRate: 48_000, channels: 2)
        #expect(throws: M4AEncoderError.timedOut) { try encoder.finalize() }
        #expect(FileManager.default.fileExists(atPath: target.path))
    }

    @Test("Capture hand-off drains in order and rejects a late callback")
    func captureBarrier() async {
        // Owned CMSampleBuffer backing survives until the queue consumes it.
        nonisolated struct Sample: @unchecked Sendable { let value: CMSampleBuffer }
        let sample = Sample(value: SampleBufferFixtures.makeSampleBuffer(from: buffer()))
        let count = OSAllocatedUnfairLock(initialState: 0)
        let output = AudioCaptureOutput { _ in count.withLock { $0 += 1 } }
        for _ in 0..<50 {
            output.queue.async { output.process(sample.value, type: .audio) }
        }
        await output.finish()
        #expect(count.withLock { $0 } == 50)
        output.queue.async { output.process(sample.value, type: .audio) }
        await output.finish()
        #expect(count.withLock { $0 } == 50)
    }
}
