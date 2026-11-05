import AppKit
import CoreMedia
import CoreAudio
import SwiftUI
import Testing
import Vision
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
                .environment(recorder).preferredColorScheme(.dark)
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

    @Test func collapsedVirtualCardShowsCaptureControlWithoutDisclosure() async throws {
        let suite = "routing-capture-checkbox-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let mic = InputDeviceInfo(uid: "mic", name: "Microphone", inputChannels: 1)
        let virtual = InputDeviceInfo(uid: "virtual", name: "Meeting loopback", inputChannels: 2,
            transport: kAudioDeviceTransportTypeVirtual)
        let original = InputSelection(deviceUID: virtual.uid, routes: [.init(channel: 1, placement: .right)])
        let source = AudioSource.multiple(appBundleID: nil, inputs: [.init(device: mic), original])
        let provider = MockAudioSourceProviding(selectedSource: source)
        provider.availableInputDevicesResult = [mic, virtual]
        let controller = MockRecordingControlling()
        let audio = AudioServices(defaults: defaults)
        audio.levels.set("input:virtual", .init(decibels: -3, muted: true))
        let recorder = RecorderViewModel(controller: controller, permissions: MockPermissionProviding(.granted),
            clock: ManualClock(), audioSource: provider, defaults: defaults, audio: audio)
        let view = AudioRoutingView(levels: audio.levels, monitor: audio.monitor, playbackLevels: audio.playbackLevels,
            hardwareObserver: audio.hardware).environment(recorder).preferredColorScheme(.dark)
        let host = NSHostingView(rootView: view)
        host.frame = CGRect(x: 0, y: 0, width: 760, height: 900)
        let window = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.appearance = NSAppearance(named: .darkAqua); window.contentView = host
        // Native SwiftUI controls are installed lazily. Give this fixture a real
        // AppKit backing window, offscreen, rather than relying on a local renderer cache.
        window.setFrameOrigin(NSPoint(x: -10000, y: -10000))
        window.orderFront(nil)
        defer { window.contentView = nil; window.close() }
        // Check the rendered label rather than SwiftUI's OS-dependent native
        // subview classes. This fails if capture remains hidden in disclosure.
        let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1520, pixelsHigh: 1800,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        bitmap.size = host.bounds.size
        var text = ""
        for _ in 0..<3 {
            await settle()
            host.layoutSubtreeIfNeeded()
            host.cacheDisplay(in: host.bounds, to: bitmap)
            let image = try #require(bitmap.cgImage)
            let request = VNRecognizeTextRequest()
            // Pin the legacy recognizer for CPU-only CI VMs without ANE.
            request.revision = VNRecognizeTextRequestRevision1
            request.recognitionLevel = .accurate
            request.usesCPUOnly = true
            request.recognitionLanguages = ["en-US"]
            request.usesLanguageCorrection = true
            try VNImageRequestHandler(cgImage: image).perform([request])
            text = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ")
            if text.lowercased().filter({ !$0.isWhitespace }).contains("recordmeetingloopback") { break }
        }
        #expect(text.lowercased().filter { !$0.isWhitespace }.contains("recordmeetingloopback"),
            "The collapsed card must visibly expose its capture control. Rendered text: \(text)")
        #expect(provider.selectedSource == source, "Rendering the direct control must not change capture selection")
        #expect(audio.levels.level("input:virtual") == .init(decibels: -3, muted: true))
        #expect(controller.startCount == 0)
        await audio.shutdown()
    }

    @Test(arguments: [250.0, 450.0, 720.0])
    func muteKeepsCollapsedHeadersAndExpandedFadersTheSameSize(_ width: Double) async throws {
        let suite = "routing-mute-layout-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let levels = AudioLevels(defaults: defaults)
        for title in ["System audio", "MacBook Air Microphone", "Microsoft Teams Audio"] {
            var sizes: [CGSize] = []
            for muted in [false, true, false] {
                levels.set("input:mic", .init(muted: muted))
                let header = AudioRoutingCardHeader(title: title, symbol: "mic.fill",
                    subtitle: "Hardware input · 1 channel → L + R", value: "+0.0 dB",
                    expanded: false, muted: muted, warning: nil, muteTitle: "Muted in mix", toggle: {}) {
                    AudioRoutingMuteButton(title: title, muted: muted, action: {})
                    Image(systemName: "ellipsis")
                }
                sizes.append(try await measuredSize(header, width: width))
            }
            #expect(sizes[0] == sizes[1] && sizes[1] == sizes[2], "Mute must not move this or the following cards")
        }
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
