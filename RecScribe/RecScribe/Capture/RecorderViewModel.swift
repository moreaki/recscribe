import AppKit
import Foundation
import Observation

/// Capture lifecycle and source selection. Permission, installation and user
/// preferences have independent observable owners; telemetry is consumed by leaves.
@MainActor
@Observable final class RecorderViewModel {
    let audioTest: AudioTestController?
    let audio: AudioServices
    let telemetry = RecorderTelemetry()
    let permissionCoordinator: PermissionCoordinator
    let installLocationMonitor: InstallLocationMonitor
    let preferences: RecorderPreferences
    let alerts = RecorderAlerts()
    let audioSource: AudioSourceProviding
    private var automaticRoutingEnabled = false
    private let automaticRouting: AutomaticRoutingSources
    private let controller: RecordingControlling
    private let clock: DurationClock
    private var sourceRevision = 0
    private var recordingStartTime: Date?
    private var longRecordingWarned = false
    private var failureFinalizationTask: Task<Void, Never>?
    private(set) var state: RecordingState = .idle
    private(set) var isFinalizingAfterFailure = false
    var lastRecordingURL: URL?

    init(
        controller: RecordingControlling? = nil,
        permissions: PermissionProviding? = nil,
        clock: DurationClock? = nil,
        saveLocation: SaveLocationProviding? = nil,
        audioSource: AudioSourceProviding? = nil,
        installLocation: InstallLocationProviding? = nil,
        defaults: UserDefaults = .standard,
        audio: AudioServices? = nil,
        installNoticePresenter: (() -> Void)? = nil,
        notificationCenter: NotificationCenter = .default,
        pollClock: PollClock? = nil,
        registrationTimeout: TimeInterval = 2.0,
        audioTest: AudioTestController? = nil
    ) {
        automaticRouting = AutomaticRoutingSources(defaults: defaults)
        self.audioTest = audioTest
        self.audio = audio ?? AudioServices(defaults: defaults)
        let installation = installLocation ?? BundleInstallLocation()
        installLocationMonitor = InstallLocationMonitor(
            provider: installation,
            presenter: installNoticePresenter, notificationCenter: notificationCenter)
        permissionCoordinator = PermissionCoordinator(
            permissions: permissions ?? PermissionManager(),
            pollClock: pollClock ?? SystemPollClock(), registrationTimeout: registrationTimeout,
            blocked: installation.location.blocksRecording, notificationCenter: notificationCenter)
        let storage = saveLocation ?? SaveLocationManager(defaults: defaults)
        preferences = RecorderPreferences(saveLocation: storage, defaults: defaults)
        let source = audioSource ?? AudioSourceManager(defaults: defaults)
        self.audioSource = source
        self.controller =
            controller
            ?? RecordingController(
                captureManager: ScreenCaptureAudioManager(hardwareObserver: self.audio.hardware),
                saveLocation: storage,
                audioSource: source, levels: self.audio.levels, monitor: self.audio.monitor)
        self.clock = clock ?? SystemDurationClock()
        self.controller.onStreamError = { [weak self] in self?.handleStreamFailure($0) }
    }

    var isRecording: Bool { state == .recording }
    var allowsCaptureSourceChange: Bool {
        state.allowsCaptureSourceChange && audioTest?.locksSources != true
    }
    var showsSettingsShelf: Bool { allowsCaptureSourceChange }
    var requiresScreenCapturePermission: Bool { selectedSource.requiresScreenCapture }
    var canRecord: Bool {
        (!requiresScreenCapturePermission || permissionStatus == .granted)
            && !installLocationBlocksRecording
    }
    var selectedSource: AudioSource {
        _ = sourceRevision
        return audioSource.selectedSource
    }

    func startRecording() async {
        if automaticRoutingEnabled, allowsCaptureSourceChange {
            refreshAvailableRoutingSources(audioSource.availableInputDevices())
        }
        guard !isFinalizingAfterFailure, state.canTransition(to: .starting) else { return }
        if installLocation.blocksRecording { showInstallLocationNotice(); return }
        if selectedSource.requiresScreenCapture, permissionStatus != .granted {
            await requestPermission()
            guard permissionStatus == .granted else { return }
        }
        // A second command may have arrived during the permission request.
        guard !isFinalizingAfterFailure, state.canTransition(to: .starting) else { return }
        transition(to: .starting)
        await audioTest?.prepareForRecording()
        alerts.reviewMessage = nil
        alerts.errorMessage = nil
        alerts.showError = false
        alerts.recoverySuggestion = nil
        if selectedSource.requiresMicrophone, !(await requestMicrophoneAccess()) {
            transition(to: .error(.microphoneDenied))
            return
        }
        controller.onWaveformData = { [weak self] in self?.telemetry.waveformSamples = $0 }
        do {
            lastRecordingURL = try await controller.startRecording()
            recordingStartTime = clock.now
            telemetry.duration = 0
            longRecordingWarned = false
            transition(to: .recording)
            refreshCaptureHealth()
            clock.startTicking(every: 0.1) { [weak self] in self?.updateElapsedTime() }
            if preferences.saveLocation.isConfiguredLocationUnavailable {
                presentError(RecorderError.saveLocationUnavailable.message, recovery: .chooseFolder)
            }
        } catch {
            Log.recordFailure(error, operation: "recording_start")
            let failure: RecorderError
            if case RecordingControllerError.insufficientDiskSpace = error { failure = .diskFull }
            else if let missing = error as? AudioSourceError { failure = .sourceUnavailable(missing) }
            else { failure = .startFailed(error.localizedDescription) }
            transition(to: .error(failure))
        }
    }

