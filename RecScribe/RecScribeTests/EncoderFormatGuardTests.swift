import AVFoundation
import Foundation
import Testing
@testable import RecScribe

struct EncoderFormatGuardTests {
    private func buffer(sampleRate: Double, channels: Int) -> AVAudioPCMBuffer {
        SampleBufferFixtures.makePCMBuffer(channels: channels, frames: 256,
            sampleRate: sampleRate, interleaved: false) { channel, _ in channel == 0 ? 0.25 : -0.5 }
    }

    @Test(arguments: [44_100.0, 48_000.0], [1, 2])
    func rejectsHeaderDisagreementWithoutAppending(rate: Double, channels: Int) throws {
        let target = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")
        defer { try? FileManager.default.removeItem(at: target) }
        let sink = WAVWriter()
        try sink.createFile(at: target, sampleRate: 48_000, channels: 2)
        let packet = buffer(sampleRate: rate, channels: channels)
        let matches = rate == 48_000 && channels == 2
        if matches { try sink.writeBuffer(packet) }
        else { #expect(throws: WAVWriterError.formatMismatch) { try sink.writeBuffer(packet) } }
        try sink.finalize()
        #expect(try AVAudioFile(forReading: target).length == (matches ? 256 : 0))
    }

    @Test("SessionWAVWriter enforces WAV sample rate and channel count guards")
    func sessionWAVWriterRejectsMismatchedFormat() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("session-guard-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let url = dir.appendingPathComponent("take.wav")
        let writer = SessionWAVWriter()
        try writer.createFile(at: url, sampleRate: 48_000, channels: 2)

        #expect(throws: WAVWriterError.formatMismatch) {
            try writer.writeBuffer(self.buffer(sampleRate: 44_100, channels: 2))
        }
    }
}
