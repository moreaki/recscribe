import AVFoundation
import CoreMedia
import Foundation
import os

/// Admission and stop share one lock; the worker owns PCM after submission.
/// Budget: 4 MiB queued PCM plus a 384 KiB mix ring and one pending buffer /
/// normalizer per selected source (250-ms packets, 32 channels maximum).
/// No ASR runs on this queue.
@MainActor
final class MultiSourceRecorder {
    private nonisolated struct State: Sendable {
        var id = UUID()
        var active = false
        var accepting = false
        var failedTracks: Set<CaptureTrack> = []
        var closedSources: Set<CaptureTrack> = []
        var bytes = 0
        var buffers = 0
        var peakBytes = 0
        var writeMS = 0.0
        var maxWriteMS = 0.0
        var maxQueueMS = 0.0
        var failure: Error?
        var tracks: [CaptureTrack] = []
        var continueOnSourceFailure = false
        var health: [CaptureTrack: RecordingHealth] = [:]
        var meters: [CaptureTrack: CaptureSourceMeters] = [:]
        var mixMeter = CapturePeakMeter()
        var waveform: [Float]?
        var waveformScheduled = false
    }
    nonisolated private let state = OSAllocatedUnfairLock(initialState: State())
    nonisolated private let queue = DispatchQueue(label: "com.moreaki.recscribe.multisource", qos: .userInitiated)
    nonisolated(unsafe) private var writer: SynchronizedCaptureWriter? // queue-confined after setup
    nonisolated private let maximumBytes: Int
    nonisolated private let maximumBuffers: Int
    private var stopping = false
    private(set) var manifestURL: URL?
    private(set) var audioURL: URL?
    private var descriptors: [RecordingSession.SourceTrack] = []
    nonisolated private let monitor: CapturedAudioMonitor
    nonisolated let onError: @MainActor @Sendable (String) -> Void
    nonisolated let onWaveform: (@MainActor @Sendable ([Float]) -> Void)?

    init(onError: @escaping @MainActor @Sendable (String) -> Void,
         onWaveform: (@MainActor @Sendable ([Float]) -> Void)? = nil,
         maximumBytes: Int = 4 * 1_024 * 1_024, maximumBuffers: Int = 256, monitor: CapturedAudioMonitor? = nil) {
        precondition(maximumBytes > 0 && maximumBuffers > 0)
        self.monitor = monitor ?? .shared
        self.maximumBytes = maximumBytes; self.maximumBuffers = maximumBuffers
        self.onError = onError; self.onWaveform = onWaveform
    }

    func start(at url: URL, descriptors: [RecordingSession.SourceTrack], options: RecordingStorageOptions,
               epoch: Double = CMClockGetTime(CMClockGetHostTimeClock()).seconds,
               levels: @escaping @Sendable () -> RecordingLevels = { .init() }, continueOnSourceFailure: Bool = false,
               maximumFrames: Int64? = nil) throws {
        guard !stopping, !state.withLock({ $0.active }) else { throw AudioRecorderError.alreadyRecording }
        let mix = SessionWAVWriter(options: options)
        try mix.createFile(at: url, sampleRate: 48_000, channels: 2)
        try begin(mix: mix, descriptors: descriptors, options: options, epoch: epoch, levels: levels,
                  continueOnSourceFailure: continueOnSourceFailure, maximumFrames: maximumFrames)
    }

    /// The same normalization, timestamp alignment, routing and ramps without
    /// any disk sinks, manifests or unbounded PCM history.
    func startPreview(descriptors: [RecordingSession.SourceTrack], epoch: Double = CMClockGetTime(CMClockGetHostTimeClock()).seconds,
                      levels: @escaping @Sendable () -> RecordingLevels = { .init() }) throws {
        guard !stopping, !state.withLock({ $0.active }) else { throw AudioRecorderError.alreadyRecording }
        try begin(mix: nil, descriptors: descriptors, options: .init(), epoch: epoch, levels: levels,
                  continueOnSourceFailure: true, maximumFrames: 600 * 48_000)
    }

