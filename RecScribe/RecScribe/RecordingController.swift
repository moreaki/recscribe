//
//  RecordingController.swift
//  RecScribe
//
//  Orchestrates the recording workflow
//

import Foundation
import os

/// Errors originating from the recording controller before/around capture.
enum RecordingControllerError: Error {
    case insufficientDiskSpace
}

/// Controller that coordinates audio recording workflow
class RecordingController: RecordingControlling {

    // MARK: - Properties

    private let captureManager: AudioCapturing
    private let audioRecorder: AudioFileWriting
    private let saveLocation: SaveLocationProviding
    private let audioSource: AudioSourceProviding
    private let sessionLibrary: SessionLibrary?
    private let liveTranscription: LiveTranscription?
    private let activity: RecordingActivity
    private let levels: AudioLevels

    private var currentRecordingURL: URL?
    private var activeSourceName = "Selected source"
    private var starting = false
    private var multiRecorder: MultiSourceRecorder?
    private let storageOptions: () -> RecordingStorageOptions

    /// Callback for waveform visualization data
    var onWaveformData: (@MainActor @Sendable ([Float]) -> Void)?

    /// Forwarded from the capture manager when the stream fails mid-recording.
    var onStreamError: (@MainActor (String) -> Void)?

    // MARK: - Initialization

    init(
        captureManager: AudioCapturing? = nil,
        audioRecorder: AudioFileWriting? = nil,
        saveLocation: SaveLocationProviding? = nil,
        audioSource: AudioSourceProviding? = nil,
        sessionLibrary: SessionLibrary? = nil,
        liveTranscription: LiveTranscription? = nil,
        activity: RecordingActivity? = nil,
        levels: AudioLevels? = nil,
        storageOptions: @escaping () -> RecordingStorageOptions = { .init() }
    ) {
        self.levels = levels ?? .shared
        self.storageOptions = storageOptions
        self.captureManager = captureManager ?? ScreenCaptureAudioManager()
        self.audioRecorder = audioRecorder ?? AudioRecorder(encoderFactory: { _ in
            SessionWAVWriter(options: storageOptions())
        })
        self.saveLocation = saveLocation ?? SaveLocationManager()
        self.audioSource = audioSource ?? AudioSourceManager()
        self.sessionLibrary = sessionLibrary
        self.liveTranscription = liveTranscription
        self.activity = activity ?? RecordingActivity()
        self.activity.onInterruption = { [weak self] message in self?.onStreamError?(message) }
        self.captureManager.onStreamError = { [weak self] message in
            self?.onStreamError?(message)
        }
        self.audioRecorder.onWriteError = { [weak self] message in
            self?.onStreamError?(message)
        }
    }

    // MARK: - Public Methods

