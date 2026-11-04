import AppKit
import SwiftUI

/// Native slider exposes a numeric AX value/range plus a spoken time description.
/// Keeping those separate lets VoiceOver adjust seconds without announcing a
/// percentage or treating a timecode string as the slider's numeric value.
struct PlaybackPositionSlider: NSViewRepresentable {
    @Bindable var playback: SessionPlayback

    func makeNSView(context: Context) -> PlaybackSlider {
        let slider = PlaybackSlider()
        slider.isContinuous = true
        slider.controlSize = .small
        slider.target = slider
        slider.action = #selector(PlaybackSlider.positionChanged)
        slider.setAccessibilityLabel("Playback position")
        slider.setAccessibilityIdentifier("playback-position")
        return slider
    }

    func updateNSView(_ slider: PlaybackSlider, context: Context) {
        slider.minValue = 0
        slider.maxValue = playback.duration > 0 ? playback.duration : PlaybackPolicy.inactiveSliderRange.upperBound
        slider.doubleValue = min(playback.position, max(0, playback.duration))
        slider.isEnabled = playback.canSeek
        slider.setAccessibilityValueDescription(playback.positionAccessibilityValue)
        slider.onSeek = { [weak slider] seconds in
            playback.seek(to: seconds)
            slider?.setAccessibilityValueDescription(playback.positionAccessibilityValue)
        }
        slider.onEditing = { playback.setScrubbing($0) }
    }
}

final class PlaybackSlider: NSSlider {
    var onSeek: (Double) -> Void = { _ in }
    var onEditing: (Bool) -> Void = { _ in }

    @objc func positionChanged() { onSeek(doubleValue) }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        onEditing(true)
        defer { onEditing(false) }
        super.mouseDown(with: event)
    }

    override func accessibilityPerformIncrement() -> Bool { adjust(by: PlaybackPolicy.skipSeconds) }
    override func accessibilityPerformDecrement() -> Bool { adjust(by: -PlaybackPolicy.skipSeconds) }

    private func adjust(by delta: Double) -> Bool {
        guard isEnabled else { return false }
        doubleValue = min(maxValue, max(minValue, doubleValue + delta))
        onSeek(doubleValue)
        NSAccessibility.post(element: self, notification: .valueChanged)
        return true
    }
}
