import AppKit
import Observation
import SwiftUI

@MainActor @Observable final class RecorderTelemetry {
    var sourceHealth: [SourceRecordingHealth] = [] {
        didSet {
            let names = sourceHealth.filter { $0.health.failed }.map(\.name).joined(separator: ", ")
            let summary = names.isEmpty ? nil : "\(names) interrupted; unaffected sources continue recording."
            if interruptedSourceSummary != summary { interruptedSourceSummary = summary }
        }
    }
    private(set) var interruptedSourceSummary: String?
    private(set) var detailSources: [SourceRecordingHealth] = []
    /// Only topology/health transitions affect SwiftUI geometry. Numeric detail
    /// and meter changes repaint native readouts without relaying out the rail.
    private(set) var layoutSources: [SourceRecordingHealth] = []
    private(set) var detailTime: TimeInterval = 0
    /// Detailed text is diagnostic, not a meter. Keep its expensive text layout
    /// out of the 10 Hz meter/health loop, but publish status changes immediately.
    static let detailInterval: TimeInterval = 1

    func refreshDetails() {
        let structuralChange = sourceHealth.count != detailSources.count || zip(sourceHealth, detailSources).contains { next, old in
            next.id != old.id || next.name != old.name || next.detail != old.detail
                || next.health.startedAt != old.health.startedAt
                || next.health.channels != old.health.channels || next.health.sampleRate != old.health.sampleRate
                || next.health.failureMessage != old.health.failureMessage || next.health.clipped != old.health.clipped
                || next.health.status(at: healthTime) != old.health.status(at: detailTime)
        }
        guard structuralChange || healthTime < detailTime || healthTime - detailTime >= Self.detailInterval else { return }
        if structuralChange { layoutSources = sourceHealth }
        detailSources = sourceHealth
        detailTime = healthTime
    }
    var sourceMeters: [CaptureTrack: CaptureSourceMeters] = [:]
    var healthTime = ProcessInfo.processInfo.systemUptime
    var duration: TimeInterval = 0
    var waveformSamples = [Float](repeating: 0, count: 200)
    var formattedDuration: String {
        let elapsed = duration.isFinite ? Int(max(0, min(Double(Int.max).nextDown, duration))) : 0
        return String(format: "%02d:%02d", elapsed / 60, elapsed % 60)
    }
}

@MainActor @Observable final class PermissionCoordinator {
    var permissionStatus: PermissionStatus
    private(set) var isOpeningSystemSettings = false
    private(set) var hasSoughtPermission = false
    var isPolling: Bool { watcher?.isPolling == true }
    private let permissions: PermissionProviding
    private let pollClock: PollClock
    private let registrationTimeout: TimeInterval
    private let blocked: Bool
    private let notifications: NotificationCenter
    @ObservationIgnored nonisolated(unsafe) private var activation: NSObjectProtocol?
    private var watcher: PermissionGrantWatcher?
    private var grantRevision = 0
    private struct Probe {
        let identity = UUID()
        let revision: Int
        let result: Task<PermissionStatus, Never>
    }
    private var pending: Probe?

