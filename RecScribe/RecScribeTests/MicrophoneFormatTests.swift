import AVFoundation
import Testing
@testable import RecScribe

struct MicrophoneFormatTests {
    @Test(arguments: [1, 2, 4, 6, 8] as [UInt32], [SampleBufferFixtures.IntegerLayout.int16,
        .int32, .int24Packed, .int24AlignedHigh])
    func nativeIntegerPacketsKeepChannelValues(channels: UInt32, layout: SampleBufferFixtures.IntegerLayout) throws {
        let sample = SampleBufferFixtures.integer(frames: 512, channels: channels, layout: layout) {
            channel, frame in Float(channel + 1) / 16 + Float(frame % 8) / 128
        }
        let decoded = try #require(AudioSampleConverter.makePCMBuffer(from: sample))
        #expect(decoded.frameLength == 512 && decoded.format.channelCount == channels)
        let planes = try #require(decoded.floatChannelData)
        for channel in 0..<Int(channels) {
            for frame in 0..<512 {
                let expected = Float(channel + 1) / 16 + Float(frame % 8) / 128
                #expect(abs(planes[channel][frame] - expected) < 0.001)
            }
        }
        let stereo = try #require(AudioFormatNormalizer().normalize(decoded))
        #expect(stereo.format.channelCount == 2)
        let out = try #require(stereo.floatChannelData)
        // Only the first pair belongs in the canonical stream; later channels may be loopback.
        for channel in 0..<2 {
            let sourceChannel = min(channel, Int(channels) - 1)
            let expected = Float(sourceChannel + 1) / 16
            #expect(abs(out[channel][128] - expected) < 0.02)
        }
    }

    @Test func separateIntegerPlanesDecodeWithoutReinterpretationAsFloats() throws {
        let layout = SampleBufferFixtures.IntegerLayout(bitsPerChannel: 16, isInterleaved: false)
        let packet = SampleBufferFixtures.integer(frames: 256, channels: 2, layout: layout) {
            channel, frame in Float(frame % 8) / 16 + Float(channel) / 4
        }
        let decoded = try #require(AudioSampleConverter.makePCMBuffer(from: packet))
        let planes = try #require(decoded.floatChannelData)
        for channel in 0..<2 {
            for frame in 0..<256 {
                #expect(abs(planes[channel][frame] - (Float(frame % 8) / 16 + Float(channel) / 4)) < 0.001)
            }
        }
    }
}
