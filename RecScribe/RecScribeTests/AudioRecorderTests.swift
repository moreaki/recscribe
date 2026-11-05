//
//  AudioRecorderTests.swift
//  RecScribeTests
//
//  BL-024: the recording path confines writer state to a single serial queue.
//  These tests assert no trailing buffers are dropped on stop and exercise
//  rapid start/stop cycles (run under Thread Sanitizer to catch data races).
//

import Testing
import Foundation
import AVFoundation
import os
@testable import RecScribe

@MainActor
struct AudioRecorderTests {

    private func tempURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("audiorecorder-test-\(UUID().uuidString).wav")
    }

    /// Build a silent, canonical non-interleaved Float32 PCM buffer with the given
    /// frame count — the same shape every `AudioCapturing` source delivers (BL-099).
    private func makePCMBuffer(frames: Int, sampleRate: Double = 48000, channels: Int = 2) -> AVAudioPCMBuffer {
        SampleBufferFixtures.makePCMBuffer(
            channels: channels, frames: frames, sampleRate: sampleRate, interleaved: false
        ) { _, _ in 0 }
    }

    /// Read the WAV `data` chunk size (UInt32 LE at offset 40).
    private func wavDataSize(at url: URL) throws -> Int {
        let b = [UInt8](try Data(contentsOf: url))
        return Int(UInt32(b[40]) | (UInt32(b[41]) << 8) | (UInt32(b[42]) << 16) | (UInt32(b[43]) << 24))
    }

    @Test("All submitted buffers are written — no trailing drops on stop")
    func noBufferDropsOnStop() async throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let recorder = AudioRecorder()
        try recorder.startRecording(to: url, format: .wav)

        let bufferCount = 50
        let framesPerBuffer = 64
        for _ in 0..<bufferCount {
            recorder.processAudioSample(makePCMBuffer(frames: framesPerBuffer))
        }
        try await recorder.stopRecording()   // drains all in-flight buffers, then finalizes

        // 48kHz stereo Int16: frames * channels(2) * 2 bytes
        let expected = bufferCount * framesPerBuffer * 2 * 2
        #expect(try wavDataSize(at: url) == expected)
    }

    /// Delays the real WAV write until the producer has released its reference.
    private nonisolated final class LifetimeEncoder: AudioFileEncoder, @unchecked Sendable {
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let deallocations: OSAllocatedUnfairLock<Int>
        let writer = WAVWriter() // encoding queue only
        static func wait(_ signal: DispatchSemaphore) -> Bool { signal.wait(timeout: .now() + 30) == .success }
        init(deallocations: OSAllocatedUnfairLock<Int>) { self.deallocations = deallocations }
        func createFile(at url: URL, sampleRate: Double, channels: Int) throws {
            try writer.createFile(at: url, sampleRate: sampleRate, channels: channels)
        }
        func writeBuffer(_ buffer: AVAudioPCMBuffer) throws {
            entered.signal()
            guard release.wait(timeout: .now() + 30) == .success else {
                throw WAVWriterError.fileWriteFailed
            }
            #expect(deallocations.withLock { $0 } == 0, "Queued PCM storage must survive until the writer finishes reading")
            try writer.writeBuffer(buffer)
            #expect(deallocations.withLock { $0 } == 0)
        }
        func finalize() throws { try writer.finalize() }
    }

    @Test("Queued PCM storage is released only after its last reader; allocation churn preserves bytes")
    func queuedPCMLifetimeIsExplicit() async throws {
        let target = tempURL()
        defer { try? FileManager.default.removeItem(at: target) }
        let deallocations = OSAllocatedUnfairLock(initialState: 0)
        let encoder = LifetimeEncoder(deallocations: deallocations)
        defer { encoder.release.signal() }
        let recorder = AudioRecorder { _ in encoder }
        try recorder.startRecording(to: target, format: .wav)
        autoreleasepool {
            let pcm = SampleBufferFixtures.makePCMBuffer(channels: 2, frames: 64, interleaved: false,
                onDeallocate: { deallocations.withLock { $0 += 1 } }) { channel, _ in channel == 0 ? 0.25 : -0.5 }
            recorder.processAudioSample(pcm)
        }
        #expect(await Task.detached { LifetimeEncoder.wait(encoder.entered) }.value)
        #expect(deallocations.withLock { $0 } == 0)
        // These allocations must not reuse storage still owned by the writer.
        for _ in 0..<1000 {
            _ = SampleBufferFixtures.makePCMBuffer(channels: 2, frames: 64, interleaved: false) { _, _ in 1 }
        }
        encoder.release.signal()
        try await recorder.stopRecording()
        #expect(deallocations.withLock { $0 } == 1, "The queued owner must release its fixture storage after writing")
        let data = Array(try Data(contentsOf: target).dropFirst(44))
        var expected: [UInt8] = []
        for _ in 0..<64 {
            for value: Float in [0.25, -0.5] {
                let pcm = UInt16(bitPattern: Int16(value * 32767))
                expected += [UInt8(pcm & 0xff), UInt8(pcm >> 8)]
            }
        }
        #expect(data == expected)
    }

    @Test("20 rapid start/stop cycles produce no corrupt-header files (TSan target)")
    func rapidStartStopCycles() async throws {
        let buffersPerCycle = 5
        let framesPerBuffer = 32
        for _ in 0..<20 {
            let url = tempURL()
            defer { try? FileManager.default.removeItem(at: url) }

            let recorder = AudioRecorder()
            try recorder.startRecording(to: url, format: .wav)
            for _ in 0..<buffersPerCycle {
                recorder.processAudioSample(makePCMBuffer(frames: framesPerBuffer))
            }
            try await recorder.stopRecording()

            // Header must be valid and match the audio written (no corruption).
            let expected = buffersPerCycle * framesPerBuffer * 2 * 2
            #expect(try wavDataSize(at: url) == expected)
        }
    }

    @Test("stopRecording without an active recording throws")
    func stopWithoutStartThrows() async {
        let recorder = AudioRecorder()
        await #expect(throws: AudioRecorderError.self) {
            try await recorder.stopRecording()
        }
    }

    // MARK: - BL-016 finalize-error propagation

    /// An encoder whose `finalize()` always fails, so the stop path's error
    /// handling can be driven without a real codec failure.
    private final class FailingFinalizeEncoder: AudioFileEncoder {
        struct Boom: Error, Equatable {}
        private(set) var finalizeCount = 0
        func createFile(at url: URL, sampleRate: Double, channels: Int) throws {
            FileManager.default.createFile(atPath: url.path, contents: Data())
        }
        func writeBuffer(_ buffer: AVAudioPCMBuffer) throws {}
        func finalize() throws {
            finalizeCount += 1
            throw Boom()
        }
    }

    @Test("A finalize failure propagates instead of being silently swallowed")
    func finalizeErrorPropagates() async throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let recorder = AudioRecorder(encoderFactory: { _ in FailingFinalizeEncoder() })
        try recorder.startRecording(to: url, format: .wav)

        await #expect(throws: FailingFinalizeEncoder.Boom.self) {
            try await recorder.stopRecording()
        }
    }

    /// The regression this guards: releasing the encoder inside a `defer` so a
    /// failed finalize can't strand the recorder in a permanently-recording state
    /// that refuses every subsequent start.
    @Test("A failed finalize still releases the encoder")
    func failedFinalizeStillClearsState() async throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let recorder = AudioRecorder(encoderFactory: { _ in FailingFinalizeEncoder() })
        try recorder.startRecording(to: url, format: .wav)
        #expect(recorder.recording)

        await #expect(throws: FailingFinalizeEncoder.Boom.self) {
            try await recorder.stopRecording()
        }

        #expect(!recorder.recording)
        // A second stop reports "not recording", not another finalize attempt.
        await #expect(throws: AudioRecorderError.self) {
            try await recorder.stopRecording()
        }
        // And a fresh recording can still be started.
        let next = tempURL()
        defer { try? FileManager.default.removeItem(at: next) }
        try recorder.startRecording(to: next, format: .wav)
        #expect(recorder.recording)
    }
}
