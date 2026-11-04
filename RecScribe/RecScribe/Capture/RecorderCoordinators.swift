import AppKit
import Combine
import Foundation
import SwiftUI

/// Isolates high-frequency capture telemetry (`duration`, `waveformSamples`,
/// `sourceHealth`, and `healthTime`) from `RecorderViewModel.objectWillChange`
/// so only leaf status, waveform, and health subviews re-evaluate at 10–30 Hz (#41).
@MainActor
final class RecorderTelemetry: ObservableObject {
    @Published var sourceHealth: [SourceRecordingHealth] = []
    @Published var healthTime = ProcessInfo.processInfo.systemUptime
    @Published var duration: TimeInterval = 0
    @Published var waveformSamples: [Float] = Array(repeating: 0, count: 200)

    var formattedDuration: String {
        let minutes = Int(duration) / 60
        let seconds = Int(duration) % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }
}

/// Coordinates Screen Recording and Microphone permission probing, registration waits,
/// and live grant polling (#41).
@MainActor
final class PermissionCoordinator {
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
        registrationTimeout: TimeInterval
    ) {
        self.permissions = permissions
        self.pollClock = pollClock
        self.registrationTimeout = registrationTimeout
    }

    var isPolling: Bool { grantWatcher?.isPolling ?? false }

    func preflight() -> PermissionStatus {
        permissions.preflight()
    }

    func markPermissionSought() {
        hasSoughtPermission = true
    }

    func checkPermission(onUpdate: (PermissionStatus) -> Void) async {
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
        onUpdate(status)
    }

    func applyObservedGrant(onUpdate: (PermissionStatus) -> Void) {
        permissionGeneration += 1
        onUpdate(.granted)
    }

    func requestScreenCapturePermission() async -> Bool {
        hasSoughtPermission = true
        return await permissions.requestPermission()
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

    func openSystemPreferences() {
        permissions.openSystemPreferences()
    }

    func openSystemPreferences(for kind: PermissionKind) {
        permissions.openSystemPreferences(for: kind)
    }
}

/// Manages install-location visibility tracking and fallback floating-panel presentation (#41).
@MainActor
final class InstallLocationMonitor {
    private let provider: InstallLocationProviding
    private let presenter: (() -> Void)?
    private var panel: FloatingPanelHost?
    private(set) var visibleWindowCount = 0

    init(
        provider: InstallLocationProviding,
        presenter: (() -> Void)? = nil
    ) {
        self.provider = provider
        self.presenter = presenter
    }

    func mainWindowDidAppear() {
        visibleWindowCount += 1
        panel?.dismiss()
    }

    func mainWindowDidDisappear(onLastWindowClosedWhenBlocked: () -> Void) {
        visibleWindowCount = max(0, visibleWindowCount - 1)
        if provider.location.blocksRecording && visibleWindowCount == 0 {
            onLastWindowClosedWhenBlocked()
        }
    }

    func showNotice(
        message: String,
        onReveal: @escaping () -> Void,
        onDismiss: @escaping () -> Void,
        onPanelWillClose: @escaping () -> Void
    ) {
        if visibleWindowCount > 0 {
            panel?.dismiss()
            return
        }
        if let presenter {
            presenter()
            return
        }
        if panel == nil {
            let host = FloatingPanelHost(title: "RecScribe", width: 340) {
                AnyView(
                    InstallLocationNoticeView(
                        message: message,
                        onReveal: onReveal,
                        onDismiss: onDismiss
                    )
                )
            }
            host.onWillClose = onPanelWillClose
            panel = host
        }
        panel?.show()
    }

    func dismissPanel() {
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
