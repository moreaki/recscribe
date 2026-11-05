import AppKit
import CoreMedia
import Testing
@testable import RecScribe

@MainActor
struct CaptureSourceMenuTests {
    private let apps = [RunningAppInfo(bundleID: "app.a", applicationName: "App A"),
        RunningAppInfo(bundleID: "app.b", applicationName: "App B")]
    private let devices = [InputDeviceInfo(uid: "input.a", name: "Input A"), InputDeviceInfo(uid: "input.b", name: "Input B")]

    @Test(arguments: [AudioSource.systemAll, .app(bundleID: "app.a"), .app(bundleID: "app.gone"),
        .mic(deviceUID: "input.a"), .mic(deviceUID: "input.gone")])
    func selectionRemainsVisibleEvenWhenUnavailable(selection: AudioSource) throws {
        let context = OverflowContext(selectedSource: selection, apps: apps, selectedAppName: "Missing App",
            inputDevices: devices, selectedMicName: "Missing Input")
        let definition = OverflowMenu()
        let rows = definition.captureSourceEntries(context)
        let rootChecks = rows.filter {
            switch $0 {
            case .action(let row): return row.isSourceRow && row.isChecked
            case .submenu(let menu): return menu.isChecked
            default: return false
            }
        }
        #expect(rootChecks.count == 1)
        let actions = definition.actions(context)
        let checked = actions.filter { $0.isChecked && $0.isSourceRow }
        #expect(!checked.isEmpty)
        if selection.appBundleID == "app.gone" || selection.microphoneUID == "input.gone" {
            let missing = try #require(checked.first { !$0.isEnabled })
            #expect(missing.title.contains("Missing"))
        }
        let locked = OverflowContext(selectedSource: selection, allowsCaptureSourceChange: false,
            apps: apps, inputDevices: devices)
        #expect(definition.captureSourceEntries(locked).isEmpty)
        #expect(!definition.actions(locked).contains { $0.isSourceRow })
        #expect(Set(definition.actions(locked).map(\.id)).isSuperset(of: ["showWindow", "about", "recordings", "quit"]))
    }

    @Test func permissionAndDiscoveryStatesHaveDistinctRecoveryPaths() throws {
        var requests = 0
        let definition = OverflowMenu(onRequestPermission: { requests += 1 })
        let denied = definition.perAppSubmenu(.init(permissionGranted: false, apps: apps))
        let request = try #require(denied.entries.compactMap { if case .action(let row) = $0 { row } else { nil } }.first)
        #expect(request.isEnabled)
        request.perform()
        #expect(requests == 1)
        #expect(!definition.actions(.init(permissionGranted: false, apps: apps)).contains { $0.id.hasPrefix("sourceApp:") })
        func notices(_ rows: [OverflowEntry]) -> [String] {
            rows.compactMap { if case .disabledNotice(let text) = $0 { text } else { nil } }
        }
        #expect(notices(definition.perAppSubmenu(.init(apps: nil)).entries) == ["Looking for open apps…"])
        #expect(notices(definition.perAppSubmenu(.init(apps: [])).entries) == ["No other apps are open"])
        #expect(notices(definition.microphoneSubmenu(.init()).entries) == ["No microphones found"])
        let microphone = definition.microphoneSubmenu(.init(permissionGranted: false, inputDevices: devices))
        #expect(microphone.entries.count == 2)
    }

    @Test(arguments: [true, false])
    func openingAppMenuUsesCacheAndOnlyRefreshesWithPermission(granted: Bool) async {
        let source = MockAudioSourceProviding()
        source.availableAppsResult = apps
        let cache = PerAppListCache()
        let delegate = PerAppMenuDelegate(cache: cache, source: source,
            makeContext: { OverflowContext(permissionGranted: granted, apps: cache.apps) })
        let menu = NSMenu()
        delegate.menuNeedsUpdate(menu)
        #expect(menu.items.map(\.title) == [granted ? "Looking for open apps…" : "Allow Screen Recording…"])
        if granted {
            await waitUntil("refresh completes") { source.availableAppsCallCount == 1 && menu.items.count == 2 }
            #expect(menu.items.map(\.title) == ["App A", "App B"])
        } else {
            await settle()
            #expect(source.availableAppsCallCount == 0)
        }
    }
}

@MainActor
struct AudioCapableFilterTests {
    @Test(.timeLimit(.minutes(1))) func hardwareQueryFinishesAndReturnsValidIdentifiersWhenAvailable() {
        if let identifiers = AudioCapableProcesses().audioCapableBundleIDs() {
            #expect(identifiers.allSatisfy { !$0.isEmpty })
        }
        #expect(AudioSourceManager.alwaysExcludedBundleIDs.contains("com.apple.finder"))
        #expect(!AudioSourceManager.alwaysExcludedBundleIDs.contains("com.apple.Terminal"))
    }

