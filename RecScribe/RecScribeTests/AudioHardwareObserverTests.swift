import CoreAudio
import Foundation
import Testing
@testable import RecScribe

@MainActor
private final class MockAudioHardwareBackend: AudioHardwareBackend {
    private nonisolated final class Token: HardwareListenerToken {
        let hasRegistrationFailure: Bool
        init(hasRegistrationFailure: Bool) {
            self.hasRegistrationFailure = hasRegistrationFailure
        }
    }

    var currentInputs: [InputDeviceInfo] = []
    var currentOutputs: [AudioOutputDevice] = []
    var currentDefaultInputUID: String?
    var currentDefaultOutputUID: String?
    var deviceIDsByUID: [String: AudioDeviceID] = [:]
    var simulateSystemRegistrationFailure = false
    var simulateDeviceRegistrationFailure = false

    private(set) var systemListeners: [ObjectIdentifier: @Sendable () -> Void] = [:]
    private(set) var deviceListeners: [ObjectIdentifier: (deviceID: AudioDeviceID, inputScope: Bool, includeVolumes: Bool, handler: @Sendable () -> Void)] = [:]
    private(set) var totalSystemRegistrations = 0
    private(set) var totalSystemRemovals = 0
    private(set) var totalDeviceRegistrations = 0
    private(set) var totalDeviceRemovals = 0

    func inputDevices() -> [InputDeviceInfo] { currentInputs }
    func outputDevices() -> [AudioOutputDevice] { currentOutputs }
    func defaultInputUID() -> String? { currentDefaultInputUID }
    func defaultOutputUID() -> String? { currentDefaultOutputUID }
    func deviceID(forUID uid: String) -> AudioDeviceID? { deviceIDsByUID[uid] }

    func addSystemListener(_ handler: @escaping @Sendable () -> Void) -> AnyObject {
        let token = Token(hasRegistrationFailure: simulateSystemRegistrationFailure)
        systemListeners[ObjectIdentifier(token)] = handler
        totalSystemRegistrations += 1
        return token
    }

    func removeSystemListener(_ token: AnyObject) {
        if systemListeners.removeValue(forKey: ObjectIdentifier(token)) != nil {
            totalSystemRemovals += 1
        }
    }

    func addDeviceListener(
        deviceID: AudioDeviceID,
        inputScope: Bool,
        includeVolumes: Bool,
        handler: @escaping @Sendable () -> Void
    ) -> AnyObject {
        let token = Token(hasRegistrationFailure: simulateDeviceRegistrationFailure)
        deviceListeners[ObjectIdentifier(token)] = (
            deviceID: deviceID,
            inputScope: inputScope,
            includeVolumes: includeVolumes,
            handler: handler
        )
        totalDeviceRegistrations += 1
        return token
    }

    func removeDeviceListener(_ token: AnyObject) {
        if deviceListeners.removeValue(forKey: ObjectIdentifier(token)) != nil {
            totalDeviceRemovals += 1
        }
    }

    func fireSystemEvent() {
        for listener in systemListeners.values {
            listener()
        }
    }

    func fireDeviceEvent(deviceID: AudioDeviceID) {
        for entry in deviceListeners.values where entry.deviceID == deviceID {
            entry.handler()
        }
    }
}

@MainActor
private final class StubInputDeviceEnumerator: InputDeviceEnumerating {
    var devices: [InputDeviceInfo]
    init(_ devices: [InputDeviceInfo]) { self.devices = devices }
    func availableInputDevices() -> [InputDeviceInfo] { devices }
}

