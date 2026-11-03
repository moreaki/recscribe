//
//  ScreenCaptureAudioManager.swift
//  RecScribe
//
//  Manages system audio capture using ScreenCaptureKit
//

import Foundation
import ScreenCaptureKit
import AVFoundation
import os

/// Errors for ScreenCaptureKit audio capture
enum ScreenCaptureAudioError: Error, LocalizedError {
    case notAuthorized
    case noDisplaysAvailable
    case streamCreationFailed
    case startCaptureFailed(Error)
    case interruptedBySleep
    /// The `.app` source's bundle ID has no matching running `SCRunningApplication` (BL-100).
    case appNotRunning(String)

    var errorDescription: String? {
        switch self {
        case .notAuthorized:
            return "Screen Recording permission not granted"
        case .noDisplaysAvailable:
            return "No displays available for capture"
        case .streamCreationFailed:
            return "Failed to create capture stream"
        case .startCaptureFailed(let error):
            return "Failed to start audio capture: \(error.localizedDescription)"
        case .interruptedBySleep:
            return "The Mac or display entered sleep while starting capture. Wake it and start a new recording."
        case .appNotRunning(let bundleID):
            return "The selected app (\(bundleID)) is not currently running."
        }
    }

    var recoverySuggestion: String? {
        switch self {
        case .notAuthorized:
            return "Grant Screen Recording permission in System Settings > Privacy & Security"
        case .noDisplaysAvailable:
            return "Ensure your Mac has at least one display connected"
        case .streamCreationFailed:
            return "Try restarting the application"
        case .startCaptureFailed:
            return "Check if another app is already capturing system audio"
        case .interruptedBySleep:
            return "Keep the Mac open and awake while recording."
        case .appNotRunning:
            return "Open the app, or choose a different capture source."
        }
    }
}

/// Manages system audio capture using ScreenCaptureKit
class ScreenCaptureAudioManager: NSObject, AudioCapturing {

    // MARK: - Properties

    private var stream: SCStream?
    private var isCapturing = false
    private var output: AudioCaptureOutput?
    private var deviceInputs: [CaptureTrack: DeviceInputCapture] = [:]
    private var pendingInputs: [InputSelection] = []
    private var useLegacyMicrophoneTrack = false
    private var singleInputNormalizer: SingleInputAudioNormalizer?
    private var inputCallback: (@Sendable (CapturedAudioSample) -> Void)?
    private var inputGeneration = UUID()
    private var deviceWatchTokens: [UUID] = []
    private let hardwareObserver: AudioHardwareObserver
    var onSourceFailure: (@MainActor (CaptureTrack, String) -> Void)?
    private var stopTask: Task<Void, Error>?

    /// Called when the stream stops unexpectedly. See `AudioCapturing`.
    var onStreamError: (@MainActor (String) -> Void)?

    init(hardwareObserver: AudioHardwareObserver = .shared) {
        self.hardwareObserver = hardwareObserver
        super.init()
    }

    // MARK: - Public Methods

    /// Set up capture for `source` (BL-100 / #40).
    /// When `source.playback == .none`, captures input directly via `DeviceInputCapture`
    /// without creating an `SCStream` or requiring Screen Recording permission.
    func setupCapture(source: AudioSource, audioCallback: @escaping @Sendable (AVAudioPCMBuffer) -> Void) async throws {
        guard source.valid else { throw SessionError.invalid("Invalid capture source selection") }
        if !source.requiresScreenCapture {
            guard let selection = source.inputs.first else {
                throw SessionError.invalid("No input device selected for capture")
            }
            stream = nil
            output = nil
            pendingInputs = [selection]
            useLegacyMicrophoneTrack = false
            let normalizer = SingleInputAudioNormalizer(callback: audioCallback) { [weak self] message in
                self?.onStreamError?(message)
            }
            singleInputNormalizer = normalizer
            inputCallback = { sample in normalizer.accept(sample.buffer) }
            return
        }
        pendingInputs = []
        useLegacyMicrophoneTrack = false
        singleInputNormalizer = nil
        inputCallback = nil
        try await configure(source: source, audioCallback: audioCallback, sampleCallback: nil)
    }

