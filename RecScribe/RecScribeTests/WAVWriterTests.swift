import AVFoundation
import Foundation
import Testing
@testable import RecScribe

struct WAVWriterTests {
    @Test(arguments: [44_100, 48_000], [1, 2])
    func headerAndPayloadRemainReadable(rate: Int, channels: Int) throws {
        let target = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")
        defer { try? FileManager.default.removeItem(at: target) }
        let sink = WAVWriter()
        try sink.createFile(at: target, sampleRate: Double(rate), channels: channels)
        // Check the public file format before and after a sequence of writes.
        for batch in 0...3 {
            if batch > 0 {
                let packet = SampleBufferFixtures.makePCMBuffer(channels: channels, frames: 50,
                    sampleRate: Double(rate), interleaved: false) { _, _ in 0 }
                try sink.writeBuffer(packet)
            }
            if batch == 3 { try sink.finalize() }
        }
        let bytes = try Data(contentsOf: target)
        #expect(bytes.count == 44 + 150 * channels * 2)
        #expect(String(decoding: bytes.prefix(4), as: UTF8.self) == "RIFF")
        #expect(String(decoding: bytes[8..<16], as: UTF8.self) == "WAVEfmt ")
        #expect(String(decoding: bytes[36..<40], as: UTF8.self) == "data")
        let audio = try AVAudioFile(forReading: target)
        #expect(audio.length == 150)
        #expect(audio.fileFormat.sampleRate == Double(rate))
        #expect(audio.fileFormat.channelCount == channels)
        #expect(audio.fileFormat.streamDescription.pointee.mBitsPerChannel == 16)
    }

    @Test func checkpointSupportsReadingBeforeClose() throws {
        let target = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")
        defer { try? FileManager.default.removeItem(at: target) }
        let sink = WAVWriter()
        try sink.createFile(at: target, sampleRate: 48_000, channels: 2)
        for _ in 0..<WAVWriter.headerUpdateInterval {
            try sink.writeBuffer(SampleBufferFixtures.makePCMBuffer(channels: 2, frames: 64,
                interleaved: false) { _, _ in 0.25 })
        }
        #expect(try AVAudioFile(forReading: target).length == Int64(64 * WAVWriter.headerUpdateInterval))
        try sink.finalize()
    }

    @Test func fixedQuantizationVector() throws {
        let target = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")
        defer { try? FileManager.default.removeItem(at: target) }
        let vector: [Float] = [-2, -1, -0.75, -0.5, -0.25, 0, 0.25, 0.5, 0.75, 1, 2]
        // Literal compatibility values; do not calculate them with the encoder formula.
        let expected: [Int16] = [-32767, -32767, -24575, -16383, -8191, 0, 8191, 16383, 24575, 32767, 32767]
        let sink = WAVWriter()
        try sink.createFile(at: target, sampleRate: 48_000, channels: 1)
        try sink.writeBuffer(SampleBufferFixtures.makePCMBuffer(channels: 1, frames: vector.count,
            interleaved: false) { _, index in vector[index] })
        try sink.finalize()
        let payload = Array(try Data(contentsOf: target).dropFirst(44))
        let result = stride(from: 0, to: payload.count, by: 2).map {
            Int16(bitPattern: UInt16(payload[$0]) + UInt16(payload[$0 + 1]) * 256)
        }
        #expect(result == expected)
    }

    @Test func lifecycleAndStorageFormatErrors() throws {
        let sink = WAVWriter()
        let packet = SampleBufferFixtures.makePCMBuffer(channels: 2, frames: 8, interleaved: false) { _, _ in 0 }
        #expect(throws: WAVWriterError.fileNotOpen) { try sink.writeBuffer(packet) }
        #expect(throws: WAVWriterError.fileNotOpen) { try sink.finalize() }
        let target = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")
        defer { try? FileManager.default.removeItem(at: target) }
        try sink.createFile(at: target, sampleRate: 48_000, channels: 2)
        let integerFormat = try #require(AVAudioFormat(commonFormat: .pcmFormatInt16,
            sampleRate: 48_000, channels: 2, interleaved: true))
        let integer = try #require(AVAudioPCMBuffer(pcmFormat: integerFormat, frameCapacity: 8))
        integer.frameLength = 8
        #expect(throws: WAVWriterError.invalidFormat) { try sink.writeBuffer(integer) }
        try sink.finalize()
        #expect(try AVAudioFile(forReading: target).length == 0)
    }
}
