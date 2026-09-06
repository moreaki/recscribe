//
//  FLACEncoderTests.swift
//  RecScribeTests
//
//  BL-013: drive FLACEncoder through the AudioFileEncoder protocol and assert
//  the produced .flac is a real FLAC file with an exact frame count and audio
//  that round-trips losslessly on the encoder's 24-bit grid.
//
//  Two things here differ deliberately from M4AEncoderTests:
//
//  1. Every readback test must write ≥ FLACEncoder.minimumEncodableFrames
//     (4608). FLAC emits nothing below one packet, so a test built on the
//     256-frame buffer used elsewhere would fail confusingly.
//
//  2. Losslessness is asserted against an *exactly computed* expected value
//     (`quantize24`), not a tolerance. AAC forces tolerance; FLAC does not, and
//     an exact model catches channel swaps and off-by-ones that "the file
//     decodes" never would. There is deliberately NO byte-exact golden file:
//     Apple's FLAC encoder carries no cross-OS/arch stability contract, so a
//     point-release retune would break CI with a failure that looks alarming
//     and means nothing. See BL-013 non-goals — do not re-litigate.
//

import Testing
import Foundation
import AVFoundation
@testable import RecScribe

@MainActor
struct FLACEncoderTests {

    private let sampleRate: Double = 48_000
    private let channels = 2
    private let bufferCount = 48
    private let framesPerBuffer = 1_024   // 48 × 1024 = 49,152 frames ≈ 1.024 s

    private var totalFrames: Int { bufferCount * framesPerBuffer }

