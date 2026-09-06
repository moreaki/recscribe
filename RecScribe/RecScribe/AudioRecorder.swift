import AVFoundation
import Foundation
import os

enum AudioRecorderError: Error, LocalizedError {
    case notRecording, alreadyRecording, bufferLimit
    var errorDescription: String? {
        switch self {
        case .notRecording: "Not currently recording"
        case .alreadyRecording: "The previous recording is still active or finalizing"
        case .bufferLimit: "Encoding cannot keep up; the partial recording has been preserved"
        }
    }
}

/// Fixed-size aggregate telemetry, never audio or paths.
nonisolated struct RecorderMetrics: Sendable {
    var accepted = 0
    var written = 0
    var rejected = 0
    var peakBuffers = 0
    var peakBytes = 0
    var maxQueueMS = 0.0
    var writeMS = 0.0
    var maxWriteMS = 0.0
    var drainMS = 0.0
    var finalizeMS = 0.0
}

/// Capture submits owned PCM; the serial queue alone touches the encoder.
/// Admission bounds include the in-flight write. No per-buffer logging.
final class AudioRecorder: AudioFileWriting {
    var onWaveformData: (@MainActor @Sendable ([Float]) -> Void)?
    var onWriteError: (@MainActor @Sendable (String) -> Void)?
    private(set) var lastMetrics = RecorderMetrics()
    private(set) var sessionManifestURL: URL?
    private(set) var actualAudioURL: URL?
    private let encoderFactory: (AudioFormat) throws -> any AudioFileEncoder
    nonisolated private let queue = DispatchQueue(label: "com.moreaki.recscribe.encoding", qos: .userInitiated)
    nonisolated private let maxBuffers: Int
    nonisolated private let maxBytes: Int
    nonisolated private let state = OSAllocatedUnfairLock(initialState: State())
    nonisolated(unsafe) private var encoder: (any AudioFileEncoder)? // queue-confined
    nonisolated private static let trace = OSSignposter(logger: Log.recorder)
    private var interval: OSSignpostIntervalState?
    private var stopping = false

    private nonisolated struct State {
        var id = UUID()
        var active = false
        var accepting = false
        var buffers = 0
        var bytes = 0
        var error: Error?
        var writeFailed = false
        var metrics = RecorderMetrics()
        var waveform: [Float]?
        var waveformScheduled = false
        var onWaveform: (@MainActor @Sendable ([Float]) -> Void)?
        var onError: (@MainActor @Sendable (String) -> Void)?
    }

    init(maxBuffers: Int = 256, maxBytes: Int = 4 * 1_024 * 1_024,
         encoderFactory: @escaping (AudioFormat) throws -> any AudioFileEncoder = { try $0.makeEncoder() }) {
        precondition(maxBuffers > 0 && maxBytes > 0)
        self.maxBuffers = maxBuffers
        self.maxBytes = maxBytes
        self.encoderFactory = encoderFactory
    }

    var recording: Bool { stopping || state.withLock { $0.active } }

    func startRecording(to url: URL, format: AudioFormat) throws {
        guard !recording else { throw AudioRecorderError.alreadyRecording }
        let encoder = try encoderFactory(format)
        try encoder.createFile(at: url, sampleRate: 48_000, channels: 2)
        sessionManifestURL = (encoder as? SessionWAVWriter)?.manifestURL
        actualAudioURL = (encoder as? SessionWAVWriter)?.audioURL ?? url
        queue.sync { self.encoder = encoder }
        let waveform = onWaveformData
        let failure = onWriteError
        state.withLock {
            $0 = State()
            $0.active = true
            $0.accepting = true
            $0.onWaveform = waveform
            $0.onError = failure
        }
        interval = Self.trace.beginInterval("Recording", id: Self.trace.makeSignpostID())
        Log.recorder.notice("Recording started id=\(self.state.withLock { $0.id }.uuidString, privacy: .public) format=\(format.fileExtension, privacy: .public) max_buffers=\(self.maxBuffers) max_pcm_bytes=\(self.maxBytes)")
    }

    nonisolated func processAudioSample(_ buffer: AVAudioPCMBuffer) {
        let bytes = Int(buffer.frameCapacity) * Int(buffer.format.channelCount) * MemoryLayout<Float>.size
        let submitted = ContinuousClock.now
        let transferred = TransferredPCMBuffer(value: buffer)
        // Submission and stop's barrier share this lock, including queue.async.
        state.withLock { s in
            guard s.accepting else { return }
            guard s.buffers < maxBuffers, bytes <= maxBytes - s.bytes else {
                s.metrics.rejected += 1
                fail(AudioRecorderError.bufferLimit, state: &s)
                return
            }
            s.buffers += 1
            s.bytes += bytes
            s.metrics.accepted += 1
            s.metrics.peakBuffers = max(s.metrics.peakBuffers, s.buffers)
            s.metrics.peakBytes = max(s.metrics.peakBytes, s.bytes)
            queue.async { self.write(transferred.value, bytes: bytes, submitted: submitted) }
        }
    }

