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
    private var stopTask: Task<Void, Error>?

    /// Called when the stream stops unexpectedly. See `AudioCapturing`.
    var onStreamError: (@MainActor (String) -> Void)?

    // MARK: - Public Methods

    /// Set up capture for `source` (BL-100: all system audio or a specific running app).
    /// - Parameters:
    ///   - source: what to capture. `.app` resolves to the matching `SCRunningApplication`.
    ///   - audioCallback: Closure called for each audio buffer
    /// - Throws: ScreenCaptureAudioError if setup fails, or `.appNotRunning` if `source`
    ///   is `.app` and no running app matches its bundle ID.
    func setupCapture(source: AudioSource, audioCallback: @escaping @Sendable (AVAudioPCMBuffer) -> Void) async throws {
        let id = UUID()
        let output = AudioCaptureOutput(id: id, audioCallback: audioCallback) { [weak self] message in
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

        // Configure stream for audio capture
        // Note: ScreenCaptureKit requires video to be captured alongside audio
        let config = SCStreamConfiguration()

        // Audio configuration. For a mic source we want *only* the mic: mixing
        // mic and system audio into one file is a stated non-goal for v1.
        //
        // ⚠️ `sampleRate`/`channelCount` govern the `.audio` output ONLY. A
        // `.microphone` buffer arrives in the device's native format regardless
        // (SCStream.h), which is exactly why `AudioFormatNormalizer` exists.
        let isMicSource: Bool
        if case .mic = source { isMicSource = true } else { isMicSource = false }

        config.capturesAudio = !isMicSource
        config.excludesCurrentProcessAudio = true  // Don't record our own app
        config.sampleRate = 48000  // 48kHz
        config.channelCount = 2    // Stereo

        if case .mic(let deviceUID) = source {
            config.captureMicrophone = true
            // "This deviceID is the uniqueID from AVCaptureDevice" (SCStream.h),
            // which is precisely what `InputDeviceEnumerator` returns.
            config.microphoneCaptureDeviceID = deviceUID
        }

        // Minimal video configuration (required but we won't use it)
        config.width = 100
        config.height = 100
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.showsCursor = false
        config.scalesToFit = false

        // Content filter: all display audio, or a single app's audio (BL-100).
        let filter: SCContentFilter
        switch source {
        case .systemAll:
            filter = SCContentFilter(display: display, excludingWindows: [])
        case .app(let bundleID):
            guard let app = content.applications.first(where: { $0.bundleIdentifier == bundleID }) else {
                Log.capture.error("Selected app not running for per-app capture")
                throw ScreenCaptureAudioError.appNotRunning(bundleID)
            }
            filter = SCContentFilter(display: display, including: [app], exceptingWindows: [])
        case .mic:
            // The filter still has to describe *something* capturable — the
            // stream needs a display for its (unused) video output — but with
            // `capturesAudio = false` no system audio is recorded from it.
            filter = SCContentFilter(display: display, excludingWindows: [])
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

        if isMicSource {
            try stream.addStreamOutput(output, type: .microphone, sampleHandlerQueue: output.queue)
        }

        Log.capture.debug("Capture stream configured (screen + audio handlers added)")
    }

    /// Start audio capture
    /// - Throws: ScreenCaptureAudioError if start fails
    func startCapture() async throws {
        guard let stream = stream else {
            throw ScreenCaptureAudioError.streamCreationFailed
        }

        do {
            try await stream.startCapture()
            isCapturing = true
            Log.capture.info("Capture started")
        } catch {
            Log.recordFailure(error, operation: "start_stream")
            throw ScreenCaptureAudioError.startCaptureFailed(error)
        }
    }

    /// Stop audio capture
    func stopCapture() async throws {
        if let stopTask { return try await stopTask.value }
        guard let stream else { return }
        let shouldStop = isCapturing, output = output
        isCapturing = false
        let task = Task {
            var failure: Error?
            if shouldStop {
                do { try await stream.stopCapture() }
                catch { Log.recordFailure(error, operation: "stop_stream"); failure = error }
            }
            // Even a stream stopped by macOS may still have queued callbacks.
            // Cleanup joins this drain; it must not call stopCapture twice.
            await output?.finish()
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
    private var hasLoggedConversionFailure = false
    private var hasLoggedNormalizeFailure = false
    private var accepting = true
    private var buffers = 0
    private var callbackMS = 0.0
    private var maxCallbackMS = 0.0
    private let onError: @MainActor @Sendable (String) -> Void

    init(id: UUID = UUID(), audioCallback: @escaping @Sendable (AVAudioPCMBuffer) -> Void,
         onError: @escaping @MainActor @Sendable (String) -> Void = { _ in }) {
        self.id = id
        self.audioCallback = audioCallback
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
        // `.microphone` is a distinct output type from `.audio` (BL-130), and
        // only one of them is ever configured at a time — a mic source sets
        // `capturesAudio = false`, so no `.audio` buffers arrive to interleave
        // with it. Both are normalised by the same converter on the same queue.
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
