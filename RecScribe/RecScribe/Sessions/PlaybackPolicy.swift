import AVFoundation
import Foundation

/// File transport behavior, independent of capture formats and listening levels.
nonisolated enum PlaybackPolicy {
    static let skipSeconds: TimeInterval = 15
    static let backwardSymbol = "gobackward.15"
    static let forwardSymbol = "goforward.15"
    static let observerInterval = CMTime(value: 1, timescale: 10)
    // A stable sample-precision timebase, also for imported files at other rates.
    static let seekTimescale: CMTimeScale = 48_000
    static let seekTolerance = CMTime.zero
    // Zero delegates file-backed buffering to AVFoundation. No application PCM
    // preload/cache is added; this is not a hard process-RSS limit.
    static let preferredForwardBufferDuration: TimeInterval = 0
    static let inactiveSliderRange: ClosedRange<Double> = 0...1

    static func spokenTime(_ seconds: Double, locale: Locale = .current) -> String {
        guard seconds.isFinite, seconds >= 0, seconds < Double(Int.max) else { return "Unknown duration" }
        return Duration.seconds(seconds.rounded(.down))
            .formatted(.units(allowed: [.hours, .minutes, .seconds], width: .wide).locale(locale))
    }
}

nonisolated enum PlaybackPhase: String, CaseIterable {
    case idle, preparing, paused, playing, buffering, scrubbing, ended, failed

    var label: String {
        switch self {
        case .idle: "Stopped"
        case .preparing: "Preparing audio…"
        case .paused: "Paused"
        case .playing: "Playing"
        case .buffering: "Buffering audio…"
        case .scrubbing: "Seeking…"
        case .ended: "Playback finished"
        case .failed: "Playback failed"
        }
    }
}