    @Test("Nested browser helper bundles and WebKit XPC processes resolve to their enclosing app bundle ID (#16)")
    func helperProcessesResolveToEnclosingBrowserBundleID() {
        let chromeHelperURL = URL(fileURLWithPath: "/Applications/Google Chrome.app/Contents/Frameworks/Google Chrome Framework.framework/Versions/130.0/Helpers/Google Chrome Helper (Renderer).app")
        let resolvedChrome = AudioCapableProcesses.enclosingAppBundleIDs(
            bundleURL: chromeHelperURL,
            directBundleID: "com.google.Chrome.helper.renderer",
            bundleIdentifierLookup: { url in
                url.path == "/Applications/Google Chrome.app" ? "com.google.Chrome" : nil
            }
        )
        #expect(resolvedChrome.contains("com.google.Chrome"))
        #expect(resolvedChrome.contains("com.google.Chrome.helper.renderer"))

        let firefoxPluginExecutable = URL(fileURLWithPath: "/Applications/Firefox.app/Contents/MacOS/plugin-container.app/Contents/MacOS/plugin-container")
        let resolvedFirefox = AudioCapableProcesses.enclosingAppBundleIDs(
            bundleURL: nil,
            executableURL: firefoxPluginExecutable,
            directBundleID: "org.mozilla.plugincontainer",
            bundleIdentifierLookup: { url in
                url.path == "/Applications/Firefox.app" ? "org.mozilla.firefox" : nil
            }
        )
        #expect(resolvedFirefox.contains("org.mozilla.firefox"))

        let resolvedSafariWebKit = AudioCapableProcesses.enclosingAppBundleIDs(
            bundleURL: URL(fileURLWithPath: "/System/Library/Frameworks/WebKit.framework/Versions/A/XPCServices/com.apple.WebKit.GPU.xpc"),
            directBundleID: "com.apple.WebKit.GPU"
        )
        #expect(resolvedSafariWebKit.contains("com.apple.Safari"))
    }