    func setupMultiCapture(source: AudioSource, sampleCallback: @escaping @Sendable (CapturedAudioSample) -> Void) async throws {
        guard source.valid else { throw SessionError.invalid("Invalid multi-input selection") }
        pendingInputs = source.inputs
        useLegacyMicrophoneTrack = (source.kind == .mixed)
        singleInputNormalizer = nil
        inputCallback = sampleCallback
        if source.requiresScreenCapture {
            try await configure(source: source, audioCallback: { _ in }, sampleCallback: sampleCallback)
        } else {
            stream = nil
            output = nil
        }
    }

    /// Filters all running `SCRunningApplication` instances matching `bundleID` (#16),
    /// throwing `ScreenCaptureAudioError.appNotRunning(bundleID)` only when none match.
    static func matchingApplications<App>(
        in applications: [App],
        bundleID: String,
        bundleIdentifier: (App) -> String
    ) throws -> [App] {
        let matched = applications.filter { bundleIdentifier($0) == bundleID }
        guard !matched.isEmpty else {
            throw ScreenCaptureAudioError.appNotRunning(bundleID)
        }
        return matched
    }

    private func configure(source: AudioSource, audioCallback: @escaping @Sendable (AVAudioPCMBuffer) -> Void,
                           sampleCallback: (@Sendable (CapturedAudioSample) -> Void)?) async throws {
        let id = UUID()
        let output = AudioCaptureOutput(id: id, audioCallback: audioCallback, sampleCallback: sampleCallback) { [weak self] message in
            guard let self, self.output?.id == id else { return }
            self.onStreamError?(message)
        }
        self.output = output

        // Get available displays (and, for .app, running applications)
        let content = try await SCShareableContent.excludingDesktopWindows(
            false,
            onScreenWindowsOnly: false
        )

        guard let display = content.displays.first else {
            Log.capture.error("No displays available for audio capture")
            throw ScreenCaptureAudioError.noDisplaysAvailable
        }

        // Configure stream for playback audio capture (#40: microphone inputs use DeviceInputCapture)
        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.excludesCurrentProcessAudio = true  // Don't record our own app
        config.sampleRate = 48000  // 48kHz
        config.channelCount = 2    // Stereo

        // Minimal video configuration (required by SCStream alongside audio)
        config.width = 100
        config.height = 100
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.showsCursor = false
        config.scalesToFit = false

        // Content filter: all display audio, or all matching instances of the selected app (#16).
        let filter: SCContentFilter
        switch source.playback {
        case .none:
            throw SessionError.invalid("Playback stream configuration requires an active playback source")
        case .systemAll:
            filter = SCContentFilter(display: display, excludingWindows: [])
        case .app(let bundleID):
            let apps: [SCRunningApplication]
            do {
                apps = try Self.matchingApplications(
                    in: content.applications,
                    bundleID: bundleID,
                    bundleIdentifier: \.bundleIdentifier
                )
            } catch {
                Log.capture.error("Selected app not running for per-app capture")
                throw error
            }
            filter = SCContentFilter(display: display, including: apps, exceptingWindows: [])
        }

        // Create stream
        stream = SCStream(filter: filter, configuration: config, delegate: self)

        // Add output handlers
        guard let stream = stream else {
            throw ScreenCaptureAudioError.streamCreationFailed
        }

        // Add screen output (required even though we only want audio)
        try stream.addStreamOutput(
            output,
            type: .screen,
            sampleHandlerQueue: output.queue
        )

        try stream.addStreamOutput(output, type: .audio, sampleHandlerQueue: output.queue)

        Log.capture.debug("Capture stream configured (screen + audio handlers added)")
    }

