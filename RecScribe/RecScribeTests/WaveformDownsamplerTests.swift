//
//  WaveformDownsamplerTests.swift
//  RecScribeTests
//
//  BL-007: waveform downsampling, in isolation.
//

import Testing
import Foundation
import AVFoundation
@testable import RecScribe

@MainActor
struct WaveformDownsamplerTests {

    private func buffer(channels: Int, frames: Int, fill: @escaping (Int, Int) -> Float) -> AVAudioPCMBuffer {
        SampleBufferFixtures.makePCMBuffer(channels: channels, frames: frames, interleaved: false, fill: fill)
    }

    @Test("Strides by max(1, frameCount/target) and averages channels")
    func strideAndAverage() {
        // 4800 frames, target 200 → step 24. Both channels = frame index → avg == frame index.
        let buf = buffer(channels: 2, frames: 4800) { _, frame in Float(frame) }
        let samples = WaveformDownsampler.downsample(buf, targetSamples: 200)

        #expect(samples.count == 200)
        #expect(samples[0] == 0)
        #expect(samples[1] == 24)
        #expect(samples[199] == 199 * 24)
    }

    @Test("Channel averaging collapses to mono")
    func channelAveraging() {
        // ch0 = +0.5, ch1 = -0.5 → every averaged sample is 0.
        let buf = buffer(channels: 2, frames: 10) { ch, _ in ch == 0 ? 0.5 : -0.5 }
        let samples = WaveformDownsampler.downsample(buf, targetSamples: 200)

        #expect(samples.count == 10)            // fewer frames than target → step 1
        #expect(samples.allSatisfy { $0 == 0 })
    }

    @Test("Fewer frames than target yields one value per frame (step 1)")
    func fewerFramesThanTarget() {
        let buf = buffer(channels: 1, frames: 50) { _, frame in Float(frame) }
        let samples = WaveformDownsampler.downsample(buf, targetSamples: 200)

        #expect(samples.count == 50)
        #expect(samples[0] == 0)
        #expect(samples[49] == 49)
    }

    @Test("Single-frame buffer yields a single value")
    func singleFrame() {
        let buf = buffer(channels: 1, frames: 1) { _, _ in 0.42 }
        let samples = WaveformDownsampler.downsample(buf, targetSamples: 200)

        #expect(samples == [0.42])
    }
}