    private func tempURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("flac-test-\(UUID().uuidString).flac")
    }

    /// The encoder's exact quantizer, verified against measured output in the
    /// BL-013 spike with zero mismatches over 4608 frames.
    private func quantize24(_ x: Float) -> Float {
        Float(min(max((x * 8_388_608).rounded(), -8_388_608), 8_388_607)) / 8_388_608
    }

    /// Deliberately **asymmetric** across channels. An antisymmetric fixture
    /// (ch1 = -ch0) cannot detect a channel swap — `data[0] == -data[1]` holds
    /// just as well when the channels are exchanged — so the scaling factor is
    /// what makes `channelsAreNotSwapped` able to fail.
    private func sample(_ index: Int, _ frame: Int, channel: Int) -> Float {
        let n = index * framesPerBuffer + frame
        let v = Float(sin(Double(n) * 0.02)) * 0.4
        return channel == 0 ? v : -v * 0.5
    }

    private func buffer(_ index: Int) -> AVAudioPCMBuffer {
        SampleBufferFixtures.makePCMBuffer(
            channels: channels, frames: framesPerBuffer,
            sampleRate: sampleRate, interleaved: false
        ) { ch, frame in self.sample(index, frame, channel: ch) }
    }

    private func encodeStream(to url: URL) throws {
        let encoder: any AudioFileEncoder = FLACEncoder()
        try encoder.createFile(at: url, sampleRate: sampleRate, channels: channels)
        for i in 0..<bufferCount {
            try encoder.writeBuffer(buffer(i))
        }
        try encoder.finalize()
    }

    // MARK: - Format validity

    @Test("Encodes a synthetic stream to a real .flac file")
    func producesValidFLAC() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }

        try encodeStream(to: url)

        // `fLaC` magic — the thing that is absent from a short-take stub.
        #expect(Array(try Data(contentsOf: url).prefix(4)) == Array("fLaC".utf8))

        let file = try AVAudioFile(forReading: url)
        #expect(file.fileFormat.channelCount == AVAudioChannelCount(channels))
        #expect(file.fileFormat.sampleRate == sampleRate)
    }

    @Test("Frame count is exact — FLAC adds no priming or padding")
    func frameCountIsExact() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }

        try encodeStream(to: url)

        let file = try AVAudioFile(forReading: url)
        #expect(file.length == AVAudioFramePosition(totalFrames))
    }

    @Test("Compresses — the file is smaller than the equivalent 24-bit PCM")
    func compressesRelativeToPCM() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }

        try encodeStream(to: url)

        let size = try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int ?? 0
        #expect(size > 0)
        // Measured ~0.15x on this signal, so 0.75x still leaves ~5x headroom
        // while actually noticing if compression stopped happening. The loose
        // "smaller than raw 24-bit" bound would pass even on uncompressed 16-bit.
        #expect(size < totalFrames * channels * 3 * 3 / 4)
    }

    // MARK: - Losslessness

    @Test("Round-trips losslessly on the encoder's 24-bit grid")
    func roundTripIsLosslessAt24Bit() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }

        try encodeStream(to: url)

        let file = try AVAudioFile(forReading: url)
        let read = AVAudioPCMBuffer(
            pcmFormat: file.processingFormat,
            frameCapacity: AVAudioFrameCount(file.length)
        )
        let readback = try #require(read)
        try file.read(into: readback)
        // Without this the loops below can pass vacuously: `read(into:)` fills
        // *up to* capacity, so a future OS returning one packet per call would
        // silently shrink coverage instead of failing.
        #expect(readback.frameLength == AVAudioFrameCount(totalFrames))
        let data = try #require(readback.floatChannelData)

        // Report once, not 98,304 times.
        var mismatches = 0
        for frame in 0..<Int(readback.frameLength) {
            let index = frame / framesPerBuffer
            let offset = frame % framesPerBuffer
            for ch in 0..<channels
            where data[ch][frame] != quantize24(sample(index, offset, channel: ch)) {
                mismatches += 1
            }
        }
        #expect(mismatches == 0)
    }

    @Test("Over-unity samples clip rather than wrapping")
    func clipsOverUnitySamples() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let frames = Int(FLACEncoder.minimumEncodableFrames)
        let probes: [Float] = [1.5, -2.0, 1.0, -1.0, 0.5]

        let encoder: any AudioFileEncoder = FLACEncoder()
        try encoder.createFile(at: url, sampleRate: sampleRate, channels: channels)
        try encoder.writeBuffer(
            SampleBufferFixtures.makePCMBuffer(
                channels: channels, frames: frames, sampleRate: sampleRate, interleaved: false
            ) { _, frame in probes[frame % probes.count] }
        )
        try encoder.finalize()

        let file = try AVAudioFile(forReading: url)
        let read = try #require(AVAudioPCMBuffer(
            pcmFormat: file.processingFormat,
            frameCapacity: AVAudioFrameCount(file.length)
        ))
        try file.read(into: read)
        #expect(read.frameLength == FLACEncoder.minimumEncodableFrames)
        let data = try #require(read.floatChannelData)

        for frame in 0..<min(probes.count * 4, Int(read.frameLength)) {
            #expect(data[0][frame] == quantize24(probes[frame % probes.count]))
        }
    }

    @Test("Channels are not swapped")
    func channelsAreNotSwapped() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }

        try encodeStream(to: url)

        let file = try AVAudioFile(forReading: url)
        let read = try #require(AVAudioPCMBuffer(
            pcmFormat: file.processingFormat,
            frameCapacity: AVAudioFrameCount(file.length)
        ))
        try file.read(into: read)
        #expect(read.frameLength == AVAudioFrameCount(totalFrames))
        let data = try #require(read.floatChannelData)

        // ch1 is -0.5x ch0, so exchanging the channels breaks the relationship.
        var wrong = 0
        for frame in 0..<Int(read.frameLength)
        where data[1][frame] != quantize24(-0.5 * sample(frame / framesPerBuffer,
                                                         frame % framesPerBuffer,
                                                         channel: 0)) {
            wrong += 1
        }
        #expect(wrong == 0)
    }

    // MARK: - Safety guards

    /// The highest-value test here. A mismatched buffer is not merely wrong —
    /// a sample-rate mismatch writes pitch-shifted audio with NO error, and an
    /// Int16 non-interleaved buffer kills the process outright via an
    /// uncatchable abort. Both must be rejected before reaching AVAudioFile.
    @Test("A sample-rate mismatch throws instead of silently corrupting")
    func sampleRateMismatchThrows() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let encoder: any AudioFileEncoder = FLACEncoder()
        try encoder.createFile(at: url, sampleRate: sampleRate, channels: channels)

        let wrongRate = SampleBufferFixtures.makePCMBuffer(
            channels: channels, frames: framesPerBuffer,
            sampleRate: 44_100, interleaved: false
        ) { _, _ in 0.25 }

        #expect(throws: FLACEncoderError.formatMismatch) {
            try encoder.writeBuffer(wrongRate)
        }
    }

    @Test("A channel-count mismatch throws")
    func channelCountMismatchThrows() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let encoder: any AudioFileEncoder = FLACEncoder()
        try encoder.createFile(at: url, sampleRate: sampleRate, channels: channels)

        let mono = SampleBufferFixtures.makePCMBuffer(
            channels: 1, frames: framesPerBuffer,
            sampleRate: sampleRate, interleaved: false
        ) { _, _ in 0.25 }

        #expect(throws: FLACEncoderError.formatMismatch) {
            try encoder.writeBuffer(mono)
        }
    }

    @Test("An interleaved buffer throws rather than reaching the encoder")
    func interleavedBufferThrows() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let encoder: any AudioFileEncoder = FLACEncoder()
        try encoder.createFile(at: url, sampleRate: sampleRate, channels: channels)

        let interleaved = SampleBufferFixtures.makePCMBuffer(
            channels: channels, frames: framesPerBuffer,
            sampleRate: sampleRate, interleaved: true
        ) { _, _ in 0.25 }

        #expect(throws: FLACEncoderError.formatMismatch) {
            try encoder.writeBuffer(interleaved)
        }
    }

    /// The dimension the *uncatchable abort* actually hangs off. An Int16
    /// non-interleaved buffer overruns ExtAudioFile's input and kills the
    /// process — no Swift error, no NSException, nothing to catch. Without this
    /// test, weakening the guard to compare only sampleRate/channels/interleaved
    /// (all of which the other guard tests pin) would keep the suite green while
    /// fully reopening the crash. If the guard is ever removed, this test aborts
    /// the test host rather than failing cleanly — that is the intended and only
    /// possible signal.
    @Test("An Int16 buffer throws rather than aborting the process")
    func int16BufferThrows() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let encoder: any AudioFileEncoder = FLACEncoder()
        try encoder.createFile(at: url, sampleRate: sampleRate, channels: channels)

        let int16Format = try #require(AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: sampleRate,
            channels: AVAudioChannelCount(channels),
            interleaved: false
        ))
        let int16Buffer = try #require(AVAudioPCMBuffer(
            pcmFormat: int16Format,
            frameCapacity: AVAudioFrameCount(framesPerBuffer)
        ))
        int16Buffer.frameLength = AVAudioFrameCount(framesPerBuffer)

        #expect(throws: FLACEncoderError.formatMismatch) {
            try encoder.writeBuffer(int16Buffer)
        }
    }

    @Test("An unwritable destination throws .setupFailed")
    func unwritableDestinationThrows() {
        let encoder: any AudioFileEncoder = FLACEncoder()
        // Keep the intentionally nonexistent destination inside test storage.
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("nonexistent-\(UUID().uuidString)/out.flac")

        #expect(throws: FLACEncoderError.setupFailed) {
            try encoder.createFile(at: url, sampleRate: sampleRate, channels: channels)
        }
    }

    // MARK: - Short takes

    /// The silent-data-loss guard. `AudioRecorder` swallows write errors on the
    /// hot path (`try? writeBuffer`), so if the format guard rejected *every*
    /// buffer, padding would happily produce a 96ms silent file and report
    /// success — a five-minute recording lost with no error anywhere. Failing
    /// loudly is the whole point.
    @Test("A recording that captured nothing fails instead of padding to silence")
    func zeroFramesFailsRatherThanPadding() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let encoder: any AudioFileEncoder = FLACEncoder()
        try encoder.createFile(at: url, sampleRate: sampleRate, channels: channels)

        // Every buffer rejected — exactly what a capture-format drift produces.
        let mono = SampleBufferFixtures.makePCMBuffer(
            channels: 1, frames: framesPerBuffer,
            sampleRate: sampleRate, interleaved: false
        ) { _, _ in 0.25 }
        for _ in 0..<8 {
            #expect(throws: FLACEncoderError.formatMismatch) {
                try encoder.writeBuffer(mono)
            }
        }

        #expect(throws: FLACEncoderError.noAudioWritten) {
            try encoder.finalize()
        }
    }

    /// One bad buffer must not poison the rest of the recording.
    @Test("The encoder survives a rejected buffer and keeps an exact frame count")
    func recoversAfterRejectedBuffer() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let encoder: any AudioFileEncoder = FLACEncoder()
        try encoder.createFile(at: url, sampleRate: sampleRate, channels: channels)

        try encoder.writeBuffer(buffer(0))
        #expect(throws: FLACEncoderError.formatMismatch) {
            try encoder.writeBuffer(SampleBufferFixtures.makePCMBuffer(
                channels: 1, frames: framesPerBuffer,
                sampleRate: sampleRate, interleaved: false
            ) { _, _ in 0.25 })
        }
        for i in 1..<bufferCount {
            try encoder.writeBuffer(buffer(i))
        }
        try encoder.finalize()

        // The rejected buffer contributed nothing; everything else survived.
        let file = try AVAudioFile(forReading: url)
        #expect(file.length == AVAudioFramePosition(totalFrames))
    }

    /// Without padding, a sub-packet take produces a 42-byte stub with no `fLaC`
    /// magic that nothing can open. WAV and M4A both handle this fine, so it
    /// would be a FLAC-only regression.
    @Test("A take shorter than one FLAC packet still produces a readable file")
    func shortTakeProducesReadableFile() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let encoder: any AudioFileEncoder = FLACEncoder()
        try encoder.createFile(at: url, sampleRate: sampleRate, channels: channels)
        try encoder.writeBuffer(buffer(0))     // 1024 frames — well under 4608
        try encoder.finalize()

        #expect(Array(try Data(contentsOf: url).prefix(4)) == Array("fLaC".utf8))

        let file = try AVAudioFile(forReading: url)
        // The literal, not the constant: 4608 is an empirically discovered FLAC
        // packet boundary, not a free parameter. Asserting the constant against
        // itself would let a change to it pass silently.
        #expect(file.length == 4_608)
        #expect(FLACEncoder.minimumEncodableFrames == 4_608)
    }

    // MARK: - Lifecycle

    @Test("finalize before createFile throws")
    func finalizeBeforeCreateThrows() {
        let encoder: any AudioFileEncoder = FLACEncoder()
        #expect(throws: FLACEncoderError.notOpen) {
            try encoder.finalize()
        }
    }

    @Test("writeBuffer after finalize throws")
    func writeAfterFinalizeThrows() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let encoder: any AudioFileEncoder = FLACEncoder()
        try encoder.createFile(at: url, sampleRate: sampleRate, channels: channels)
        try encoder.writeBuffer(buffer(0))
        try encoder.finalize()

        #expect(throws: FLACEncoderError.notOpen) {
            try encoder.writeBuffer(buffer(1))
        }
    }

    // MARK: - Wiring

    @Test("FLAC is selectable and builds a FLACEncoder")
    func formatIsWiredUp() throws {
        #expect(AudioFormat.available.contains(.flac))
        #expect(try AudioFormat.flac.makeEncoder() is FLACEncoder)
    }
}
