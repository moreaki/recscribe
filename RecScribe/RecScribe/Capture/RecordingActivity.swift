import AppKit
import os

/// ScreenCaptureKit uses a display even for audio-only capture. Hold the idle
/// sleep assertions only for the recording lifecycle, not for transcription.
@MainActor
final class RecordingActivity {
    static let options: ProcessInfo.ActivityOptions = [.userInitiated, .idleDisplaySleepDisabled]
    private let center: NotificationCenter
    private let beginActivity: () -> NSObjectProtocol
    private let endActivity: (NSObjectProtocol) -> Void
    private var activity: NSObjectProtocol?
    private var observers: [NSObjectProtocol] = []
    private var started: ContinuousClock.Instant?
    private var id: UUID?
    private(set) var interrupted = false
    var onInterruption: (String) -> Void = { _ in }
    var active: Bool { activity != nil }
    private var elapsedSeconds: Double {
        guard let started else { return 0 }
        let elapsed = started.duration(to: .now).components
        return Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18
    }

    init(center: NotificationCenter = NSWorkspace.shared.notificationCenter,
         beginActivity: @escaping () -> NSObjectProtocol = {
             ProcessInfo.processInfo.beginActivity(options: RecordingActivity.options,
                 reason: "Keeping audio capture and its display source awake")
         }, endActivity: @escaping (NSObjectProtocol) -> Void = { ProcessInfo.processInfo.endActivity($0) }) {
        self.center = center
        self.beginActivity = beginActivity
        self.endActivity = endActivity
    }

    func start() {
        guard !active else { return }
        let id = UUID()
        self.id = id
        interrupted = false
        started = .now
        activity = beginActivity()
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.screensDidSleepNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                // NotificationCenter's explicit main queue is the actor boundary.
                MainActor.assumeIsolated {
                    guard let self, self.id == id, !self.interrupted else { return }
                    self.interrupted = true
                    Log.capture.error("Recording power interruption id=\(id) event=\(name.rawValue, privacy: .public) elapsed_s=\(self.elapsedSeconds)")
                    self.onInterruption("The Mac or its display entered sleep; review the end of the recording")
                }
            })
        }
        Log.capture.notice("Recording sleep protection started id=\(id) system_idle=true display_idle=true")
    }

    func stop() {
        guard let activity else { return }
        for observer in observers { center.removeObserver(observer) }
        observers.removeAll()
        endActivity(activity)
        self.activity = nil
        if let id {
            Log.capture.notice("Recording sleep protection ended id=\(id) elapsed_s=\(self.elapsedSeconds) interrupted=\(self.interrupted)")
        }
        id = nil
        started = nil
    }

    isolated deinit { stop() }
}
