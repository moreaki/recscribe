import AVFoundation
import Foundation
@testable import RecScribe

private struct CallLedger {
    private var counts: [String: Int] = [:]
    mutating func record(_ operation: String) { counts[operation, default: 0] += 1 }
    subscript(_ operation: String) -> Int { counts[operation, default: 0] }
}

@MainActor final class MockAudioCapturing: AudioCapturing {
    private var calls = CallLedger()
    var capturing = false
    var onInputAvailable: (@MainActor (InputDeviceInfo, InputSelection) async -> Bool)?
    var onSourceFailure: (@MainActor (CaptureTrack, String) -> Void)?
    var onStreamError: (@MainActor (String) -> Void)?
    var setupError: Error?
    var stopError: Error?
    var onStart: (() -> Void)?
    var beforeSetup: (() async -> Void)?
    private(set) var lastSource: AudioSource?
    private var pcm: (@Sendable (AVAudioPCMBuffer) -> Void)?
    private var packets: (@Sendable (CapturedAudioSample) -> Void)?
    var setupCount: Int { calls["setup"] }
    var startCount: Int { calls["start"] }
    var stopCount: Int { calls["stop"] }
    var cleanupCount: Int { calls["cleanup"] }

    func setupCapture(source: AudioSource, audioCallback: @escaping @Sendable (AVAudioPCMBuffer) -> Void) async throws {
        calls.record("setup")
        if let failure = setupError { throw failure }
        lastSource = source
        pcm = audioCallback
    }
    func setupMultiCapture(source: AudioSource, sampleCallback: @escaping @Sendable (CapturedAudioSample) -> Void) async throws {
        calls.record("setup")
        await beforeSetup?()
        if let failure = setupError { throw failure }
        lastSource = source
        packets = sampleCallback
    }
    func emit(_ sample: CapturedAudioSample) { packets?(sample) }
    func emitPCM(_ buffer: AVAudioPCMBuffer) { pcm?(buffer) }
    func startCapture() async throws {
        calls.record("start")
        capturing = true
        onStart?()
    }
    func stopCapture() async throws {
        calls.record("stop")
        if let failure = stopError { throw failure }
        capturing = false
    }
    func cleanup() async {
        calls.record("cleanup")
        pcm = nil
        packets = nil
        capturing = false
    }
    func simulateStreamError(_ explanation: String) {
        capturing = false
        onStreamError?(explanation)
    }
}

@MainActor final class MockAudioFileWriting: AudioFileWriting {
    private var calls = CallLedger()
    var onWriteError: (@MainActor @Sendable (String) -> Void)?
    var onWaveformData: (@MainActor @Sendable ([Float]) -> Void)?
    private(set) var recording = false
    private(set) var lastStartFormat: AudioFormat?
    var onStop: (() -> Void)?
    var stopError: Error?
    var startCount: Int { calls["start"] }
    var stopCount: Int { calls["stop"] }
    func startRecording(to fileURL: URL, format: AudioFormat) throws {
        calls.record("start")
        lastStartFormat = format
        recording = true
    }
    nonisolated func processAudioSample(_ pcmBuffer: AVAudioPCMBuffer) {}
    func stopRecording() async throws {
        calls.record("stop")
        recording = false
        onStop?()
        if let failure = stopError { throw failure }
    }
}

/// A provider can retain the state seen when a request began, or answer with
/// current state on release. Those distinct modes exercise stale-result handling.
@MainActor final class MockPermissionProviding: PermissionProviding {
    private var calls = CallLedger()
    var status: PermissionStatus
    var micStatus: PermissionStatus?
    var preflightStatus: PermissionStatus?
    var holdsChecks = false
    var answersWithStatusAtIssue = false
    private var waiting: [CheckedContinuation<Void, Never>] = []
    private(set) var requestedKinds: [PermissionKind] = []
    private(set) var requestedPermissionKinds: [PermissionKind] = []
    var checkCount: Int { calls["check"] }
    var preflightCount: Int { calls["preflight"] }
    var openSettingsCount: Int { calls["settings"] }
    init(_ status: PermissionStatus = .granted) { self.status = status }
    func preflight(_ kind: PermissionKind = .screenCapture) -> PermissionStatus {
        calls.record("preflight")
        if kind == .microphone { return micStatus ?? preflightStatus ?? status }
        return preflightStatus ?? status
    }
    func checkPermission(_ kind: PermissionKind = .screenCapture) async -> PermissionStatus {
        calls.record("check")
        requestedKinds.append(kind)
        let captured = answersWithStatusAtIssue ? status : nil
        if holdsChecks { await withCheckedContinuation { waiting.append($0) } }
        return captured ?? status
    }
    func requestPermission(_ kind: PermissionKind = .screenCapture) async -> Bool {
        requestedPermissionKinds.append(kind)
        return (kind == .microphone ? micStatus ?? status : status) == .granted
    }
    func openSystemPreferences(for kind: PermissionKind = .screenCapture) { calls.record("settings") }
    func resumePendingChecks() {
        let suspended = waiting
        waiting.removeAll()
        for continuation in suspended { continuation.resume() }
    }
}