@MainActor
struct AudioHardwareObserverTests {
    @Test func previewRebuildWaitsForSameUIDAndHardwareEventsNeverRestartHealthyOrRecordingCapture() async throws {
        let backend = MockAudioHardwareBackend()
        let device = InputDeviceInfo(uid: "preview-mic", name: "Preview input", inputChannels: 2)
        backend.currentInputs = [device]
        let hardware = AudioHardwareObserver(backend: backend)
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let capture = MockAudioCapturing()
        let source = MockAudioSourceProviding(selectedSource: .inputsOnly([.init(device: device)]))
        source.availableInputDevicesResult = [device]
        let test = AudioTestController(capture: capture, source: source, permissions: MockPermissionProviding(.granted),
            levels: AudioLevels(defaults: defaults), monitor: CapturedAudioMonitor(defaults: defaults, hardwareObserver: hardware),
            saveDirectory: { FileManager.default.temporaryDirectory }, hardwareObserver: hardware)
        await test.startPreview()
        #expect(capture.startCount == 1 && test.state == .testing)
        backend.fireSystemEvent()
        await settle()
        #expect(capture.startCount == 1) // A healthy graph ignores unrelated hardware events.
        source.availableInputDevicesResult = []
        backend.currentInputs = []
        capture.onSourceFailure?(.input(device.uid), "Selected input disconnected")
        backend.fireSystemEvent()
        await settle()
        #expect(capture.startCount == 1 && test.previewRebuildCount == 0)
        // A different UID with the same display name must never substitute for it.
        source.availableInputDevicesResult = [.init(uid: "different", name: device.name, inputChannels: 2)]
        backend.fireSystemEvent(); await settle()
        #expect(capture.startCount == 1)
        source.availableInputDevicesResult = [device]; backend.currentInputs = [device]
        backend.fireSystemEvent()
        await waitUntil("same-UID preview restart") { capture.startCount == 2 && test.state == .testing }
        #expect(test.previewRebuildCount == 1 && test.notice?.contains("reconnected") == true)
        for expected in 2...3 {
            capture.onSourceFailure?(.input(device.uid), "Input audio format changed")
            await waitUntil("bounded format restart") { test.previewRebuildCount == expected && capture.startCount == expected + 1 && test.state == .testing }
        }
        capture.onSourceFailure?(.input(device.uid), "Input audio format changed")
        backend.fireSystemEvent(); await settle()
        #expect(capture.startCount == 4 && test.previewRebuildCount == 3)
        #expect(test.notice?.contains("limit") == true)
        await test.prepareForRecording()
        backend.fireSystemEvent(); await settle()
        #expect(capture.startCount == 4 && !capture.capturing)
        await test.close()
        hardware.stopObserving()
    }

    @Test func appOwnedAudioGraphSharesHardwareAndUnregistersOnShutdown() async {
        let backend = MockAudioHardwareBackend()
        let hardware = AudioHardwareObserver(backend: backend)
        let audio = AudioServices(defaults: UserDefaults(suiteName: UUID().uuidString)!, hardware: hardware)
        let first = audio.makePlayback(), second = audio.makePlayback()
        #expect(first.hardwareObserver === hardware && second.hardwareObserver === hardware)
        #expect(backend.totalSystemRegistrations == 1)
        await audio.shutdown()
        #expect(!hardware.isObserving)
        #expect(backend.totalSystemRemovals == 1)
    }


    @Test("System and per-device Core Audio listener registration, coalescing, volume scoping, and teardown (#42)")
    func observerCoalescesEventsAndScopesDeviceListeners() async {
        let backend = MockAudioHardwareBackend()
        backend.currentInputs = [InputDeviceInfo(uid: "usb-mic", name: "USB Mic", inputChannels: 2, sampleRate: 48_000)]
        backend.currentOutputs = [AudioOutputDevice(uid: "speakers", name: "MacBook Pro Speakers", sampleRate: 48_000)]
        backend.currentDefaultInputUID = "usb-mic"
        backend.currentDefaultOutputUID = "speakers"
        backend.deviceIDsByUID = ["usb-mic": 42, "speakers": 84]

        let observer = AudioHardwareObserver(backend: backend)
        #expect(observer.inputDevices.map(\.uid) == ["usb-mic"])
        #expect(observer.outputDevices.map(\.uid) == ["speakers"])
        #expect(observer.defaultOutputUID == "speakers")
        #expect(backend.systemListeners.count == 1)
        #expect(backend.deviceListeners.isEmpty)

        var micNotifications = 0
        let micToken = observer.watchDevice(uid: "usb-mic", inputScope: true, includeVolumes: false) {
            micNotifications += 1
        }
        #expect(backend.deviceListeners.count == 1)
        #expect(backend.deviceListeners.values.first?.includeVolumes == false)

        var volumeNotifications = 0
        let volumeToken = observer.watchDevice(uid: "speakers", inputScope: false, includeVolumes: true) {
            volumeNotifications += 1
        }
        #expect(backend.deviceListeners.count == 2)
        #expect(backend.deviceListeners.values.contains { $0.deviceID == 84 && $0.includeVolumes == true })

        // Rapid device events coalesce onto a single flush.
        backend.fireDeviceEvent(deviceID: 42)
        backend.fireDeviceEvent(deviceID: 42)
        observer.flushPendingNotifications()
        #expect(micNotifications == 1)
        #expect(volumeNotifications == 0)

        // System topology update rebinds changed AudioDeviceIDs and updates published snapshots.
        backend.currentOutputs = [
            AudioOutputDevice(uid: "speakers", name: "MacBook Pro Speakers", sampleRate: 48_000),
            AudioOutputDevice(uid: "headphones", name: "Studio Headphones", sampleRate: 48_000)
        ]
        backend.currentDefaultOutputUID = "headphones"
        backend.deviceIDsByUID["usb-mic"] = 99
        backend.fireSystemEvent()
        observer.flushPendingNotifications()

        #expect(observer.outputDevices.map(\.uid) == ["speakers", "headphones"])
        #expect(observer.defaultOutputUID == "headphones")
        #expect(micNotifications == 2)
        #expect(backend.deviceListeners.values.contains { $0.deviceID == 99 && $0.inputScope == true })

        observer.unwatchDevice(volumeToken)
        #expect(backend.deviceListeners.count == 1)

        observer.unwatchDevice(micToken)
        #expect(backend.deviceListeners.isEmpty)

        observer.stopObserving()
        #expect(backend.systemListeners.isEmpty)
        #expect(backend.totalSystemRemovals == 1)
    }

