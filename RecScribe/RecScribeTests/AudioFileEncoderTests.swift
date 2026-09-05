//
//  AudioFileEncoderTests.swift
//  RecScribeTests
//
//  BL-011: exercises the AudioFileEncoder protocol contract in isolation
//  (independent of AudioRecorder), driving the WAV conformer through the
//  protocol type. The deterministic byte assertions are WAV/lossless-only; the
//  decodability assertion is the format-agnostic hook that lossy encoders
//  (M4A/MP3 — BL-012/014) will reuse, since they can't be byte-compared.
//

import Testing
import Foundation
import AVFoundation
@testable import RecScribe

@MainActor
struct AudioFileEncoderTests {

    // MARK: - Helpers (local copies; small + low-risk to duplicate)

    private func tempURL(_ ext: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("encoder-test-\(UUID().uuidString).\(ext)")
    }

    private func makeFloatBuffer(
        channels: AVAudioChannelCount,
        frames: AVAudioFrameCount,
        fill: (_ channel: Int, _ frame: Int) -> Float
    ) -> AVAudioPCMBuffer {
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: 48000,
            channels: channels, interleaved: false
        )!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        let data = buffer.floatChannelData!
        for c in 0..<Int(channels) {
            for f in 0..<Int(frames) {
                data[c][f] = fill(c, f)
            }
        }
        return buffer
    }

    private func readInt16LE(_ b: [UInt8], _ o: Int) -> Int16 {
        Int16(bitPattern: UInt16(b[o]) | (UInt16(b[o + 1]) << 8))
    }

    // MARK: - WAV conformance through the protocol

    @Test("Protocol path: a known ramp encodes to the expected Int16 LE bytes")
    func wavRampThroughProtocol() throws {
        let url = tempURL("wav")
        defer { try? FileManager.default.removeItem(at: url) }

        let ramp: [Float] = [-1.0, -0.75, -0.5, -0.25, 0, 0.25, 0.5, 0.75]
        let encoder: any AudioFileEncoder = WAVWriter()
        try encoder.createFile(at: url, sampleRate: 48000, channels: 1)
        try encoder.writeBuffer(makeFloatBuffer(channels: 1, frames: AVAudioFrameCount(ramp.count)) { _, f in ramp[f] })
        try encoder.finalize()

        let expected = ramp.map { Int16(max(-1.0, min(1.0, $0)) * 32767.0) }
        let bytes = [UInt8](try Data(contentsOf: url))
        let samples = (0..<ramp.count).map { readInt16LE(bytes, 44 + $0 * 2) }
        #expect(samples == expected)
    }

    @Test("Encoder output is decodable by AVAudioFile with the expected format and length")
    func wavOutputIsDecodable() throws {
        let url = tempURL("wav")
        defer { try? FileManager.default.removeItem(at: url) }

        let frames: AVAudioFrameCount = 256
        let encoder: any AudioFileEncoder = WAVWriter()
        try encoder.createFile(at: url, sampleRate: 48000, channels: 2)
        try encoder.writeBuffer(makeFloatBuffer(channels: 2, frames: frames) { c, f in
            Float((f + c) % 50) / 100.0
        })
        try encoder.finalize()

        let file = try AVAudioFile(forReading: url)
        #expect(file.fileFormat.channelCount == 2)
        #expect(file.fileFormat.sampleRate == 48000)
        #expect(file.length == AVAudioFramePosition(frames))   // exact for lossless WAV
    }

    // MARK: - Error paths through the protocol

    @Test("writeBuffer before createFile throws (protocol contract)")
    func writeBeforeCreateThrows() {
        let encoder: any AudioFileEncoder = WAVWriter()
        let buffer = makeFloatBuffer(channels: 2, frames: 10) { _, _ in 0 }
        #expect(throws: WAVWriterError.fileNotOpen) {
            try encoder.writeBuffer(buffer)
        }
    }

    @Test("finalize before createFile throws (protocol contract)")
    func finalizeBeforeCreateThrows() {
        let encoder: any AudioFileEncoder = WAVWriter()
        #expect(throws: WAVWriterError.fileNotOpen) {
            try encoder.finalize()
        }
    }
}
