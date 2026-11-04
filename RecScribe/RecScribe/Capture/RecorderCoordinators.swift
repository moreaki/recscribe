import AppKit
import Foundation
import Observation
import SwiftUI

/// Isolates high-frequency capture telemetry (`duration`, `waveformSamples`,
/// `sourceHealth`, and `healthTime`) from capture controls
/// so only leaf status, waveform, and health subviews re-evaluate at 10–30 Hz (#41).
@MainActor
@Observable final class RecorderTelemetry {
    var sourceHealth: [SourceRecordingHealth] = []
    var healthTime = ProcessInfo.processInfo.systemUptime
    var duration: TimeInterval = 0
    var waveformSamples: [Float] = Array(repeating: 0, count: 200)

    var formattedDuration: String {
        let minutes = Int(duration) / 60
        let seconds = Int(duration) % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }
}

/// Coordinates Screen Recording and Microphone permission probing, registration waits,
/// and live grant polling (#41).
@MainActor
@Observable final class PermissionCoordinator {
    var permissionStatus: PermissionStatus
    private(set) var isOpeningSystemSettings = false
    private let blocked: Bool
    private let notificationCenter: NotificationCenter
    @ObservationIgnored nonisolated(unsafe) private var activationObserver: NSObjectProtocol?
    private let permissions: PermissionProviding
    private let pollClock: PollClock
    private let registrationTimeout: TimeInterval
    private(set) var hasSoughtPermission = false
    private var permissionProbe: Task<PermissionStatus, Never>?
    private var grantWatcher: PermissionGrantWatcher?
    private var permissionGeneration = 0

    init(
        permissions: PermissionProviding,
        pollClock: PollClock,
        registrationTimeout: TimeInterval,
        blocked: Bool = false,
        notificationCenter: NotificationCenter = .default
    ) {
        self.permissions = permissions
        self.pollClock = pollClock
        self.registrationTimeout = registrationTimeout
        self.blocked = blocked
        self.notificationCenter = notificationCenter
        // Silent preflight only. Authoritative probes require an explicit request.
        self.permissionStatus = permissions.preflight()
        activationObserver = notificationCenter.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.hasSoughtPermission, !self.blocked,
                    self.permissionStatus != .granted
                else { return }
                await self.checkPermission()
            }
        }
    }

    var isPolling: Bool { grantWatcher?.isPolling ?? false }

    func markPermissionSought() {
        hasSoughtPermission = true
        permissions.beginUserRequest(.screenCapture)
    }

    func checkPermission() async {
        if let inFlight = permissionProbe {
            _ = await inFlight.value
            return
        }
        let generation = permissionGeneration
        let probe = Task { await permissions.checkPermission() }
        permissionProbe = probe
        let status = await probe.value
        permissionProbe = nil
        guard generation == permissionGeneration else { return }
        permissionStatus = status
    }

    private func applyObservedGrant() {
        permissionGeneration += 1
        permissionStatus = .granted
    }

    func requestScreenCapturePermission() async -> Bool {
        hasSoughtPermission = true
        let granted = await permissions.requestPermission()
        permissionStatus = granted ? .granted : .denied
        return granted
    }

    func requestMicrophoneAccess() async -> Bool {
        await permissions.requestPermission(.microphone)
    }

    func startGrantWatcher(onGranted: @escaping @MainActor () -> Void) {
        if grantWatcher == nil {
            let watcher = PermissionGrantWatcher(permissions: permissions, clock: pollClock)
            watcher.onGranted = onGranted
            grantWatcher = watcher
        }
        grantWatcher?.startPolling()
    }

    func awaitRegistration(probeAction: @escaping @MainActor () async -> Void) async {
        let probe = Task { await probeAction() }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let resumer = OnceResumer(continuation)
            Task { @MainActor in
                await probe.value
                resumer.resume()
            }
            Task { @MainActor [pollClock, registrationTimeout] in
                try? await pollClock.sleep(for: registrationTimeout)
                resumer.resume()
            }
        }
    }

    deinit {
        if let activationObserver { notificationCenter.removeObserver(activationObserver) }
    }

    /// One deliberate retry registers the app before opening Settings. A slow
    /// probe outlives the deadline without fabricating a denial or being cancelled.
    func openSystemSettings() {
        guard !blocked, !isOpeningSystemSettings else { return }
        markPermissionSought()
        startGrantWatcher { [weak self] in self?.applyObservedGrant() }
        isOpeningSystemSettings = true
        Task { [weak self] in
            guard let self else { return }
            await self.awaitRegistration { [weak self] in await self?.checkPermission() }
            self.isOpeningSystemSettings = false
            guard self.permissionStatus != .granted else { return }
            self.permissions.openSystemPreferences()
        }
    }

    func openSystemPreferences(for kind: PermissionKind) {
        permissions.openSystemPreferences(for: kind)
    }
}

