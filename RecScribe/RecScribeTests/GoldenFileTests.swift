import AVFoundation
import Foundation
import Testing
@testable import RecScribe

@MainActor
struct GoldenFileTests {
    private func tempURL() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")
    }

    @Test func deterministicSequenceKeepsTheAcceptedPCMAndHeader() async throws {
        let target = tempURL()
        defer { try? FileManager.default.removeItem(at: target) }
        let recorder = AudioRecorder()
        try recorder.startRecording(to: target, format: .wav)
        var reference = Data()
        // This compatibility signal and its quantization match the pre-replacement test.
        for batch in 0..<5 {
            let packet = SampleBufferFixtures.makePCMBuffer(channels: 2, frames: 64, interleaved: false) {
                channel, frame in
                let value = Float((batch * 64 + frame) % 200) / 100 - 1
                return channel == 0 ? value : -value
            }
            recorder.processAudioSample(packet)
            for frame in 0..<64 {
                let left = Float((batch * 64 + frame) % 200) / 100 - 1
                for value in [left, -left] {
                    var sample = Int16(value * 32767).littleEndian
                    withUnsafeBytes(of: &sample) { reference.append(contentsOf: $0) }
                }
            }
        }
        try await recorder.stopRecording()
        let result = try Data(contentsOf: target)
        #expect(Data(result.dropFirst(44)) == reference)
        // Constant canonical header fields, with the expected 1280-byte payload.
        let header: [UInt8] = [82,73,70,70,36,5,0,0,87,65,86,69,102,109,116,32,
            16,0,0,0,1,0,2,0,128,187,0,0,0,238,2,0,4,0,16,0,100,97,116,97,0,5,0,0]
        #expect(Array(result.prefix(44)) == header)
    }

    @Test func queuedBuffersSurviveProducerAllocationChurnWithoutChangingPCMBytes() async throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let count = 256, frames = 128
        let recorder = AudioRecorder(maxBuffers: count, maxBytes: 1_024 * 1_024)
        try recorder.startRecording(to: url, format: .wav)
        var expected: [UInt8] = []
        for index in 0..<count {
            autoreleasepool {
                let buffer = SampleBufferFixtures.makePCMBuffer(channels: 2, frames: frames, interleaved: false) {
                    channel, frame in Float((index + channel + frame) % 32 - 16) / 32
                }
                recorder.processAudioSample(buffer)
            } // No producer reference survives; only the queued worker owns it.
            for frame in 0..<frames {
                for channel in 0..<2 {
                    let value = Float((index + channel + frame) % 32 - 16) / 32
                    let pcm = UInt16(bitPattern: Int16(value * 32767))
                    expected.append(UInt8(pcm & 0xff))
                    expected.append(UInt8(pcm >> 8))
                }
            }
            await Task.yield()
        }
        try await recorder.stopRecording()
        #expect(Array(try Data(contentsOf: url).dropFirst(44)) == expected)
        #expect(recorder.lastMetrics.accepted == count)
        #expect(recorder.lastMetrics.written == count)
        #expect(recorder.lastMetrics.rejected == 0)
    }

}