    @Test("Headphone unplug during live monitoring mutes/disables monitoring instead of falling back to speakers (#36)")
    func headphoneUnplugDisablesLiveMonitoringWithoutSpeakerFallback() throws {
        let suite = "recscribe-monitor-safety-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let backend = MockAudioHardwareBackend()
        backend.currentOutputs = [
            AudioOutputDevice(uid: "speakers", name: "Built-in Speakers", sampleRate: 48_000),
            AudioOutputDevice(uid: "headphones", name: "External Headphones", sampleRate: 48_000)
        ]
        backend.currentDefaultOutputUID = "speakers"
        backend.deviceIDsByUID = ["speakers": 10, "headphones": 20]

        let observer = AudioHardwareObserver(backend: backend)
        var configuredRoutes: [String?] = []
        let monitor = CapturedAudioMonitor(
            defaults: defaults,
            hardwareObserver: observer,
            isLoopbackCheck: { _ in false },
            startEngineAction: { uid, _, _ in
                configuredRoutes.append(uid)
            }
        )

        monitor.levels.set(.init(volume: 0.6, muted: false, outputUID: "headphones"))
        monitor.setEnabled(true, source: .systemAll)
        #expect(monitor.enabled)
        #expect(monitor.warning == nil)
        #expect(configuredRoutes == ["headphones"])

        // Unplug headphones while built-in speakers remain default output.
        backend.currentOutputs = [
            AudioOutputDevice(uid: "speakers", name: "Built-in Speakers", sampleRate: 48_000)
        ]
        backend.deviceIDsByUID.removeValue(forKey: "headphones")
        observer.refreshNow()

        // Must immediately disable monitoring and warn — never configure "speakers".
        #expect(!monitor.enabled)
        #expect(monitor.warning?.localizedCaseInsensitiveContains("speaker feedback") == true)
        #expect(!configuredRoutes.contains("speakers"))
    }

    @Test("Aggregate sub-device membership changes are rejected by validation and configuration policy (#36)")
    func aggregateSubDeviceChangesAreDetected() async throws {
        let suite = "recscribe-aggregate-safety-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let initialAggregate = InputDeviceInfo(
            uid: "agg-1",
            name: "Podcast Aggregate",
            inputChannels: 2,
            sampleRate: 48_000,
            transport: kAudioDeviceTransportTypeAggregate,
            channelLabels: ["Host", "Guest"],
            aggregateMembers: ["mic-a", "mic-b"]
        )
        let selection = InputSelection(device: initialAggregate)
        #expect(selection.aggregateMembers == ["mic-a", "mic-b"])

