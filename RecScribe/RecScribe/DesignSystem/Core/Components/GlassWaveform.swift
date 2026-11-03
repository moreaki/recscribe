import SwiftUI

/// Geometry for the waveform family. Defaults come from the theme; overrides
/// exist for the two places the density genuinely differs (a 60pt trace in the
/// recording bar can't use the same bar pitch as a 380pt player).
public struct GlassWaveformStyle: Equatable {
    public var barWidth: CGFloat?
    public var barSpacing: CGFloat?
    /// Opacity of the unplayed portion.
    public var dimOpacity: Double?
    public var showsPlayhead: Bool

    public init(
        barWidth: CGFloat? = nil,
        barSpacing: CGFloat? = nil,
        dimOpacity: Double? = nil,
        showsPlayhead: Bool = true
    ) {
        self.barWidth = barWidth
        self.barSpacing = barSpacing
        self.dimOpacity = dimOpacity
        self.showsPlayhead = showsPlayhead
    }

    public static let standard = GlassWaveformStyle()
    /// A take's identity thumbnail: no playhead, no progress, just the shape.
    public static let thumbnail = GlassWaveformStyle(showsPlayhead: false)
}

// MARK: - Live waveform

/// The live capture trace: newest samples at the trailing edge, older ones
/// scrolling off the left.
public struct GlassLiveWaveform: View {
    private let samples: [Float]
    private let style: GlassWaveformStyle
    private let tintRole: GlassColorRole
    private let opacity: Double

    @Environment(\.glassTheme) private var theme

    public init(
        samples: [Float],
        style: GlassWaveformStyle = .standard,
        tint: GlassColorRole = .accent,
        opacity: Double = 1
    ) {
        self.samples = samples
        self.style = style
        self.tintRole = tint
        self.opacity = opacity
    }

    public var body: some View {
        let tint = theme.colors[tintRole].opacity(opacity)
        let barWidth = style.barWidth ?? theme.metrics.waveformBarWidth
        let pitch = barWidth + (style.barSpacing ?? theme.metrics.waveformBarSpacing)

        Canvas(opaque: false) { context, size in
            guard !samples.isEmpty, pitch > 0 else { return }
            let count = max(1, Int(size.width / pitch))
            // Trailing window of the ring buffer: a capture shorter than the
            // view starts at the left and grows rightward, rather than
            // stretching four samples across the whole width.
            let window = Array(samples.suffix(count))
            let offset = count - window.count

            for (index, sample) in window.enumerated() {
                let height = max(2, CGFloat(sample) * size.height)
                let rect = CGRect(
                    x: CGFloat(offset + index) * pitch,
                    y: (size.height - height) / 2,
                    width: barWidth,
                    height: height
                )
                context.fill(Path(roundedRect: rect, cornerRadius: barWidth / 2), with: .color(tint))
            }
        }
        .accessibilityHidden(true)
    }
}
