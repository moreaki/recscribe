import Foundation

/// Constant-size telemetry. Times are monotonic, never wall-clock dates.
nonisolated struct RecordingHealth: Sendable, Equatable {
    struct Policy: Sendable {
        var firstDataTimeout: TimeInterval = 3
        var stallTimeout: TimeInterval = 3
        var silencePeak: Float = 0.000_1 // -80 dBFS; describes signal, not capture success.
    }
    enum Status: String, Sendable {
        case waiting, noData, audio, silence, stalled, writing, writeStalled, failed
        var label: String {
            switch self {
            case .waiting: "Waiting for audio"
            case .noData: "No audio data — check the source and permissions"
            case .audio: "Receiving audio · saved to disk"
            case .silence: "Receiving silence · saved to disk"
            case .stalled: "Audio data stopped — check the source"
            case .writing: "Receiving data · waiting for disk"
            case .writeStalled: "Audio is arriving but disk writes have stalled"
            case .failed: "Capture or write failed · review saved audio"
            }
        }
    }
    var startedAt: TimeInterval = 0
    var firstReceivedAt: TimeInterval?
    var lastReceivedAt: TimeInterval?
    var lastWrittenAt: TimeInterval?
    var receivedFrames: Int64 = 0
    var writtenFrames: Int64 = 0
    var sampleRate: Double?
    var channels: Int?
    var postPeak: Float?
    var mixPeak: Float?
    var clipped = false
    var peak: Float = 0
    var failed = false
    var failureMessage: String?

    func status(at now: TimeInterval, policy: Policy = .init()) -> Status {
        if failed { return .failed }
        guard let received = lastReceivedAt else {
            return now - startedAt >= policy.firstDataTimeout ? .noData : .waiting
        }
        if now - received >= policy.stallTimeout { return .stalled }
        // Native received frames and resampled/padded timeline frames are not
        // comparable counts. Detect a stalled writer from monotonic activity.
        if received > (lastWrittenAt ?? -.infinity),
           now - (lastWrittenAt ?? firstReceivedAt ?? received) >= policy.stallTimeout { return .writeStalled }
        guard writtenFrames > 0 else { return .writing }
        return peak <= policy.silencePeak ? .silence : .audio
    }
}

nonisolated struct SourceRecordingHealth: Identifiable, Sendable, Equatable {
    var id: String
    var name: String
    var detail: String? = nil
    var health: RecordingHealth
}


/// Fixed-size peak telemetry, copied to the UI at 10 Hz. No PCM is retained.
nonisolated struct CapturePeakMeter: Sendable, Equatable {
    var peaks: [Float] = []
    var hold: [Float] = []
    var updatedAt: TimeInterval = 0
    mutating func update(_ values: [Float], at time: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        peaks = Array(values.prefix(32))
        updatedAt = time
        if hold.count != peaks.count { hold = Array(repeating: 0, count: peaks.count) }
        for index in peaks.indices { hold[index] = max(hold[index], peaks[index]) }
    }
    func current(at time: TimeInterval) -> [Float] {
        time - updatedAt < 0.4 ? peaks : peaks.map { _ in 0 }
    }
}

nonisolated struct CaptureSourceMeters: Sendable, Equatable {
    var raw = CapturePeakMeter()
    var processed = CapturePeakMeter()
}

/// Shared explicitly by the production recording and test controllers.
@MainActor
final class CaptureSessionGate {
    private var owner: UUID?
    func acquire(_ id: UUID) throws {
        guard owner == nil else { throw SessionError.invalid("Another capture is starting or stopping. Try again after it finishes.") }
        owner = id
    }
    func release(_ id: UUID) { if owner == id { owner = nil } }
}