    /// Start recording system audio in the given output `format` (BL-015).
    /// - Returns: URL where the recording is being saved
    /// - Throws: Error if recording cannot start
    @MainActor
    func startRecording(format: AudioFormat) async throws -> URL {
        guard !starting, !audioRecorder.recording, multiRecorder == nil else { throw AudioRecorderError.alreadyRecording }
        starting = true
        defer { starting = false }
        sessionLibrary?.setRecording(true)
        var started = false
        defer { if !started { CapturedAudioMonitor.shared.recordingStopped(); activity.stop(); sessionLibrary?.setRecording(false) } }
        // Pre-flight: fail before touching disk if the selected source isn't
        // capturable right now (BL-100 — e.g. the chosen app isn't running).
        let source = audioSource.selectedSource
        try await audioSource.validate(source)
        if CapturedAudioMonitor.shared.enabled { CapturedAudioMonitor.shared.setEnabled(true, source: source) }
        if let uid = source.microphoneUID { activeSourceName = audioSource.availableInputDevices().first { $0.uid == uid }?.name ?? "Input" }
        else if let bundle = source.appBundleID { activeSourceName = audioSource.knownAppName(forBundleID: bundle) ?? bundle }
        else { activeSourceName = "System playback" }

        // Generate file path (extension follows the chosen format).
        let fileURL = generateFilePath(format: .wav)

        // Refuse to start a doomed recording on a near-full disk.
        if let available = DiskSpace.availableBytes(at: fileURL),
           !DiskSpace.hasEnoughSpace(availableBytes: available) {
            throw RecordingControllerError.insufficientDiskSpace
        }

        // Wire waveform callback
        audioRecorder.onWaveformData = onWaveformData

        // Start audio recorder first (creates the file in the chosen format).
        activity.start()
        if case .mixed(let bundle, let uid) = source {
            let micName = audioSource.availableInputDevices().first { $0.uid == uid }?.name ?? "Microphone"
            let playbackName = bundle.map { audioSource.knownAppName(forBundleID: $0) ?? $0 } ?? "System playback"
            let recorder = MultiSourceRecorder(onError: { [weak self] in self?.onStreamError?($0) }, onWaveform: onWaveformData)
            multiRecorder = recorder
            do {
                try recorder.start(at: fileURL, descriptors: [
                    .init(role: .playback, name: playbackName, bundleID: bundle),
                    .init(role: .microphone, name: micName, deviceUID: uid)
                ], options: storageOptions(), levels: { [levels] in levels.snapshot(for: source) })
                try await captureManager.setupMultiCapture(source: source) { recorder.accept($0) }
                try await captureManager.startCapture()
                guard !activity.interrupted else { throw ScreenCaptureAudioError.interruptedBySleep }
            } catch {
                await captureManager.cleanup()
                try? await recorder.stop(failure: error)
                if let manifest = recorder.manifestURL { sessionLibrary?.enqueue(manifest, issue: error.localizedDescription) }
                multiRecorder = nil
                throw error
            }
            let actual = recorder.audioURL ?? fileURL
            currentRecordingURL = actual
            liveTranscription?.recordingStarted(actual)
            started = true
            return actual
        }
        (audioRecorder as? AudioRecorder)?.configureLevels(source: source, levels: levels)
        try audioRecorder.startRecording(to: fileURL, format: .wav)

        // Set up capture with audio callback
        let recorder = audioRecorder  // Keep strong reference
        do {
            try await captureManager.setupCapture(source: source) { pcmBuffer in
                recorder.processAudioSample(pcmBuffer)
            }
            try await captureManager.startCapture()
            guard !activity.interrupted else {
                throw ScreenCaptureAudioError.interruptedBySleep
            }
        } catch {
            await captureManager.cleanup()
            try? await audioRecorder.stopRecording()
            audioRecorder.onWaveformData = nil
            if let manifest = audioRecorder.sessionManifestURL { sessionLibrary?.enqueue(manifest, issue: error.localizedDescription) }
            throw error
        }

        let actualURL = audioRecorder.actualAudioURL ?? fileURL
        currentRecordingURL = actualURL
        liveTranscription?.recordingStarted(actualURL)
        started = true
        Log.recorder.info("Recording started")
        return actualURL
    }

    /// Stop recording
    /// - Throws: Error if stop fails
    func stopRecording() async throws {
        var needsReview = false
        defer {
            CapturedAudioMonitor.shared.recordingStopped()
            activity.stop()
            liveTranscription?.recordingStopped(needsReview: needsReview)
            sessionLibrary?.setRecording(false)
        }
        // Stop capturing audio
        var captureError: Error?
        do { try await captureManager.stopCapture() } catch { captureError = error }

        if let recorder = multiRecorder {
            var failure = captureError
            do { try await recorder.stop(failure: captureError) } catch { if failure == nil { failure = error } }
            await captureManager.cleanup()
            currentRecordingURL = nil
            multiRecorder = nil
            needsReview = failure != nil || activity.interrupted
            if let manifest = recorder.manifestURL {
                sessionLibrary?.enqueue(manifest, issue: failure?.localizedDescription)
            }
            if let failure { throw failure }
            return
        }
        // Finalize the file, but capture the error rather than rethrowing here:
        // the teardown below must run either way, or a failed finalize would leak
        // the capture session and leave a stale recording URL behind. (BL-016 —
        // the error used to be swallowed inside AudioRecorder, so before now this
        // path could never be reached.)
        let finalizeError: Error?
        do {
            try await audioRecorder.stopRecording()
            finalizeError = nil
        } catch {
            finalizeError = error
        }

        // Clean up capture manager
        await captureManager.cleanup()

        audioRecorder.onWaveformData = nil
        currentRecordingURL = nil
        if let manifest = audioRecorder.sessionManifestURL {
            let issue = (finalizeError ?? captureError)?.localizedDescription
                ?? (activity.interrupted ? "Sleep interrupted recording; review the end of this session" : nil)
            sessionLibrary?.enqueue(manifest, issue: issue)
        }
        needsReview = finalizeError != nil || captureError != nil || activity.interrupted

        if let finalizeError {
            Log.recorder.error(
                "Finalize failed on stop: \(finalizeError.localizedDescription, privacy: .public)"
            )
            throw finalizeError
        }
        if let captureError { throw captureError }
        Log.recorder.info("Recording stopped")
    }

