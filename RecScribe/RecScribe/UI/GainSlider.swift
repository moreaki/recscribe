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
    func makeNSView(context: Context) -> GainSliderContainer {
        let slider = GainSliderControl(value: value, minValue: GainSliderSnap.range.lowerBound,
                                       maxValue: GainSliderSnap.range.upperBound,
                                       target: context.coordinator, action: #selector(Coordinator.changed(_:)))
        slider.isContinuous = true
        slider.numberOfTickMarks = 0
        slider.allowsTickMarkValuesOnly = false
        slider.isVertical = false
        slider.controlSize = .small
        slider.setContentHuggingPriority(.defaultLow, for: .horizontal)
        slider.onBeginTracking = { [weak coordinator = context.coordinator] in coordinator?.snap.reset() }
        slider.toolTip = "0 dB keeps the original level. Drag near round values to snap; hold Option for fine adjustment. Arrow keys adjust by 0.5 dB, Option-arrow by 0.1 dB."
        let container = GainSliderContainer(slider: slider)
        updateNSView(container, context: context)
        return container
    }
    func updateNSView(_ container: GainSliderContainer, context: Context) {
        let slider = container.slider
        context.coordinator.parent = self
        if slider.doubleValue != value {
            context.coordinator.snap.reset()
            slider.doubleValue = value
        }
        slider.isEnabled = context.environment.isEnabled
        slider.setAccessibilityLabel(label)
        slider.setAccessibilityValueDescription(String(format: "%+.1f decibels", value))
        container.referenceLabel.textColor = slider.isEnabled ? .labelColor : .disabledControlTextColor
        container.needsLayout = true
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

/// Reserve a separate label lane: the knob can never paint over the unity label.
@MainActor
final class GainSliderContainer: NSView {
    let slider: GainSliderControl
    let referenceLabel = NSTextField(labelWithString: "0 dB")

    init(slider: GainSliderControl) {
        self.slider = slider
        super.init(frame: .zero)
        referenceLabel.font = .monospacedDigitSystemFont(ofSize: 10, weight: .medium)
        referenceLabel.textColor = .labelColor
        referenceLabel.alignment = .center
        referenceLabel.setAccessibilityElement(false)
        addSubview(slider)
        addSubview(referenceLabel)
    }
    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        let labelHeight: CGFloat = 12
        slider.frame = NSRect(x: 0, y: labelHeight + 2, width: bounds.width,
                              height: max(0, bounds.height - labelHeight - 2))
        let labelWidth: CGFloat = 32
        referenceLabel.frame = NSRect(x: max(0, min(bounds.width - labelWidth, slider.zeroReferenceX - labelWidth / 2)),
                                      y: 0, width: labelWidth, height: labelHeight)
        needsDisplay = true
    }
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        (slider.isEnabled ? NSColor.labelColor : .disabledControlTextColor).setFill()
        NSRect(x: slider.zeroReferenceX - 0.5, y: 12, width: 1, height: 2).fill()
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
