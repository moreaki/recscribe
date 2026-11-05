import AppKit
import SwiftUI

/// Diagnostic values have fixed line slots. Growing frame counters and changing
/// dB values must not remeasure the entire window once per second.
struct CaptureHealthReadout: View {
    let telemetry: RecorderTelemetry
    let source: SourceRecordingHealth
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        let size = 10 * typeSize.studioScale
        CaptureHealthNativeReadout(telemetry: telemetry, sourceID: source.id, fontSize: size)
            .frame(height: CaptureHealthDrawingView.height(for: source, fontSize: size))
    }
}

private struct CaptureHealthNativeReadout: NSViewRepresentable {
    let telemetry: RecorderTelemetry
    let sourceID: String
    let fontSize: CGFloat
    func makeNSView(context: Context) -> CaptureHealthDrawingView {
        CaptureHealthDrawingView(telemetry: telemetry, sourceID: sourceID)
    }
    func updateNSView(_ view: CaptureHealthDrawingView, context: Context) { view.configure(fontSize: fontSize) }
    static func dismantleNSView(_ view: CaptureHealthDrawingView, coordinator: ()) { view.stopObserving() }
}

private nonisolated struct CaptureReadoutValue: Equatable, Sendable {
    var source: SourceRecordingHealth?
    var time: TimeInterval
    var peak: Float
}

final class CaptureHealthDrawingView: NSView {
    private var observation: ObservationSubscription?
    private var value = CaptureReadoutValue(time: 0, peak: 0)
    private var font = NSFont.systemFont(ofSize: 10)
    private var lines: [(String, Int, NSColor)] = []
    private var meterRect = NSRect.zero
    private static let gap: CGFloat = 4
    override var isFlipped: Bool { true }

    static func height(for source: SourceRecordingHealth, fontSize: CGFloat) -> CGFloat {
        let line = ceil(fontSize * 1.3)
        let hasFormat = source.health.channels != nil && source.health.sampleRate != nil
        let slots = 4 + (source.health.failureMessage == nil ? 0 : 2)
            + (hasFormat ? 3 + (source.health.clipped ? 1 : 0) : 0)
        let groups = 2 + (source.health.failureMessage == nil ? 0 : 1)
            + (hasFormat ? 3 + (source.health.clipped ? 1 : 0) : 0)
        return CGFloat(slots) * line + CGFloat(groups - 1) * gap + (hasFormat ? 10 + gap : 0)
    }

    init(telemetry: RecorderTelemetry, sourceID: String) {
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        func read() -> CaptureReadoutValue {
            .init(source: telemetry.detailSources.first { $0.id == sourceID }, time: telemetry.detailTime,
                  peak: telemetry.sourceHealth.first { $0.id == sourceID }?.health.peak ?? 0)
        }
        update(read())
        observation = ObservationSubscription(read: read) { [weak self] in self?.update($0) }
    }
    required init?(coder: NSCoder) { nil }
    func stopObserving() { observation?.cancel(); observation = nil }
    func configure(fontSize: CGFloat) {
        guard font.pointSize != fontSize else { return }
        font = .systemFont(ofSize: fontSize)
        needsDisplay = true
    }

