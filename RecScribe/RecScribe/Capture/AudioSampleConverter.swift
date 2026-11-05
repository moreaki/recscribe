import AVFoundation
import CoreMedia

/// Copies native linear PCM into owned planar Float32 storage. The decoder reads
/// bytes explicitly, allowing packed samples, endian changes and unaligned input.
nonisolated enum AudioSampleConverter {
    static func makePCMBuffer(from sampleBuffer: CMSampleBuffer) -> AVAudioPCMBuffer? {
        guard let description = CMSampleBufferGetFormatDescription(sampleBuffer),
              let basic = CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee,
              let encoding = PCMEncoding(basic) else { return nil }
        let frames = CMSampleBufferGetNumSamples(sampleBuffer)
        guard frames > 0, frames <= Int(UInt32.max), basic.mSampleRate.isFinite, basic.mSampleRate > 0 else { return nil }
        let channels = basic.mChannelsPerFrame
        let format: AVAudioFormat?
        if channels < 3 {
            format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: basic.mSampleRate,
                                   channels: channels, interleaved: false)
        } else {
            guard let layout = AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_DiscreteInOrder | channels) else { return nil }
            format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: basic.mSampleRate,
                                   interleaved: false, channelLayout: layout)
        }
        guard let format, let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: UInt32(frames)),
              let destination = output.floatChannelData else { return nil }
        var needed = 0
        let query = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer, bufferListSizeNeededOut: &needed, bufferListOut: nil, bufferListSize: 0,
            blockBufferAllocator: nil, blockBufferMemoryAllocator: nil, flags: 0, blockBufferOut: nil)
        guard query == noErr, needed >= MemoryLayout<AudioBufferList>.size else { return nil }
        let storage = UnsafeMutableRawPointer.allocate(byteCount: needed, alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { storage.deallocate() }
        let list = storage.assumingMemoryBound(to: AudioBufferList.self)
        var owner: CMBlockBuffer?
        let fetched = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer, bufferListSizeNeededOut: nil, bufferListOut: list, bufferListSize: needed,
            blockBufferAllocator: nil, blockBufferMemoryAllocator: nil, flags: 0, blockBufferOut: &owner)
        guard fetched == noErr else { return nil }
        return withExtendedLifetime((sampleBuffer, owner, output)) {
            let buffers = UnsafeMutableAudioBufferListPointer(list)
            let planeCount = encoding.planar ? Int(channels) : 1
            guard buffers.count == planeCount else { return nil }
            let stride = Int(basic.mBytesPerFrame)
            let required = frames.multipliedReportingOverflow(by: stride)
            guard !required.overflow else { return nil }
            for plane in buffers {
                guard plane.mData != nil, Int(plane.mDataByteSize) >= required.partialValue,
                      plane.mNumberChannels == (encoding.planar ? 1 : channels) else { return nil }
            }
            for channel in 0..<Int(channels) {
                let plane = buffers[encoding.planar ? channel : 0]
                let source = plane.mData!.assumingMemoryBound(to: UInt8.self)
                let channelOffset = encoding.planar ? 0 : channel * encoding.containerBytes
                for frame in 0..<frames {
                    destination[channel][frame] = encoding.read(source + frame * stride + channelOffset)
                }
            }
            output.frameLength = UInt32(frames)
            return output
        }
    }

    private struct PCMEncoding {
        let planar: Bool
        let containerBytes: Int
        let bits: Int
        let floating: Bool
        let bigEndian: Bool
        let high: Bool

        init?(_ basic: AudioStreamBasicDescription) {
            guard basic.mFormatID == kAudioFormatLinearPCM, basic.mChannelsPerFrame > 0 else { return nil }
            let flags = basic.mFormatFlags
            planar = flags & kAudioFormatFlagIsNonInterleaved != 0
            floating = flags & kAudioFormatFlagIsFloat != 0
            bigEndian = flags & kAudioFormatFlagIsBigEndian != 0
            high = flags & kAudioFormatFlagIsAlignedHigh != 0
            bits = Int(basic.mBitsPerChannel)
            let divisor = planar ? 1 : Int(basic.mChannelsPerFrame)
            guard Int(basic.mBytesPerFrame).isMultiple(of: divisor) else { return nil }
            containerBytes = Int(basic.mBytesPerFrame) / divisor
            if floating {
                guard (bits == 32 || bits == 64), containerBytes * 8 == bits else { return nil }
            } else {
                guard flags & kAudioFormatFlagIsSignedInteger != 0,
                      [16, 24, 32].contains(bits), (2...4).contains(containerBytes),
                      bits <= containerBytes * 8 else { return nil }
            }
        }

        func read(_ bytes: UnsafePointer<UInt8>) -> Float {
            var word: UInt64 = 0
            for index in 0..<containerBytes {
                let shift = (bigEndian ? containerBytes - index - 1 : index) * 8
                word |= UInt64(bytes[index]) << shift
            }
            if floating {
                return bits == 32 ? Float(bitPattern: UInt32(word)) : Float(Double(bitPattern: word))
            }
            if high { word >>= containerBytes * 8 - bits }
            // Sign extend only the significant bits, including low-aligned PCM24.
            let extensionShift = 64 - bits
            let signed = Int64(bitPattern: word << extensionShift) >> extensionShift
            return Float(signed) / Float(UInt64(1) << (bits - 1))
        }
    }
}
