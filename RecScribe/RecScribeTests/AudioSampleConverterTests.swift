//
//  AudioSampleConverterTests.swift
//  RecScribeTests
//
//  BL-007: CMSampleBuffer → AVAudioPCMBuffer conversion, in isolation.
//

import Testing
import Foundation
import AVFoundation
@testable import RecScribe

@MainActor
struct AudioSampleConverterTests {

    // Distinct, recoverable value per (channel, frame) so deinterleave order is provable.
    private func value(channel: Int, frame: Int) -> Float {
        Float(channel) * 1000 + Float(frame)
    }

    @Test("Interleaved stereo deinterleaves into the right channel/frame slots")
    func interleavedStereo() throws {
        let frames = 4, channels = 2
        let sb = SampleBufferFixtures.interleaved(frames: frames, channels: channels) { ch, f in value(channel: ch, frame: f) }

        let pcm = try #require(AudioSampleConverter.makePCMBuffer(from: sb))
        #expect(Int(pcm.frameLength) == frames)
        #expect(Int(pcm.format.channelCount) == channels)
        let data = try #require(pcm.floatChannelData)
        for ch in 0..<channels {
            for f in 0..<frames {
                #expect(data[ch][f] == value(channel: ch, frame: f))
            }
        }
    }

    @Test("Mono interleaved converts to a single channel")
    func monoInterleaved() throws {
        let frames = 3
        let sb = SampleBufferFixtures.interleaved(frames: frames, channels: 1) { _, f in value(channel: 0, frame: f) }

        let pcm = try #require(AudioSampleConverter.makePCMBuffer(from: sb))
        #expect(Int(pcm.format.channelCount) == 1)
        #expect(Int(pcm.frameLength) == frames)
        let data = try #require(pcm.floatChannelData)
        for f in 0..<frames {
            #expect(data[0][f] == value(channel: 0, frame: f))
        }
    }

    @Test("Non-interleaved input is copied per channel")
    func nonInterleavedStereo() throws {
        let frames = 4, channels = 2
        let sb = SampleBufferFixtures.nonInterleaved(frames: frames, channels: channels) { ch, f in value(channel: ch, frame: f) }

        let pcm = try #require(AudioSampleConverter.makePCMBuffer(from: sb))
        #expect(Int(pcm.frameLength) == frames)
        #expect(Int(pcm.format.channelCount) == channels)
        let data = try #require(pcm.floatChannelData)
        for ch in 0..<channels {
            for f in 0..<frames {
                #expect(data[ch][f] == value(channel: ch, frame: f))
            }
        }
    }

    @Test("Odd/small frame count is preserved exactly")
    func oddFrameCount() throws {
        let frames = 7
        let sb = SampleBufferFixtures.interleaved(frames: frames, channels: 2) { ch, f in value(channel: ch, frame: f) }

        let pcm = try #require(AudioSampleConverter.makePCMBuffer(from: sb))
        #expect(Int(pcm.frameLength) == frames)
        let data = try #require(pcm.floatChannelData)
        #expect(data[1][frames - 1] == value(channel: 1, frame: frames - 1))  // last sample correct
    }

    @Test("Zero-frame buffer returns nil (dropped)")
    func zeroFramesReturnsNil() {
        let sb = SampleBufferFixtures.interleaved(frames: 0, channels: 2) { _, _ in 0 }
        #expect(AudioSampleConverter.makePCMBuffer(from: sb) == nil)
    }
}