    init(permissions: PermissionProviding, pollClock: PollClock, registrationTimeout: TimeInterval,
         blocked: Bool = false, notificationCenter: NotificationCenter = .default) {
        self.permissions = permissions
        self.pollClock = pollClock
        self.registrationTimeout = registrationTimeout
        self.blocked = blocked
        notifications = notificationCenter
        permissionStatus = permissions.preflight()
        activation = notificationCenter.addObserver(forName: NSApplication.didBecomeActiveNotification,
                                                    object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.hasSoughtPermission, !self.blocked, self.permissionStatus != .granted else { return }
                await self.checkPermission()
            }
        }
    }
    func markPermissionSought() {
        permissions.beginUserRequest(.screenCapture)
        hasSoughtPermission = true
    }
    func checkPermission() async {
        let request: Probe
        if let shared = pending { request = shared }
        else {
            request = Probe(revision: grantRevision, result: Task { await permissions.checkPermission() })
            pending = request
        }
        let response = await request.result.value
        if pending?.identity == request.identity { pending = nil }
        if grantRevision == request.revision { permissionStatus = response }
    }
    func requestScreenCapturePermission() async -> Bool {
        hasSoughtPermission = true
        let revision = grantRevision
        let permitted = await permissions.requestPermission()
        if revision == grantRevision { permissionStatus = permitted ? .granted : .denied }
        return permissionStatus == .granted
    }
    func requestMicrophoneAccess() async -> Bool { await permissions.requestPermission(.microphone) }
    func startGrantWatcher(onGranted: @escaping @MainActor () -> Void) {
        if watcher == nil {
            let observation = PermissionGrantWatcher(permissions: permissions, clock: pollClock)
            observation.onGranted = onGranted
            watcher = observation
        }
        watcher?.startPolling()
    }
    func awaitRegistration(probeAction: @escaping @MainActor () async -> Void) async {
        let registration = Task { await probeAction() }
        await withCheckedContinuation { continuation in
            let latch = RegistrationCompletion(continuation)
            let deadline = Task { [pollClock, registrationTimeout] in
                do { try await pollClock.sleep(for: registrationTimeout) }
                catch { return }
                latch.finish()
            }
            Task {
                await registration.value
                deadline.cancel()
                latch.finish()
            }
        }
    }
    func openSystemSettings() {
        guard !blocked, !isOpeningSystemSettings else { return }
        markPermissionSought()
        startGrantWatcher { [weak self] in
            self?.grantRevision += 1
            self?.permissionStatus = .granted
        }
        isOpeningSystemSettings = true
        Task { [weak self] in
            guard let self else { return }
            await self.awaitRegistration { [weak self] in await self?.checkPermission() }
            self.isOpeningSystemSettings = false
            if self.permissionStatus != .granted { self.permissions.openSystemPreferences() }
        }
    }
    func openSystemPreferences(for kind: PermissionKind) { permissions.openSystemPreferences(for: kind) }
    deinit { if let activation { notifications.removeObserver(activation) } }
}

@MainActor private final class RegistrationCompletion {
    private var waiting: CheckedContinuation<Void, Never>?
    init(_ continuation: CheckedContinuation<Void, Never>) { waiting = continuation }
    func finish() {
        let continuation = waiting
        waiting = nil
        continuation?.resume()
    }
}

@MainActor @Observable final class InstallLocationMonitor {
    let installLocation: InstallLocation
    private let provider: InstallLocationProviding
    private let presenter: (() -> Void)?
    private let notifications: NotificationCenter
    @ObservationIgnored nonisolated(unsafe) private var launch: NSObjectProtocol?
    private var panel: FloatingPanelHost?
    private(set) var visibleWindowCount = 0
    private(set) var showsInstallLocationNotice: Bool
    private(set) var installNoticeDismissed = false
    var installNotice: String? {
        installNoticeDismissed && installLocation.noticeIsDismissible ? nil : installLocation.explanation
    }
    init(provider: InstallLocationProviding, presenter: (() -> Void)? = nil,
         notificationCenter: NotificationCenter = .default) {
        self.provider = provider
        self.presenter = presenter
        notifications = notificationCenter
        installLocation = provider.location
        showsInstallLocationNotice = provider.location.blocksRecording
        if provider.location.blocksRecording {
            launch = notificationCenter.addObserver(forName: NSApplication.didFinishLaunchingNotification,
                                                    object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in
                    if self?.visibleWindowCount == 0 { self?.showNotice() }
                }
            }
        }
    }
    func mainWindowDidAppear() { visibleWindowCount += 1; panel?.dismiss() }
    func mainWindowDidDisappear() {
        visibleWindowCount = max(0, visibleWindowCount - 1)
        if visibleWindowCount == 0, installLocation.blocksRecording { showNotice() }
    }
    func showNotice() {
        guard let text = installNotice else { return }
        showsInstallLocationNotice = true
        guard visibleWindowCount == 0 else { panel?.dismiss(); return }
        if let presenter { presenter(); return }
        if panel == nil {
            let created = FloatingPanelHost(title: "RecScribe", width: 340) { [weak self] in
                AnyView(InstallLocationNoticeView(message: text, onReveal: { self?.revealAppInFinder() },
                                                onDismiss: { self?.dismissNotice() }))
            }
            created.onWillClose = { [weak self] in self?.showsInstallLocationNotice = false }
            panel = created
        }
        panel?.show()
    }
    func dismissNotice() {
        if installLocation.noticeIsDismissible { installNoticeDismissed = true }
        showsInstallLocationNotice = false
        panel?.dismiss()
    }
    func revealAppInFinder() { NSWorkspace.shared.activateFileViewerSelecting([provider.bundleURL]) }
    deinit { if let launch { notifications.removeObserver(launch) } }
}