    private func update(_ next: CaptureReadoutValue) {
        let detailsChanged = value.source != next.source || value.time != next.time
        value = next
        guard detailsChanged else { setNeedsDisplay(meterRect); return }
        guard let source = value.source else { lines = []; needsDisplay = true; return }
        let h = source.health, status = h.status(at: value.time)
        let warning: [RecordingHealth.Status] = [.noData, .stalled, .writeStalled, .failed]
        lines = [("\(source.name): \(status.label)", 2, warning.contains(status) ? .systemOrange : .secondaryLabelColor)]
        if let message = h.failureMessage { lines.append((message, 2, .systemOrange)) }
        if let rate = h.sampleRate, let channels = h.channels {
            let peak = h.peak >= 1 ? "clipping" : String(format: "peak %.1f dBFS", 20 * log10(max(0.000_001, h.peak)))
            lines.append(("\(channels) input channels · \(rate.formatted(.number.precision(.fractionLength(0)))) Hz · \(peak)", 1, .secondaryLabelColor))
            let post = h.postPeak ?? h.peak
            lines.append((String(format: "After fader: %.1f dBFS · saved mix: %.1f dBFS", 20 * log10(max(0.000_001, post)), 20 * log10(max(0.000_001, h.mixPeak ?? post))), 2, h.clipped ? .systemOrange : .secondaryLabelColor))
            if h.clipped { lines.append(("Clipping detected · reduce recording gain", 1, .systemOrange)) }
        }
        lines.append(("\(h.receivedFrames.formatted()) frames received · \(h.writtenFrames.formatted()) written", 2, .secondaryLabelColor))
        setAccessibilityLabel("\(source.name) level")
        setAccessibilityValue(lines.map(\.0).joined(separator: "\n"))
        toolTip = source.detail ?? source.name
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let lineHeight = ceil(font.pointSize * 1.3)
        var y: CGFloat = 0
        for (index, line) in lines.enumerated() {
            if index == lines.count - 1, value.source?.health.channels != nil {
                meterRect = NSRect(x: 0, y: y, width: bounds.width, height: 6)
                NSColor.quaternaryLabelColor.setFill()
                NSBezierPath(roundedRect: meterRect, xRadius: 3, yRadius: 3).fill()
                let peak = value.peak.isFinite ? max(0, min(1, value.peak)) : 0
                NSColor(WorkspaceStyle.blue).setFill()
                NSBezierPath(roundedRect: NSRect(x: 0, y: y, width: bounds.width * CGFloat(peak), height: 6), xRadius: 3, yRadius: 3).fill()
                y += 10 + Self.gap
            }
            let rect = NSRect(x: 0, y: y, width: bounds.width, height: CGFloat(line.1) * lineHeight)
            if rect.intersects(dirtyRect) {
                let paragraph = NSMutableParagraphStyle(); paragraph.lineBreakMode = .byTruncatingTail
                (line.0 as NSString).draw(with: rect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
                    attributes: [.font: font, .foregroundColor: line.2, .paragraphStyle: paragraph])
            }
            y += rect.height + Self.gap
        }
    }
}

struct RecorderElapsedDisplay: NSViewRepresentable {
    let telemetry: RecorderTelemetry
    @Environment(\.dynamicTypeSize) private var typeSize
    func makeNSView(context: Context) -> RecorderElapsedDrawingView { .init(telemetry: telemetry) }
    func updateNSView(_ view: RecorderElapsedDrawingView, context: Context) { view.configure(size: 22 * typeSize.studioScale) }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: RecorderElapsedDrawingView, context: Context) -> CGSize? {
        .init(width: proposal.width ?? 100, height: ceil(29 * typeSize.studioScale))
    }
    static func dismantleNSView(_ view: RecorderElapsedDrawingView, coordinator: ()) { view.stopObserving() }
}

final class RecorderElapsedDrawingView: NSView {
    private var observation: ObservationSubscription?
    private var text: String
    private var font = NSFont.monospacedDigitSystemFont(ofSize: 22, weight: .semibold)
    override var isFlipped: Bool { true }
    init(telemetry: RecorderTelemetry) {
        text = telemetry.formattedDuration
        super.init(frame: .zero)
        setAccessibilityElement(true); setAccessibilityRole(.staticText)
        setAccessibilityLabel("Recording duration"); setAccessibilityValue(text)
        observation = ObservationSubscription(read: { telemetry.formattedDuration }) { [weak self] value in
            self?.text = value; self?.setAccessibilityValue(value); self?.needsDisplay = true
        }
    }
    required init?(coder: NSCoder) { nil }
    func stopObserving() { observation?.cancel(); observation = nil }
    func configure(size: CGFloat) {
        guard font.pointSize != size else { return }
        font = .monospacedDigitSystemFont(ofSize: size, weight: .semibold); needsDisplay = true
    }
    override func draw(_ dirtyRect: NSRect) {
        (text as NSString).draw(in: bounds, withAttributes: [.font: font, .foregroundColor: NSColor.labelColor])
    }
}
