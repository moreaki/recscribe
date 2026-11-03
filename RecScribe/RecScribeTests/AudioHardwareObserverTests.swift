import CoreAudio
import Foundation
import Testing
@testable import RecScribe

@MainActor
private final class MockAudioHardwareBackend: AudioHardwareBackend {
    private final class Token {}

    var currentInputs: [InputDeviceInfo] = []
    var currentOutputs: [AudioOutputDevice] = []
    var currentDefaultInputUID: String?
    var currentDefaultOutputUID: String?
    var deviceIDsByUID: [String: AudioDeviceID] = [:]

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
        let token = Token()
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
        let token = Token()
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

        var policy = DeviceInputConfigurationPolicy(startedAt: 10)
        let decision = policy.evaluate(
            connected: true,
            sameDevice: true,
            sameFormat: true,
            sameAggregateMembers: false,
            running: true,
            receivedFrames: 4800,
            now: 12
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
}
