import Foundation

nonisolated enum RecorderError: Error, Equatable, Sendable {
    case startFailed(String), sourceUnavailable(AudioSourceError), microphoneDenied
    case noAudio, stopFailed(String), captureStopFailed(String), streamFailed(String)
    case diskFull, saveLocationUnavailable

    var detail: String {
        if case .sourceUnavailable(let problem) = self { return problem.localizedDescription }
        switch self {
        case .startFailed(let text), .stopFailed(let text), .captureStopFailed(let text), .streamFailed(let text): return text
        case .microphoneDenied: return "microphone access denied"
        case .noAudio: return "no captured audio frames"
        case .diskFull: return "insufficient free disk space"
        case .saveLocationUnavailable: return "configured save folder is missing or unwritable"
        case .sourceUnavailable: return "capture source unavailable"
        }
    }
    var message: String {
        switch self {
        case .startFailed:
            "RecScribe couldn't start recording. Check the selected sources and their recording permissions, then try again."
        case .sourceUnavailable(let problem): problem.localizedDescription
        case .microphoneDenied: "RecScribe doesn't have permission to use the microphone."
        case .noAudio: "No audio data was captured. Check the selected sources and their permissions, then record again."
        case .stopFailed: "RecScribe couldn't finish saving the recording. Open Recordings to verify or recover the saved parts."
        case .captureStopFailed: "Audio capture did not shut down cleanly. Open Recordings to verify the saved parts before starting another take."
        case .streamFailed: "Recording was interrupted. Open Recordings to verify the saved audio and review its ending before use. Sleep, a disconnected source or a capture error can interrupt recording."
        case .diskFull: "Free space on the recording volume before starting another take."
        case .saveLocationUnavailable: "The selected recording folder is unavailable. This take is being saved to Desktop."
        }
    }
    var recovery: RecoverySuggestion? {
        if self == .microphoneDenied { return .openMicrophoneSettings }
        if self == .saveLocationUnavailable { return .chooseFolder }
        if case .startFailed = self { return .tryAgain }
        return nil
    }
}

nonisolated enum RecoverySuggestion: Equatable, Sendable {
    case openSettings, openMicrophoneSettings, tryAgain, chooseFolder
    var label: String {
        if self == .chooseFolder { return "Choose folder…" }
        return self == .tryAgain ? "Try again" : "Open settings"
    }
}

/// Compatibility states of a take. The transition graph is explicit and error
/// payloads never affect which outgoing transitions are admitted.
nonisolated enum RecordingState: Equatable, Sendable {
    case idle, starting, recording, stopping, error(RecorderError), recovering
    private enum Phase: Int, Hashable { case idle, starting, recording, stopping, failure, recovering }
    private var phase: Phase {
        switch self {
        case .idle: .idle
        case .starting: .starting
        case .recording: .recording
        case .stopping: .stopping
        case .error: .failure
        case .recovering: .recovering
        }
    }
    var allowsCaptureSourceChange: Bool { phase == .idle || phase == .failure }
    func canTransition(to destination: Self) -> Bool {
        let edges: [Phase: Set<Phase>] = [
            .idle: [.starting], .starting: [.recording, .failure, .idle],
            .recording: [.stopping, .failure, .recovering], .stopping: [.idle, .failure],
            .failure: [.idle, .starting], .recovering: [.recording, .stopping, .failure]
        ]
        return edges[phase]?.contains(destination.phase) == true
    }
    func heading(duration: String) -> String {
        if self == .recording { return duration }
        if self == .idle { return "Ready when you are" }
        if self == .starting { return "Starting recording…" }
        if self == .stopping { return "Saving recording…" }
        if self == .recovering { return "Recovering recording…" }
        switch self {
        case .error(.noAudio): return "No audio captured"
        case .error(.streamFailed): return "Recording interrupted"
        case .error(.stopFailed), .error(.captureStopFailed): return "Recording needs review"
        default: return "Recording unavailable"
        }
    }
}
