import AVFoundation
import Foundation
import os

/// Queue-confined source writers and bounded timestamp mixer. All source tracks
/// share a 48-kHz host-clock timeline; only the derived mix reduces channels.
nonisolated final class SynchronizedCaptureWriter {
    struct Policy: Sendable {
        var mixWindowFrames = 48_000 // one second of callback reordering
        var blockFrames = 4_096
        var maximumPacketSeconds = 0.25
        var maximumDurationSeconds = 7 * 24 * 60 * 60.0 // checked timestamp arithmetic
        var maximumDriftFraction = 0.02
        var sourceStallSeconds = 3.0
        var maximumEndSkewSeconds = 0.25
    }
    private final class Input {
        let writer: SessionWAVWriter?
        let format: AVAudioFormat
        let normalizer: AudioFormatNormalizer
        var pending: AVAudioPCMBuffer?
        var time: Double = 0
        var duration: Double = 0
        var end: Int64 = 0
        var receivedFrames: Int64 = 0
        var gaps: Int64 = 0
        init(writer: SessionWAVWriter?, format: AVAudioFormat, output: AVAudioFormat) {
            self.writer = writer; self.format = format
            self.normalizer = AudioFormatNormalizer(outputFormat: output)
        }
    }
    let mix: SessionWAVWriter?
    let epoch: Double
    private let options: RecordingStorageOptions
    private let policy: Policy
    private var descriptors: [RecordingSession.SourceTrack]
    private var inputs: [CaptureTrack: Input] = [:]
    private var left: [Float]
    private var right: [Float]
    private var head: Int64 = 0
    private var end: Int64 = 0
    private var clippedFrames: Int64 = 0
    private var sealed = false
    private var failedSources: Set<CaptureTrack> = []
    private var tracks: [CaptureTrack] { descriptors.map(\.role) }
    private let automation: GainAutomation
    private let levels: @Sendable () -> RecordingLevels
    private(set) var mixPeak: Float = 0
    private var postPeaks: [CaptureTrack: Float] = [:]
    private(set) var sourceMeters: [CaptureTrack: CaptureSourceMeters] = [:]
    private(set) var mixMeter = CapturePeakMeter()
    private let maximumFrames: Int64?
    var onMix: ((AVAudioPCMBuffer) -> Void)?

    init(mix: SessionWAVWriter? = nil, descriptors: [RecordingSession.SourceTrack], epoch: Double,
         options: RecordingStorageOptions, policy: Policy = .init(),
         maximumFrames: Int64? = nil,
         levels: @escaping @Sendable () -> RecordingLevels = { .init() }) throws {
        guard epoch.isFinite && epoch >= 0, maximumFrames.map({ $0 > 0 }) ?? true,
              (1...CaptureTrack.maximumSources).contains(descriptors.count), Set(descriptors.map(\.role)).count == descriptors.count,
              descriptors.allSatisfy({ $0.role.valid }),
              policy.mixWindowFrames > 0, policy.blockFrames > 0,
              policy.maximumPacketSeconds > 0 else { throw SessionError.invalid("Invalid mixer policy") }
        self.levels = levels; self.automation = GainAutomation(levels(), tracks: descriptors.map(\.role))
        self.mix = mix; self.descriptors = descriptors; self.epoch = epoch
        self.options = options; self.policy = policy
        self.maximumFrames = maximumFrames
        left = Array(repeating: 0, count: policy.mixWindowFrames)
        right = left
        try journal()
        try mix?.setGainAutomation(automation.events, scope: "derived_mix", tracks: tracks)
    }

    private func frame(_ time: Double) throws -> Int64 {
        let seconds = time - epoch
        guard seconds.isFinite, seconds >= -0.001, seconds <= policy.maximumDurationSeconds else {
            throw SessionError.invalid("Capture timestamp is outside the recording timeline")
        }
        return max(0, Int64((seconds * 48_000).rounded()))
    }

    func accept(_ sample: CapturedAudioSample) throws {
        guard !sealed, !failedSources.contains(sample.track), sample.buffer.frameLength > 0 else { return }
        if let maximumFrames, try frame(sample.presentationTime) >= maximumFrames { return }
        if try automation.update(levels(), at: max(end, head)) {
            try mix?.setGainAutomation(automation.events, scope: "derived_mix", tracks: tracks)
        }
        let format = sample.buffer.format
        guard format.sampleRate.isFinite, (1...384_000).contains(format.sampleRate),
              (1...32).contains(Int(format.channelCount)),
              Double(sample.buffer.frameLength) <= format.sampleRate * policy.maximumPacketSeconds,
              sample.buffer.floatChannelData != nil else { throw SessionError.invalid("Capture buffer exceeds supported format or packet budget") }
        _ = try frame(sample.presentationTime)
        let input: Input
        if let existing = inputs[sample.track] {
            guard existing.format == format else {
                throw SessionError.invalid("An input changed audio format; review the preserved source tracks")
            }
            input = existing
        } else {
            guard let index = descriptors.firstIndex(where: { $0.role == sample.track }) else { throw SessionError.invalid("Unknown capture source") }
            var writer: SessionWAVWriter?
            let output = try Self.format(channels: format.channelCount)
            if let mix {
                guard let base = mix.audioURL, let id = mix.sessionID else { throw SessionError.invalid("Missing recording identity") }
                let sink = SessionWAVWriter(options: .init(maximumPartBytes: options.maximumPartBytes))
                let url = base.deletingPathExtension().appendingPathExtension(sample.track.rawValue + ".wav")
                try sink.createFile(at: url, sampleRate: 48_000, channels: Int(format.channelCount))
                var identity = descriptors[index]
                identity.channels = Int(format.channelCount); identity.nativeSampleRate = format.sampleRate; identity.manifestPath = nil
                try sink.setParent(id, epoch: epoch, startedAt: mix.startedAt, source: identity)
                writer = sink
            }
            input = Input(writer: writer, format: format, output: output)
            inputs[sample.track] = input
            Log.capture.notice("Source format role=\(sample.track.rawValue, privacy: .public) native_rate=\(format.sampleRate) channels=\(format.channelCount) saved_rate=48000")
            descriptors[index].manifestPath = writer?.manifestURL?.lastPathComponent
            descriptors[index].nativeSampleRate = format.sampleRate
            descriptors[index].channels = Int(format.channelCount)
            if let routes = descriptors[index].channelRoutes {
                guard routes.allSatisfy({ $0.channel < Int(format.channelCount) }) else { throw SessionError.invalid("Selected input channels are unavailable in the captured format") }
                descriptors[index].mixChannels = routes.map(\.channel)
            } else { descriptors[index].mixChannels = Array(0..<min(2, Int(format.channelCount))) }
            try journal()
        }
        if let previous = input.pending {
            let start = try frame(input.time)
            let next = try frame(sample.presentationTime)
            guard next > start else { throw SessionError.invalid("Capture timestamps went backwards or repeated") }
            let nominal = Int64((input.duration * 48_000).rounded())
            let interval = next - start
            let drift = abs(Double(interval - nominal)) / Double(nominal)
            // One-buffer lookahead maps an independent device's sample clock to
            // the shared timestamp clock. Small rate differences are smoothly
            // time-scaled; a real gap remains silence and is reported.
            let frames = drift <= policy.maximumDriftFraction ? Int(interval) : Int(nominal)
            input.pending = nil
            try emit(previous, frames: frames, start: start, input: input, role: sample.track)
        }
        guard let normalized = input.normalizer.normalize(sample.buffer) else {
            throw SessionError.invalid("Source audio could not be normalized")
        }
        input.pending = normalized
        input.time = sample.presentationTime
        input.duration = Double(sample.buffer.frameLength) / format.sampleRate
        input.receivedFrames += Int64(sample.buffer.frameLength)
        var raw = [Float](repeating: 0, count: Int(format.channelCount))
        if let data = sample.buffer.floatChannelData {
            for channel in raw.indices {
                for frame in 0..<Int(sample.buffer.frameLength) { raw[channel] = max(raw[channel], abs(data[channel][frame])) }
            }
        }
        sourceMeters[sample.track, default: .init()].raw.update(raw)
        try flushAvailable()
    }

    private static func format(channels: AVAudioChannelCount) throws -> AVAudioFormat {
        if channels <= 2, let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: channels) { return format }
        guard let layout = AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_DiscreteInOrder | channels) else {
            throw SessionError.invalid("Unsupported source channel layout")
        }
        return AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, interleaved: false, channelLayout: layout)
    }

    private func emit(_ buffer: AVAudioPCMBuffer, frames nominalFrames: Int, start: Int64, input: Input, role: CaptureTrack) throws {
        let frames = maximumFrames.map { min(nominalFrames, Int(max(0, $0 - start))) } ?? nominalFrames
        if frames == 0 { return }
        guard frames > 0, frames <= Int(48_000 * policy.maximumPacketSeconds) + 512,
              start >= input.end else { throw SessionError.invalid("Capture audio overlaps its previous interval") }
        if start > input.end {
            if input.end > 0 {
                input.gaps += start - input.end
                try mix?.addIssue("A source has timestamp gaps; silence preserves its position. Review the source tracks.")
            }
            try silence(to: input.writer, frames: start - input.end, channels: buffer.format.channelCount)
        }
        let aligned: AVAudioPCMBuffer
        if frames == Int(buffer.frameLength) { aligned = buffer }
        else {
            guard let result = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: AVAudioFrameCount(frames)),
                  let source = buffer.floatChannelData, let target = result.floatChannelData else { throw WAVWriterError.invalidFormat }
            result.frameLength = AVAudioFrameCount(frames)
            // Small asynchronous-clock corrections only; nominal sample-rate
            // conversion uses each source's persistent AVAudioConverter first.
            for channel in 0..<Int(buffer.format.channelCount) {
                for frame in 0..<frames {
                    let position = Double(frame) * Double(buffer.frameLength) / Double(nominalFrames)
                    let lower = min(Int(position), Int(buffer.frameLength) - 1)
                    let upper = min(lower + 1, Int(buffer.frameLength) - 1)
                    let fraction = Float(position - Double(lower))
                    target[channel][frame] = source[channel][lower] + (source[channel][upper] - source[channel][lower]) * fraction
                }
            }
            aligned = result
        }
        try input.writer?.writeBuffer(aligned)
        input.end = start + Int64(frames)
        end = max(end, input.end)
        // Retain source audio even when a callback arrives beyond the mixing
        // reorder window. Never present that derived mix as fully covered.
        if input.end - head > Int64(policy.mixWindowFrames) {
            try flush(to: input.end - Int64(policy.mixWindowFrames))
        }
        if start < head {
            try mix?.addIssue("A source arrived too late for the stereo mix; its separate track is preserved. Review the recording.")
        }
        guard let data = aligned.floatChannelData else { throw WAVWriterError.invalidFormat }
        guard let slot = descriptors.firstIndex(where: { $0.role == role }) else { throw SessionError.invalid("Unknown source identity") }
        let base = slot * 32
        let descriptor = descriptors[slot]
        let routes = descriptor.channelRoutes ?? (buffer.format.channelCount == 1 ? [.init(channel: 0, placement: .center)] : [.init(channel: 0, placement: .left), .init(channel: 1, placement: .right)])
        let leftCount = max(1, routes.filter { $0.placement != .right }.count)
        let rightCount = max(1, routes.filter { $0.placement != .left }.count)
        var postPeak: Float = 0
        var channelPeaks = [Float](repeating: 0, count: Int(aligned.format.channelCount))
        for offset in 0..<frames {
            let absolute = start + Int64(offset)
            guard absolute >= head else { continue }
            let index = Int(absolute % Int64(policy.mixWindowFrames))
            let event = automation.event(at: absolute)
            var l: Float = 0, r: Float = 0
            for route in routes {
                let value = data[route.channel][offset] * event.value(base + route.channel, at: absolute)
                postPeak = max(postPeak, abs(value))
                channelPeaks[route.channel] = max(channelPeaks[route.channel], abs(value))
                if route.placement != .right { l += value / Float(leftCount) }
                if route.placement != .left { r += value / Float(rightCount) }
            }
            // Average contributions for per-channel and per-source headroom.
            left[index] += l / Float(descriptors.count)
            right[index] += r / Float(descriptors.count)
        }
        postPeaks[role] = postPeak
        sourceMeters[role, default: .init()].processed.update(channelPeaks)
    }

    private func flushAvailable() throws {
        let active = tracks.filter { !failedSources.contains($0) }
        let earliestEnd = active.map { inputs[$0]?.end ?? 0 }.min() ?? end
        if end - earliestEnd > Int64(policy.sourceStallSeconds * 48_000) {
            try mix?.addIssue("A selected source stopped delivering data; review source coverage and silence in the mix.")
        }
        try flush(to: earliestEnd)
    }

    private func flush(to target: Int64) throws {
        if head < target { mixPeak = 0 }
        while head < target {
            let count = min(policy.blockFrames, Int(target - head))
            guard let buffer = AVAudioPCMBuffer(pcmFormat: AudioFormatNormalizer.canonical, frameCapacity: AVAudioFrameCount(count)),
                  let data = buffer.floatChannelData else { throw WAVWriterError.invalidFormat }
            buffer.frameLength = AVAudioFrameCount(count)
            var peaks: [Float] = [0, 0]
            for offset in 0..<count {
                let index = Int((head + Int64(offset)) % Int64(policy.mixWindowFrames))
                let absolute = head + Int64(offset)
                let master = automation.event(at: absolute).value(automation.masterIndex, at: absolute)
                let l = left[index] * master, r = right[index] * master
                mixPeak = max(mixPeak, abs(l), abs(r))
                peaks[0] = max(peaks[0], abs(l)); peaks[1] = max(peaks[1], abs(r))
                if abs(l) > 1 || abs(r) > 1 { clippedFrames += 1 }
                data[0][offset] = max(-1, min(1, l))
                data[1][offset] = max(-1, min(1, r))
                left[index] = 0; right[index] = 0
            }
            onMix?(buffer)
            mixMeter.update(peaks)
            try mix?.writeBuffer(buffer)
            head += Int64(count)
        }
    }

    private func silence(to writer: SessionWAVWriter?, frames: Int64, channels: AVAudioChannelCount) throws {
        guard let writer, frames > 0 else { return }
        let format = try Self.format(channels: channels)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(policy.blockFrames)),
              let data = buffer.floatChannelData else { throw WAVWriterError.invalidFormat }
        for channel in 0..<Int(channels) { data[channel].initialize(repeating: 0, count: policy.blockFrames) }
        var remaining = frames
        while remaining > 0 {
            buffer.frameLength = AVAudioFrameCount(min(Int64(policy.blockFrames), remaining))
            try writer.writeBuffer(buffer)
            remaining -= Int64(buffer.frameLength)
        }
    }

    private func journal() throws {
        for index in descriptors.indices {
            if let input = inputs[descriptors[index].role] {
                descriptors[index].receivedFrames = input.receivedFrames
                descriptors[index].gapFrames = input.gaps
            }
        }
        try mix?.setSourceTracks(descriptors, epoch: epoch)
    }

    func sourceFailed(_ track: CaptureTrack, message: String) throws {
        guard !sealed, let index = descriptors.firstIndex(where: { $0.role == track }), !failedSources.contains(track) else { return }
        if let input = inputs[track], let pending = input.pending {
            try emit(pending, frames: Int((input.duration * 48_000).rounded()), start: frame(input.time), input: input, role: track)
            input.pending = nil
            try input.writer?.addIssue(message)
        }
        failedSources.insert(track)
        descriptors[index].failure = message
        try mix?.addIssue("A selected input failed; other sources continued. Review incomplete source coverage.")
        try journal()
        try flushAvailable()
    }

    func health(for track: CaptureTrack) -> (written: Int64, peak: Float, postPeak: Float, mixPeak: Float, clipped: Bool) {
        guard let input = inputs[track] else { return (0, 0, 0, mixPeak, clippedFrames > 0) }
        return (input.writer?.frameCount ?? input.end, input.pending.map { AudioRecorder.peak($0) } ?? 0, postPeaks[track] ?? 0, mixPeak, clippedFrames > 0)
    }

    func finish(failure: Error? = nil) throws {
        guard !sealed else { return }
        sealed = true
        var failureToReport = failure
        for track in tracks {
            do {
                guard let input = inputs[track] else {
                    try mix?.addIssue("Selected \(track.rawValue) source delivered no data; coverage is incomplete.")
                    continue
                }
                if let pending = input.pending {
                    try emit(pending, frames: Int((input.duration * 48_000).rounded()), start: frame(input.time), input: input, role: track)
                    input.pending = nil
                }
            } catch { if failureToReport == nil { failureToReport = error } }
        }
        for input in inputs.values {
            if end - input.end > Int64(policy.maximumEndSkewSeconds * 48_000) {
                try? mix?.addIssue("A selected source stopped delivering data; review source coverage and silence in the mix.")
            }
            do { try silence(to: input.writer, frames: end - input.end, channels: input.format.channelCount) }
            catch { if failureToReport == nil { failureToReport = error } }
        }
        do {
            try flush(to: end)
            if clippedFrames > 0 { try mix?.addIssue("The derived mix clipped; unattenuated source tracks are retained.") }
            try journal()
        } catch { if failureToReport == nil { failureToReport = error } }
        for (role, input) in inputs {
            Log.recorder.notice("Source timing role=\(role.rawValue, privacy: .public) received_native_frames=\(input.receivedFrames) saved_timeline_frames=\(input.writer?.frameCount ?? input.end) timestamp_gap_frames=\(input.gaps) mix_clipped_frames=\(self.clippedFrames)")
        }
        // Every writer must finalize even if another writer or mixing failed.
        for input in inputs.values {
            do {
                if let failureToReport { try input.writer?.markFailure(failureToReport) }
                try input.writer?.finalize()
            } catch { if failureToReport == nil { failureToReport = error } }
        }
        do {
            if let failureToReport { try mix?.markFailure(failureToReport) }
            try mix?.finalize()
        } catch { if failureToReport == nil { failureToReport = error } }
        if let failureToReport { throw failureToReport }
    }
}
