import AVFoundation
import Testing
@testable import RecScribe

struct AudioSampleConverterTests {
    @Test(arguments: [1, 2, 4], [1, 7, 64])
    func planarAndInterleavedFloatSamplesKeepTheirCoordinates(channels: Int, frames: Int) throws {
        for interleaved in [false, true] {
        let source = SampleBufferFixtures.makePCMBuffer(channels: channels, frames: frames, interleaved: interleaved) {
            channel, frame in Float(channel * 100 + frame) / 100
        }
        let packet = SampleBufferFixtures.makeSampleBuffer(from: source)
        let decoded = try #require(AudioSampleConverter.makePCMBuffer(from: packet))
        #expect(decoded.frameLength == frames)
        #expect(decoded.format.channelCount == channels)
        #expect(!decoded.format.isInterleaved)
        for channel in 0..<channels {
            let expected = (0..<frames).map { Float(channel * 100 + $0) / 100 }
            let actual = Array(UnsafeBufferPointer(start: decoded.floatChannelData![channel], count: frames))
            #expect(actual == expected)
        }
    }
        }
    @Test func emptyPacketDoesNotCreatePCM() {
        let empty = SampleBufferFixtures.interleaved(frames: 0) { _, _ in 0 }
        #expect(AudioSampleConverter.makePCMBuffer(from: empty) == nil)
    }
}