    /// Finalize after an unexpected capture failure. The stream has already
    /// stopped, so capture teardown is best-effort; finalizing the recorder
    /// preserves the audio captured before the failure as a playable file.
    func finalizeAfterFailure() async {
        defer {
            CapturedAudioMonitor.shared.recordingStopped()
            activity.stop()
            liveTranscription?.recordingStopped(needsReview: true)
            sessionLibrary?.setRecording(false)
        }
        try? await captureManager.stopCapture()
        if let recorder = multiRecorder {
            let failure = SessionError.invalid("Capture interrupted; review the preserved source tracks and mix")
            try? await recorder.stop(failure: failure)
            await captureManager.cleanup()
            if let manifest = recorder.manifestURL { sessionLibrary?.enqueue(manifest, issue: failure.localizedDescription) }
            multiRecorder = nil
            currentRecordingURL = nil
            return
        }
        // Keep the original interruption visible, but don't lose a secondary
        // finalization failure: record it in diagnostics and the session issue.
        var issue = "Capture stopped unexpectedly; review the end of this session"
        do { try await audioRecorder.stopRecording() }
        catch {
            Log.recordFailure(error, operation: "finalize_after_capture_failure")
            issue += "; audio finalization also failed; verify or recover the saved parts"
        }
        await captureManager.cleanup()
        audioRecorder.onWaveformData = nil
        currentRecordingURL = nil
        if let manifest = audioRecorder.sessionManifestURL {
            sessionLibrary?.enqueue(manifest, issue: issue)
        }
        Log.recorder.error("Recording finalized after stream failure")
    }

    var sourceHealth: [SourceRecordingHealth] {
        if let multiRecorder { return multiRecorder.sourceHealth }
        return [.init(id: "capture", name: activeSourceName, health: audioRecorder.healthSnapshot)]
    }

    /// Check if currently recording
    var isRecording: Bool {
        return captureManager.capturing
    }

    /// Get current recording URL
    var recordingURL: URL? {
        return currentRecordingURL
    }

    // MARK: - File path

    /// Generate a unique file path in the resolved save directory, with the
    /// extension for `format` (BL-015). `internal` for unit testing. The directory
    /// comes from `SaveLocationProviding`, which always resolves to a writable
    /// folder (falling back to the Desktop).
    func generateFilePath(format: AudioFormat) -> URL {
        let directory = saveLocation.resolvedDirectory

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let timestamp = formatter.string(from: Date())
        let base = "recording_\(timestamp)"
        let ext = format.fileExtension

        // Avoid clobbering an existing file (timestamps are second-granular).
        var candidate = directory.appendingPathComponent("\(base).\(ext)")
        var suffix = 1
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = directory.appendingPathComponent("\(base) (\(suffix)).\(ext)")
            suffix += 1
        }
        return candidate
    }

    // MARK: - Cleanup

    deinit {
        // Capture managers directly to avoid referencing self inside the Task closure
        let captureManager = captureManager
        let audioRecorder = audioRecorder
        let sessionLibrary = sessionLibrary
        let activity = activity
        Task { @MainActor in
            defer { activity.stop() }
            guard captureManager.capturing || audioRecorder.recording else { return }
            try? await captureManager.stopCapture()
            try? await audioRecorder.stopRecording()
            await captureManager.cleanup()
            if let manifest = audioRecorder.sessionManifestURL { sessionLibrary?.enqueue(manifest, issue: "Recorder closed before normal stop") }
            sessionLibrary?.setRecording(false)
        }
    }
}