    /// Caller cancellation never discards accepted audio. MainActor remains free.
    func stopRecording() async throws {
        guard recording, !stopping else { throw AudioRecorderError.notRecording }
        stopping = true
        let stop = ContinuousClock.now
        let trace = Self.trace.beginInterval("DrainAndFinalize", id: Self.trace.makeSignpostID())
        defer {
            stopping = false
            Self.trace.endInterval("DrainAndFinalize", trace)
            if let interval { Self.trace.endInterval("Recording", interval); self.interval = nil }
        }
        let error: Error? = await withCheckedContinuation { continuation in
            state.withLock { s in
                s.accepting = false
                queue.async {
                    let finalize = ContinuousClock.now
                    var finalError: Error?
                    if let failure = self.state.withLock({ $0.error }) {
                        try? (self.encoder as? SessionWAVWriter)?.markFailure(failure)
                    }
                    do { try self.encoder?.finalize() } catch { finalError = error }
                    self.encoder = nil
                    let completionError = finalError
                    let snapshot = self.state.withLock { s -> (RecorderMetrics, Error?, UUID) in
                        s.metrics.drainMS = Self.ms(stop.duration(to: finalize))
                        s.metrics.finalizeMS = Self.ms(finalize.duration(to: .now))
                        s.active = false
                        s.waveform = nil
                        return (s.metrics, s.error ?? completionError, s.id)
                    }
                    let m = snapshot.0
                    Log.recorder.notice("Recording ended id=\(snapshot.2.uuidString, privacy: .public) failed=\(snapshot.1 != nil) accepted=\(m.accepted) written=\(m.written) rejected=\(m.rejected) peak_buffers=\(m.peakBuffers) peak_pcm_bytes=\(m.peakBytes) max_queue_ms=\(m.maxQueueMS) write_ms=\(m.writeMS) max_write_ms=\(m.maxWriteMS) drain_ms=\(m.drainMS) finalize_ms=\(m.finalizeMS)")
                    continuation.resume(returning: snapshot.1)
                }
            }
        }
        lastMetrics = state.withLock { $0.metrics }
        if let error { throw error }
    }

    nonisolated private static func ms(_ duration: Duration) -> Double {
        Double(duration.components.seconds) * 1_000 + Double(duration.components.attoseconds) / 1e15
    }

    /// Called under admission's lock; report once, off the capture queue.
    nonisolated private func fail(_ error: Error, state s: inout State) {
        guard s.error == nil else { return }
        s.error = error
        s.accepting = false
        let id = s.id
        let callback = s.onError
        let message = error.localizedDescription
        DispatchQueue.main.async { [self] in
            guard state.withLock({ $0.id == id && $0.active }) else { return }
            Log.recorder.error("Recording write failure id=\(id.uuidString, privacy: .public): \(message, privacy: .private)")
            callback?(message)
        }
    }

    nonisolated private func write(_ buffer: AVAudioPCMBuffer, bytes: Int, submitted: ContinuousClock.Instant) {
        let start = ContinuousClock.now
        defer { state.withLock { $0.buffers -= 1; $0.bytes -= bytes } }
        guard !state.withLock({ $0.writeFailed }), let encoder else { return }
        do {
            try autoreleasepool { try encoder.writeBuffer(buffer) }
            let elapsed = Self.ms(start.duration(to: .now))
            state.withLock {
                $0.metrics.written += 1
                $0.metrics.maxQueueMS = max($0.metrics.maxQueueMS, Self.ms(submitted.duration(to: start)))
                $0.metrics.writeMS += elapsed
                $0.metrics.maxWriteMS = max($0.metrics.maxWriteMS, elapsed)
            }
        } catch {
            state.withLock { $0.writeFailed = true; fail(error, state: &$0) }
            return
        }
        guard state.withLock({ $0.onWaveform != nil }) else { return }
        let samples = WaveformDownsampler.downsample(buffer)
        state.withLock { s in
            s.waveform = samples
            guard !s.waveformScheduled else { return }
            s.waveformScheduled = true
            let id = s.id
            DispatchQueue.main.async { [self] in
                let delivery = state.withLock { s -> ([Float]?, (@MainActor @Sendable ([Float]) -> Void)?) in
                    guard s.id == id else { return (nil, nil) }
                    defer { s.waveform = nil; s.waveformScheduled = false }
                    return (s.active ? s.waveform : nil, s.onWaveform)
                }
                if let samples = delivery.0 { delivery.1?(samples) }
            }
        }
    }
}

/// Producer relinquishes this buffer; the encoding queue is its sole reader.
private nonisolated struct TransferredPCMBuffer: @unchecked Sendable {
    let value: AVAudioPCMBuffer
}
