//
//  WAVWriterTests.swift
//  RecScribeTests
//
//  Data-integrity tests for WAVWriter (BL-004): header layout, finalize,
//  byte accumulation, Int16 conversion/clipping, and error paths.
//

import Testing
import Foundation
import AVFoundation
@testable import RecScribe

@MainActor
struct WAVWriterTests {

    // MARK: - Helpers

    private func tempURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("wavwriter-test-\(UUID().uuidString).wav")
    }

    /// Build a non-interleaved Float32 PCM buffer, filling each sample via `fill`.
    private func makeFloatBuffer(
        channels: AVAudioChannelCount,
        frames: AVAudioFrameCount,
        fill: (_ channel: Int, _ frame: Int) -> Float
    ) -> AVAudioPCMBuffer {
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 48000,
            channels: channels,
            interleaved: false
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

    private func readUInt32LE(_ b: [UInt8], _ o: Int) -> UInt32 {
        UInt32(b[o]) | (UInt32(b[o + 1]) << 8) | (UInt32(b[o + 2]) << 16) | (UInt32(b[o + 3]) << 24)
    }

    private func readUInt16LE(_ b: [UInt8], _ o: Int) -> UInt16 {
        UInt16(b[o]) | (UInt16(b[o + 1]) << 8)
    }

    private func readInt16LE(_ b: [UInt8], _ o: Int) -> Int16 {
        Int16(bitPattern: readUInt16LE(b, o))
    }

    private func ascii(_ b: [UInt8], _ range: Range<Int>) -> String {
        String(bytes: b[range], encoding: .ascii) ?? ""
    }

    // MARK: - Header layout

    @Test("Header layout is exact for stereo 48kHz")
    func headerStereo48k() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let writer = WAVWriter()
        try writer.createFile(at: url, sampleRate: 48000, channels: 2)
        try writer.finalize()

        let bytes = [UInt8](try Data(contentsOf: url))
        #expect(bytes.count == 44)                       // header only, no audio data
        #expect(ascii(bytes, 0..<4) == "RIFF")
        #expect(readUInt32LE(bytes, 4) == 36)            // 36 + dataSize(0)
        #expect(ascii(bytes, 8..<12) == "WAVE")
        #expect(ascii(bytes, 12..<16) == "fmt ")
        #expect(readUInt32LE(bytes, 16) == 16)           // fmt chunk size
        #expect(readUInt16LE(bytes, 20) == 1)            // PCM
        #expect(readUInt16LE(bytes, 22) == 2)            // channels
        #expect(readUInt32LE(bytes, 24) == 48000)        // sample rate
        #expect(readUInt32LE(bytes, 28) == 48000 * 2 * 2) // byte rate
        #expect(readUInt16LE(bytes, 32) == 4)            // block align (channels * 2)
        #expect(readUInt16LE(bytes, 34) == 16)           // bits per sample
        #expect(ascii(bytes, 36..<40) == "data")
        #expect(readUInt32LE(bytes, 40) == 0)            // data size
    }

    @Test("Header layout is exact for mono 44.1kHz")
    func headerMono44k() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let writer = WAVWriter()
        try writer.createFile(at: url, sampleRate: 44100, channels: 1)
        try writer.finalize()

        let bytes = [UInt8](try Data(contentsOf: url))
        #expect(readUInt16LE(bytes, 22) == 1)            // channels
        #expect(readUInt32LE(bytes, 24) == 44100)        // sample rate
        #expect(readUInt32LE(bytes, 28) == 44100 * 1 * 2) // byte rate
        #expect(readUInt16LE(bytes, 32) == 2)            // block align (channels * 2)
        #expect(readUInt16LE(bytes, 34) == 16)           // bits per sample
    }

    // MARK: - Finalize / byte accounting

    @Test("finalize rewrites RIFF and data sizes to match bytes written")
    func finalizeUpdatesSizes() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let writer = WAVWriter()
        try writer.createFile(at: url, sampleRate: 48000, channels: 2)
        try writer.writeBuffer(makeFloatBuffer(channels: 2, frames: 100) { _, _ in 0 })
        try writer.finalize()

        let expectedDataSize: UInt32 = 100 * 2 * 2 // frames * channels * 2 bytes
        let bytes = [UInt8](try Data(contentsOf: url))
        #expect(readUInt32LE(bytes, 40) == expectedDataSize)          // data chunk size
        #expect(readUInt32LE(bytes, 4) == 36 + expectedDataSize)      // RIFF size
        #expect(bytes.count == 44 + Int(expectedDataSize))            // header + data
    }

    @Test("bytesWritten accumulates across multiple writeBuffer calls")
    func multipleWritesAccumulate() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let writer = WAVWriter()
        try writer.createFile(at: url, sampleRate: 48000, channels: 2)
        for _ in 0..<3 {
            try writer.writeBuffer(makeFloatBuffer(channels: 2, frames: 50) { _, _ in 0 })
        }
        try writer.finalize()

        let expected: UInt32 = 3 * 50 * 2 * 2
        let bytes = [UInt8](try Data(contentsOf: url))
        #expect(readUInt32LE(bytes, 40) == expected)
    }

    @Test("Header is periodically rewritten so the file is playable without finalize (crash safety)")
    func periodicHeaderMakesFilePlayableWithoutFinalize() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let writer = WAVWriter()
        try writer.createFile(at: url, sampleRate: 48000, channels: 2)

        // Write exactly enough buffers to trigger one periodic header rewrite.
        let frames = 64
        let count = WAVWriter.headerUpdateInterval
        for _ in 0..<count {
            try writer.writeBuffer(makeFloatBuffer(channels: 2, frames: AVAudioFrameCount(frames)) { _, _ in 0 })
        }

        // Deliberately DO NOT finalize — simulate a crash / force-quit.
        let bytes = [UInt8](try Data(contentsOf: url))
        let dataSize = readUInt32LE(bytes, 40)
        let expected = UInt32(count * frames * 2 * 2)
        #expect(dataSize == expected)   // header reflects written audio
        #expect(dataSize > 0)           // not the initial zero-size (unreadable) header
        #expect(readUInt32LE(bytes, 4) == 36 + expected)
    }

    // MARK: - Int16 conversion / clipping

    @Test("Float→Int16 conversion clamps to the representable range")
    func int16ConversionAndClipping() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let inputs: [Float] = [1.0, -1.0, 2.0, -2.0, 0.0]
        let writer = WAVWriter()
        try writer.createFile(at: url, sampleRate: 48000, channels: 1)
        try writer.writeBuffer(makeFloatBuffer(channels: 1, frames: AVAudioFrameCount(inputs.count)) { _, frame in
            inputs[frame]
        })
        try writer.finalize()

        let bytes = [UInt8](try Data(contentsOf: url))
        let samples = (0..<inputs.count).map { readInt16LE(bytes, 44 + $0 * 2) }
        // +1→32767, -1→-32767, +2 clamped→32767, -2 clamped→-32767, 0→0
        #expect(samples == [32767, -32767, 32767, -32767, 0])
    }

    @Test("Known asymmetry: full-scale negative encodes as -32767, never -32768")
    func fullScaleNegativeAsymmetry() throws {
        // Documents a known bug: WAVWriter uses `value * 32767.0`, so -1.0 maps to
        // -32767 and the minimum Int16 (-32768) is unreachable. Asserting current
        // behavior; a proper symmetric mapping is a separate fix.
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let writer = WAVWriter()
        try writer.createFile(at: url, sampleRate: 48000, channels: 1)
        try writer.writeBuffer(makeFloatBuffer(channels: 1, frames: 1) { _, _ in -1.0 })
        try writer.finalize()

        let bytes = [UInt8](try Data(contentsOf: url))
        #expect(readInt16LE(bytes, 44) == -32767)
        #expect(readInt16LE(bytes, 44) != Int16.min)
    }

    @Test("Golden: a known ramp encodes to the expected Int16 little-endian bytes")
    func goldenRamp() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let ramp: [Float] = [-1.0, -0.75, -0.5, -0.25, 0, 0.25, 0.5, 0.75]
        let writer = WAVWriter()
        try writer.createFile(at: url, sampleRate: 48000, channels: 1)
        try writer.writeBuffer(makeFloatBuffer(channels: 1, frames: AVAudioFrameCount(ramp.count)) { _, frame in
            ramp[frame]
        })
        try writer.finalize()

        let expected = ramp.map { Int16(max(-1.0, min(1.0, $0)) * 32767.0) }
        let bytes = [UInt8](try Data(contentsOf: url))
        let samples = (0..<ramp.count).map { readInt16LE(bytes, 44 + $0 * 2) }
        #expect(samples == expected)
    }

    // MARK: - Error paths

    @Test("writeBuffer before createFile throws .fileNotOpen")
    func writeBeforeCreateThrows() {
        let writer = WAVWriter()
        let buffer = makeFloatBuffer(channels: 2, frames: 10) { _, _ in 0 }
        #expect(throws: WAVWriterError.fileNotOpen) {
            try writer.writeBuffer(buffer)
        }
    }

    @Test("finalize before createFile throws .fileNotOpen")
    func finalizeBeforeCreateThrows() {
        let writer = WAVWriter()
        #expect(throws: WAVWriterError.fileNotOpen) {
            try writer.finalize()
        }
    }

    @Test("writeBuffer with a non-float buffer throws .invalidFormat")
    func nonFloatBufferThrows() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let writer = WAVWriter()
        try writer.createFile(at: url, sampleRate: 48000, channels: 2)

        let intFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: 48000,
            channels: 2,
            interleaved: true
        )!
        let intBuffer = AVAudioPCMBuffer(pcmFormat: intFormat, frameCapacity: 10)!
        intBuffer.frameLength = 10

        #expect(throws: WAVWriterError.invalidFormat) {
            try writer.writeBuffer(intBuffer)
        }
    }
}
