import AVFoundation
import Testing
@testable import RecScribe

struct AudioFormatNormalizerTests {
    private func signal(first: Int, count: Int, rate: Double, channels: Int) -> AVAudioPCMBuffer {
        SampleBufferFixtures.makePCMBuffer(channels: channels, frames: count, sampleRate: rate, interleaved: false) { _, frame in
            Float(sin(Double(first + frame) * 2 * .pi * 440 / rate))
        }
    }
    @Test func canonicalInputIdentityIsPreserved() {
        let input = signal(first: 0, count: 512, rate: 48_000, channels: 2)
        #expect(AudioFormatNormalizer().normalize(input) === input)
    }
    @Test(arguments: [16_000.0, 44_100.0])
    func resamplingEmitsReportedStereoFramesWithIdenticalMonoChannels(rate: Double) throws {
        let normalizer = AudioFormatNormalizer()
        for block in 0..<8 {
            let converted = try #require(normalizer.normalize(signal(first: block * 1024, count: 1024, rate: rate, channels: 1)))
            #expect(converted.format == AudioFormatNormalizer.canonical)
            #expect(converted.frameLength > 0 && converted.frameLength <= converted.frameCapacity)
            let left = UnsafeBufferPointer(start: converted.floatChannelData![0], count: Int(converted.frameLength))
            let right = UnsafeBufferPointer(start: converted.floatChannelData![1], count: Int(converted.frameLength))
            #expect(Array(left) == Array(right))
            #expect(right.contains { abs($0) > 0.01 })
        }
    }
    @Test func streamingHistoryProtectsSeamsAndTheControlDetectsAReset() throws {
        let retained = AudioFormatNormalizer()
        func collect(reset: Bool) throws -> [Float] {
            var result: [Float] = []
            for block in 0..<12 {
                let normalizer = reset ? AudioFormatNormalizer() : retained
                let output = try #require(normalizer.normalize(signal(first: block * 1024, count: 1024, rate: 44_100, channels: 1)))
                result += UnsafeBufferPointer(start: output.floatChannelData![0], count: Int(output.frameLength))
            }
            return result
        }
        func largestStep(_ values: [Float]) -> Float { zip(values, values.dropFirst()).map { abs($0 - $1) }.max() ?? 0 }
        let continuous = try collect(reset: false)
        #expect(continuous.count > 10_000)
        #expect(largestStep(continuous) < 0.2)
        #expect(try largestStep(collect(reset: true)) > 0.2)
    }
    @Test func aDifferentSourceRateStartsANewConversionSession() throws {
        let normalizer = AudioFormatNormalizer()
        for rate in [44_100.0, 16_000.0] {
            let output = try #require(normalizer.normalize(signal(first: 0, count: 512, rate: rate, channels: 1)))
            #expect(output.format.sampleRate == 48_000 && output.frameLength > 0)
        }
    }
}