    /// Start audio capture
    /// - Throws: ScreenCaptureAudioError if start fails
    func startCapture() async throws {
        guard stream != nil || !pendingInputs.isEmpty else {
            throw ScreenCaptureAudioError.streamCreationFailed
        }

        do {
            inputGeneration = UUID()
            let generation = inputGeneration
            let isSingleInputOnly = (stream == nil && pendingInputs.count == 1 && singleInputNormalizer != nil)
            if let inputCallback {
                for selection in pendingInputs {
                    let track: CaptureTrack = useLegacyMicrophoneTrack ? .microphone : .input(selection.deviceUID)
                    let input = DeviceInputCapture(uid: selection.deviceUID, track: track, callback: inputCallback) { [weak self] message in
                        guard let self else { return }
                        if isSingleInputOnly {
                            guard self.inputGeneration == generation, self.isCapturing else { return }
                            self.isCapturing = false
                            self.onStreamError?(message)
                        } else {
                            self.inputFailed(track, message: message, generation: generation)
                        }
                    }
                    deviceInputs[track] = input
                    try input.start()
                }
            }
            if let stream {
                try await stream.startCapture()
            }
            isCapturing = true
            if !deviceInputs.isEmpty {
                for (track, input) in deviceInputs {
                    let uid = input.uid
                    let token = hardwareObserver.watchDevice(uid: uid, inputScope: true, includeVolumes: false) { [weak self] in
                        guard let self, self.isCapturing, self.inputGeneration == generation,
                              let currentInput = self.deviceInputs[track] else { return }
                        currentInput.checkHardwareStatus()
                        let connected = Set(self.hardwareObserver.inputDevices.map(\.uid))
                        if !connected.contains(uid), self.deviceInputs[track] != nil {
                            if isSingleInputOnly {
                                self.isCapturing = false
                                self.onStreamError?("The selected microphone was disconnected.")
                            } else {
                                self.inputFailed(track, message: "Input disconnected; its track is incomplete. Other sources continue.", generation: generation)
                            }
                        }
                    }
                    deviceWatchTokens.append(token)
                }
            }
            Log.capture.info("Capture started")
        } catch {
            clearDeviceWatches()
            for input in deviceInputs.values { input.stop() }
            deviceInputs = [:]
            Log.recordFailure(error, operation: "start_stream")
            throw ScreenCaptureAudioError.startCaptureFailed(error)
        }
    }

    private func clearDeviceWatches() {
        for token in deviceWatchTokens {
            hardwareObserver.unwatchDevice(token)
        }
        deviceWatchTokens.removeAll()
    }

    private func inputFailed(_ track: CaptureTrack, message: String, generation: UUID) {
        guard inputGeneration == generation, let input = deviceInputs.removeValue(forKey: track) else { return }
        input.stop()
        onSourceFailure?(track, message)
    }

    /// Stop audio capture
    func stopCapture() async throws {
        if let stopTask { return try await stopTask.value }
        guard stream != nil || !deviceInputs.isEmpty || isCapturing else { return }
        clearDeviceWatches()
        for (track, input) in deviceInputs {
            if let message = input.stop() { onSourceFailure?(track, message) }
        }
        deviceInputs = [:]
        let shouldStop = isCapturing
        let activeStream = stream
        let output = output
        let normalizer = singleInputNormalizer
        isCapturing = false
        let task = Task {
            var failure: Error?
            if shouldStop, let activeStream {
                do { try await activeStream.stopCapture() }
                catch { Log.recordFailure(error, operation: "stop_stream"); failure = error }
            }
            // Even a stream stopped by macOS may still have queued callbacks.
            // Cleanup joins this drain; it must not call stopCapture twice.
            await output?.finish()
            await normalizer?.finish()
            if let failure { throw failure }
        }
        stopTask = task
        defer { stopTask = nil }
        try await task.value
    }

    /// Clean up resources
    func cleanup() async {
        try? await stopCapture()
        stream = nil
        output = nil
        singleInputNormalizer = nil
        pendingInputs = []; inputCallback = nil
    }

    var capturing: Bool {
        return isCapturing
    }
}

// MARK: - SCStreamDelegate

extension ScreenCaptureAudioManager: SCStreamDelegate {

