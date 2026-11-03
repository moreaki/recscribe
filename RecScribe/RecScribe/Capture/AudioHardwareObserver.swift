import Combine
import CoreAudio
import Foundation

/// Low-level hardware query and listener registration seam so unit tests can
/// drive device topology, default-route, format, aggregate, and volume events
/// deterministically without touching live Core Audio hardware.
@MainActor
protocol AudioHardwareBackend: AnyObject {
    func inputDevices() -> [InputDeviceInfo]
    func outputDevices() -> [AudioOutputDevice]
    func defaultInputUID() -> String?
    func defaultOutputUID() -> String?
    func deviceID(forUID uid: String) -> AudioDeviceID?
    func addSystemListener(_ handler: @escaping @Sendable () -> Void) -> AnyObject
    func removeSystemListener(_ token: AnyObject)
    func addDeviceListener(
        deviceID: AudioDeviceID,
        inputScope: Bool,
        includeVolumes: Bool,
        handler: @escaping @Sendable () -> Void
    ) -> AnyObject
    func removeDeviceListener(_ token: AnyObject)
}

/// Live Core Audio implementation using `AudioObjectAddPropertyListenerBlock` on a
/// dedicated serial dispatch queue. Callbacks hop to `@MainActor` asynchronously
/// and never block Core Audio's notification queue.
@MainActor
final class SystemAudioHardwareBackend: AudioHardwareBackend {
    private let listenerQueue = DispatchQueue(label: "com.moreaki.recscribe.audio-hardware-listener", qos: .userInitiated)
    private let enumerator = InputDeviceEnumerator()