    @Test("Idle user-facing apps stay selectable before a call while audio-active apps sort first and badge (#16)")
    func idleBrowsersStaySelectableAndActiveAppsSortFirst() {
        let candidates: [(bundleID: String, applicationName: String)] = [
            ("com.apple.finder", "Finder"),
            ("com.moreaki.recscribe", "RecScribe"),
            ("com.apple.Safari", "Safari"),
            ("com.google.Chrome", "Google Chrome"),
            ("com.cisco.webexmeetingsapp", "Webex")
        ]
        let userFacing: Set<String> = [
            "com.apple.finder",
            "com.moreaki.recscribe",
            "com.apple.Safari",
            "com.google.Chrome",
            "com.cisco.webexmeetingsapp"
        ]
        let filtered = AudioSourceManager.filterAndSortAvailableApps(
            candidates: candidates,
            userFacingBundleIDs: userFacing,
            audioActiveBundleIDs: ["com.cisco.webexmeetingsapp"],
            ownBundleID: "com.moreaki.recscribe"
        )
        #expect(filtered.map(\.bundleID) == [
            "com.cisco.webexmeetingsapp",
            "com.google.Chrome",
            "com.apple.Safari"
        ])
        #expect(filtered.first?.isAudioActive == true)
        #expect(filtered.dropFirst().allSatisfy { !$0.isAudioActive })

        let submenu = OverflowMenu().perAppSubmenu(
            OverflowContext(
                selectedSource: .systemAll,
                permissionGranted: true,
                apps: filtered
            )
        )
        let titles = submenu.entries.compactMap { entry -> String? in
            if case .action(let action) = entry { return action.title }
            return nil
        }
        #expect(titles == [
            "Webex · Playing audio",
            "Google Chrome",
            "Safari"
        ])
    }

    @Test("matchingApplications includes all SCRunningApplication instances for a bundle ID (#16)")
    func matchingApplicationsIncludesAllInstances() throws {
        struct StubApp: Equatable {
            let pid: Int
            let bundleIdentifier: String
        }
        let running = [
            StubApp(pid: 101, bundleIdentifier: "com.google.Chrome"),
            StubApp(pid: 102, bundleIdentifier: "com.apple.Safari"),
            StubApp(pid: 103, bundleIdentifier: "com.google.Chrome")
        ]
        let matched = try ScreenCaptureAudioManager.matchingApplications(
            in: running,
            bundleID: "com.google.Chrome",
            bundleIdentifier: \.bundleIdentifier
        )
        #expect(matched.map(\.pid) == [101, 103])
        #expect(throws: ScreenCaptureAudioError.self) {
            try ScreenCaptureAudioManager.matchingApplications(
                in: running,
                bundleID: "com.missing.app",
                bundleIdentifier: \.bundleIdentifier
            )
        }
    }

    @Test("AudioSource validates every input route and routes custom channel selections through the lossless multi-source path (#40)")
    @MainActor
    func audioSourceValidatesAllInputsAndRoutesCustomChannelsThroughMultiSource() async throws {
        // 1. One-device default inputsOnly is .microphone and valid.
        let oneDefault = AudioSource.inputsOnly([InputSelection(deviceUID: "mic-1")])
        #expect(oneDefault.kind == .microphone)
        #expect(!oneDefault.usesMultiInputRouting)
        #expect(!oneDefault.isMixed)
        #expect(oneDefault.valid)

        // 2. Multi-device inputsOnly is .multiple and valid.
        let manyInputs = AudioSource.inputsOnly([
            InputSelection(deviceUID: "mic-1"),
            InputSelection(deviceUID: "mic-2")
        ])
        #expect(manyInputs.kind == .multiple)
        #expect(manyInputs.usesMultiInputRouting)
        #expect(manyInputs.isMixed)
        #expect(manyInputs.valid)

        // 3. Single-device inputsOnly with custom channel routes uses the lossless multi-source path (.multiple).
        let customRouteInput = InputSelection(
            deviceUID: "interface-1",
            routes: [.init(channel: 1, placement: .right)]
        )
        let customInputsOnly = AudioSource.inputsOnly([customRouteInput])
        #expect(customRouteInput.hasCustomRoutes)
        #expect(customInputsOnly.kind == .multiple)
        #expect(customInputsOnly.usesMultiInputRouting)
        #expect(customInputsOnly.isMixed)
        #expect(!customInputsOnly.requiresScreenCapture)
        #expect(customInputsOnly.microphoneUID == nil)
        #expect(customInputsOnly.valid)

        // Verify RecordingController routes customInputsOnly through setupMultiCapture (lossless MultiSourceRecorder).
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("custom-route-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let capture = MockAudioCapturing()
        let provider = MockAudioSourceProviding(selectedSource: customInputsOnly)
        provider.availableInputDevicesResult = [
            InputDeviceInfo(uid: "interface-1", name: "Audio Interface", inputChannels: 2, sampleRate: 48_000)
        ]
        let controller = RecordingController(
            captureManager: capture,
            saveLocation: MockSaveLocationProviding(directory: dir),
            audioSource: provider,
            levels: AudioLevels(defaults: UserDefaults(suiteName: "custom-route-\(UUID())")!)
        )
        let audio = try await controller.startRecording()
        #expect(capture.setupCount == 1)
        #expect(capture.lastSource == customInputsOnly)
        let now = CMClockGetTime(CMClockGetHostTimeClock()).seconds
        let stereoFrame = SampleBufferFixtures.makePCMBuffer(channels: 2, frames: 480, interleaved: false) { ch, _ in ch == 1 ? 0.5 : 0.1 }
        capture.emit(.init(track: .input("interface-1"), presentationTime: now, buffer: stereoFrame))
        capture.emit(.init(track: .input("interface-1"), presentationTime: now + 0.01, buffer: stereoFrame))
        _ = try await controller.stopRecording()
        let parentSession = try RecordingSession.read(RecordingSession.manifestURL(for: audio))
        #expect(parentSession.sourceTracks?.count == 1)
        #expect(parentSession.sourceTracks?.first?.role == .input("interface-1"))
        #expect(parentSession.sourceTracks?.first?.channelRoutes == [.init(channel: 1, placement: .right)])

        // 4. Invalid routes (negative, duplicate, oversized channel, >32 routes) fail validation even for 1-input mic/mixed/inputsOnly.
        let negativeRoute = InputSelection(deviceUID: "mic-1", routes: [.init(channel: -1, placement: .center)])
        let duplicateRoute = InputSelection(deviceUID: "mic-1", routes: [
            .init(channel: 0, placement: .left),
            .init(channel: 0, placement: .right)
        ])
        let oversizedChannel = InputSelection(deviceUID: "mic-1", routes: [.init(channel: 32, placement: .center)])
        let tooManyRoutes = InputSelection(
            deviceUID: "mic-1",
            routes: (0..<33).map { .init(channel: $0, placement: .center) }
        )

        for invalidInput in [negativeRoute, duplicateRoute, oversizedChannel, tooManyRoutes] {
            #expect(!invalidInput.valid)
            #expect(!AudioSource.inputsOnly([invalidInput]).valid)
            #expect(!AudioSource(playback: .none, inputs: [invalidInput], usesMultiInputRouting: false).valid)
            #expect(!AudioSource(playback: .systemAll, inputs: [invalidInput], usesMultiInputRouting: false).valid)
        }
    }
}
