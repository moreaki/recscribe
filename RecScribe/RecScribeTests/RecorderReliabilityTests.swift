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
        semaphore.wait(timeout: .now() + 60) == .success
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
                _ = release.wait(timeout: .now() + 90)
            }
            if failWrite { throw WriteFailure() }
        }
        func finalize() throws {
            finalizes += 1
            if blockFinalize {
                entered.signal()
                _ = release.wait(timeout: .now() + 90)
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
        #expect(recorder.healthSnapshot.failed)
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

    @Test("SingleInputAudioNormalizer enforces bounded byte/buffer admission including in-flight work and drains before finish", arguments: [true, false])
    func singleInputNormalizerBoundedAdmissionAndStopRace(byCount: Bool) async {
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let delivered = OSAllocatedUnfairLock(initialState: 0)
        let deliveredFrames = OSAllocatedUnfairLock(initialState: 0)
        let deliveredFirstSamples = OSAllocatedUnfairLock(initialState: [Float]())
        let errors = OSAllocatedUnfairLock(initialState: [String]())

        let normalizer = SingleInputAudioNormalizer(
            maxBuffers: byCount ? 2 : 100,
            maxBytes: byCount ? 1_024 : 128,
            callback: { normalized in
                let index = delivered.withLock { count -> Int in
                    count += 1
                    return count
                }
                let frames = Int(normalized.frameLength)
                deliveredFrames.withLock { $0 += frames }
                if let sample = normalized.floatChannelData?[0][0] {
                    deliveredFirstSamples.withLock { $0.append(sample) }
                }
                if index == 1 {
                    entered.signal()
                    _ = release.wait(timeout: .now() + 90)
                }
            },
            onError: { message in
                errors.withLock { $0.append(message) }
            }
        )

        let firstAdmitted = SampleBufferFixtures.makePCMBuffer(channels: 2, frames: 8, sampleRate: 48_000, interleaved: false) { _, _ in 0.25 }
        let secondAdmitted = SampleBufferFixtures.makePCMBuffer(channels: 2, frames: 8, sampleRate: 48_000, interleaved: false) { _, _ in 0.5 }
        let overflowCandidate = SampleBufferFixtures.makePCMBuffer(channels: 2, frames: 8, sampleRate: 48_000, interleaved: false) { _, _ in 0.75 }

        // First buffer enters the callback and stays in-flight; second is admitted and queued; remaining overflow once.
        normalizer.accept(firstAdmitted)
        #expect(await Task.detached { Self.wait(entered) }.value)
        normalizer.accept(secondAdmitted)
        for _ in 0..<200 {
            normalizer.accept(overflowCandidate)
        }
        release.signal()
        await normalizer.finish()
        // Both admitted buffers (in-flight #1 and queued #2) must reach callback in order BEFORE finish() returns.
        #expect(delivered.withLock { $0 } == 2)
        #expect(deliveredFrames.withLock { $0 } == 16)
        #expect(deliveredFirstSamples.withLock { $0 } == [0.25, 0.5])
        await settle()

        let m = normalizer.metrics
        #expect(m.peakBuffers == 2)
        #expect(m.peakBytes == 128)
        #expect(m.rejected == 1)
        #expect(errors.withLock { $0.count } == 1)
        #expect(errors.withLock { $0.first } == AudioRecorderError.bufferLimit.localizedDescription)

        // Stop-race / drain-before-finalize ordering on a clean instance.
        let cleanCount = OSAllocatedUnfairLock(initialState: 0)
        let cleanNormalizer = SingleInputAudioNormalizer(
            callback: { _ in cleanCount.withLock { $0 += 1 } },
            onError: { _ in Issue.record("Unexpected normalizer error") }
        )
        for _ in 0..<40 {
            cleanNormalizer.accept(buffer())
        }
        await cleanNormalizer.finish()
        #expect(cleanCount.withLock { $0 } == 40)
        cleanNormalizer.accept(buffer())
        await cleanNormalizer.finish()
        #expect(cleanCount.withLock { $0 } == 40)
    }

    @Test("ScreenCaptureAudioManager ignores stale SingleInputAudioNormalizer errors across stop and new setup")
    func singleInputNormalizerGenerationGuardAcrossStopAndRestart() async throws {
        let manager = ScreenCaptureAudioManager()
        var recordedErrors: [String] = []
        manager.onStreamError = { message in
            recordedErrors.append(message)
        }

        try await manager.setupCapture(source: .mic(deviceUID: "mic-1")) { _ in }
        manager.setCapturingForTesting(true)
        let firstCallback = try #require(manager.inputCallback)

        // Create a buffer with non-finite float samples so normalization fails asynchronously on the normalizer queue.
        let invalidBuffer = buffer()
        invalidBuffer.floatChannelData![0][0] = .nan
        firstCallback(.init(track: .input("mic-1"), presentationTime: 1.0, buffer: invalidBuffer))

        // Immediately stop/cleanup and set up a new capture before the MainActor error task runs.
        try await manager.stopCapture()
        await manager.cleanup()
        try await manager.setupCapture(source: .mic(deviceUID: "mic-2")) { _ in }
        manager.setCapturingForTesting(true)

        // Yield so any pending MainActor error task from the first normalizer executes.
        for _ in 0..<10 {
            await Task.yield()
        }
        #expect(recordedErrors.isEmpty)
        #expect(manager.capturing)
        await manager.cleanup()
    }
}
