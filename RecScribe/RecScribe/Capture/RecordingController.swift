import Foundation
import CoreMedia
import os

enum RecordingControllerError: Error {
    case insufficientDiskSpace
    case captureShutdownFailed(Error)
}

/// Coordinates capture, durable writing and post-recording work. Capture stops
/// before the writer is sealed; every error path releases the shared capture lease.
@MainActor final class RecordingController: RecordingControlling {
    private let captureManager: AudioCapturing
    private let audioRecorder: AudioFileWriting
    private let saveLocation: SaveLocationProviding
    private let audioSource: AudioSourceProviding
    private let sessionLibrary: SessionLibrary?
    private let liveTranscription: LiveTranscription?
    private let activity: RecordingActivity
    private let levels: AudioLevels
    private let monitor: CapturedAudioMonitor
    private let captureGate: CaptureSessionGate
    private let captureID = UUID()
    private let storageOptions: () -> RecordingStorageOptions
    private var multiRecorder: MultiSourceRecorder?
    private var opening = false
    private var currentRecordingURL: URL?
    private var sourceTitle = "Selected source"
    private(set) var stopReviewMessage: String?
    var onWaveformData: (@MainActor @Sendable ([Float]) -> Void)?
    var onStreamError: (@MainActor (String) -> Void)?

    init(captureManager: AudioCapturing? = nil, audioRecorder: AudioFileWriting? = nil,
         saveLocation: SaveLocationProviding? = nil, audioSource: AudioSourceProviding? = nil,
         sessionLibrary: SessionLibrary? = nil, liveTranscription: LiveTranscription? = nil,
         activity: RecordingActivity? = nil, levels: AudioLevels? = nil, monitor: CapturedAudioMonitor? = nil,
         captureGate: CaptureSessionGate = CaptureSessionGate(),
         storageOptions: @escaping () -> RecordingStorageOptions = { .init() }) {
        self.captureManager = captureManager ?? ScreenCaptureAudioManager()
        self.audioRecorder = audioRecorder ?? AudioRecorder(encoderFactory: { _ in SessionWAVWriter(options: storageOptions()) })
        self.saveLocation = saveLocation ?? SaveLocationManager()
        self.audioSource = audioSource ?? AudioSourceManager()
        self.sessionLibrary = sessionLibrary
        self.liveTranscription = liveTranscription
        self.activity = activity ?? RecordingActivity()
        self.levels = levels ?? AudioLevels()
        self.monitor = monitor ?? CapturedAudioMonitor()
        self.captureGate = captureGate
        self.storageOptions = storageOptions
        self.captureManager.onStreamError = { [weak self] in self?.onStreamError?($0) }
        self.activity.onInterruption = { [weak self] in self?.onStreamError?($0) }
        self.audioRecorder.onWriteError = { [weak self] in self?.onStreamError?($0) }
        self.captureManager.onSourceFailure = { [weak self] track, reason in self?.multiRecorder?.sourceFailed(track, message: reason) }
        self.captureManager.onInputAvailable = { [weak self] device, selection in
            await self?.prepareDiscoveredInput(device, selection: selection) ?? false
        }
    }

    private func prepareDiscoveredInput(_ device: InputDeviceInfo, selection: InputSelection) async -> Bool {
        guard let sink = multiRecorder else { return false }
        let identity = CaptureTrack.input(device.uid)
        let preference = "input:" + device.uid
        if !sink.hasSource(identity), !levels.hasSetting(preference) { levels.set(preference, .init(muted: true)) }
        do {
            try await sink.prepareSource(.init(role: identity, name: device.name, deviceUID: device.uid,
                channelRoutes: selection.routes, channelLabels: device.channelLabels))
            var source = audioSource.selectedSource
            if !source.inputs.contains(where: { $0.deviceUID == device.uid }) {
                source.inputs.append(selection)
                source.allowDuplicateRoutes = false
            }
            audioSource.setSelectedSource(source)
            if device.mayLoopBack, monitor.enabled { monitor.setEnabled(true, source: source) }
            return true
        } catch { return false }
    }

    func startRecording() async throws -> URL {
        guard !opening, !audioRecorder.recording, multiRecorder == nil else { throw AudioRecorderError.alreadyRecording }
        opening = true
        stopReviewMessage = nil
        defer { opening = false }
        try captureGate.acquire(captureID)
        sessionLibrary?.setRecording(true)
        var completed = false
        defer { if !completed { releaseRecordingResources(needsReview: false, notifyTranscription: false) } }
        let selection = audioSource.selectedSource
        try await audioSource.validate(selection)
        let destination = generateFilePath()
        if let capacity = DiskSpace.availableBytes(at: destination), !DiskSpace.hasEnoughSpace(availableBytes: capacity) {
            throw RecordingControllerError.insufficientDiskSpace
        }
        if monitor.enabled { monitor.setEnabled(true, source: selection) }
        sourceTitle = name(for: selection)
        activity.start()
        let actual: URL
        if selection.isMixed { actual = try await beginMultiSource(selection, destination: destination) }
        else { actual = try await beginSingleSource(selection, destination: destination) }
        currentRecordingURL = actual
        liveTranscription?.recordingStarted(actual)
        completed = true
        return actual
    }