@MainActor final class NeverPollClock: PollClock {
    func sleep(for interval: TimeInterval) async throws { try await Task.sleep(for: .seconds(86_400)) }
}
@MainActor final class ImmediatePollClock: PollClock {
    private(set) var sleepCount = 0
    func sleep(for interval: TimeInterval) async throws {
        sleepCount += 1
        try Task.checkCancellation()
        await Task.yield()
    }
}

@MainActor final class MockAudioSourceProviding: AudioSourceProviding {
    private var calls = CallLedger()
    var selectedSource: AudioSource
    var validateError: Error?
    var availableAppsResult: [RunningAppInfo] = []
    var availableInputDevicesResult: [InputDeviceInfo] = []
    var knownAppNamesResult: [String: String] = [:]
    var setCount: Int { calls["set"] }
    var validateCount: Int { calls["validate"] }
    var availableAppsCallCount: Int { calls["apps"] }
    init(selectedSource: AudioSource = .systemAll) { self.selectedSource = selectedSource }
    func setSelectedSource(_ value: AudioSource) { calls.record("set"); selectedSource = value }
    func validate(_ value: AudioSource) async throws {
        calls.record("validate")
        if let failure = validateError { throw failure }
    }
    func availableApps() async throws -> [RunningAppInfo] { calls.record("apps"); return availableAppsResult }
    func availableInputDevices() -> [InputDeviceInfo] { availableInputDevicesResult }
    func knownAppName(forBundleID bundleID: String) -> String? { knownAppNamesResult[bundleID] }
}
@MainActor final class MockSaveLocationProviding: SaveLocationProviding {
    private var calls = CallLedger()
    var configuredDirectory: URL?
    var resolvedDirectory: URL
    var isConfiguredLocationUnavailable = false
    var setCount: Int { calls["set"] }
    var resetCount: Int { calls["reset"] }
    init(directory: URL) { configuredDirectory = directory; resolvedDirectory = directory }
    func setSaveDirectory(_ selected: URL) {
        calls.record("set")
        configuredDirectory = selected
        resolvedDirectory = selected
    }
    func reset() { calls.record("reset"); configuredDirectory = nil }
}
@MainActor final class MockInstallLocationProviding: InstallLocationProviding {
    var location: InstallLocation
    var bundleURL: URL
    init(_ location: InstallLocation = .applications, bundleURL: URL = .init(fileURLWithPath: "/Applications/RecScribe.app")) {
        self.location = location
        self.bundleURL = bundleURL
    }
}
@MainActor final class ManualClock: DurationClock {
    var now = Date(timeIntervalSinceReferenceDate: 0)
    private var callback: (@MainActor () -> Void)?
    var isTicking: Bool { callback != nil }
    func startTicking(every interval: TimeInterval, onTick: @escaping @MainActor () -> Void) { callback = onTick }
    func stopTicking() { callback = nil }
    func advance(by seconds: TimeInterval) { now.addTimeInterval(seconds); callback?() }
}
@MainActor final class MockRecordingControlling: RecordingControlling {
    private var calls = CallLedger()
    var onWaveformData: (@MainActor @Sendable ([Float]) -> Void)?
    var onStreamError: (@MainActor (String) -> Void)?
    var sourceHealth: [SourceRecordingHealth] = []
    var sourceMeters: [CaptureTrack: CaptureSourceMeters] = [:]
    private(set) var isRecording = false
    private(set) var recordingURL: URL?
    var fileURL = URL(fileURLWithPath: "/tmp/mock-recording.wav")
    var startError: Error?
    var stopError: Error?
    var onFinalize: (() -> Void)?
    var beforeFinalize: (() async -> Void)?
    var startCount: Int { calls["start"] }
    var stopCount: Int { calls["stop"] }
    var finalizeCount: Int { calls["finalize"] }
    func startRecording() async throws -> URL {
        calls.record("start")
        if let failure = startError { throw failure }
        recordingURL = fileURL
        isRecording = true
        return fileURL
    }
    func stopRecording() async throws {
        calls.record("stop")
        if let failure = stopError { throw failure }
        recordingURL = nil
        isRecording = false
    }
    func finalizeAfterFailure() async {
        await beforeFinalize?()
        calls.record("finalize")
        recordingURL = nil
        isRecording = false
        onFinalize?()
    }
    func emitStreamError(_ explanation: String) { onStreamError?(explanation) }
}
