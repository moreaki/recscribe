import AppKit
import Observation
import SwiftUI
import Testing
import os

@testable import RecScribe

@MainActor
@Suite(.serialized)
struct ObservationLayoutTests {
    @Test func detailCountersCoalesceButStatusAndFailureChangesAreImmediate() {
        let telemetry = RecorderTelemetry()
        var health = RecordingHealth(startedAt: 0, lastReceivedAt: 0, lastWrittenAt: 0,
                                     receivedFrames: 480, writtenFrames: 480, sampleRate: 48000, channels: 2, peak: 0.1)
        func publish(at time: TimeInterval) {
            telemetry.healthTime = time
            telemetry.sourceHealth = [.init(id: "playback", name: "Playback", health: health)]
            telemetry.refreshDetails()
        }
        publish(at: 0)
        let initial = telemetry.detailSources
        let changes = OSAllocatedUnfairLock(initialState: 0)
        withObservationTracking { _ = telemetry.detailSources } onChange: { changes.withLock { $0 += 1 } }
        for step in 1...9 {
            health.receivedFrames += 480; health.writtenFrames += 480
            health.lastReceivedAt = Double(step) / 10; health.lastWrittenAt = Double(step) / 10
            health.peak = Float(step) / 10
            publish(at: Double(step) / 10)
            #expect(telemetry.detailSources == initial)
        }
        #expect(changes.withLock { $0 } == 0)
        publish(at: 1)
        #expect(changes.withLock { $0 } == 1)
        #expect(telemetry.detailSources.first?.health == health)
        health.failed = true; health.failureMessage = "Input disconnected"
        publish(at: 1.1)
        #expect(telemetry.detailSources.first?.health.failed == true)
        #expect(telemetry.interruptedSourceSummary?.contains("Playback interrupted") == true)
        health.failed = false; health.failureMessage = nil; health.peak = 0
        publish(at: 1.2)
        #expect(telemetry.detailSources.first?.health.peak == 0)
        #expect(telemetry.interruptedSourceSummary == nil)
        health.peak = 0.2
        publish(at: 1.3)
        // A new take must never display the previous take's counters, even
        // when it starts within the diagnostic refresh interval.
        health.startedAt = 1.4; health.receivedFrames = 1; health.writtenFrames = 1
        health.lastReceivedAt = 1.4; health.lastWrittenAt = 1.4
        publish(at: 1.4)
        #expect(telemetry.detailSources.first?.health.receivedFrames == 1)
    }