    private func begin(mix: SessionWAVWriter?, descriptors: [RecordingSession.SourceTrack], options: RecordingStorageOptions,
                       epoch: Double, levels: @escaping @Sendable () -> RecordingLevels,
                       continueOnSourceFailure: Bool, maximumFrames: Int64?) throws {
        self.descriptors = descriptors
        audioURL = mix?.audioURL; manifestURL = mix?.manifestURL
        let now = ProcessInfo.processInfo.systemUptime
        state.withLock { s in
            s = State(); s.active = true; s.accepting = true
            s.tracks = descriptors.map(\.role); s.continueOnSourceFailure = continueOnSourceFailure
            for track in s.tracks { s.health[track] = .init(startedAt: now) }
        }
        do {
            let worker = try SynchronizedCaptureWriter(mix: mix, descriptors: descriptors, epoch: epoch, options: options,
                                                       maximumFrames: maximumFrames, levels: levels)
            worker.onMix = { [weak self] in self?.monitor.submit($0); self?.publishWaveform($0) }
            queue.sync { writer = worker }
        } catch {
            try? mix?.markFailure(error); try? mix?.finalize()
            state.withLock { $0.accepting = false; $0.active = false }
            throw error
        }
    }

    nonisolated func accept(_ sample: CapturedAudioSample) {
        guard sample.buffer.frameLength > 0 else { return }
        let bytes = Int(sample.buffer.frameCapacity) * Int(sample.buffer.format.channelCount) * MemoryLayout<Float>.size
        let submitted = ContinuousClock.now
        let frames = Int64(sample.buffer.frameLength)
        let rate = sample.buffer.format.sampleRate
        let channels = Int(sample.buffer.format.channelCount)
        state.withLock { s in
            guard s.accepting, s.tracks.contains(sample.track), !s.closedSources.contains(sample.track), !s.failedTracks.contains(sample.track) else { return }
            guard s.buffers < maximumBuffers, bytes <= maximumBytes - s.bytes else {
                fail(AudioRecorderError.bufferLimit, state: &s); return
            }
            s.bytes += bytes; s.buffers += 1; s.peakBytes = max(s.peakBytes, s.bytes)
            let now = ProcessInfo.processInfo.systemUptime
            s.health[sample.track]?.receivedFrames += frames
            s.health[sample.track]?.sampleRate = rate
            s.health[sample.track]?.channels = channels
            s.health[sample.track]?.lastReceivedAt = now
            if s.health[sample.track]?.firstReceivedAt == nil { s.health[sample.track]?.firstReceivedAt = now }
            queue.async { self.write(sample, bytes: bytes, submitted: submitted) }
        }
    }

    nonisolated private func write(_ sample: CapturedAudioSample, bytes: Int, submitted: ContinuousClock.Instant) {
        let started = ContinuousClock.now
        defer { state.withLock { $0.bytes -= bytes; $0.buffers -= 1 } }
        guard state.withLock({ !$0.failedTracks.contains(sample.track) }), let writer else { return }
        do {
            try autoreleasepool { try writer.accept(sample) }
            let writeMS = Self.milliseconds(started.duration(to: .now))
            let queueMS = Self.milliseconds(submitted.duration(to: started))
            let snapshot = state.withLock { $0.tracks }.map { ($0, writer.health(for: $0)) }
            let meters = writer.sourceMeters, mixMeter = writer.mixMeter
            state.withLock { s in
                s.writeMS += writeMS
                s.maxWriteMS = max(s.maxWriteMS, writeMS)
                s.maxQueueMS = max(s.maxQueueMS, queueMS)
                for (track, health) in snapshot {
                    if health.written > (s.health[track]?.writtenFrames ?? 0) {
                        s.health[track]?.writtenFrames = health.written
                        s.health[track]?.lastWrittenAt = ProcessInfo.processInfo.systemUptime
                    }
                    s.health[track]?.peak = health.peak
                    s.health[track]?.postPeak = health.postPeak
                    s.health[track]?.mixPeak = health.mixPeak
                    if health.clipped { s.health[track]?.clipped = true }
                }
                s.meters = meters; s.mixMeter = mixMeter
            }
        } catch {
            if case SessionError.invalid = error, state.withLock({ $0.continueOnSourceFailure }) {
                let message = "Input timing or format changed; other sources continue. " + error.localizedDescription
                do {
                    try writer.sourceFailed(sample.track, message: message)
                    state.withLock {
                        $0.failedTracks.insert(sample.track); $0.closedSources.insert(sample.track)
                        $0.health[sample.track]?.failed = true; $0.health[sample.track]?.failureMessage = message
                    }
                } catch { state.withLock { fail(error, state: &$0) } }
            } else { state.withLock { $0.failedTracks.insert(sample.track); fail(error, state: &$0) } }
        }
    }

    nonisolated func sourceFailed(_ track: CaptureTrack, message: String) {
        state.withLock { s in
            guard s.accepting, s.tracks.contains(track), !s.closedSources.contains(track) else { return }
            s.closedSources.insert(track)
            s.health[track]?.failed = true
            s.health[track]?.failureMessage = message
            queue.async { [self] in
                state.withLock { _ = $0.failedTracks.insert(track) }
                do { try writer?.sourceFailed(track, message: message) }
                catch { state.withLock { fail(error, state: &$0) } }
            }
        }
    }

