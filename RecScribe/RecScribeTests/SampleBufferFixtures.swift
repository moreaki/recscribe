import AVFoundation
import CoreMedia
import Foundation

/// Synthetic owned PCM used by independent recording contracts. No microphone,
/// permission request or external fixture is involved.
enum SampleBufferFixtures {
    static func makePCMBuffer(
        channels: Int,
        frames: Int,
        sampleRate: Double = 48000,
        interleaved: Bool,
        onDeallocate: (@Sendable () -> Void)? = nil,
        fill: (_ channel: Int, _ frame: Int) -> Float
    ) -> AVAudioPCMBuffer {
        let format: AVAudioFormat
        if channels > 2 {
            let layout = AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_DiscreteInOrder | AVAudioChannelCount(channels))!
            format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate,
                                  interleaved: interleaved, channelLayout: layout)
        } else {
            format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate,
                                  channels: AVAudioChannelCount(channels), interleaved: interleaved)!
        }
        let capacity = max(frames, 1)
        let samples = UnsafeMutablePointer<Float>.allocate(capacity: capacity * channels)
        samples.initialize(repeating: 0, count: capacity * channels)
        let list = AudioBufferList.allocate(maximumBuffers: interleaved ? 1 : channels)
        list.count = interleaved ? 1 : channels
        for index in 0..<list.count {
            list[index] = AudioBuffer(
                mNumberChannels: AVAudioChannelCount(interleaved ? channels : 1),
                mDataByteSize: UInt32(capacity * (interleaved ? channels : 1) * MemoryLayout<Float>.size),
                mData: UnsafeMutableRawPointer(samples.advanced(by: interleaved ? 0 : index * capacity)))
        }
        let buffer = AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: list.unsafePointer) { _ in
            // Publish retirement before an allocator can hand this address to
            // the next producer. A post-free observer can lag address reuse.
            onDeallocate?()
            samples.deinitialize(count: capacity * channels)
            samples.deallocate()
            list.unsafeMutablePointer.deallocate()
        }!
        buffer.frameLength = AVAudioFrameCount(frames)

        if frames > 0 {
            if interleaved {
                let abl = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
                let ptr = abl[0].mData!.assumingMemoryBound(to: Float.self)
                for frame in 0..<frames {
                    for channel in 0..<channels {
                        ptr[frame * channels + channel] = fill(channel, frame)
                    }
                }
            } else {
                let channelData = buffer.floatChannelData!
                for channel in 0..<channels {
                    for frame in 0..<frames {
                        channelData[channel][frame] = fill(channel, frame)
                    }
                }
            }
        }
        return buffer
    }


    static func makeSampleBuffer(from pcm: AVAudioPCMBuffer) -> CMSampleBuffer {
        wrap(description: pcm.format.streamDescription.pointee, frames: Int(pcm.frameLength),
             buffers: pcm.audioBufferList, owner: pcm)
    }
    static func interleaved(frames: Int, channels: Int = 2, sampleRate: Double = 48_000,
                            fill: (Int, Int) -> Float) -> CMSampleBuffer {
        makeSampleBuffer(from: makePCMBuffer(channels: channels, frames: frames, sampleRate: sampleRate,
                                             interleaved: true, fill: fill))
    }
    static func nonInterleaved(frames: Int, channels: Int = 2, sampleRate: Double = 48_000,
                               fill: (Int, Int) -> Float) -> CMSampleBuffer {
        makeSampleBuffer(from: makePCMBuffer(channels: channels, frames: frames, sampleRate: sampleRate,
                                             interleaved: false, fill: fill))
    }
    struct IntegerLayout {
        let bitsPerChannel: UInt32
        let bytesPerSample: UInt32
        let isAlignedHigh: Bool
        let isInterleaved: Bool
        init(bitsPerChannel: UInt32, bytesPerSample: UInt32? = nil,
             isAlignedHigh: Bool = false, isInterleaved: Bool = true) {
            self.bitsPerChannel = bitsPerChannel
            self.bytesPerSample = bytesPerSample ?? bitsPerChannel / 8
            self.isAlignedHigh = isAlignedHigh
            self.isInterleaved = isInterleaved
        }
        static let int16 = Self(bitsPerChannel: 16)
        static let int32 = Self(bitsPerChannel: 32)
        static let int24Packed = Self(bitsPerChannel: 24, bytesPerSample: 3)
        static let int24AlignedHigh = Self(bitsPerChannel: 24, bytesPerSample: 4, isAlignedHigh: true)
        var formatFlags: AudioFormatFlags {
            var flags = kAudioFormatFlagIsSignedInteger
            if isAlignedHigh { flags |= kAudioFormatFlagIsAlignedHigh }
            else if bytesPerSample * 8 == bitsPerChannel { flags |= kAudioFormatFlagIsPacked }
            if !isInterleaved { flags |= kAudioFormatFlagIsNonInterleaved }
            return flags
        }
    }
    static func integer(frames: Int, channels: UInt32 = 2, sampleRate: Double = 48_000,
                        layout: IntegerLayout = .int16,
                        fill: (Int, Int) -> Float = { channel, frame in
                            sin(Float(frame) * 0.07 + Float(channel) * 0.4) * 0.5
                        }) -> CMSampleBuffer {
        let stride = Int(layout.bytesPerSample)
        let width = Int(channels)
        let capacity = max(1, frames * width * stride)
        let owner = NSMutableData(length: capacity)!
        let bytes = owner.mutableBytes.assumingMemoryBound(to: UInt8.self)
        let fullScale = Double(UInt64(1) << (layout.bitsPerChannel - 1)) - 1
        let alignment = layout.isAlignedHigh ? stride * 8 - Int(layout.bitsPerChannel) : 0
        for channel in 0..<width {
            for frame in 0..<frames {
                let value = Int64(max(-1, min(1, Double(fill(channel, frame)))) * fullScale) << alignment
                let sample = layout.isInterleaved ? frame * width + channel : channel * frames + frame
                for byte in 0..<stride { bytes[sample * stride + byte] = UInt8(truncatingIfNeeded: value >> (byte * 8)) }
            }
        }
        let planes = layout.isInterleaved ? 1 : width
        let list = AudioBufferList.allocate(maximumBuffers: planes)
        defer { list.unsafeMutablePointer.deallocate() }
        list.count = planes
        for plane in 0..<planes {
            let length = frames * stride * (layout.isInterleaved ? width : 1)
            list[plane] = AudioBuffer(mNumberChannels: layout.isInterleaved ? channels : 1,
                mDataByteSize: UInt32(length), mData: owner.mutableBytes.advanced(by: plane * length))
        }
        let frameBytes = layout.bytesPerSample * (layout.isInterleaved ? channels : 1)
        let description = AudioStreamBasicDescription(mSampleRate: sampleRate, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: layout.formatFlags, mBytesPerPacket: frameBytes, mFramesPerPacket: 1,
            mBytesPerFrame: frameBytes, mChannelsPerFrame: channels, mBitsPerChannel: layout.bitsPerChannel, mReserved: 0)
        return wrap(description: description, frames: frames, buffers: list.unsafePointer, owner: owner)
    }

    private static func wrap(description: AudioStreamBasicDescription, frames: Int,
                             buffers: UnsafePointer<AudioBufferList>, owner: AnyObject) -> CMSampleBuffer {
        var description = description
        var format: CMAudioFormatDescription?
        let madeFormat = CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault, asbd: &description,
            layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil, extensions: nil,
            formatDescriptionOut: &format)
        precondition(madeFormat == noErr)
        var sample: CMSampleBuffer?
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: CMTimeScale(description.mSampleRate)),
                                        presentationTimeStamp: .zero, decodeTimeStamp: .invalid)
        let madeSample = CMSampleBufferCreate(allocator: kCFAllocatorDefault, dataBuffer: nil, dataReady: false,
            makeDataReadyCallback: nil, refcon: nil, formatDescription: format, sampleCount: frames,
            sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleSizeEntryCount: 0,
            sampleSizeArray: nil, sampleBufferOut: &sample)
        precondition(madeSample == noErr && sample != nil)
        if frames == 0 { return sample! }
        let attached = CMSampleBufferSetDataBufferFromAudioBufferList(sample!, blockBufferAllocator: kCFAllocatorDefault,
            blockBufferMemoryAllocator: kCFAllocatorDefault, flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment,
            bufferList: buffers)
        precondition(attached == noErr)
        CMSetAttachment(sample!, key: "RecScribeFixturePCMOwner" as CFString, value: owner,
                        attachmentMode: kCMAttachmentMode_ShouldNotPropagate)
        return sample!
    }
}