    nonisolated func stream(_ stream: SCStream, didStopWithError error: Error) {
        let error = error as NSError
        let message = error.localizedDescription
        let identity = ObjectIdentifier(stream)
        Task { @MainActor [weak self] in
            guard let self, self.stream.map(ObjectIdentifier.init) == identity else { return }
            Log.recordFailure(error, operation: "stream_delegate")
            Log.capture.error("Capture stream interrupted id=\(String(describing: self.output?.id), privacy: .public)")
            guard self.isCapturing else { return } // Don't report teardown as a second failure.
            self.isCapturing = false
            self.onStreamError?(message)
        }
    }
}

// MARK: - SCStreamOutput

/// One output per session. Mutable converter state and callbacks are confined
/// to this queue, not implicitly MainActor like the capture lifecycle manager.
/// @unchecked Sendable is limited to the queue-owned storage below.
nonisolated final class AudioCaptureOutput: NSObject, SCStreamOutput, @unchecked Sendable {
    let id: UUID
    let queue = DispatchQueue(label: "com.moreaki.recscribe.audio.capture", qos: .userInitiated)
    private let audioCallback: @Sendable (AVAudioPCMBuffer) -> Void
    private let audioNormalizer = AudioFormatNormalizer()
    private let sampleCallback: (@Sendable (CapturedAudioSample) -> Void)?
    private var hasLoggedConversionFailure = false
    private var hasLoggedNormalizeFailure = false
    private var accepting = true
    private var buffers = 0
    private var callbackMS = 0.0
    private var maxCallbackMS = 0.0
    private let onError: @MainActor @Sendable (String) -> Void

    init(id: UUID = UUID(), audioCallback: @escaping @Sendable (AVAudioPCMBuffer) -> Void,
         sampleCallback: (@Sendable (CapturedAudioSample) -> Void)? = nil,
         onError: @escaping @MainActor @Sendable (String) -> Void = { _ in }) {
        self.id = id
        self.audioCallback = audioCallback
        self.sampleCallback = sampleCallback
        self.onError = onError
    }

    /// After stopCapture, wait for all already-delivered samples before sealing
    /// this session. Late callbacks cannot enter a subsequent recording.
    func finish() async {
        await withCheckedContinuation { continuation in
            queue.async {
                if self.accepting {
                    Log.capture.notice("Capture drained id=\(self.id.uuidString, privacy: .public) buffers=\(self.buffers) callback_ms=\(self.callbackMS) max_callback_ms=\(self.maxCallbackMS) conversion_failed=\(self.hasLoggedConversionFailure || self.hasLoggedNormalizeFailure)")
                }
                self.accepting = false
                continuation.resume()
            }
        }
    }

    func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of type: SCStreamOutputType
    ) {
        process(sampleBuffer, type: type)
    }

    func process(_ sampleBuffer: CMSampleBuffer, type: SCStreamOutputType) {
        // Ignore video samples (we only need audio). No logging here: this
        // fires per audio buffer on the capture queue — the hot path.
        //
        // Single-source callbacks use the legacy canonical converter. Combined
        // callbacks transfer native PCM and timestamps to separate source state.
        dispatchPrecondition(condition: .onQueue(queue))
        guard accepting, type == .audio || type == .microphone else { return }
        guard CMSampleBufferGetNumSamples(sampleBuffer) > 0 else { return }
        let start = ContinuousClock.now
        defer {
            let elapsed = start.duration(to: .now)
            let ms = Double(elapsed.components.seconds) * 1_000 + Double(elapsed.components.attoseconds) / 1e15
            callbackMS += ms
            maxCallbackMS = max(maxCallbackMS, ms)
            buffers += 1
        }

        // Convert at the delegate boundary so every AudioCapturing implementation
        // hands AudioRecorder the same canonical AVAudioPCMBuffer type (BL-099),
        // then normalise so it is the same *format* too (BL-112). For system
        // audio the normaliser is a pass-through — the SCK config already pins
        // 48 kHz stereo — so the existing path stays byte-identical.
        // ⚠️ Never drop a buffer here in silence (BL-150). These two guards used
        // to be one `else { return }`, so when a Scarlett 2i2's integer-format
        // microphone buffers were rejected, every one vanished without a trace
        // and the only symptom was "No audio was captured for this recording"
        // at the end. The format is logged once per session — this is the hot
        // path, so it must not log per buffer.
        if sampleCallback != nil {
            let frames = CMSampleBufferGetNumSamples(sampleBuffer)
            let description = CMSampleBufferGetFormatDescription(sampleBuffer)
                .flatMap { CMAudioFormatDescriptionGetStreamBasicDescription($0)?.pointee }
            guard let description, description.mSampleRate.isFinite,
                  (1...384_000).contains(description.mSampleRate),
                  (1...32).contains(description.mChannelsPerFrame),
                  Double(frames) <= description.mSampleRate * 0.25,
                  UInt64(frames) * UInt64(description.mChannelsPerFrame) * 4 <= 4 * 1_024 * 1_024 else {
                if !hasLoggedConversionFailure {
                    hasLoggedConversionFailure = true
                    Task { @MainActor [onError] in onError("Capture packet exceeded the format or memory budget; partial audio is preserved") }
                }
                return
            }
        }
        guard let pcmBuffer = AudioSampleConverter.makePCMBuffer(from: sampleBuffer) else {
            if !hasLoggedConversionFailure {
                hasLoggedConversionFailure = true
                let desc = CMSampleBufferGetFormatDescription(sampleBuffer)
                    .flatMap { CMAudioFormatDescriptionGetStreamBasicDescription($0)?.pointee }
                    .map { "\($0.mChannelsPerFrame)ch \($0.mSampleRate)Hz \($0.mBitsPerChannel)-bit flags=\($0.mFormatFlags)" }
                    ?? "unknown format"
                Log.capture.error("Dropping buffers: unsupported capture format — \(desc, privacy: .public)")
                Task { @MainActor [onError] in onError("Capture audio could not be converted; the partial recording is preserved") }
            }
            return
        }
        if let sampleCallback {
            let time = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            guard time.isNumeric, time.seconds.isFinite else {
                if !hasLoggedNormalizeFailure {
                    hasLoggedNormalizeFailure = true
                    Task { @MainActor [onError] in onError("Capture timestamps are invalid; source tracks are preserved") }
                }
                return
            }
            sampleCallback(.init(track: type == .microphone ? .microphone : .playback,
                                 presentationTime: time.seconds, buffer: pcmBuffer))
            return
        }
        guard let normalized = audioNormalizer.normalize(pcmBuffer) else {
            if !hasLoggedNormalizeFailure {
                hasLoggedNormalizeFailure = true
                let f = pcmBuffer.format
                Log.capture.error("Dropping buffers: normalizer rejected \(f.channelCount, privacy: .public)ch \(f.sampleRate, privacy: .public)Hz")
                Task { @MainActor [onError] in onError("Capture audio could not be normalized; the partial recording is preserved") }
            }
            return
        }
        audioCallback(normalized)
    }
}

