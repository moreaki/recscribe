import AppKit

/// Read-through presentation and compatibility bindings. State lives on the
/// corresponding observable controller, so unrelated reads stay independent.
@MainActor
extension RecorderViewModel {
    // Compatibility accessors preserve existing view bindings while reads track
    // only the property on the responsible subcontroller.
    var sourceHealth: [SourceRecordingHealth] {
        get { telemetry.sourceHealth }
        set { telemetry.sourceHealth = newValue }
    }
    var healthTime: TimeInterval {
        get { telemetry.healthTime }
        set { telemetry.healthTime = newValue }
    }
    var duration: TimeInterval {
        get { telemetry.duration }
        set { telemetry.duration = newValue }
    }
    var waveformSamples: [Float] {
        get { telemetry.waveformSamples }
        set { telemetry.waveformSamples = newValue }
    }
    var errorMessage: String? {
        get { alerts.errorMessage }
        set { alerts.errorMessage = newValue }
    }
    var showError: Bool {
        get { alerts.showError }
        set { alerts.showError = newValue }
    }
    var recoverySuggestion: RecoverySuggestion? {
        get { alerts.recoverySuggestion }
        set { alerts.recoverySuggestion = newValue }
    }
    var showLongRecordingWarning: Bool {
        get { alerts.showLongRecordingWarning }
        set { alerts.showLongRecordingWarning = newValue }
    }
    var showOnboarding: Bool {
        get { preferences.showOnboarding }
        set { preferences.showOnboarding = newValue }
    }
    var saveLocationName: String { preferences.saveLocationName }
    var hasCustomSaveLocation: Bool { preferences.hasCustomSaveLocation }
    var saveLocationPath: String { preferences.saveLocationPath }
    var permissionStatus: PermissionStatus {
        get { permissionCoordinator.permissionStatus }
        set { permissionCoordinator.permissionStatus = newValue }
    }
    var isOpeningSystemSettings: Bool { permissionCoordinator.isOpeningSystemSettings }
    var installLocation: InstallLocation { installLocationMonitor.installLocation }
    var showsInstallLocationNotice: Bool { installLocationMonitor.showsInstallLocationNotice }
    var installNoticeDismissed: Bool { installLocationMonitor.installNoticeDismissed }
    var installNotice: String? { installLocationMonitor.installNotice }
    var visibleWindowCount: Int { installLocationMonitor.visibleWindowCount }

    var installLocationBlocksRecording: Bool { installLocation.blocksRecording }
    var grantWatcherIsPolling: Bool { permissionCoordinator.isPolling }
    var formattedDuration: String { telemetry.formattedDuration }
    func checkPermission() async { await permissionCoordinator.checkPermission() }
    func requestPermission() async {
        if !(await permissionCoordinator.requestScreenCapturePermission()) {
            presentError(
                "Allow RecScribe under Screen Recording in System Settings to capture playback audio. Screen frames are discarded.",
                recovery: .openSettings)
        }
    }
    func requestMicrophoneAccess() async -> Bool {
        await permissionCoordinator.requestMicrophoneAccess()
    }
    func openSystemSettings() {
        guard !installLocationBlocksRecording else {
            showInstallLocationNotice()
            return
        }
        permissionCoordinator.openSystemSettings()
    }
    func mainWindowDidAppear() { installLocationMonitor.mainWindowDidAppear() }
    func mainWindowDidDisappear() { installLocationMonitor.mainWindowDidDisappear() }
    func showInstallLocationNotice() { installLocationMonitor.showNotice() }
    func dismissInstallLocationNotice() { installLocationMonitor.dismissNotice() }
    func revealAppInFinder() { installLocationMonitor.revealAppInFinder() }
    func chooseSaveLocation() { preferences.chooseSaveLocation() }
    func resetSaveLocation() { preferences.resetSaveLocation() }
    func completeOnboarding() { preferences.completeOnboarding() }
    func showOnboardingAgain() { preferences.showOnboarding = true }
    func presentError(_ message: String, recovery: RecoverySuggestion?) {
        alerts.present(message, recovery: recovery)
    }

    func revealInFinder() {
        guard let url = lastRecordingURL else { return }

        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    var hasInterruptedSource: Bool {
        isRecording && sourceHealth.contains(where: { $0.health.failed })
    }

    var interruptedSourceSummary: String? {
        guard isRecording else { return nil }
        let failed = sourceHealth.filter { $0.health.failed }
        guard !failed.isEmpty else { return nil }
        let names = failed.map(\.name).joined(separator: ", ")
        return "\(names) interrupted; unaffected sources continue recording."
    }

    var captureSourceName: String? {
        let source = selectedSource
        switch source.kind {
        case .multiple:
            if source.requiresScreenCapture {
                let playback =
                    source.appBundleID.map { audioSource.knownAppName(forBundleID: $0) ?? $0 }
                    ?? "System audio"
                return "\(playback) + \(source.inputs.count) inputs"
            }
            return "\(source.inputs.count) inputs"
        case .mixed:
            let playback =
                source.appBundleID.map { audioSource.knownAppName(forBundleID: $0) ?? $0 }
                ?? "System audio"
            let uid = source.microphoneUID ?? ""
            let mic =
                audioSource.availableInputDevices().first { $0.uid == uid }?.name ?? "Microphone"
            return "\(playback) + \(mic)"
        case .systemAll:
            return nil
        case .app:
            guard let bundleID = source.appBundleID else { return nil }
            return audioSource.knownAppName(forBundleID: bundleID) ?? bundleID
        case .microphone:
            let uid = source.microphoneUID ?? ""
            return audioSource.availableInputDevices()
                .first { $0.uid == uid }?.name ?? "Microphone"
        }
    }

    var captureSourceHint: String {
        let source = selectedSource
        switch source.kind {
        case .multiple:
            return
                "System or selected-app playback plus the selected inputs. Each device has a separate source track and contributes to the derived mix. Microphones and interfaces are added automatically between recordings. Enable virtual inputs explicitly in Audio routing. Manual mute settings are kept."
        case .mixed:
            return
                "Playback + selected input · separate source tracks and a stereo mix. Use headphones to avoid speaker recapture."
        case .systemAll:
            return "System playback only · microphone excluded"
        case .app:
            return "Selected app playback only · microphone excluded"
        case .microphone:
            return "Selected input only · system playback excluded"
        }
    }

    var statusText: String {
        if case .error(let failure) = state { return failure.message }
        if state == .starting { return "Starting…" }
        if state == .stopping { return "Stopping…" }
        if state == .recovering { return "Recovering…" }
        if state == .recording { return ["Recording", captureSourceName].compactMap { $0 }.joined(separator: " ") }
        if installLocationBlocksRecording { return "Move to Applications" }
        if requiresScreenCapturePermission, permissionStatus != .granted { return "Almost ready" }
        return captureSourceName.map { "Ready to record " + $0 } ?? "Play something, then hit record"
    }
}