    nonisolated private func fail(_ error: Error, state s: inout State) {
        guard s.failure == nil else { return }
        s.failure = error; s.accepting = false
        for track in s.tracks { s.health[track]?.failed = true }
        let id = s.id
        DispatchQueue.main.async { [self] in
            guard state.withLock({ $0.id == id && $0.active && $0.failure != nil }) else { return }
            let context = manifestURL == nil ? "Audio test stopped." : "Multi-source capture stopped; preserved source tracks need review."
            onError("\(context) \(error.localizedDescription)")
        }
    }

    nonisolated private func publishWaveform(_ buffer: AVAudioPCMBuffer) {
        guard onWaveform != nil else { return }
        let samples = WaveformDownsampler.downsample(buffer)
        state.withLock { s in
            s.waveform = samples
            guard !s.waveformScheduled else { return }
            s.waveformScheduled = true
            let id = s.id
            DispatchQueue.main.async { [self] in
                let value = state.withLock { s -> [Float]? in
                    guard s.id == id else { return nil }
                    defer { s.waveform = nil; s.waveformScheduled = false }
                    return s.accepting ? s.waveform : nil
                }
                if let value { onWaveform?(value) }
            }
        }
    }

    var sourceHealth: [SourceRecordingHealth] {
        let health = state.withLock { $0.health }
        return descriptors.map { .init(id: $0.role.rawValue, name: $0.name, detail: $0.deviceUID ?? $0.bundleID ?? "All system playback (RecScribe excluded)", health: health[$0.role] ?? .init()) }
    }
    var sourceMeters: [CaptureTrack: CaptureSourceMeters] { state.withLock { $0.meters } }
    var mixMeter: CapturePeakMeter { state.withLock { $0.mixMeter } }

    nonisolated private static func milliseconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) * 1_000 + Double(duration.components.attoseconds) / 1e15
    }

    func stop(failure: Error? = nil, reportReviewIssues: Bool = true) async throws {
        guard !stopping, state.withLock({ $0.active }) else { throw AudioRecorderError.notRecording }
        let stopStarted = ContinuousClock.now
        stopping = true
        defer { stopping = false }
        let error: Error? = await withCheckedContinuation { continuation in
            state.withLock { s in
                s.accepting = false
                queue.async { [self] in
                    let finalizeStarted = ContinuousClock.now
                    let drainMS = Self.milliseconds(stopStarted.duration(to: finalizeStarted))
                    var resultError = failure ?? state.withLock { $0.failure }
                    do { try writer?.finish(failure: resultError) } catch { if resultError == nil { resultError = error } }
                    for track in state.withLock({ $0.tracks }) {
                        let frames = writer?.health(for: track).written ?? 0
                        state.withLock { $0.health[track]?.writtenFrames = frames }
                    }
                    let meters = writer?.sourceMeters ?? [:], mixMeter = writer?.mixMeter ?? .init()
                    state.withLock { $0.meters = meters; $0.mixMeter = mixMeter }
                    if reportReviewIssues, resultError == nil, writer?.mix?.hasIssues == true {
                        resultError = SessionError.invalid("The recording has clipping, timing gaps or incomplete source coverage. Review the preserved source tracks and mix.")
                    }
                    let finalizeMS = Self.milliseconds(finalizeStarted.duration(to: .now))
                    let timings = state.withLock { ($0.writeMS, $0.maxWriteMS, $0.maxQueueMS, $0.peakBytes) }
                    Log.recorder.notice("Multi-source drained write_ms=\(timings.0) max_write_ms=\(timings.1) max_queue_ms=\(timings.2) drain_ms=\(drainMS) finalize_ms=\(finalizeMS) peak_pcm_bytes=\(timings.3)")
                    writer = nil
                    state.withLock { $0.active = false }
                    let snapshot = state.withLock { ($0.health, $0.peakBytes) }
                    for track in state.withLock({ $0.tracks }) {
                        let h = snapshot.0[track] ?? .init()
                        Log.recorder.notice("Source drained role=\(track.rawValue, privacy: .public) received_frames=\(h.receivedFrames) written_frames=\(h.writtenFrames) peak_queued_pcm_bytes=\(snapshot.1)")
                    }
                    if reportReviewIssues, resultError == nil, snapshot.0.values.contains(where: { $0.receivedFrames == 0 }) {
                        resultError = SessionError.invalid("A selected source delivered no audio data; coverage is incomplete. Review saved source tracks.")
                    }
                    continuation.resume(returning: resultError)
                }
            }
        }
        if let error { throw error }
    }
}