    private nonisolated final class SystemListenerHandle {
        let queue: DispatchQueue
        var registrations: [(AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []

        init(queue: DispatchQueue, registrations: [(AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)]) {
            self.queue = queue
            self.registrations = registrations
        }

        func unregister() {
            let active = registrations
            registrations.removeAll()
            for (var address, block) in active {
                _ = AudioObjectRemovePropertyListenerBlock(
                    AudioObjectID(kAudioObjectSystemObject),
                    &address,
                    queue,
                    block
                )
            }
        }

        deinit {
            unregister()
        }
    }

    private nonisolated final class DeviceListenerHandle {
        let deviceID: AudioDeviceID
        let queue: DispatchQueue
        var registrations: [(AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []

        init(
            deviceID: AudioDeviceID,
            queue: DispatchQueue,
            registrations: [(AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)]
        ) {
            self.deviceID = deviceID
            self.queue = queue
            self.registrations = registrations
        }

        func unregister() {
            let active = registrations
            registrations.removeAll()
            for (var address, block) in active {
                _ = AudioObjectRemovePropertyListenerBlock(
                    deviceID,
                    &address,
                    queue,
                    block
                )
            }
        }

        deinit {
            unregister()
        }
    }

    func inputDevices() -> [InputDeviceInfo] {
        enumerator.availableInputDevices()
    }

    func outputDevices() -> [AudioOutputDevice] {
        AudioDeviceControls.outputs()
    }

    func defaultInputUID() -> String? {
        AudioDeviceControls.defaultInputUID()
    }

    func defaultOutputUID() -> String? {
        AudioDeviceControls.defaultOutputUID()
    }

    func deviceID(forUID uid: String) -> AudioDeviceID? {
        AudioDeviceControls.device(uid: uid)
    }

    func addSystemListener(_ handler: @escaping @Sendable () -> Void) -> AnyObject {
        let selectors: [AudioObjectPropertySelector] = [
            kAudioHardwarePropertyDevices,
            kAudioHardwarePropertyDefaultInputDevice,
            kAudioHardwarePropertyDefaultOutputDevice
        ]
        var registrations: [(AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []
        for selector in selectors {
            var address = AudioObjectPropertyAddress(
                mSelector: selector,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            let block: AudioObjectPropertyListenerBlock = { _, _ in
                handler()
            }
            if AudioObjectAddPropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject),
                &address,
                listenerQueue,
                block
            ) == noErr {
                registrations.append((address, block))
            }
        }
        return SystemListenerHandle(queue: listenerQueue, registrations: registrations)
    }

    func removeSystemListener(_ token: AnyObject) {
        (token as? SystemListenerHandle)?.unregister()
    }

    func addDeviceListener(
        deviceID: AudioDeviceID,
        inputScope: Bool,
        includeVolumes: Bool,
        handler: @escaping @Sendable () -> Void
    ) -> AnyObject {
        var addresses: [AudioObjectPropertyAddress] = [
            AudioDeviceControls.address(kAudioDevicePropertyDeviceIsAlive),
            AudioDeviceControls.address(kAudioDevicePropertyNominalSampleRate),
            AudioDeviceControls.address(kAudioDevicePropertyStreamConfiguration, input: true),
            AudioDeviceControls.address(kAudioDevicePropertyStreamConfiguration, input: false),
            AudioDeviceControls.address(kAudioAggregateDevicePropertyActiveSubDeviceList)
        ]
        if includeVolumes {
            for element: UInt32 in 0...8 {
                var address = AudioDeviceControls.address(
                    kAudioDevicePropertyVolumeScalar,
                    input: inputScope,
                    element: element
                )
                if AudioObjectHasProperty(deviceID, &address) {
                    addresses.append(address)
                }
            }
        }

        var registrations: [(AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []
        for var address in addresses {
            let block: AudioObjectPropertyListenerBlock = { _, _ in
                handler()
            }
            if AudioObjectAddPropertyListenerBlock(
                deviceID,
                &address,
                listenerQueue,
                block
            ) == noErr {
                registrations.append((address, block))
            }
        }
        return DeviceListenerHandle(deviceID: deviceID, queue: listenerQueue, registrations: registrations)
    }

    func removeDeviceListener(_ token: AnyObject) {
        (token as? DeviceListenerHandle)?.unregister()
    }
}

/// Centralized event-driven Core Audio hardware observer (#42).
///
/// Replaces all `Task.sleep` Core Audio polling loops across UI and capture
/// services with `AudioObjectAddPropertyListenerBlock` subscriptions and scoped
/// per-device watches.
@MainActor
final class AudioHardwareObserver: ObservableObject {
    static let shared = AudioHardwareObserver()

    @Published private(set) var inputDevices: [InputDeviceInfo] = []
    @Published private(set) var outputDevices: [AudioOutputDevice] = []
    @Published private(set) var defaultInputUID: String?
    @Published private(set) var defaultOutputUID: String?
    @Published private(set) var revision: Int = 0

    private struct DeviceWatch {
        let uid: String
        let inputScope: Bool
        let includeVolumes: Bool
        let onChange: @MainActor () -> Void
        var deviceID: AudioDeviceID?
        var token: AnyObject?
    }

    private let backend: AudioHardwareBackend
    private var systemToken: AnyObject?
    private var watches: [UUID: DeviceWatch] = [:]
    private var pendingSystemRefresh = false
    private var pendingWatchTokens = Set<UUID>()
    private var coalesceTask: Task<Void, Never>?

    init(backend: AudioHardwareBackend? = nil) {
        let resolvedBackend = backend ?? SystemAudioHardwareBackend()
        self.backend = resolvedBackend
        refreshSystemSnapshot()
        systemToken = resolvedBackend.addSystemListener { [weak self] in
            if Thread.isMainThread {
                MainActor.assumeIsolated {
                    self?.scheduleSystemRefresh()
                }
            } else {
                Task { @MainActor [weak self] in
                    self?.scheduleSystemRefresh()
                }
            }
        }
    }

    deinit {
        coalesceTask?.cancel()
    }

    /// Unregister all system and per-device Core Audio property listeners.
    func stopObserving() {
        coalesceTask?.cancel()
        coalesceTask = nil
        pendingSystemRefresh = false
        pendingWatchTokens.removeAll()
        if let systemToken {
            backend.removeSystemListener(systemToken)
            self.systemToken = nil
        }
        for (_, watch) in watches {
            if let token = watch.token {
                backend.removeDeviceListener(token)
            }
        }
        watches.removeAll()
    }

    /// Force an immediate refresh of system device lists and default routes.
    func refreshNow() {
        refreshSystemSnapshot()
        rebindDeviceWatchesAndNotifyAll()
    }

    /// Register a scoped per-device property listener for a specific UID.
    /// Volume scalar listeners are only attached when `includeVolumes == true`
    /// (e.g. while `DeviceVolumeView`'s disclosure group is expanded).
    @discardableResult
    func watchDevice(
        uid: String,
        inputScope: Bool = true,
        includeVolumes: Bool = false,
        onChange: @escaping @MainActor () -> Void
    ) -> UUID {
        let id = UUID()
        var watch = DeviceWatch(
            uid: uid,
            inputScope: inputScope,
            includeVolumes: includeVolumes,
            onChange: onChange,
            deviceID: nil,
            token: nil
        )
        bindWatch(&watch, id: id)
        watches[id] = watch
        return id
    }

    /// Unregister a previously registered per-device listener.
    func unwatchDevice(_ id: UUID?) {
        guard let id, let watch = watches.removeValue(forKey: id) else { return }
        pendingWatchTokens.remove(id)
        if let token = watch.token {
            backend.removeDeviceListener(token)
        }
    }

    // MARK: - Internal Coalescing & Binding

    private func scheduleSystemRefresh() {
        pendingSystemRefresh = true
        scheduleFlushIfNeeded()
    }

    private func scheduleWatchNotification(_ id: UUID) {
        guard watches[id] != nil else { return }
        pendingWatchTokens.insert(id)
        scheduleFlushIfNeeded()
    }

    private func scheduleFlushIfNeeded() {
        guard coalesceTask == nil else { return }
        coalesceTask = Task { @MainActor [weak self] in
            await Task.yield()
            guard !Task.isCancelled, let self else { return }
            self.coalesceTask = nil
            self.flushPendingNotifications()
        }
    }

    func flushPendingNotifications() {
        let doSystem = pendingSystemRefresh
        let watchIDs = pendingWatchTokens
        pendingSystemRefresh = false
        pendingWatchTokens.removeAll()

        if doSystem {
            refreshSystemSnapshot()
            rebindDeviceWatchesAndNotifyAll()
        } else {
            for id in watchIDs {
                watches[id]?.onChange()
            }
        }
    }

    private func refreshSystemSnapshot() {
        let nextInputs = backend.inputDevices()
        let nextOutputs = backend.outputDevices()
        let nextDefaultInput = backend.defaultInputUID()
        let nextDefaultOutput = backend.defaultOutputUID()

        if inputDevices != nextInputs { inputDevices = nextInputs }
        if outputDevices != nextOutputs { outputDevices = nextOutputs }
        if defaultInputUID != nextDefaultInput { defaultInputUID = nextDefaultInput }
        if defaultOutputUID != nextDefaultOutput { defaultOutputUID = nextDefaultOutput }
        revision &+= 1
    }

    private func rebindDeviceWatchesAndNotifyAll() {
        let keys = Array(watches.keys)
        for id in keys {
            guard var watch = watches[id] else { continue }
            let resolvedID = backend.deviceID(forUID: watch.uid)
            if resolvedID != watch.deviceID {
                if let token = watch.token {
                    backend.removeDeviceListener(token)
                    watch.token = nil
                }
                watch.deviceID = nil
                bindWatch(&watch, id: id)
                watches[id] = watch
            }
            watch.onChange()
        }
    }

    private func bindWatch(_ watch: inout DeviceWatch, id: UUID) {
        guard let deviceID = backend.deviceID(forUID: watch.uid), deviceID != 0 else { return }
        watch.deviceID = deviceID
        watch.token = backend.addDeviceListener(
            deviceID: deviceID,
            inputScope: watch.inputScope,
            includeVolumes: watch.includeVolumes
        ) { [weak self] in
            if Thread.isMainThread {
                MainActor.assumeIsolated {
                    self?.scheduleWatchNotification(id)
                }
            } else {
                Task { @MainActor [weak self] in
                    self?.scheduleWatchNotification(id)
                }
            }
        }
    }
}
