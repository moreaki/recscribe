import AppKit
import SwiftUI
import Testing
@testable import RecScribe

@MainActor
struct GainSliderTests {
    @Test func magnetsCaptureHoldReleaseAndAllowFineAdjustment() throws {
        var snap = GainSliderSnap()
        #expect(snap.value(for: -6.5) == -6)
        #expect(snap.value(for: -7.1) == -6)
        #expect(snap.value(for: -7.2) == -7.2)
        #expect(snap.value(for: 8.1) == 8.1) // free movement between detents
        #expect(snap.value(for: 0.9) == 0)
        #expect(snap.value(for: 1.4) == 0) // wider release radius prevents jitter
        #expect(snap.value(for: 1.6) == 1.6)
        #expect(snap.value(for: 12.4) == 12)
        #expect(snap.value(for: 12.2, bypass: true) == 12.2)
        #expect(snap.held == nil)
        #expect(snap.value(for: 0.2, bypass: true) == 0.2)
        #expect(snap.value(for: 100) == 24)
        #expect(snap.value(for: -100) == -60)
        #expect(snap.value(for: .nan) == nil && snap.held == nil)
        #expect(snap.value(for: .infinity) == nil)
    }

    @Test func everyDetentIsReachableFromBothDirections() {
        for detent in GainSliderSnap.detents {
            for direction in [-1.0, 1.0] {
                var snap = GainSliderSnap()
                #expect(snap.value(for: detent + direction * 0.4) == detent)
                snap.reset()
                #expect(snap.held == nil)
            }
        }
    }

    @Test func unityMarkerTracksNativeKnobGeometryAtDifferentWidths() throws {
        for width in [180.0, 320.0, 640.0] {
            let slider = GainSliderControl(value: 0, minValue: -60, maxValue: 24, target: nil, action: nil)
            slider.frame = NSRect(x: 0, y: 0, width: width, height: 30)
            let window = NSWindow(contentRect: slider.frame, styleMask: .borderless, backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = slider
            defer { window.contentView = nil; window.close() }
            let bitmap = try #require(slider.bitmapImageRepForCachingDisplay(in: slider.bounds))
            slider.cacheDisplay(in: slider.bounds, to: bitmap)
            let cell = try #require(slider.cell as? NSSliderCell)
            #expect(slider.numberOfTickMarks == 0)
            #expect(abs(slider.zeroReferenceX - cell.knobRect(flipped: slider.isFlipped).midX) <= 1)
            let reference = slider.zeroReferenceX
            slider.doubleValue = -12
            #expect(abs(slider.zeroReferenceX - reference) <= 1)
            slider.doubleValue = 12
            #expect(abs(slider.zeroReferenceX - reference) <= 1)
        }
    }

    @Test func accessibleStepsEscapeDetentsAndRespectBounds() {
        var saved = 0.0
        let view = GainSlider(value: Binding(get: { saved }, set: { saved = $0 }), label: "Test gain")
        let coordinator = GainSlider.Coordinator(view)
        #expect(coordinator.snap.value(for: 0.8) == 0)
        let slider = GainSliderControl(value: 0, minValue: -60, maxValue: 24, target: coordinator,
                                       action: #selector(GainSlider.Coordinator.changed(_:)))
        #expect(slider.accessibilityPerformIncrement())
        #expect(slider.doubleValue == 0.5 && saved == 0.5 && !slider.isStepping)
        #expect(coordinator.snap.held == nil)
        #expect(slider.accessibilityPerformDecrement())
        #expect(slider.doubleValue == 0)
        slider.doubleValue = 24
        #expect(slider.accessibilityPerformIncrement() && slider.doubleValue == 24)
        slider.doubleValue = -60
        #expect(slider.accessibilityPerformDecrement() && slider.doubleValue == -60)
        slider.isEnabled = false
        #expect(!slider.accessibilityPerformIncrement() && slider.doubleValue == -60)
    }
}