    private func beginSingleSource(_ selection: AudioSource, destination: URL) async throws -> URL {
        audioRecorder.onWaveformData = onWaveformData
        (audioRecorder as? AudioRecorder)?.configureLevels(source: selection, levels: levels, monitor: monitor)
        try audioRecorder.startRecording(to: destination, format: .wav)
        do {
            let sink = audioRecorder
            try await captureManager.setupCapture(source: selection) { sink.processAudioSample($0) }
            try await captureManager.startCapture()
            if activity.interrupted { throw ScreenCaptureAudioError.interruptedBySleep }
        } catch {
            await captureManager.cleanup()
            try? await audioRecorder.stopRecording()
            audioRecorder.onWaveformData = nil
            enqueue(audioRecorder.sessionManifestURL, issue: error.localizedDescription)
            throw error
        }
        return audioRecorder.actualAudioURL ?? destination
    }

    private func beginMultiSource(_ selection: AudioSource, destination: URL) async throws -> URL {
        let sink = MultiSourceRecorder(onError: { [weak self] in self?.onStreamError?($0) },
                                       onWaveform: onWaveformData, monitor: monitor)
        multiRecorder = sink
        do {
            try sink.start(at: destination, descriptors: descriptors(for: selection), options: storageOptions(),
                levels: { [levels] in levels.snapshot(for: selection, includingDiscoveredInputs: true) },
                continueOnSourceFailure: selection.kind == .multiple)
            try await captureManager.setupMultiCapture(source: selection) { sink.accept($0) }
            try await captureManager.startCapture()
            if activity.interrupted { throw ScreenCaptureAudioError.interruptedBySleep }
        } catch {
            await captureManager.cleanup()
            try? await sink.stop(failure: error)
            enqueue(sink.manifestURL, issue: error.localizedDescription)
            multiRecorder = nil
            throw error
        }
        return sink.audioURL ?? destination
    }

    private func name(for selection: AudioSource) -> String {
        if let uid = selection.microphoneUID { return audioSource.availableInputDevices().first { $0.uid == uid }?.name ?? "Input" }
        return selection.appBundleID.map { audioSource.knownAppName(forBundleID: $0) ?? $0 } ?? "System playback"
    }

    private func descriptors(for selection: AudioSource) -> [RecordingSession.SourceTrack] {
        var tracks: [RecordingSession.SourceTrack] = []
        if selection.requiresScreenCapture {
            let bundle = selection.appBundleID
            tracks.append(.init(role: .playback, name: bundle.map { audioSource.knownAppName(forBundleID: $0) ?? $0 } ?? "System playback", bundleID: bundle))
        }
        let devices = audioSource.availableInputDevices()
        for input in selection.inputSelections {
            let details = devices.first { $0.uid == input.deviceUID }
            let multiple = selection.kind == .multiple
            tracks.append(.init(role: multiple ? .input(input.deviceUID) : .microphone, name: details?.name ?? "Input",
                deviceUID: input.deviceUID, channelRoutes: multiple ? input.routes : nil, channelLabels: details?.channelLabels))
        }
        return tracks
    }

    func stopRecording() async throws {
        var needsReview = false
        defer { releaseRecordingResources(needsReview: needsReview) }
        // Backends finish at different times. Coverage is required through the
        // user's stop request, while every callback admitted during drain stays.
        let requestedEndTime = CMClockGetTime(CMClockGetHostTimeClock()).seconds
        let captureFailure = await haltCapture()
        if let sink = multiRecorder {
            var writeFailure: Error?
            do { try await sink.stop(failure: captureFailure, expectedEndTime: requestedEndTime) }
            catch { writeFailure = error }
            await captureManager.cleanup()
            multiRecorder = nil
            currentRecordingURL = nil
            stopReviewMessage = sink.reviewMessage
            let failure = captureFailure ?? writeFailure
            needsReview = failure != nil || stopReviewMessage != nil || activity.interrupted
            enqueue(sink.manifestURL, issue: failure?.localizedDescription ?? stopReviewMessage)
            if let captureFailure { throw RecordingControllerError.captureShutdownFailed(captureFailure) }
            if let writeFailure { throw writeFailure }
            return
        }
        var writeFailure: Error?
        do { try await audioRecorder.stopRecording() }
        catch { writeFailure = error }
        await captureManager.cleanup()
        audioRecorder.onWaveformData = nil
        currentRecordingURL = nil
        let failure = writeFailure ?? captureFailure
        needsReview = failure != nil || activity.interrupted
        enqueue(audioRecorder.sessionManifestURL, issue: failure?.localizedDescription
            ?? (activity.interrupted ? "Sleep interrupted recording; review the end of this session" : nil))
        if let writeFailure { throw writeFailure }
        if let captureFailure { throw RecordingControllerError.captureShutdownFailed(captureFailure) }
    }

