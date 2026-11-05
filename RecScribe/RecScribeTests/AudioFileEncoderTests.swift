import AVFoundation
import Foundation
import Testing
@testable import RecScribe

struct AudioFileEncoderTests {
    @Test func protocolProducesDecodableStereoWithDistinctChannels() throws {
        let target = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")
        defer { try? FileManager.default.removeItem(at: target) }
        let encoder: any AudioFileEncoder = WAVWriter()
        let packet = SampleBufferFixtures.makePCMBuffer(channels: 2, frames: 256, interleaved: false) {
            channel, _ in channel == 0 ? 0.25 : -0.5
        }
        #expect(throws: WAVWriterError.fileNotOpen) { try encoder.writeBuffer(packet) }
        #expect(throws: WAVWriterError.fileNotOpen) { try encoder.finalize() }
        try encoder.createFile(at: target, sampleRate: 48_000, channels: 2)
        try encoder.writeBuffer(packet)
        try encoder.finalize()
        let decoded = try AVAudioFile(forReading: target)
        #expect(decoded.length == 256 && decoded.fileFormat.channelCount == 2)
        #expect(decoded.fileFormat.sampleRate == 48_000)
        let output = try #require(AVAudioPCMBuffer(pcmFormat: decoded.processingFormat, frameCapacity: 256))
        try decoded.read(into: output)
        let planes = try #require(output.floatChannelData)
        for frame in 0..<256 {
            #expect(abs(planes[0][frame] - 0.25) < 0.0001)
            #expect(abs(planes[1][frame] + 0.5) < 0.0001)
        }
    }
}
