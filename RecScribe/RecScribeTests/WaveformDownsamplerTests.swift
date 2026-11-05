import AVFoundation
import Testing
@testable import RecScribe

struct WaveformDownsamplerTests {
    @Test(arguments: [1, 10, 50, 4_800], [1, 2])
    func samplePositionsAndChannelMeanAreStable(frames: Int, channels: Int) {
        for interleaved in [false, true] {
        let buffer = SampleBufferFixtures.makePCMBuffer(channels: channels, frames: frames, interleaved: interleaved) {
            channel, frame in Float(frame) + Float(channel) * 4
        }
        let actual = WaveformDownsampler.downsample(buffer)
        let interval = max(1, frames / 200)
        let expected = stride(from: 0, to: frames, by: interval).map { Float($0) + (channels == 2 ? 2 : 0) }
        #expect(actual == expected)
    }
        }
    @Test func oppositePolarityCancelsInTheDisplayMean() {
        let buffer = SampleBufferFixtures.makePCMBuffer(channels: 2, frames: 11, interleaved: false) { c, _ in c == 0 ? -0.5 : 0.5 }
        #expect(WaveformDownsampler.downsample(buffer) == [Float](repeating: 0, count: 11))
        #expect(WaveformDownsampler.downsample(buffer, targetSamples: 0).isEmpty)
    }
}