/// Queue-confined normalizer bridging `DeviceInputCapture` native PCM buffers
/// into the single-source canonical 48 kHz stereo `audioCallback` path (#40).
nonisolated final class SingleInputAudioNormalizer: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.moreaki.recscribe.audio.single-input-normalizer", qos: .userInitiated)
    private let normalizer = AudioFormatNormalizer()
    private let callback: @Sendable (AVAudioPCMBuffer) -> Void
    private let onError: @MainActor @Sendable (String) -> Void
    private var accepting = true
    private var hasLoggedFailure = false

    init(
        callback: @escaping @Sendable (AVAudioPCMBuffer) -> Void,
        onError: @escaping @MainActor @Sendable (String) -> Void
    ) {
        self.callback = callback
        self.onError = onError
    }

    func accept(_ buffer: AVAudioPCMBuffer) {
        queue.async {
            guard self.accepting else { return }
            guard let normalized = self.normalizer.normalize(buffer) else {
                if !self.hasLoggedFailure {
                    self.hasLoggedFailure = true
                    let onError = self.onError
                    Task { @MainActor in
                        onError("Capture audio could not be normalized; the partial recording is preserved")
                    }
                }
                return
            }
            self.callback(normalized)
        }
    }

    func finish() async {
        await withCheckedContinuation { continuation in
            queue.async {
                self.accepting = false
                continuation.resume()
            }
        }
    }
}
