import AppKit
import CoreAudio
import SwiftUI
import Testing
@testable import RecScribe

/// Synthetic devices and isolated settings. Windows are never ordered on screen;
/// no capture, playback or system volume changes. Opt-in PNGs support visual QA.
@MainActor
struct AudioRoutingViewTests {
    @Test(arguments: [1, 32])
    func compactAndExpandedViewsPreserveSettingsAndFitNarrowWindows(_ channels: Int) async throws {
        let suite = "recscribe-routing-view-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let levels = AudioLevels(defaults: defaults)
        levels.set("input:mic", .init(decibels: -6, muted: true))
        let playback = PlaybackLevels(defaults: defaults)
        playback.set(.init(volume: 0.75, muted: true, outputUID: "unplugged-output"))
        let monitor = CapturedAudioMonitor(defaults: defaults)
        let devices = [InputDeviceInfo(uid: "mic", name: "Studio Display Microphone", inputChannels: channels, sampleRate: 48_000),
                       InputDeviceInfo(uid: "virtual", name: "Meeting loopback", inputChannels: 2, sampleRate: 48_000, transport: kAudioDeviceTransportTypeVirtual)]
        let source = AudioSource.multiple(appBundleID: nil, inputs: devices.map(InputSelection.init(device:)))
        let provider = MockAudioSourceProviding(selectedSource: source)
        provider.availableInputDevicesResult = devices
        let controller = MockRecordingControlling()
        let recorder = RecorderViewModel(controller: controller, permissions: MockPermissionProviding(.granted),
                                         clock: ManualClock(), audioSource: provider, defaults: defaults)
        recorder.permissionStatus = .granted
        let savedLevels = levels.snapshot(for: source)
        let savedPlayback = playback.value
        let savedMonitor = monitor.levels.value
        let panels: [(String, AudioRoutingPanel?)] = [
            ("compact-overview", nil), ("playback-gain", .playback), ("input-expanded", .input("mic")),
            ("mix-expanded", .mix), ("monitor-expanded", .monitor), ("output-expanded", .recordingPlayback)
        ]

        for (name, panel) in panels {
            let root = AudioRoutingView(levels: levels, monitor: monitor, playbackLevels: playback, expandedPanel: panel)
                .environmentObject(recorder).preferredColorScheme(.dark)
            let hosting = NSHostingView(rootView: root)
            hosting.frame = CGRect(origin: .zero, size: CGSize(width: 1120, height: panel == nil ? 500 : 700))
            let window = NSWindow(contentRect: hosting.frame, styleMask: .borderless, backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: .darkAqua)
            window.contentView = hosting
            defer { window.contentView = nil; window.close() }

            func render(_ name: String) async throws {
                try await Task.sleep(for: .milliseconds(100))
                hosting.layoutSubtreeIfNeeded()
                let bitmap = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
                hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
                #expect(hosting.fittingSize.width <= hosting.frame.width + 1)
                if let path = ProcessInfo.processInfo.environment["ROUTING_SNAPSHOTS"] {
                    let folder = URL(fileURLWithPath: path)
                    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                    let filename = (channels == 1 ? "" : "32-channels-") + name + ".png"
                    try #require(bitmap.representation(using: .png, properties: [:])).write(to: folder.appendingPathComponent(filename))
                }
            }
            try await render(name)
            func gainControls(_ view: NSView) -> [GainSliderControl] {
                (view as? GainSliderControl).map { [$0] } ?? view.subviews.flatMap(gainControls)
            }
            let controls = gainControls(hosting)
            let hasGain = panel == .playback || panel == .input("mic") || panel == .mix
            #expect(controls.count == (hasGain ? 1 : 0), "Only the selected card should construct a gain control")
            if panel == .input("mic") { #expect(controls.first?.doubleValue == -6) }
            hosting.frame.size = CGSize(width: 760, height: 700)
            try await render(name + "-narrow")
        }
        // Rendering/disclosing must never rewrite capture selection or settings.
        #expect(provider.setCount == 0)
        #expect(provider.selectedSource == source)
        #expect(levels.snapshot(for: source) == savedLevels)
        #expect(playback.value == savedPlayback)
        #expect(monitor.levels.value == savedMonitor)
        #expect(!monitor.enabled)
        #expect(controller.startCount == 0)
    }
}
