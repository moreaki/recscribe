import SwiftUI

struct StudioWaveformStyle: Equatable {
    var barWidth: CGFloat? = nil
    var barSpacing: CGFloat? = nil
    var dimOpacity: Double? = nil
    var showsPlayhead = true
    static let standard = Self()
    static let thumbnail = Self(showsPlayhead: false)
}

struct StudioLiveWaveform: View {
    let samples: [Float]
    var style: StudioWaveformStyle = .standard
    var tint: StudioColorRole = .accent
    var opacity = 1.0
    @Environment(\.studioTheme) private var theme
    var body: some View {
        Canvas { context, bounds in
            let width = style.barWidth ?? theme.metrics.waveformBarWidth
            let step = width + (style.barSpacing ?? theme.metrics.waveformBarSpacing)
            guard step.isFinite, step > 0, width > 0, bounds.width > 0 else { return }
            let capacity = max(1, Int(bounds.width / step))
            let visible = samples.suffix(capacity)
            let start = CGFloat(capacity - visible.count) * step
            var bars = Path()
            for (position, amplitude) in visible.enumerated() {
                let level = amplitude.isFinite ? min(1, max(0, amplitude)) : 0
                let height = min(bounds.height, max(2, bounds.height * CGFloat(level)))
                let rect = CGRect(x: start + CGFloat(position) * step, y: (bounds.height - height) / 2,
                                  width: width, height: height)
                bars.addRoundedRect(in: rect, cornerSize: CGSize(width: width / 2, height: width / 2))
            }
            context.fill(bars, with: .color(theme.colors[tint].opacity(opacity)))
        }
        .accessibilityHidden(true)
    }
}

/// Peak envelopes use a fixed -60dB display floor. Both surfaces show the same
/// capture interval regardless of the number of display buckets.
nonisolated enum RecorderWaveformAdapter {
    static let mainWindowBarCount = 123
    static let popoverBarCount = 82
    static func barCount(forWidth width: CGFloat) -> Int {
        guard width.isFinite else { return 1 }
        return max(1, Int(width / 3))
    }
    static func magnitudes(_ signed: [Float], bucketedTo count: Int) -> [Float] {
        guard count > 0 else { return [] }
        if signed.isEmpty { return Array(repeating: 0, count: count) }
        return (0..<count).map { bucket in
            let lower = signed.count * bucket / count
            let upper = min(signed.count, max(lower + 1, signed.count * (bucket + 1) / count))
            let peak = signed[lower..<upper].reduce(Float.zero) { value, next in
                next.isFinite ? max(value, abs(next)) : value
            }
            guard peak > 0.001 else { return 0 }
            return min(1, max(0, 1 + log10(peak) / 3))
        }
    }
}
