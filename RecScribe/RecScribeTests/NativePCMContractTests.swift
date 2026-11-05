import AVFoundation
import CoreMedia
import Foundation
import Testing
@testable import RecScribe

/// Additional boundaries of the replacement PCM implementations. Existing
/// recording, frozen-reference and fixture tests remain unchanged.
struct NativePCMContractTests {
    private func sample(bytes: [UInt8], frames: Int, bits: UInt32, container: UInt32,
                        flags: AudioFormatFlags) throws -> CMSampleBuffer {
        var basic = AudioStreamBasicDescription(mSampleRate: 48_000, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: flags, mBytesPerPacket: container, mFramesPerPacket: 1,
            mBytesPerFrame: container, mChannelsPerFrame: 1, mBitsPerChannel: bits, mReserved: 0)
        var format: CMAudioFormatDescription?
        #expect(CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault, asbd: &basic,
            layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil, extensions: nil,
            formatDescriptionOut: &format) == noErr)
        var block: CMBlockBuffer?
        #expect(CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil,
            blockLength: bytes.count, blockAllocator: kCFAllocatorDefault, customBlockSource: nil,
            offsetToData: 0, dataLength: bytes.count, flags: 0, blockBufferOut: &block) == noErr)
        let owned = try #require(block)
        #expect(bytes.withUnsafeBytes {
            CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: owned,
                                           offsetIntoDestination: 0, dataLength: bytes.count)
        } == noErr)
        var output: CMSampleBuffer?
        #expect(CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: owned,
            formatDescription: try #require(format), sampleCount: frames, sampleTimingEntryCount: 0,
            sampleTimingArray: nil, sampleSizeEntryCount: 0, sampleSizeArray: nil,
            sampleBufferOut: &output) == noErr)
        return try #require(output)
    }

    @Test func bigEndianPCM16AndFloat32DecodeByValue() throws {
        let integer = try sample(bytes: [0x40, 0x00, 0xc0, 0x00], frames: 2, bits: 16, container: 2,
                                 flags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsBigEndian | kAudioFormatFlagIsPacked)
        let floats = try sample(bytes: [0x3f, 0x00, 0x00, 0x00, 0xbf, 0x00, 0x00, 0x00], frames: 2,
                                bits: 32, container: 4,
                                flags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsBigEndian | kAudioFormatFlagIsPacked)
        for input in [integer, floats] {
            let decoded = try #require(AudioSampleConverter.makePCMBuffer(from: input))
            #expect(decoded.frameLength == 2)
            #expect(decoded.floatChannelData?[0][0] == 0.5)
            #expect(decoded.floatChannelData?[0][1] == -0.5)
        }
    }

    @Test func lowAlignedPCM24SignExtendsSignificantBits() throws {
        let input = try sample(bytes: [0x00, 0x00, 0x40, 0xff, 0x00, 0x00, 0xc0, 0x00], frames: 2,
                               bits: 24, container: 4, flags: kAudioFormatFlagIsSignedInteger)
        let decoded = try #require(AudioSampleConverter.makePCMBuffer(from: input))
        #expect(decoded.floatChannelData?[0][0] == 0.5)
        #expect(decoded.floatChannelData?[0][1] == -0.5)
    }

    @Test func truncatedSamplePayloadIsRefused() throws {
        let input = try sample(bytes: [0x00, 0x40], frames: 4, bits: 16, container: 2,
                               flags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked)
        #expect(AudioSampleConverter.makePCMBuffer(from: input) == nil)
    }

    @Test func finalizationDoesNotReopenAReplacedPath() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let original = root.appendingPathComponent("take.wav")
        let moved = root.appendingPathComponent("moved.wav")
        let writer = WAVWriter()
        try writer.createFile(at: original, sampleRate: 48_000, channels: 2)
        let pcm = SampleBufferFixtures.makePCMBuffer(channels: 2, frames: 4, interleaved: false) { _, _ in 0.25 }
        try writer.writeBuffer(pcm)
        try FileManager.default.moveItem(at: original, to: moved)
        let unrelated = Data("unrelated file at the previous recording path".utf8)
        try unrelated.write(to: original)
        try writer.finalize()
        #expect(try Data(contentsOf: original) == unrelated)
        #expect(try PCM16WAV.read(moved).frames == 4)
    }

    @Test func interleavedFloatFramesRetainChannelOrderAndSlice() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("pcm-\(UUID()).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        let buffer = SampleBufferFixtures.makePCMBuffer(channels: 2, frames: 6, interleaved: true) { channel, frame in
            Float(frame + channel) / 8
        }
        let writer = WAVWriter()
        try writer.createFile(at: url, sampleRate: 48_000, channels: 2)
        try writer.writeFrames(buffer, offset: 2, count: 2)
        try writer.finalize()
        let bytes = Array(try Data(contentsOf: url).dropFirst(44))
        let samples = stride(from: 0, to: bytes.count, by: 2).map {
            Int16(bitPattern: UInt16(bytes[$0]) | UInt16(bytes[$0 + 1]) << 8)
        }
        #expect(samples == [8191, 12287, 12287, 16383])
    }
}
