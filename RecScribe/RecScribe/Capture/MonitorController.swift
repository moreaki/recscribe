import AVFoundation
import CoreAudio

enum MonitoringMode: String, Codable, Sendable, CaseIterable {
    case off, whileRecording, always
    var displayName: String {
        if self == .whileRecording { return "While Recording" }
        return self == .always ? "Always" : "Off"
    }
}

enum MonitorError: Error, LocalizedError, Equatable {
    case engineUnavailable(String), deviceUnavailable
    var errorDescription: String? {
        self == .deviceUnavailable ? "The input device for monitoring isn't available." : "RecScribe couldn't start monitoring."
    }
    var recoverySuggestion: String? { "Your recording is unaffected. Check the device, then turn monitoring on again." }
}

@MainActor protocol MonitorControlling: AnyObject {
    var mode: MonitoringMode { get }
    var isMonitoring: Bool { get }
    var onWarning: (@MainActor (MonitorError) -> Void)? { get set }
    func setMode(_ mode: MonitoringMode)
    func recordingStateChanged(isRecording: Bool)
}

/// Compatibility input-monitor service. Its engine has no path to recording
/// failure callbacks and is discarded as soon as monitoring is no longer wanted.
@MainActor final class MonitorController: MonitorControlling {
    private let defaults: UserDefaults
    private let currentDeviceUID: @MainActor () -> String?
    private var graph: AVAudioEngine?
    private var recording = false
    private(set) var mode: MonitoringMode
    var onWarning: (@MainActor (MonitorError) -> Void)?
    var isMonitoring: Bool { graph?.isRunning == true }

    init(defaults: UserDefaults = .standard, currentDeviceUID: @escaping @MainActor () -> String? = { nil }) {
        self.defaults = defaults
        self.currentDeviceUID = currentDeviceUID
        mode = defaults.string(forKey: "monitoringMode").flatMap(MonitoringMode.init(rawValue:)) ?? .off
    }
    func setMode(_ choice: MonitoringMode) {
        mode = choice
        defaults.set(choice.rawValue, forKey: "monitoringMode")
        reconcile()
    }
    func recordingStateChanged(isRecording: Bool) {
        recording = isRecording
        reconcile()
    }
    static func shouldRun(mode: MonitoringMode, isRecording: Bool) -> Bool {
        mode == .always || (mode == .whileRecording && isRecording)
    }
    private func reconcile() {
        guard Self.shouldRun(mode: mode, isRecording: recording) else {
            graph?.stop()
            graph = nil
            return
        }
        if graph != nil { return }
        guard let uid = currentDeviceUID(), let device = AudioDeviceControls.device(uid: uid) else {
            onWarning?(.deviceUnavailable)
            return
        }
        let replacement = AVAudioEngine()
        do {
            guard let unit = replacement.inputNode.audioUnit else { throw MonitorError.deviceUnavailable }
            var selected = device
            let status = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice,
                kAudioUnitScope_Global, 0, &selected, UInt32(MemoryLayout.size(ofValue: selected)))
            guard status == noErr else { throw MonitorError.engineUnavailable("Input device selection failed: \(status)") }
            let microphone = replacement.inputNode
            replacement.connect(microphone, to: replacement.mainMixerNode, format: microphone.outputFormat(forBus: 0))
            try replacement.start()
            graph = replacement
        } catch {
            replacement.stop()
            onWarning?(.engineUnavailable(error.localizedDescription))
        }
    }
}
