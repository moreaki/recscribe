//
//  EncoderFormatGuardTests.swift
//  RecScribeTests
//
//  BL-112: an encoder is told its input format once, in `createFile`, and then
//  stamps a header from it. A later buffer that disagrees is not a bad frame —
//  it is silent corruption (WAV) and must be refused immediately.
//

import Testing
import Foundation
import AVFoundation
@testable import RecScribe

struct EncoderFormatGuardTests {

    private func tempURL(_ ext: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("guard-\(UUID().uuidString).\(ext)")
    }

    private func buffer(sampleRate: Double, channels: Int, frames: Int = 256) -> AVAudioPCMBuffer {
        SampleBufferFixtures.makePCMBuffer(
            channels: channels,
            frames: frames,
            sampleRate: sampleRate,
            interleaved: false
        ) { channel, frame in
            // Asymmetric across channels so a swap or a mono/stereo confusion
            // can't accidentally satisfy an assertion.
            Float(frame % 32) / 64.0 + Float(channel) * 0.25
        }
    }

    // MARK: - WAV

    @Test("WAV refuses a buffer whose sample rate contradicts its header")
    func wavRejectsWrongSampleRate() throws {
        let url = tempURL("wav")
        defer { try? FileManager.default.removeItem(at: url) }

        let writer = WAVWriter()
        try writer.createFile(at: url, sampleRate: 48_000, channels: 2)

        // Header says 48 kHz; this plays ~8.8% fast if written.
        #expect(throws: WAVWriterError.formatMismatch) {
            try writer.writeBuffer(self.buffer(sampleRate: 44_100, channels: 2))
        }
    }

    @Test("WAV refuses a mono buffer in a stereo-declared file")
    func wavRejectsWrongChannelCount() throws {
        let url = tempURL("wav")
        defer { try? FileManager.default.removeItem(at: url) }

        let writer = WAVWriter()
        try writer.createFile(at: url, sampleRate: 48_000, channels: 2)

        // The interleave loop uses the buffer's channel count while the header
        // declares two: written, this reads back as L/R pairs — half speed, an
        // octave down, with no error anywhere.
        #expect(throws: WAVWriterError.formatMismatch) {
            try writer.writeBuffer(self.buffer(sampleRate: 48_000, channels: 1))
        }
    }

    @Test("WAV still accepts a buffer that matches what it was told")
    func wavAcceptsMatchingFormat() throws {
        let url = tempURL("wav")
        defer { try? FileManager.default.removeItem(at: url) }

        let writer = WAVWriter()
        try writer.createFile(at: url, sampleRate: 48_000, channels: 2)
        try writer.writeBuffer(buffer(sampleRate: 48_000, channels: 2))
        try writer.finalize()

        let size = try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int
        // 44-byte header + 256 frames x 2ch x 2 bytes.
        #expect(size == 44 + 256 * 2 * 2)
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
