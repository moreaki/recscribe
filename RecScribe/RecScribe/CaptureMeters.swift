import Foundation

/// Fixed-size peak telemetry, copied to the UI at 10 Hz. No PCM is retained.
nonisolated struct CapturePeakMeter: Sendable, Equatable {
    var peaks: [Float] = []
    var hold: [Float] = []
    var updatedAt: TimeInterval = 0
    mutating func update(_ values: [Float], at time: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        peaks = Array(values.prefix(32)); updatedAt = time
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
