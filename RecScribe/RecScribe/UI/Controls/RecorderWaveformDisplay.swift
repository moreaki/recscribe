import AppKit
import SwiftUI

/// Samples change pixels, not intrinsic size. A SwiftUI body reading every PCM
/// packet made the window remeasure its layout at the capture callback rate.
struct RecorderWaveformDisplay: NSViewRepresentable {
    let telemetry: RecorderTelemetry
    var barCount = RecorderWaveformAdapter.popoverBarCount
    @Environment(\.studioTheme) private var theme

    func makeNSView(context: Context) -> RecorderWaveformDrawingView {
        RecorderWaveformDrawingView(telemetry: telemetry)
    }
    func updateNSView(_ view: RecorderWaveformDrawingView, context: Context) {
        view.configure(color: NSColor(theme.colors[.accent]), width: theme.metrics.waveformBarWidth,
                       spacing: theme.metrics.waveformBarSpacing, count: barCount)
    }
    static func dismantleNSView(_ view: RecorderWaveformDrawingView, coordinator: ()) {
        view.stopObserving()
    }
}

final class RecorderWaveformDrawingView: NSView {
    private var observation: ObservationSubscription?
    private var samples: [Float]
    private var color: NSColor = .systemRed
    private var barWidth: CGFloat = 2
    private var spacing: CGFloat = 1
    private var barCount = RecorderWaveformAdapter.popoverBarCount

    init(telemetry: RecorderTelemetry) {
        samples = telemetry.waveformSamples
        super.init(frame: .zero)
        setAccessibilityElement(false)
        observation = ObservationSubscription(read: { telemetry.waveformSamples }) { [weak self] in
            self?.samples = $0
            self?.needsDisplay = true
        }
    }
    required init?(coder: NSCoder) { nil }
    func configure(color: NSColor, width: CGFloat, spacing: CGFloat, count: Int) {
        self.color = color; barWidth = width; self.spacing = spacing
        barCount = min(RecorderWaveformAdapter.mainWindowBarCount, max(1, count))
        needsDisplay = true
    }
    func stopObserving() { observation?.cancel(); observation = nil }

    override func draw(_ dirtyRect: NSRect) {
        guard barWidth.isFinite, spacing.isFinite, barWidth > 0, spacing >= 0, bounds.width > 0 else { return }
        let bars = RecorderWaveformAdapter.magnitudes(samples, bucketedTo: barCount)
        let pitch = max(barWidth + spacing, bounds.width / CGFloat(max(1, bars.count)))
        let capacity = max(1, Int(bounds.width / pitch))
        let visible = bars.suffix(capacity)
        let start = CGFloat(capacity - visible.count) * pitch
        let path = NSBezierPath()
        for (index, amplitude) in visible.enumerated() {
            let height = min(bounds.height, max(2, bounds.height * CGFloat(amplitude)))
            let rect = NSRect(x: start + CGFloat(index) * pitch, y: (bounds.height - height) / 2,
                              width: barWidth, height: height)
            path.appendRoundedRect(rect, xRadius: barWidth / 2, yRadius: barWidth / 2)
        }
        color.setFill(); path.fill()
    }
}
