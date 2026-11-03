import AppKit
import SwiftUI

/// Hysteresis makes useful gain values easy to find without forcing a grid.
nonisolated struct GainSliderSnap {
    static let range = -60.0...24.0
    static let detents: [Double] = [-60, -48, -36, -24, -18, -12, -9, -6, -3, 0, 3, 6, 9, 12, 18, 24]
    private(set) var held: Double?

    mutating func reset() { held = nil }
    mutating func value(for proposed: Double, bypass: Bool = false) -> Double? {
        guard proposed.isFinite else { reset(); return nil }
        let raw = min(Self.range.upperBound, max(Self.range.lowerBound, proposed))
        if bypass { reset(); return raw }
        if let held, abs(raw - held) <= (held == 0 ? 1.5 : 1.15) { return held }
        held = nil
        if let nearest = Self.detents.min(by: { abs(raw - $0) < abs(raw - $1) }),
           abs(raw - nearest) <= (nearest == 0 ? 1 : 0.65) {
            held = nearest
            return nearest
        }
        return raw
    }
}

/// Native continuous slider: no tick row, one unity-gain reference, optional detents.
struct GainSlider: NSViewRepresentable {
    @Binding var value: Double
    let label: String

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> GainSliderControl {
        let slider = GainSliderControl(value: value, minValue: GainSliderSnap.range.lowerBound,
                                       maxValue: GainSliderSnap.range.upperBound,
                                       target: context.coordinator, action: #selector(Coordinator.changed(_:)))
        slider.isContinuous = true
        slider.numberOfTickMarks = 0
        slider.allowsTickMarkValuesOnly = false
        slider.isVertical = false
        slider.setContentHuggingPriority(.defaultLow, for: .horizontal)
        slider.onBeginTracking = { [weak coordinator = context.coordinator] in coordinator?.snap.reset() }
        slider.toolTip = "0 dB keeps the original level. Drag near round values to snap; hold Option for fine adjustment. Arrow keys adjust by 0.5 dB, Option-arrow by 0.1 dB."
        updateNSView(slider, context: context)
        return slider
    }
    func updateNSView(_ slider: GainSliderControl, context: Context) {
        context.coordinator.parent = self
        if slider.doubleValue != value {
            context.coordinator.snap.reset()
            slider.doubleValue = value
        }
        slider.isEnabled = context.environment.isEnabled
        slider.setAccessibilityLabel(label)
        slider.setAccessibilityValueDescription(String(format: "%+.1f decibels", value))
        slider.needsDisplay = true
    }
    @MainActor final class Coordinator: NSObject {
        var parent: GainSlider
        var snap = GainSliderSnap()
        init(_ parent: GainSlider) { self.parent = parent }
        @objc func changed(_ slider: GainSliderControl) {
            let fine = NSEvent.modifierFlags.contains(.option)
            guard let next = snap.value(for: slider.doubleValue, bypass: fine || slider.isStepping) else { return }
            slider.doubleValue = next
            slider.setAccessibilityValueDescription(String(format: "%+.1f decibels", next))
            parent.value = next
        }
    }
}

@MainActor
final class GainSliderControl: NSSlider {
    private(set) var isStepping = false
    var onBeginTracking: (() -> Void)?

    override func mouseDown(with event: NSEvent) {
        onBeginTracking?()
        super.mouseDown(with: event)
    }

    /// Native track geometry, including the knob's inset at either endpoint.
    var zeroReferenceX: CGFloat {
        guard let cell = cell as? NSSliderCell else { return bounds.midX }
        let track = cell.barRect(flipped: isFlipped)
        let knob = cell.knobRect(flipped: isFlipped)
        let fraction = CGFloat((0 - minValue) / (maxValue - minValue))
        return track.minX + knob.width / 2 + max(0, track.width - knob.width) * fraction
    }
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let cell = cell as? NSSliderCell else { return }
        let track = cell.barRect(flipped: isFlipped)
        let y = isFlipped ? track.maxY + 3 : track.minY - 8
        let color = isEnabled ? NSColor.secondaryLabelColor : NSColor.disabledControlTextColor
        color.setFill()
        NSBezierPath(roundedRect: NSRect(x: zeroReferenceX - 0.75, y: y, width: 1.5, height: 5),
                     xRadius: 0.75, yRadius: 0.75).fill()
        let label = NSAttributedString(string: "0 dB", attributes: [
            .font: NSFont.systemFont(ofSize: 8), .foregroundColor: color
        ])
        label.draw(at: NSPoint(x: zeroReferenceX + 5, y: y + (5 - label.size().height) / 2))
    }
    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 123, 125: adjust(-1, fine: event.modifierFlags.contains(.option))
        case 124, 126: adjust(1, fine: event.modifierFlags.contains(.option))
        default: super.keyDown(with: event)
        }
    }
    override func accessibilityPerformIncrement() -> Bool { adjust(1); return isEnabled }
    override func accessibilityPerformDecrement() -> Bool { adjust(-1); return isEnabled }

    private func adjust(_ direction: Double, fine: Bool = false) {
        guard isEnabled else { return }
        let step = fine ? 0.1 : 0.5
        isStepping = true
        defer { isStepping = false }
        doubleValue = min(maxValue, max(minValue, ((doubleValue / step).rounded() + direction) * step))
        sendAction(action, to: target)
        needsDisplay = true
    }
}