        // Same UID and same total channel count (2), but sub-device order was swapped.
        let editedAggregate = InputDeviceInfo(
            uid: "agg-1",
            name: "Podcast Aggregate",
            inputChannels: 2,
            sampleRate: 48_000,
            transport: kAudioDeviceTransportTypeAggregate,
            channelLabels: ["Guest", "Host"],
            aggregateMembers: ["mic-b", "mic-a"]
        )
        let enumerator = StubInputDeviceEnumerator([editedAggregate])
        let manager = AudioSourceManager(
            defaults: defaults,
            deviceEnumerator: enumerator
        )
        let source = AudioSource.inputsOnly([selection], allowDuplicateRoutes: true)
        await #expect(throws: SessionError.self) {
            try await manager.validate(source)
        }

        let policy = DeviceInputConfigurationPolicy()
        let decision = policy.evaluate(
            connected: true,
            sameDevice: true,
            sameFormat: true,
            sameAggregateMembers: false,
            running: true,
            receivedFrames: 4800
        )
        #expect(decision == .aggregateChanged)
        #expect(decision.message.localizedCaseInsensitiveContains("aggregate"))
    }

    @Test("Mid-recording interrupted source surfaces summary and one-click new take action (#36)")
    func midRecordingInterruptedSourceAndStopAndStartNewTake() async {
        let controller = MockRecordingControlling()
        let permissions = MockPermissionProviding(.granted)
        let vm = RecorderViewModel(
            controller: controller,
            permissions: permissions,
            clock: ManualClock()
        )
        vm.permissionStatus = .granted
        await vm.startRecording()
        #expect(vm.isRecording)
        #expect(!vm.hasInterruptedSource)

        var failedHealth = RecordingHealth()
        failedHealth.failed = true
        failedHealth.failureMessage = "Input disconnected; its track is incomplete. Other sources continue."
        controller.sourceHealth = [
            SourceRecordingHealth(
                id: "input:usb-mic",
                name: "USB Mic",
                detail: "usb-mic",
                health: failedHealth
            )
        ]
        vm.refreshCaptureHealth()

        #expect(vm.hasInterruptedSource)
        #expect(vm.interruptedSourceSummary?.contains("USB Mic interrupted") == true)

        await vm.stopAndStartNewTake()
        #expect(controller.stopCount == 1)
        #expect(controller.startCount == 2)
        #expect(vm.isRecording)
    }

    @Test("Volume listener elements derive from supported controls up to channel 32 and clean up on teardown (#42)")
    func highNumberedChannelVolumeElementsAndTeardown() {
        // Master element 0 collapses to [0]; per-channel controls up to 32 (e.g. 1, 2, 16, 32) are all included.
        let masterOnly = AudioDeviceControls.supportedVolumeElements(device: 77, input: true) { _, addr in
            [0, 1, 2, 16].contains(addr.mElement)
        }
        #expect(masterOnly == [0])

        let highChannels = SystemAudioHardwareBackend.volumeAddresses(deviceID: 77, inputScope: true) { _, addr in
            [1, 2, 16, 32].contains(addr.mElement)
        }
        #expect(highChannels.map(\.mElement) == [1, 2, 16, 32])
        #expect(highChannels.allSatisfy { $0.mSelector == kAudioDevicePropertyVolumeScalar && $0.mScope == kAudioDevicePropertyScopeInput })

        let backend = MockAudioHardwareBackend()
        backend.deviceIDsByUID = ["multi-ch": 77]
        let observer = AudioHardwareObserver(backend: backend)
        var changes = 0
        let token = observer.watchDevice(uid: "multi-ch", inputScope: true, includeVolumes: true) {
            changes += 1
        }
        #expect(backend.deviceListeners.count == 1)
        backend.fireDeviceEvent(deviceID: 77)
        observer.flushPendingNotifications()
        #expect(changes == 1)

        observer.unwatchDevice(token)
        #expect(backend.deviceListeners.isEmpty)
        #expect(backend.totalDeviceRemovals == 1)
        observer.stopObserving()
    }

    @Test("Observer guards stale callbacks across stop/restart and activates fallback refresh on listener registration failure (#42)")
    func observerGuardsStaleCallbacksAndHandlesFailedListenerRegistration() async throws {
        let backend = MockAudioHardwareBackend()
        backend.currentInputs = [InputDeviceInfo(uid: "mic-1", name: "Mic 1", inputChannels: 1, sampleRate: 48_000)]
        backend.deviceIDsByUID = ["mic-1": 11]

        let observer = AudioHardwareObserver(backend: backend, fallbackPollInterval: .milliseconds(20))
        #expect(!observer.hasListenerRegistrationFailure)
        #expect(!observer.isFallbackPollingActive)

        var watchCount = 0
        _ = observer.watchDevice(uid: "mic-1", inputScope: true, includeVolumes: false) {
            watchCount += 1
        }

        // Capture the raw listener closures before stopping observation, simulating a callback queued right before stopObserving().
        let staleSystemCallback = try #require(backend.systemListeners.values.first)
        let staleDeviceCallback = try #require(backend.deviceListeners.values.first?.handler)

        observer.stopObserving()
        #expect(!observer.isObserving)
        let revisionAtStop = observer.revision

        // Firing the stale callbacks after stopObserving() must not schedule or flush refreshes.
        backend.currentInputs = [InputDeviceInfo(uid: "mic-2", name: "Mic 2", inputChannels: 1, sampleRate: 48_000)]
        staleSystemCallback()
        staleDeviceCallback()
        await Task.yield()
        observer.flushPendingNotifications()
        #expect(observer.revision == revisionAtStop)
        #expect(observer.inputDevices.map(\.uid) == ["mic-1"])
        #expect(watchCount == 0)

        // Restarting observation with a registration failure surfaces hasListenerRegistrationFailure and runs fallback refresh.
        backend.simulateSystemRegistrationFailure = true
        observer.startObserving()
        #expect(observer.isObserving)
        #expect(observer.hasListenerRegistrationFailure)
        #expect(observer.isFallbackPollingActive)

        // Stale callback from the first generation is still ignored after restart.
        let revisionAfterRestart = observer.revision
        staleSystemCallback()
        observer.flushPendingNotifications()
        #expect(observer.revision == revisionAfterRestart)

        // Mutate backend state without firing any listener event; fallback polling updates the snapshot automatically.
        backend.currentInputs = [InputDeviceInfo(uid: "mic-3", name: "Mic 3", inputChannels: 2, sampleRate: 48_000)]
        for _ in 0..<20 where observer.inputDevices.map(\.uid) != ["mic-3"] {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(observer.inputDevices.map(\.uid) == ["mic-3"])

        observer.stopObserving()
        #expect(!observer.hasListenerRegistrationFailure)
        #expect(!observer.isFallbackPollingActive)
    }

    @Test("Per-device events refresh cached inputDevices, outputDevices, and revision before notifying watchers (#42)")
    func perDeviceEventsRefreshSnapshotForRateChannelAndAggregateChanges() throws {
        let suite = "recscribe-per-device-snapshot-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let backend = MockAudioHardwareBackend()
        backend.currentInputs = [
            InputDeviceInfo(
                uid: "agg-in",
                name: "Aggregate Interface",
                inputChannels: 2,
                sampleRate: 44_100,
                transport: kAudioDeviceTransportTypeAggregate,
                aggregateMembers: ["sub-a"]
            )
        ]
        backend.currentOutputs = [
            AudioOutputDevice(uid: "dac-out", name: "Studio DAC", sampleRate: 48_000)
        ]
        backend.currentDefaultOutputUID = "dac-out"
        backend.deviceIDsByUID = ["agg-in": 101, "dac-out": 202]

        let observer = AudioHardwareObserver(backend: backend)
        var configuredRates: [Double] = []
        let monitor = CapturedAudioMonitor(
            defaults: defaults,
            hardwareObserver: observer,
            isLoopbackCheck: { _ in false },
            startEngineAction: { _, _, changed in
                if changed, let rate = observer.outputDevices.first?.sampleRate {
                    configuredRates.append(rate)
                }
            }
        )
        monitor.levels.set(.init(volume: 0.5, muted: false, outputUID: "dac-out"))
        monitor.setEnabled(true, source: .systemAll)
        #expect(configuredRates == [48_000])

        var observedInputChannels: Int?
        var observedInputRate: Double?
        var observedAggregateMembers: [String]?
        _ = observer.watchDevice(uid: "agg-in", inputScope: true, includeVolumes: false) {
            let device = observer.inputDevices.first { $0.uid == "agg-in" }
            observedInputChannels = device?.inputChannels
            observedInputRate = device?.sampleRate
            observedAggregateMembers = device?.aggregateMembers
        }

        let initialRevision = observer.revision

        // Update input device rate/channels/aggregate members AND output device nominal sample rate,
        // then fire ONLY per-device events (no system device-list or default-route event).
        backend.currentInputs = [
            InputDeviceInfo(
                uid: "agg-in",
                name: "Aggregate Interface",
                inputChannels: 8,
                sampleRate: 96_000,
                transport: kAudioDeviceTransportTypeAggregate,
                aggregateMembers: ["sub-a", "sub-b"]
            )
        ]
        backend.currentOutputs = [
            AudioOutputDevice(uid: "dac-out", name: "Studio DAC", sampleRate: 96_000)
        ]

        backend.fireDeviceEvent(deviceID: 101)
        backend.fireDeviceEvent(deviceID: 202)
        observer.flushPendingNotifications()

        #expect(observer.revision > initialRevision)
        #expect(observedInputChannels == 8)
        #expect(observedInputRate == 96_000)
        #expect(observedAggregateMembers == ["sub-a", "sub-b"])
        #expect(observer.outputDevices.first?.sampleRate == 96_000)
        // CapturedAudioMonitor read the refreshed sampleRate (96_000) and restarted its engine.
        #expect(configuredRates == [48_000, 96_000])

        monitor.setEnabled(false, source: .systemAll)
        observer.stopObserving()
    }
}
