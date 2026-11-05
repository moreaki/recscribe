import AVFoundation
import Foundation
import os
import Testing
@testable import RecScribe

@MainActor
struct AudioRecorderTests {
    private func tempURL() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")
    }

    @Test(arguments: [1, 20])
    func repeatedSessionsDrainEveryAcceptedPacket(cycles: Int) async throws {
        let recorder = AudioRecorder()
        for _ in 0..<cycles {
            let target = tempURL()
            defer { try? FileManager.default.removeItem(at: target) }
            try recorder.startRecording(to: target, format: .wav)
            for _ in 0..<50 {
                recorder.processAudioSample(SampleBufferFixtures.makePCMBuffer(channels: 2,
                    frames: 64, interleaved: false) { _, _ in 0 })
            }
            try await recorder.stopRecording()
            #expect(try AVAudioFile(forReading: target).length == 3200)
            #expect(!recorder.recording)
            #expect(recorder.lastMetrics.written == 50 && recorder.lastMetrics.rejected == 0)
        }
        await #expect(throws: AudioRecorderError.self) { try await recorder.stopRecording() }
    }

    private final class RefusingSeal: AudioFileEncoder {
        struct Failure: Error {}
        func createFile(at url: URL, sampleRate: Double, channels: Int) throws {}
        func writeBuffer(_ buffer: AVAudioPCMBuffer) throws {}
        func finalize() throws { throw Failure() }
    }

    @Test func sealFailureReleasesSessionAndAllowsAnotherStart() async throws {
        let recorder = AudioRecorder(encoderFactory: { _ in RefusingSeal() })
        for _ in 0..<2 {
            try recorder.startRecording(to: tempURL(), format: .wav)
            #expect(recorder.recording)
            await #expect(throws: RefusingSeal.Failure.self) { try await recorder.stopRecording() }
            #expect(!recorder.recording)
            await #expect(throws: AudioRecorderError.self) { try await recorder.stopRecording() }
        }
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

}
