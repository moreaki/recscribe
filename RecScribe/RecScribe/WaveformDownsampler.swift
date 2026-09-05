//
//  WaveformDownsampler.swift
//  RecScribe
//
//  Downsamples a PCM buffer to a small set of mono amplitude values for the
//  live waveform UI. Extracted from AudioRecorder for unit testing (BL-007).
//  Pure and `nonisolated`.
//

import Foundation
import AVFoundation

enum WaveformDownsampler {

    /// Average the channels and stride down to roughly `targetSamples` values.
    /// When `frameCount < targetSamples` the result has one value per frame.
    nonisolated static func downsample(_ buffer: AVAudioPCMBuffer, targetSamples: Int = 200) -> [Float] {
        guard let floatChannelData = buffer.floatChannelData else { return [] }
        let frameCount = Int(buffer.frameLength)
        let channelCount = Int(buffer.format.channelCount)
        guard frameCount > 0, channelCount > 0 else { return [] }

        let step = max(1, frameCount / targetSamples)
        var samples: [Float] = []
        samples.reserveCapacity(targetSamples)

        for i in stride(from: 0, to: frameCount, by: step) {
            var sample: Float = 0
            for channel in 0..<channelCount {
                sample += floatChannelData[channel][i]
            }
            sample /= Float(channelCount)
            samples.append(sample)
        }
        return samples
    }
}
