import AVFoundation

/// A serial capture pipeline owns one resampling session. Keeping the session
/// across calls preserves filter history; a source format change starts a new one.
nonisolated final class AudioFormatNormalizer {
    static let canonical = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000,
                                          channels: 2, interleaved: false)!
    private let target: AVAudioFormat
    private var session: AVAudioConverter?

    init(outputFormat: AVAudioFormat = AudioFormatNormalizer.canonical) {
        target = outputFormat
    }

    func normalize(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        if buffer.format == target { return buffer }
        let input = buffer.format
        guard input.sampleRate.isFinite, input.sampleRate > 0, buffer.frameLength > 0 else { return nil }
        if session?.inputFormat != input {
            guard let replacement = AVAudioConverter(from: input, to: target) else { return nil }
            if input.channelCount > target.channelCount {
                // Device channels beyond this pair may carry loopback audio.
                replacement.channelMap = (0..<target.channelCount).map { NSNumber(value: $0) }
            }
            session = replacement
        }
        guard let session else { return nil }
        let required = ceil(Double(buffer.frameLength) * target.sampleRate / input.sampleRate) + 64
        guard required.isFinite, required > 0, required <= Double(UInt32.max),
              let result = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: UInt32(required)) else { return nil }
        let feed = ConversionFeed(buffer)
        var failure: NSError?
        let status = session.convert(to: result, error: &failure) { _, state in
            let next = feed.take()
            state.pointee = next == nil ? .noDataNow : .haveData
            return next
        }
        // A dry input is expected between callbacks, rather than end of stream.
        if status == .error || failure != nil || result.frameLength == 0 { return nil }
        return result
    }
}

/// AVAudioConverter consumes this synchronously during convert(). No buffer
/// crosses a queue; the unchecked conformance accommodates its Sendable block.
private nonisolated final class ConversionFeed: @unchecked Sendable {
    private var pending: AVAudioPCMBuffer?
    init(_ value: AVAudioPCMBuffer) { pending = value }
    func take() -> AVAudioPCMBuffer? {
        let value = pending
        pending = nil
        return value
    }
}