    func finalizeAfterFailure() async {
        defer { releaseRecordingResources(needsReview: true) }
        _ = await haltCapture()
        if let sink = multiRecorder {
            let failure = SessionError.invalid("Capture interrupted; review the preserved source tracks and mix")
            try? await sink.stop(failure: failure)
            await captureManager.cleanup()
            enqueue(sink.manifestURL, issue: failure.localizedDescription)
            multiRecorder = nil
        } else {
            var reason = "Capture stopped unexpectedly; review the end of this session"
            do { try await audioRecorder.stopRecording() }
            catch {
                Log.recordFailure(error, operation: "finalize_after_capture_failure")
                reason += "; audio finalization also failed; verify or recover the saved parts"
            }
            await captureManager.cleanup()
            audioRecorder.onWaveformData = nil
            enqueue(audioRecorder.sessionManifestURL, issue: reason)
        }
        currentRecordingURL = nil
    }

    private func haltCapture() async -> Error? {
        do { try await captureManager.stopCapture(); return nil }
        catch { Log.recordFailure(error, operation: "capture_shutdown"); return error }
    }
    private func enqueue(_ manifest: URL?, issue: String?) {
        if let manifest { sessionLibrary?.enqueue(manifest, issue: issue) }
    }
    private func releaseRecordingResources(needsReview: Bool, notifyTranscription: Bool = true) {
        captureGate.release(captureID)
        monitor.recordingStopped()
        activity.stop()
        sessionLibrary?.setRecording(false)
        if notifyTranscription { liveTranscription?.recordingStopped(needsReview: needsReview) }
    }
    var sourceHealth: [SourceRecordingHealth] {
        multiRecorder?.sourceHealth ?? [.init(id: "capture", name: sourceTitle, health: audioRecorder.healthSnapshot)]
    }
    var sourceMeters: [CaptureTrack: CaptureSourceMeters] { multiRecorder?.sourceMeters ?? [:] }
    var isRecording: Bool { captureManager.capturing }
    var recordingURL: URL? { currentRecordingURL }

    func generateFilePath() -> URL {
        let date = DateFormatter()
        date.locale = Locale(identifier: "en_US_POSIX")
        date.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let stem = "recording_" + date.string(from: .now)
        let directory = saveLocation.resolvedDirectory
        for counter in 0...Int.max {
            let suffix = counter == 0 ? "" : " (\(counter))"
            let proposal = directory.appendingPathComponent(stem + suffix).appendingPathExtension("wav")
            if !FileManager.default.fileExists(atPath: proposal.path) { return proposal }
        }
        // Exclusive file creation by the sink remains the final collision guard.
        return directory.appendingPathComponent(stem + "-" + UUID().uuidString + ".wav")
    }

    deinit {
        let capture = captureManager, writer = audioRecorder, multi = multiRecorder
        let library = sessionLibrary, activity = activity, gate = captureGate, owner = captureID
        Task { @MainActor in
            defer { activity.stop(); gate.release(owner) }
            guard capture.capturing || writer.recording || multi != nil else { return }
            try? await capture.stopCapture()
            if let multi {
                try? await multi.stop(failure: SessionError.invalid("Recorder closed before normal stop"))
                if let manifest = multi.manifestURL { library?.enqueue(manifest, issue: "Recorder closed before normal stop") }
            } else {
                try? await writer.stopRecording()
                if let manifest = writer.sessionManifestURL { library?.enqueue(manifest, issue: "Recorder closed before normal stop") }
            }
            await capture.cleanup()
            library?.setRecording(false)
        }
    }
}

@MainActor protocol RecordingControlling: AnyObject {
    var onWaveformData: (@MainActor @Sendable ([Float]) -> Void)? { get set }
    var onStreamError: (@MainActor (String) -> Void)? { get set }
    var isRecording: Bool { get }
    var sourceHealth: [SourceRecordingHealth] { get }
    var sourceMeters: [CaptureTrack: CaptureSourceMeters] { get }
    var stopReviewMessage: String? { get }
    var recordingURL: URL? { get }
    func startRecording() async throws -> URL
    func stopRecording() async throws
    func finalizeAfterFailure() async
}

extension RecordingControlling {
    var sourceHealth: [SourceRecordingHealth] { [] }
    var sourceMeters: [CaptureTrack: CaptureSourceMeters] { [:] }
    var stopReviewMessage: String? { nil }
}