/// Manages install-location visibility tracking and fallback floating-panel presentation (#41).
@MainActor
@Observable final class InstallLocationMonitor {
    let installLocation: InstallLocation
    private let provider: InstallLocationProviding
    private let presenter: (() -> Void)?
    private let notificationCenter: NotificationCenter
    @ObservationIgnored nonisolated(unsafe) private var launchObserver: NSObjectProtocol?
    private var panel: FloatingPanelHost?
    private(set) var visibleWindowCount = 0
    private(set) var showsInstallLocationNotice: Bool
    private(set) var installNoticeDismissed = false

    var installNotice: String? {
        guard let text = installLocation.explanation else { return nil }
        if installLocation.noticeIsDismissible && installNoticeDismissed { return nil }
        return text
    }

    init(
        provider: InstallLocationProviding, presenter: (() -> Void)? = nil,
        notificationCenter: NotificationCenter = .default
    ) {
        self.provider = provider
        self.installLocation = provider.location
        self.presenter = presenter
        self.notificationCenter = notificationCenter
        showsInstallLocationNotice = provider.location.blocksRecording
        if provider.location.blocksRecording {
            launchObserver = notificationCenter.addObserver(
                forName: NSApplication.didFinishLaunchingNotification,
                object: nil, queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self, self.visibleWindowCount == 0 else { return }
                    self.showNotice()
                }
            }
        }
    }

    deinit {
        if let launchObserver { notificationCenter.removeObserver(launchObserver) }
    }

    func mainWindowDidAppear() {
        visibleWindowCount += 1
        panel?.dismiss()
    }

    func mainWindowDidDisappear() {
        visibleWindowCount = max(0, visibleWindowCount - 1)
        if installLocation.blocksRecording && visibleWindowCount == 0 { showNotice() }
    }

    /// Main windows carry the notice inline; a floating panel is only a fallback
    /// for a blocked menu-bar-only launch or after the last window closes.
    func showNotice() {
        guard let message = installNotice else { return }
        showsInstallLocationNotice = true
        if visibleWindowCount > 0 {
            panel?.dismiss()
            return
        }
        if let presenter {
            presenter()
            return
        }
        if panel == nil {
            let host = FloatingPanelHost(title: "RecScribe", width: 340) { [weak self] in
                AnyView(
                    InstallLocationNoticeView(
                        message: message,
                        onReveal: { [weak self] in self?.revealAppInFinder() },
                        onDismiss: { [weak self] in self?.dismissNotice() }))
            }
            host.onWillClose = { [weak self] in self?.showsInstallLocationNotice = false }
            panel = host
        }
        panel?.show()
    }

    func dismissNotice() {
        showsInstallLocationNotice = false
        if installLocation.noticeIsDismissible { installNoticeDismissed = true }
        panel?.dismiss()
    }

    func revealAppInFinder() {
        NSWorkspace.shared.activateFileViewerSelecting([provider.bundleURL])
    }
}

/// Resumes a continuation exactly once, whichever racer gets there first.
/// Main-actor isolated, so "exactly once" needs no synchronisation.
@MainActor
private final class OnceResumer {
    private var continuation: CheckedContinuation<Void, Never>?

    init(_ continuation: CheckedContinuation<Void, Never>) {
        self.continuation = continuation
    }

    func resume() {
        continuation?.resume()
        continuation = nil
    }
}