    func stopRecording() async {
        guard state.canTransition(to: .stopping) else { return }
        transition(to: .stopping)
        defer { clearTransportTelemetry() }
        do {
            try await controller.stopRecording()
            alerts.reviewMessage = controller.stopReviewMessage
            transition(to: .idle)
        } catch {
            Log.recordFailure(error, operation: "recording_stop")
            let failure: RecorderError
            switch error {
            case RecordingControllerError.captureShutdownFailed(let cause): failure = .captureStopFailed(cause.localizedDescription)
            case SessionError.noAudio: failure = .noAudio
            default: failure = .stopFailed(error.localizedDescription)
            }
            transition(to: .error(failure))
        }
    }

    func toggleRecording() async {
        if state == .recording { await stopRecording() }
        else if state.allowsCaptureSourceChange { await startRecording() }
    }
    func stopAndStartNewTake() async {
        guard isRecording else { return }
        await stopRecording()
        if state == .idle { await startRecording() }
    }

    private func handleStreamFailure(_ message: String) {
        guard isRecording else { return }
        isFinalizingAfterFailure = true
        clearTransportTelemetry()
        transition(to: .error(.streamFailed(message)))
        let workflow = controller
        failureFinalizationTask = Task { [weak self] in
            await workflow.finalizeAfterFailure()
            self?.isFinalizingAfterFailure = false
            self?.failureFinalizationTask = nil
        }
    }
    func waitForFailureFinalization() async { await failureFinalizationTask?.value }

    private func transition(to next: RecordingState) {
        guard state.canTransition(to: next) else {
            Log.recorder.error("Rejected recording transition from \(String(describing: self.state), privacy: .public) to \(String(describing: next), privacy: .public)")
            return
        }
        state = next
        if next.allowsCaptureSourceChange { audioTest?.recordingFinished() }
        if case .error(let failure) = next { alerts.present(failure.message, recovery: failure.recovery) }
    }

    private func updateElapsedTime() {
        guard let began = recordingStartTime else { return }
        telemetry.duration = clock.now.timeIntervalSince(began)
        refreshCaptureHealth()
        if telemetry.duration >= DiskSpace.longRecordingThreshold, !longRecordingWarned {
            longRecordingWarned = true
            alerts.showLongRecordingWarning = true
        }
    }
    private func clearTransportTelemetry() {
        clock.stopTicking()
        telemetry.waveformSamples = .init(repeating: 0, count: 200)
    }

    func refreshCaptureHealth() {
        healthTime = ProcessInfo.processInfo.systemUptime
        sourceHealth = controller.sourceHealth
        telemetry.sourceMeters = controller.sourceMeters
        telemetry.refreshDetails()
    }

    func enableAutomaticRouting(_ devices: [InputDeviceInfo]) {
        automaticRoutingEnabled = true
        refreshAvailableRoutingSources(devices)
    }

    func refreshAvailableRoutingSources(_ devices: [InputDeviceInfo]) {
        guard allowsCaptureSourceChange, !isFinalizingAfterFailure else { return }
        applyCaptureSource(automaticRouting.selection(from: selectedSource, devices: devices, levels: audio.levels))
    }

    func setVirtualInputCapture(_ device: InputDeviceInfo, enabled: Bool) {
        guard allowsCaptureSourceChange, !isFinalizingAfterFailure, device.mayLoopBack else { return }
        automaticRouting.setVirtualCapture(device, enabled: enabled)
        refreshAvailableRoutingSources(audioSource.availableInputDevices())
    }

    func setCaptureSource(_ source: AudioSource) {
        guard allowsCaptureSourceChange, source != selectedSource else { return }
        let before = Set(selectedSource.inputSelections.map(\.deviceUID))
        let after = Set(source.inputSelections.map(\.deviceUID))
        for device in audioSource.availableInputDevices() where device.mayLoopBack && before.contains(device.uid) != after.contains(device.uid) {
            automaticRouting.setVirtualCapture(device, enabled: after.contains(device.uid))
        }
        applyCaptureSource(source)
    }

    private func applyCaptureSource(_ source: AudioSource) {
        guard allowsCaptureSourceChange, source != selectedSource else { return }
        sourceRevision &+= 1
        audioSource.setSelectedSource(source)
    }

    func performRecovery() {
        let action = alerts.recoverySuggestion
        alerts.showError = false
        if action == .openSettings { openSystemSettings() }
        if action == .openMicrophoneSettings { permissionCoordinator.openSystemPreferences(for: .microphone) }
        if action == .chooseFolder { chooseSaveLocation() }
        if action == .tryAgain { Task { await startRecording() } }
    }
}
