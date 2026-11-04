import Observation
import CoreAudio
import Foundation
import os

/// Optional status protocol implemented by listener tokens so `AudioHardwareObserver`
/// can detect partial or total Core Audio listener registration failures and activate
/// bounded fallback refresh rather than leaving an event-driven UI frozen.
nonisolated protocol HardwareListenerToken: AnyObject {
    var hasRegistrationFailure: Bool { get }
}

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

    private nonisolated final class SystemListenerHandle: HardwareListenerToken {
        let queue: DispatchQueue
        var registrations: [(AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []
        let hasRegistrationFailure: Bool

        init(
            queue: DispatchQueue,
            registrations: [(AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)],
            hasRegistrationFailure: Bool
        ) {
            self.queue = queue
            self.registrations = registrations
            self.hasRegistrationFailure = hasRegistrationFailure
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

    private nonisolated final class DeviceListenerHandle: HardwareListenerToken {
        let deviceID: AudioDeviceID
        let queue: DispatchQueue
        var registrations: [(AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []
        let hasRegistrationFailure: Bool

        init(
            deviceID: AudioDeviceID,
            queue: DispatchQueue,
            registrations: [(AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)],
            hasRegistrationFailure: Bool
        ) {
            self.deviceID = deviceID
            self.queue = queue
            self.registrations = registrations
            self.hasRegistrationFailure = hasRegistrationFailure
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

    nonisolated static func volumeAddresses(
        deviceID: AudioDeviceID,
        inputScope: Bool,
        isSupported: (AudioDeviceID, inout AudioObjectPropertyAddress) -> Bool = { dev, property in
            var writable = DarwinBoolean(false)
            return AudioObjectHasProperty(dev, &property)
                && AudioObjectIsPropertySettable(dev, &property, &writable) == noErr
                && writable.boolValue
        }
    ) -> [AudioObjectPropertyAddress] {
        AudioDeviceControls.supportedVolumeElements(
            device: deviceID,
            input: inputScope,
            isSupported: isSupported
        ).map { element in
            AudioDeviceControls.address(
                kAudioDevicePropertyVolumeScalar,
                input: inputScope,
                element: element
            )
        }
    }

    func addSystemListener(_ handler: @escaping @Sendable () -> Void) -> AnyObject {
        let selectors: [AudioObjectPropertySelector] = [
            kAudioHardwarePropertyDevices,
            kAudioHardwarePropertyDefaultInputDevice,
            kAudioHardwarePropertyDefaultOutputDevice
        ]
        var registrations: [(AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []
        var failed = 0
        for selector in selectors {
            var address = AudioObjectPropertyAddress(
                mSelector: selector,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            let block: AudioObjectPropertyListenerBlock = { _, _ in
                handler()
            }
            let status = AudioObjectAddPropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject),
                &address,
                listenerQueue,
                block
            )
            if status == noErr {
                registrations.append((address, block))
            } else {
                failed += 1
                Log.capture.error("Core Audio system listener registration failed selector=\(selector, privacy: .public) status=\(status, privacy: .public)")
            }
        }
        return SystemListenerHandle(
            queue: listenerQueue,
            registrations: registrations,
            hasRegistrationFailure: failed > 0 || registrations.isEmpty
        )
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
        let baseCandidates: [AudioObjectPropertyAddress] = [
            AudioDeviceControls.address(kAudioDevicePropertyDeviceIsAlive),
            AudioDeviceControls.address(kAudioDevicePropertyNominalSampleRate),
            AudioDeviceControls.address(kAudioDevicePropertyStreamConfiguration, input: true),
            AudioDeviceControls.address(kAudioDevicePropertyStreamConfiguration, input: false),
            AudioDeviceControls.address(kAudioAggregateDevicePropertyActiveSubDeviceList)
        ]
        var addresses = baseCandidates.filter { candidate in
            var property = candidate
            return AudioObjectHasProperty(deviceID, &property)
        }
        if includeVolumes {
            addresses.append(contentsOf: Self.volumeAddresses(deviceID: deviceID, inputScope: inputScope))
        }

        var registrations: [(AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []
        var failed = 0
        for var address in addresses {
            let block: AudioObjectPropertyListenerBlock = { _, _ in
                handler()
            }
            let status = AudioObjectAddPropertyListenerBlock(
                deviceID,
                &address,
                listenerQueue,
                block
            )
            if status == noErr {
                registrations.append((address, block))
            } else {
                failed += 1
                Log.capture.error("Core Audio device listener registration failed device=\(deviceID, privacy: .public) selector=\(address.mSelector, privacy: .public) element=\(address.mElement, privacy: .public) status=\(status, privacy: .public)")
            }
        }
        return DeviceListenerHandle(
            deviceID: deviceID,
            queue: listenerQueue,
            registrations: registrations,
            hasRegistrationFailure: failed > 0 || (!addresses.isEmpty && registrations.isEmpty)
        )
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
@Observable final class AudioHardwareObserver {
    static let shared = AudioHardwareObserver()

    private(set) var inputDevices: [InputDeviceInfo] = []
    private(set) var outputDevices: [AudioOutputDevice] = []
    private(set) var defaultInputUID: String?
    private(set) var defaultOutputUID: String?
    private(set) var revision: Int = 0
    private(set) var hasListenerRegistrationFailure: Bool = false

    private struct DeviceWatch {
        let uid: String
        let inputScope: Bool
        let includeVolumes: Bool
        let onChange: @MainActor () -> Void
        let onPropertiesChange: (@MainActor () -> Void)?
        var deviceID: AudioDeviceID?
        var token: AnyObject?
    }

    private let backend: AudioHardwareBackend
    private let fallbackPollInterval: Duration
    private var systemToken: AnyObject?
    private var watches: [UUID: DeviceWatch] = [:]
    private var pendingSystemRefresh = false
    private var pendingWatchTokens = Set<UUID>()
    @ObservationIgnored private var coalesceTask: Task<Void, Never>?
    @ObservationIgnored private var fallbackPollTask: Task<Void, Never>?
    private(set) var isObserving = false
    private var observerGeneration = UUID()

    var isFallbackPollingActive: Bool {
        fallbackPollTask != nil
    }

    init(backend: AudioHardwareBackend? = nil, fallbackPollInterval: Duration = .seconds(1)) {
        let resolvedBackend = backend ?? SystemAudioHardwareBackend()
        self.backend = resolvedBackend
        self.fallbackPollInterval = fallbackPollInterval
        startObserving()
    }

    deinit {
        coalesceTask?.cancel()
        fallbackPollTask?.cancel()
    }

    /// Start or restart system and per-device Core Audio listener observation.
    func startObserving() {
        guard !isObserving else { return }
        isObserving = true
        let generation = UUID()
        observerGeneration = generation
        refreshSystemSnapshot()
        systemToken = backend.addSystemListener { [weak self] in
            if Thread.isMainThread {
                MainActor.assumeIsolated {
                    guard let self, self.isObserving, self.observerGeneration == generation else { return }
                    self.scheduleSystemRefresh()
                }
            } else {
                Task { @MainActor [weak self] in
                    guard let self, self.isObserving, self.observerGeneration == generation else { return }
                    self.scheduleSystemRefresh()
                }
            }
        }
        let keys = Array(watches.keys)
        for id in keys {
            guard var watch = watches[id] else { continue }
            if let token = watch.token {
                backend.removeDeviceListener(token)
                watch.token = nil
            }
            watch.deviceID = nil
            bindWatch(&watch, id: id)
            watches[id] = watch
        }
        updateRegistrationFailureState()
    }

    /// Unregister all system and per-device Core Audio property listeners.
    func stopObserving() {
        isObserving = false
        observerGeneration = UUID()
        coalesceTask?.cancel()
        coalesceTask = nil
        fallbackPollTask?.cancel()
        fallbackPollTask = nil
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
        hasListenerRegistrationFailure = false
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
        onPropertiesChange: (@MainActor () -> Void)? = nil,
        onChange: @escaping @MainActor () -> Void
    ) -> UUID {
        let id = UUID()
        var watch = DeviceWatch(
            uid: uid,
            inputScope: inputScope,
            includeVolumes: includeVolumes,
            onChange: onChange,
            onPropertiesChange: onPropertiesChange,
            deviceID: nil,
            token: nil
        )
        if isObserving {
            bindWatch(&watch, id: id)
        }
        watches[id] = watch
        updateRegistrationFailureState()
        return id
    }

    /// Unregister a previously registered per-device listener.
    func unwatchDevice(_ id: UUID?) {
        guard let id, let watch = watches.removeValue(forKey: id) else { return }
        pendingWatchTokens.remove(id)
        if let token = watch.token {
            backend.removeDeviceListener(token)
        }
        updateRegistrationFailureState()
    }

    // MARK: - Internal Coalescing & Binding

    private func scheduleSystemRefresh() {
        guard isObserving else { return }
        pendingSystemRefresh = true
        scheduleFlushIfNeeded()
    }

    private func scheduleWatchNotification(_ id: UUID) {
        guard isObserving, watches[id] != nil else { return }
        pendingWatchTokens.insert(id)
        scheduleFlushIfNeeded()
    }

    private func scheduleFlushIfNeeded() {
        guard isObserving, coalesceTask == nil else { return }
        let generation = observerGeneration
        coalesceTask = Task { @MainActor [weak self] in
            await Task.yield()
            guard !Task.isCancelled, let self, self.isObserving, self.observerGeneration == generation else { return }
            self.coalesceTask = nil
            self.flushPendingNotifications()
        }
    }

    func flushPendingNotifications() {
        guard isObserving else { return }
        let doSystem = pendingSystemRefresh
        let watchIDs = pendingWatchTokens
        pendingSystemRefresh = false
        pendingWatchTokens.removeAll()

        guard doSystem || !watchIDs.isEmpty else { return }
        refreshSystemSnapshot()
        // Preserve the distinction even when system and device events coalesce.
        // An unrelated helper-device inventory event must not retry failed input I/O.
        for id in watchIDs { watches[id]?.onPropertiesChange?() }

        if doSystem {
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
                watch.onPropertiesChange?()
            }
            watch.onChange()
        }
        updateRegistrationFailureState()
    }

    private func bindWatch(_ watch: inout DeviceWatch, id: UUID) {
        guard isObserving, let deviceID = backend.deviceID(forUID: watch.uid), deviceID != 0 else { return }
        let generation = observerGeneration
        watch.deviceID = deviceID
        watch.token = backend.addDeviceListener(
            deviceID: deviceID,
            inputScope: watch.inputScope,
            includeVolumes: watch.includeVolumes
        ) { [weak self] in
            if Thread.isMainThread {
                MainActor.assumeIsolated {
                    guard let self, self.isObserving, self.observerGeneration == generation else { return }
                    self.scheduleWatchNotification(id)
                }
            } else {
                Task { @MainActor [weak self] in
                    guard let self, self.isObserving, self.observerGeneration == generation else { return }
                    self.scheduleWatchNotification(id)
                }
            }
        }
    }

    private func updateRegistrationFailureState() {
        guard isObserving else {
            hasListenerRegistrationFailure = false
            fallbackPollTask?.cancel()
            fallbackPollTask = nil
            return
        }
        let systemFailed = (systemToken as? HardwareListenerToken)?.hasRegistrationFailure ?? (systemToken == nil)
        let watchFailed = watches.values.contains { watch in
            guard watch.deviceID != nil else { return false }
            return (watch.token as? HardwareListenerToken)?.hasRegistrationFailure ?? (watch.token == nil)
        }
        let failed = systemFailed || watchFailed
        if hasListenerRegistrationFailure != failed {
            hasListenerRegistrationFailure = failed
        }
        if failed {
            startFallbackPollIfNeeded()
        } else {
            fallbackPollTask?.cancel()
            fallbackPollTask = nil
        }
    }

    private func startFallbackPollIfNeeded() {
        guard isObserving, fallbackPollTask == nil else { return }
        let generation = observerGeneration
        let interval = fallbackPollInterval
        fallbackPollTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                guard !Task.isCancelled, let self, self.isObserving,
                      self.observerGeneration == generation,
                      self.hasListenerRegistrationFailure else { return }
                self.refreshNow()
            }
        }
    }
}