    @Test func waveformRepaintsWithoutInvalidatingLayout() async throws {
        let telemetry = RecorderTelemetry()
        let host = WaveformLayoutHost(rootView: RecorderWaveformDisplay(telemetry: telemetry).frame(width: 248, height: 64))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 248, height: 64),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        defer { window.contentView = nil }
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(50))
        // Settle the native view's first content update before measuring steady
        // state. The bootstrap layout is not a per-packet layout regression.
        telemetry.waveformSamples = Array(repeating: 0.1, count: 200)
        for _ in 0..<4 {
            try await Task.sleep(for: .milliseconds(20))
            host.layoutSubtreeIfNeeded()
        }
        func pixels() throws -> Data {
            let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            return try #require(bitmap.representation(using: .png, properties: [:]))
        }
        let silence = try pixels()
        let layouts = host.layoutCount
        for step in 1...12 {
            telemetry.waveformSamples = Array(repeating: Float(step) / 12, count: 200)
            try await Task.sleep(for: .milliseconds(10))
            host.layoutSubtreeIfNeeded()
        }
        #expect(try pixels() != silence)
        #expect(host.layoutCount == layouts)
    }

    @Test func lockBackedFadersInvalidateUIReadsButNotCaptureSnapshots() {
        let defaults = UserDefaults(suiteName: "observation-levels-\(UUID())")!
        let levels = AudioLevels(defaults: defaults)
        let uiChanges = OSAllocatedUnfairLock(initialState: 0)
        let captureChanges = OSAllocatedUnfairLock(initialState: 0)
        withObservationTracking {
            _ = levels.level("master")
        } onChange: {
            uiChanges.withLock { $0 += 1 }
        }
        withObservationTracking {
            _ = levels.snapshot(for: .systemAll)
        } onChange: {
            captureChanges.withLock { $0 += 1 }
        }
        levels.set("master", .init(decibels: -6))
        #expect(uiChanges.withLock { $0 } == 1)
        #expect(captureChanges.withLock { $0 } == 0)
        #expect(levels.snapshot(for: .systemAll).master.decibels == -6)
    }

    @Test func recordingClockAndDetailTicksRepaintWithoutRelayingOutTheCapturePanel() async throws {
        let h = RecorderContractHarness()
        defer { h.cleanup() }
        await h.model.startRecording()
        defer { h.clock.stopTicking() }
        let telemetry = h.model.telemetry
        func publish(_ step: Int) {
            let time = Double(step)
            telemetry.healthTime = time
            telemetry.duration = time
            telemetry.sourceHealth = (0..<2).map { source in
                .init(id: "source-\(source)", name: source == 0 ? "System playback" : "Microphone",
                    health: .init(startedAt: 0, lastReceivedAt: time, lastWrittenAt: time,
                        receivedFrames: 999000 + Int64(step) * 400000,
                        writtenFrames: 999000 + Int64(step) * 400000,
                        sampleRate: 48000, channels: source == 0 ? 2 : 1,
                        postPeak: 0.2, mixPeak: 0.3, peak: 0.1 + Float(step % 8) / 10))
            }
            telemetry.refreshDetails()
            telemetry.waveformSamples = Array(repeating: 0.1 + Float(step % 8) / 10, count: 200)
        }
        publish(0)
        let host = WaveformLayoutHost(rootView: VStack(alignment: .leading) {
            RecorderStatusBar(state: .recording, statusText: "Recording", telemetry: telemetry)
            CaptureHealthView(recorder: h.model, telemetry: telemetry)
            RecorderWaveformSection(telemetry: telemetry)
        }.frame(width: 276))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 276, height: 650),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        defer { window.contentView = nil }
        func pixels() throws -> Data {
            let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            return try #require(bitmap.representation(using: .png, properties: [:]))
        }
        for _ in 0..<5 {
            try await Task.sleep(for: .milliseconds(20)); host.layoutSubtreeIfNeeded()
        }
        // Like the waveform test, settle the first observed content update.
        // Bootstrap sizing is separate from repeated steady-state tick layout.
        publish(1)
        for _ in 0..<5 {
            try await Task.sleep(for: .milliseconds(20)); host.layoutSubtreeIfNeeded()
        }
        let initialPixels = try pixels(), layouts = host.layoutCount
        for step in 2...25 {
            publish(step)
            try await Task.sleep(for: .milliseconds(20)); host.layoutSubtreeIfNeeded()
        }
        print("CAPTURE_LAYOUT ticks=24 ancestor_layouts=\(host.layoutCount - layouts)")
        #expect(try pixels() != initialPixels)
        #expect(host.layoutCount == layouts)
    }

    @Test func nativeReadoutKeepsFailureAndClippingDetailsAccessible() async throws {
        let telemetry = RecorderTelemetry()
        telemetry.healthTime = 1
        telemetry.sourceHealth = [.init(id: "input", name: "Microphone", health: .init(
            startedAt: 0, lastReceivedAt: 1, lastWrittenAt: 1, receivedFrames: 48000, writtenFrames: 48000,
            sampleRate: 48000, channels: 1, postPeak: 0.2, peak: 0.3))]
        telemetry.refreshDetails()
        let view = CaptureHealthDrawingView(telemetry: telemetry, sourceID: "input")
        defer { view.stopObserving() }
        telemetry.healthTime = 1.1
        telemetry.sourceHealth[0].health.failed = true
        telemetry.sourceHealth[0].health.failureMessage = "Input disconnected"
        telemetry.sourceHealth[0].health.clipped = true
        telemetry.refreshDetails()
        await waitUntil("native failure readout") {
            (view.accessibilityValue() as? String)?.contains("Input disconnected") == true
        }
        let value = try #require(view.accessibilityValue() as? String)
        #expect(value.contains("Capture or write failed"))
        #expect(value.contains("Clipping detected"))
        #expect(telemetry.layoutSources.first?.health.failed == true)
        #expect(telemetry.layoutSources.first?.health.clipped == true)
    }

    @Test func subcontrollersReleaseNotificationObserversWithRecorder() async throws {
        let center = NotificationCenter()
        let permissions = MockPermissionProviding(.denied)
        weak var permissionOwner: PermissionCoordinator?
        weak var installOwner: InstallLocationMonitor?
        do {
            let recorder = RecorderViewModel(
                controller: MockRecordingControlling(), permissions: permissions,
                installLocation: MockInstallLocationProviding(.applications),
                defaults: UserDefaults(suiteName: "observation-owner-\(UUID())")!,
                notificationCenter: center)
            permissionOwner = recorder.permissionCoordinator
            installOwner = recorder.installLocationMonitor
        }
        #expect(permissionOwner == nil)
        #expect(installOwner == nil)
        center.post(name: NSApplication.didBecomeActiveNotification, object: nil)
        try await Task.sleep(for: .milliseconds(20))
        #expect(permissionOwner == nil)
    }

    @Test func popoverHostingResizesAndKeepsFooterOutsideBoundedScroll() async throws {
        let fixture = PopoverFixture()
        let layout = PopoverLayout(availableHeight: 500)
        let host = NSHostingController(
            rootView: PopoverFrame(layout: layout) {
                Rectangle().frame(height: fixture.height)
            } footer: {
                Text("Quit").frame(height: fixture.footer)
            })
        host.sizingOptions = [.preferredContentSize]
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: WorkspaceStyle.popoverWidth, height: 200),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentViewController = host
        defer { window.contentViewController = nil }
        func settle() async throws -> CGFloat {
            for _ in 0..<6 {
                host.view.layoutSubtreeIfNeeded()
                try await Task.sleep(for: .milliseconds(20))
            }
            return host.view.fittingSize.height
        }
        let collapsed = try await settle()
        fixture.height = 330  // Expanding controls changes the content's ideal size.
        let expanded = try await settle()
        #expect(expanded > collapsed + 100)
        fixture.height = 1200
        let capped = try await settle()
        #expect(abs(capped - 500) < 2)
        fixture.footer = 85  // Accessibility-size footer gets its own room.
        let largeFooter = try await settle()
        #expect(abs(largeFooter - 500) < 2)
        #expect(layout.scrollHeight(content: fixture.height, footer: fixture.footer) == 414)
        layout.availableHeight = 300  // Moving to a shorter screen shrinks the viewport.
        let shortScreen = try await settle()
        #expect(abs(shortScreen - 300) < 2)
        fixture.height = 140
        let collapsedAgain = try await settle()
        #expect(abs(collapsedAgain - 226) < 2)
        #expect(abs(host.preferredContentSize.height - collapsedAgain) < 2)
    }
}

@MainActor private final class WaveformLayoutHost<Content: View>: NSHostingView<Content> {
    var layoutCount = 0
    override func layout() { layoutCount += 1; super.layout() }
}

@MainActor
@Observable private final class PopoverFixture {
    var height: CGFloat = 140
    var footer: CGFloat = 50
}
