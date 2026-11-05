import AppKit
import CoreMedia
import CoreAudio
import SwiftUI
import Testing
@testable import RecScribe

/// Synthetic devices and isolated settings. Windows are never ordered on screen;
/// no capture, playback or system volume changes. Opt-in PNGs support visual QA.
@MainActor
struct AudioRoutingViewTests {
    @Test(arguments: [1, 32])
    func compactSourcesAndMixOutputsPreserveSettingsAndFitNarrowWindows(_ channels: Int) async throws {
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
        let appearances: [(String, ColorScheme, NSAppearance.Name)] = [
            ("focus-light", .light, .aqua), ("focus-dark", .dark, .darkAqua)
        ]
        for (name, scheme, appearance) in appearances {
            let root = AudioRoutingView(levels: levels, monitor: monitor, playbackLevels: playback, embeddedInStudio: true)
                .environment(recorder).preferredColorScheme(scheme)
            let hosting = NSHostingView(rootView: root)
            hosting.frame = CGRect(origin: .zero, size: CGSize(width: 1120, height: 700))
            let window = NSWindow(contentRect: hosting.frame, styleMask: .borderless, backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: appearance)
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
            for width in [760.0, 620.0] {
                hosting.frame.size = CGSize(width: width, height: 700)
                try await render(name + "-\(Int(width))")
            }
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

    @Test(arguments: [250.0, 450.0, 720.0])
    func muteKeepsRecordingFadersTheSameSize(_ width: Double) async throws {
        let suite = "routing-mute-layout-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let levels = AudioLevels(defaults: defaults)
        levels.set("input:mic", .init())
        let fader = SourceFader(id: "input:mic", title: "Input gain", levels: levels, channels: 1, preservesSources: true, showsMuteToggle: false)
        let before = try await measuredSize(fader, width: width)
        levels.set("input:mic", .init(muted: true))
        let after = try await measuredSize(fader, width: width)
        #expect(before == after, "Expanded controls must also retain their height")
    }

    @Test func collapsedSourcesShowTestMetersWhileStartingAndWhileMuted() async throws {
        let suite = "routing-live-meters-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let levels = AudioLevels(defaults: defaults)
        levels.set("input:mic", .init(muted: true))
        let playback = PlaybackLevels(defaults: defaults)
        let monitor = CapturedAudioMonitor(defaults: defaults)
        let capture = MockAudioCapturing()
        let devices = [InputDeviceInfo(uid: "mic", name: "MacBook Air Microphone", inputChannels: 1, sampleRate: 48_000)]
        let provider = MockAudioSourceProviding(selectedSource: .multiple(appBundleID: nil, inputs: devices.map(InputSelection.init(device:))))
        provider.availableInputDevicesResult = devices
        let test = AudioTestController(capture: capture, source: provider, permissions: MockPermissionProviding(.granted),
            levels: levels, monitor: monitor, saveDirectory: { FileManager.default.temporaryDirectory })
        var continueSetup: CheckedContinuation<Void, Never>?
        capture.beforeSetup = { await withCheckedContinuation { continueSetup = $0 } }
        let starting = Task { await test.startPreview() }
        await waitUntil("test setup suspended") { continueSetup != nil }
        #expect(test.state == .starting && test.health.isEmpty)
        let waitingSize = try await measuredSize(AudioTestSourceMeterView(test: test, track: .input("mic"), muted: true), width: 350)
        #expect(waitingSize.height > 60, "Both meters and waiting status must be visible before any data arrives")
        continueSetup?.resume(); await starting.value
        let epoch = CMClockGetTime(CMClockGetHostTimeClock()).seconds
        for index in 0..<20 {
            for track in [CaptureTrack.playback, .input("mic")] {
                let pcm = SampleBufferFixtures.makePCMBuffer(channels: track == .playback ? 2 : 1, frames: 480, interleaved: false) { _, _ in 0.4 }
                capture.emit(.init(track: track, presentationTime: epoch + Double(index) / 100, buffer: pcm))
            }
        }
        await waitUntil("raw muted-source signal displayed") { test.meters[.input("mic")]?.raw.hold.first == 0.4 }
        #expect(test.meters[.input("mic")]?.processed.peaks.first == 0)
        let recorder = RecorderViewModel(controller: MockRecordingControlling(), permissions: MockPermissionProviding(.granted),
            clock: ManualClock(), audioSource: provider, defaults: defaults, audioTest: test)
        recorder.permissionStatus = .granted
        let root = AudioRoutingView(levels: levels, monitor: monitor, playbackLevels: playback)
            .environment(recorder).preferredColorScheme(.dark)
        _ = try await measuredSize(root.frame(height: 760), width: 1120, snapshot: "collapsed-test-meters")
        await test.stop()
        #expect(test.state == .idle)
        let stopped = try await measuredSize(AudioTestSourceMeterView(test: test, track: .input("mic"), muted: true), width: 350)
        #expect(stopped.height > 60, "Last levels remain visible after stopping the test")
        _ = try await measuredSize(root.frame(height: 760), width: 760, snapshot: "collapsed-test-stopped")
        await test.close()
    }

    private func measuredSize<Content: View>(_ view: Content, width: Double, snapshot: String? = nil) async throws -> CGSize {
        let hosting = NSHostingView(rootView: view.frame(width: width).fixedSize(horizontal: false, vertical: true))
        hosting.frame = CGRect(x: 0, y: 0, width: width, height: 800)
        let window = NSWindow(contentRect: hosting.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = hosting
        defer { window.contentView = nil; window.close() }
        try await Task.sleep(for: .milliseconds(40))
        hosting.layoutSubtreeIfNeeded()
        let size = hosting.fittingSize
        if let snapshot, let path = ProcessInfo.processInfo.environment["ROUTING_SNAPSHOTS"] {
            let folder = URL(fileURLWithPath: path)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let bitmap = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
            hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
            try #require(bitmap.representation(using: .png, properties: [:])).write(to: folder.appendingPathComponent(snapshot + ".png"))
        }
        return size
    }

    @Test("Acknowledging duplicate/loopback routes resets when inputs or playback change and requires renewed confirmation")
    func duplicateRouteAcknowledgmentResetsWhenRouteGraphChanges() {
        let safeMic = InputSelection(deviceUID: "mic-1")
        let loopbackA = InputSelection(deviceUID: "virtual-loopback-a")
        let loopbackB = InputSelection(deviceUID: "virtual-loopback-b")

        // 1. Start with a graph containing one loopback device, unacknowledged.
        let initial = AudioSource.multiple(
            appBundleID: nil,
            inputs: [safeMic, loopbackA],
            allowDuplicateRoutes: false
        )
        #expect(!initial.allowDuplicateRoutes)

        // 2. User acknowledges duplicate/loopback routes for the reviewed graph.
        let acknowledged = AudioRoutingView.makeUpdatedSource(
            from: initial,
            inputs: [safeMic, loopbackA],
            acknowledge: true
        )
        #expect(acknowledged.allowDuplicateRoutes)

        // 3. Unchanged route graph (e.g. no-op save) preserves acknowledgment.
        let unchanged = AudioRoutingView.makeUpdatedSource(
            from: acknowledged,
            inputs: [safeMic, loopbackA]
        )
        #expect(unchanged.allowDuplicateRoutes)

        // 4. Adding a new risky loopback device resets allowDuplicateRoutes and requires renewed confirmation.
        let addedRisky = AudioRoutingView.makeUpdatedSource(
            from: acknowledged,
            inputs: [safeMic, loopbackA, loopbackB]
        )
        #expect(!addedRisky.allowDuplicateRoutes)

        // 5. Replacing a risky device with another risky device resets allowDuplicateRoutes.
        let replacedRisky = AudioRoutingView.makeUpdatedSource(
            from: acknowledged,
            inputs: [safeMic, loopbackB]
        )
        #expect(!replacedRisky.allowDuplicateRoutes)

        // 6. Changing channel routing on an input resets allowDuplicateRoutes.
        var editedLoopback = loopbackA
        editedLoopback.routes = [.init(channel: 1, placement: .right)]
        let editedChannelGraph = AudioRoutingView.makeUpdatedSource(
            from: acknowledged,
            inputs: [safeMic, editedLoopback]
        )
        #expect(!editedChannelGraph.allowDuplicateRoutes)

        // 7. Changing playback mode (e.g. inputs-only -> systemAll) resets allowDuplicateRoutes.
        let inputsOnlyAck = AudioSource.inputsOnly([safeMic, loopbackA], allowDuplicateRoutes: true)
        let playbackAdded = AudioRoutingView.makeUpdatedSource(
            from: inputsOnlyAck,
            inputs: [safeMic, loopbackA],
            playbackState: .systemAll
        )
        #expect(!playbackAdded.allowDuplicateRoutes)
    }
}
