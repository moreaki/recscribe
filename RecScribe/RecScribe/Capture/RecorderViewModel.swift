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
        if automaticRoutingEnabled, allowsCaptureSourceChange { refreshAvailableRoutingSources(audioSource.availableInputDevices()) }
        guard !isFinalizingAfterFailure, state.canTransition(to: .starting) else { return }

        guard !installLocation.blocksRecording else {
            showInstallLocationNotice()
            return
        }

        if selectedSource.requiresScreenCapture && permissionStatus != .granted {
            await requestPermission()
            if permissionStatus != .granted {
                return
            }
        }

        transition(to: .starting)
        await audioTest?.prepareForRecording()
        alerts.reviewMessage = nil
        errorMessage = nil
        showError = false
        recoverySuggestion = nil

        // Move to .starting before microphone denial: idle → error is illegal.
        if selectedSource.requiresMicrophone {
            guard await requestMicrophoneAccess() else {
                transition(to: .error(.microphoneDenied))
                return
            }
        }

        do {
            controller.onWaveformData = { [weak self] samples in
                Task { @MainActor in
                    self?.waveformSamples = samples
                }
            }
            let fileURL = try await controller.startRecording(format: selectedFormat)
            lastRecordingURL = fileURL
            recordingStartTime = clock.now
            duration = 0
            longRecordingWarned = false

            transition(to: .recording)

            refreshCaptureHealth()
            startTimer()

            if preferences.saveLocation.isConfiguredLocationUnavailable {
                presentError(RecorderError.saveLocationUnavailable.message, recovery: .chooseFolder)
            }

        } catch RecordingControllerError.insufficientDiskSpace {
            Log.recorder.error("Refusing to record: insufficient disk space")
            transition(to: .error(.diskFull))
        } catch let sourceError as AudioSourceError {
            Log.recorder.error(
                "Capture source unavailable: \(sourceError.localizedDescription, privacy: .public)")
            transition(to: .error(.sourceUnavailable(sourceError)))
        } catch {
            Log.recorder.error(
                "Failed to start recording: \(error.localizedDescription, privacy: .public)")
            transition(to: .error(.startFailed(error.localizedDescription)))
        }
    }

    func stopRecording() async {
        guard state.canTransition(to: .stopping) else { return }

        transition(to: .stopping)

        defer {
            stopTimer()
            waveformSamples = Array(repeating: 0, count: 200)
        }

        do {
            try await controller.stopRecording()
            alerts.reviewMessage = controller.stopReviewMessage
            transition(to: .idle)

        } catch {
            Log.recordFailure(error, operation: "recording_stop")
            if case RecordingControllerError.captureShutdownFailed(let cause) = error {
                transition(to: .error(.captureStopFailed(cause.localizedDescription)))
            } else if case SessionError.noAudio = error {
                transition(to: .error(.noAudio))
            } else {
                transition(to: .error(.stopFailed(error.localizedDescription)))
            }
        }
    }

    func toggleRecording() async {
        switch state {
        case .idle, .error:
            await startRecording()
        case .recording:
            await stopRecording()
        case .starting, .stopping, .recovering:
            break
        }
    }

    func stopAndStartNewTake() async {
        guard state == .recording else { return }
        await stopRecording()
        guard state == .idle else { return }
        await startRecording()
    }

    private func handleStreamFailure(_ message: String) {
        guard state == .recording else { return }
        stopTimer()
        isFinalizingAfterFailure = true
        waveformSamples = Array(repeating: 0, count: 200)
        transition(to: .error(.streamFailed(message)))
        failureFinalizationTask = Task { [weak self] in
            await self?.controller.finalizeAfterFailure()
            self?.isFinalizingAfterFailure = false
            self?.failureFinalizationTask = nil
        }
    }

    func waitForFailureFinalization() async {
        await failureFinalizationTask?.value
    }

    private func transition(to next: RecordingState) {
        guard state.canTransition(to: next) else {
            Log.recorder.error(
                """
                Rejected illegal recording-state transition: \
                \(String(describing: self.state), privacy: .public) → \
                \(String(describing: next), privacy: .public)
                """)
            return
        }
        state = next
        if next.allowsCaptureSourceChange { audioTest?.recordingFinished() }
        if case .error(let recorderError) = next {
            presentError(recorderError.message, recovery: recorderError.recovery)
        }
    }

    private func startTimer() {
        clock.startTicking(every: 0.1) { [weak self] in
            guard let self, let startTime = self.recordingStartTime else { return }
            self.duration = self.clock.now.timeIntervalSince(startTime)
            self.refreshCaptureHealth()
            if !self.longRecordingWarned && self.duration >= DiskSpace.longRecordingThreshold {
                self.longRecordingWarned = true
                self.showLongRecordingWarning = true
            }
        }
    }

    func refreshCaptureHealth() {
        healthTime = ProcessInfo.processInfo.systemUptime
        sourceHealth = controller.sourceHealth
    }

    private func stopTimer() {
        clock.stopTicking()
    }

    func enableAutomaticRouting(_ devices: [InputDeviceInfo]) {
        automaticRoutingEnabled = true
        refreshAvailableRoutingSources(devices)
    }

    func refreshAvailableRoutingSources(_ devices: [InputDeviceInfo]) {
        guard allowsCaptureSourceChange, !isFinalizingAfterFailure else { return }
        setCaptureSource(automaticRouting.selection(from: selectedSource, devices: devices))
    }

    func setCaptureSource(_ source: AudioSource) {
        guard allowsCaptureSourceChange, source != selectedSource else { return }
        sourceRevision &+= 1
        audioSource.setSelectedSource(source)
    }

    func performRecovery() {
        let suggestion = recoverySuggestion
        showError = false
        switch suggestion {
        case .openSettings:
            openSystemSettings()
        case .openMicrophoneSettings:
            permissionCoordinator.openSystemPreferences(for: .microphone)
        case .tryAgain:
            Task { await startRecording() }
        case .chooseFolder:
            chooseSaveLocation()
        case nil:
            break
        }
    }

}
