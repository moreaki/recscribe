
import Foundation
import ScreenCaptureKit
import AVFoundation
import os

enum ScreenCaptureAudioError: Error, LocalizedError {
    case notAuthorized
    case noDisplaysAvailable
    case streamCreationFailed
    case startCaptureFailed(Error)
    case interruptedBySleep
    case appNotRunning(String)

    var errorDescription: String? {
        switch self {
        case .notAuthorized: "RecScribe needs access to Screen Recording before capturing playback."
        case .noDisplaysAvailable: "No display is available to host the playback capture session."
        case .streamCreationFailed: "The playback capture session is not configured."
        case .startCaptureFailed(let cause): "Playback capture could not begin: \(cause.localizedDescription)"
        case .interruptedBySleep: "Capture startup was interrupted when the Mac went to sleep."
        case .appNotRunning(let identifier): "The capture target \(identifier) is no longer open."
        }
    }
    var recoverySuggestion: String? {
        switch self {
        case .notAuthorized: "Enable RecScribe in Privacy & Security → Screen Recording."
        case .noDisplaysAvailable: "Connect or wake a display, then start another recording."
        case .streamCreationFailed: "Choose a capture source and retry."
        case .startCaptureFailed: "Review the capture source and its access in System Settings."
        case .interruptedBySleep: "Wake the Mac before starting another take."
        case .appNotRunning: "Launch the selected application or select another playback source."
        }
    }
}

class ScreenCaptureAudioManager: NSObject, AudioCapturing {


    private var stream: SCStream?
    private var isCapturing = false
    private var output: AudioCaptureOutput?
    private var deviceInputs: [CaptureTrack: any InputCaptureSession] = [:]
    private var pendingInputs: [InputSelection] = []
    private var failedInputDevices: [CaptureTrack: InputDeviceInfo] = [:]
    private var useLegacyMicrophoneTrack = false
    private(set) var singleInputNormalizer: SingleInputAudioNormalizer?
    private(set) var inputCallback: (@Sendable (CapturedAudioSample) -> Void)?
    private var inputGeneration = UUID()
    private var availabilityObservation: ObservationSubscription?
    private var reconcileRequested = false
    private var recoveryTask: Task<Void, Never>?
    var onInputAvailable: (@MainActor (InputDeviceInfo, InputSelection) async -> Bool)?
    private var watchedInputTracks: Set<CaptureTrack> = []
    private var deviceWatchTokens: [UUID] = []
    private let inputFactory: (InputCaptureRequest) -> any InputCaptureSession
    private let allowsAutomaticInput: (InputDeviceInfo) -> Bool
    private let canOpenInput: () -> Bool
    private let hardwareObserver: AudioHardwareObserver
    var onSourceFailure: (@MainActor (CaptureTrack, String) -> Void)?
    private var stopTask: Task<Void, Error>?

    var onStreamError: (@MainActor (String) -> Void)?

    init(hardwareObserver: AudioHardwareObserver = .shared,
         inputFactory: @escaping (InputCaptureRequest) -> any InputCaptureSession = {
             DeviceInputCapture(uid: $0.uid, track: $0.track, callback: $0.callback, onFailure: $0.failure)
         }, allowsAutomaticInput: @escaping (InputDeviceInfo) -> Bool = { AutomaticRoutingSources(defaults: .standard).allowsCapture($0) },
         canOpenInput: @escaping () -> Bool = { AVCaptureDevice.authorizationStatus(for: .audio) == .authorized }) {
        self.allowsAutomaticInput = allowsAutomaticInput
        self.inputFactory = inputFactory
        self.canOpenInput = canOpenInput
        self.hardwareObserver = hardwareObserver
        super.init()
    }


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
            let normalizerID = UUID()
            let normalizer = SingleInputAudioNormalizer(id: normalizerID, callback: audioCallback) { [weak self] message in
                guard let self, self.singleInputNormalizer?.id == normalizerID, self.isCapturing else { return }
                self.isCapturing = false
                self.onStreamError?(message)
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
        guard source.requiresScreenCapture else {
            throw SessionError.invalid("Playback configuration needs a playback source")
        }
        let available = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        guard let display = available.displays.first else { throw ScreenCaptureAudioError.noDisplaysAvailable }
        let selection: SCContentFilter
        if let bundle = source.appBundleID {
            let applications = try Self.matchingApplications(in: available.applications, bundleID: bundle,
                                                            bundleIdentifier: \.bundleIdentifier)
            selection = SCContentFilter(display: display, including: applications, exceptingWindows: [])
        } else {
            selection = SCContentFilter(display: display, excludingWindows: [])
        }
        let settings = SCStreamConfiguration()
        settings.capturesAudio = true
        settings.sampleRate = 48_000
        settings.channelCount = 2
        settings.excludesCurrentProcessAudio = true
        settings.width = 100
        settings.height = 100
        settings.minimumFrameInterval = CMTime(seconds: 1, preferredTimescale: 1)
        settings.showsCursor = false
        settings.scalesToFit = false
        settings.pixelFormat = kCVPixelFormatType_32BGRA
        let identity = UUID()
        let receiver = AudioCaptureOutput(id: identity, audioCallback: audioCallback, sampleCallback: sampleCallback) { [weak self] failure in
            guard self?.output?.id == identity else { return }
            self?.onStreamError?(failure)
        }
        let configured = SCStream(filter: selection, configuration: settings, delegate: self)
        try configured.addStreamOutput(receiver, type: .screen, sampleHandlerQueue: receiver.queue)
        try configured.addStreamOutput(receiver, type: .audio, sampleHandlerQueue: receiver.queue)
        output = receiver
        stream = configured
    }

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
                    let input = inputFactory(.init(uid: selection.deviceUID, track: track, callback: inputCallback, failure: { [weak self] message in
                        guard let self else { return }
                        if isSingleInputOnly {
                            guard self.inputGeneration == generation, self.isCapturing else { return }
                            self.isCapturing = false
                            self.onStreamError?(message)
                        } else {
                            self.inputFailed(track, message: message, generation: generation, attemptRecovery: false)
                        }
                    }))
                    deviceInputs[track] = input
                    do { try input.start() }
                    catch {
                        if useLegacyMicrophoneTrack { throw error }
                        inputFailed(track, message: "Input could not start; other sources continue. \(error.localizedDescription)", generation: generation)
                    }
                }
            }
            if let stream {
                try await stream.startCapture()
            }
            isCapturing = true
            if !pendingInputs.isEmpty {
                for selection in pendingInputs {
                    let track: CaptureTrack = useLegacyMicrophoneTrack ? .microphone : .input(selection.deviceUID)
                    let uid = selection.deviceUID
                    let token = hardwareObserver.watchDevice(uid: uid, inputScope: true, includeVolumes: false, onPropertiesChange: { [weak self] in
                        self?.inputPropertiesChanged(track, generation: generation)
                    }) { [weak self] in
                        guard let self, self.isCapturing, self.inputGeneration == generation else { return }
                        self.deviceInputs[track]?.checkHardwareStatus()
                        if self.deviceInputs[track] == nil, !isSingleInputOnly { self.reconcileAvailableInputs() }
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
                    watchedInputTracks.insert(track)
                }
            }
            if !useLegacyMicrophoneTrack, onInputAvailable != nil {
                availabilityObservation = ObservationSubscription(read: { [hardwareObserver] in hardwareObserver.revision }) { [weak self] _ in
                    self?.reconcileAvailableInputs()
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

    private func inputPropertiesChanged(_ track: CaptureTrack, generation: UUID) {
        guard isCapturing, inputGeneration == generation else { return }
        failedInputDevices.removeValue(forKey: track)
        reconcileAvailableInputs()
    }

    private func reconcileAvailableInputs() {
        guard isCapturing, canOpenInput(), !useLegacyMicrophoneTrack, let callback = inputCallback else { return }
        if recoveryTask != nil { reconcileRequested = true; return }
        let generation = inputGeneration
        recoveryTask = Task { [weak self] in
            guard let self else { return }
            defer {
                self.recoveryTask = nil
                if self.reconcileRequested { self.reconcileRequested = false; self.reconcileAvailableInputs() }
            }
            let availableDevices = self.hardwareObserver.inputDevices
            self.failedInputDevices = self.failedInputDevices.filter { _, failed in availableDevices.contains(failed) }
            for device in availableDevices where (1...32).contains(device.inputChannels ?? 0) {
                guard !Task.isCancelled, self.isCapturing, self.inputGeneration == generation else { return }
                let track = CaptureTrack.input(device.uid)
                guard self.pendingInputs.contains(where: { $0.deviceUID == device.uid }) || self.allowsAutomaticInput(device) else { continue }
                guard self.deviceInputs[track] == nil, self.failedInputDevices[track] == nil else { continue }
                let selection = self.pendingInputs.first { $0.deviceUID == device.uid } ?? InputSelection(device: device)
                guard let available = self.onInputAvailable, await available(device, selection),
                      !Task.isCancelled, self.isCapturing, self.inputGeneration == generation else { continue }
                let input = self.inputFactory(.init(uid: device.uid, track: track, callback: callback, failure: { [weak self] message in
                    self?.inputFailed(track, message: message, generation: generation, attemptRecovery: false)
                }))
                    if !self.watchedInputTracks.contains(track) {
                    let token = self.hardwareObserver.watchDevice(uid: device.uid, inputScope: true, includeVolumes: false, onPropertiesChange: { [weak self] in
                        self?.inputPropertiesChanged(track, generation: generation)
                    }) { [weak self] in
                        guard let self, self.isCapturing, self.inputGeneration == generation else { return }
                        self.deviceInputs[track]?.checkHardwareStatus()
                        if self.deviceInputs[track] == nil { self.reconcileAvailableInputs() }
                    }
                    self.deviceWatchTokens.append(token)
                    self.watchedInputTracks.insert(track)
                    }
                do {
                    self.deviceInputs[track] = input
                    try input.start()
                    if !self.pendingInputs.contains(where: { $0.deviceUID == device.uid }) { self.pendingInputs.append(selection) }
                } catch { self.inputFailed(track, message: "Input could not rejoin: \(error.localizedDescription)", generation: generation, attemptRecovery: false) }
            }
        }
    }

    private func clearDeviceWatches() {
        failedInputDevices.removeAll()
        availabilityObservation?.cancel(); availabilityObservation = nil
        recoveryTask?.cancel()
        for token in deviceWatchTokens {
            hardwareObserver.unwatchDevice(token)
        }
        deviceWatchTokens.removeAll()
        watchedInputTracks.removeAll()
    }

    private func inputFailed(_ track: CaptureTrack, message: String, generation: UUID, attemptRecovery: Bool = true) {
        guard inputGeneration == generation, let input = deviceInputs.removeValue(forKey: track) else { return }
        if !attemptRecovery, let device = hardwareObserver.inputDevices.first(where: { $0.uid == input.uid }) {
            failedInputDevices[track] = device
        }
        input.stop()
        onSourceFailure?(track, message)
        if attemptRecovery { reconcileAvailableInputs() }
    }

    func stopCapture() async throws {
        if let stopTask { return try await stopTask.value }
        guard stream != nil || !deviceInputs.isEmpty || isCapturing else { return }
        inputGeneration = UUID()
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
            await output?.finish()
            await normalizer?.finish()
            if let failure { throw failure }
        }
        stopTask = task
        defer { stopTask = nil }
        try await task.value
    }

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

    func setCapturingForTesting(_ active: Bool) {
        isCapturing = active
    }
}


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
    private var synchronizationClock: CMClockOrTimebase?
    private let onError: @MainActor @Sendable (String) -> Void

    init(id: UUID = UUID(), audioCallback: @escaping @Sendable (AVAudioPCMBuffer) -> Void,
         sampleCallback: (@Sendable (CapturedAudioSample) -> Void)? = nil,
         onError: @escaping @MainActor @Sendable (String) -> Void = { _ in }) {
        self.id = id
        self.audioCallback = audioCallback
        self.sampleCallback = sampleCallback
        self.onError = onError
    }

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
        if sampleCallback != nil, type == .audio || type == .microphone {
            // Retain the stream clock through shutdown: callbacks admitted
            // before stop still need its timebase while the output drains.
            guard let clock = stream.synchronizationClock ?? synchronizationClock else {
                rejectPacket("Playback synchronization clock is unavailable; source tracks are preserved", conversion: false)
                return
            }
            process(sampleBuffer, type: type, clock: clock)
        } else {
            process(sampleBuffer, type: type)
        }
    }

    func process(_ sampleBuffer: CMSampleBuffer, type: SCStreamOutputType, clock: CMClockOrTimebase? = nil) {
        dispatchPrecondition(condition: .onQueue(queue))
        if let clock { synchronizationClock = clock }
        let frameCount = CMSampleBufferGetNumSamples(sampleBuffer)
        guard accepting, frameCount > 0, type == .audio || type == .microphone else { return }
        let began = ContinuousClock.now
        defer {
            let elapsed = began.duration(to: .now).components
            let milliseconds = Double(elapsed.seconds) * 1_000 + Double(elapsed.attoseconds) / 1e15
            callbackMS += milliseconds
            maxCallbackMS = max(milliseconds, maxCallbackMS)
            buffers += 1
        }
        if sampleCallback != nil {
            guard let description = CMSampleBufferGetFormatDescription(sampleBuffer),
                  let format = CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee,
                  format.mSampleRate.isFinite, (1...384_000).contains(format.mSampleRate),
                  (1...32).contains(format.mChannelsPerFrame),
                  Double(frameCount) <= format.mSampleRate / 4,
                  UInt64(frameCount) * UInt64(format.mChannelsPerFrame) * 4 <= 4_194_304 else {
                rejectPacket("Capture packet exceeded its PCM budget; partial audio is preserved", conversion: true)
                return
            }
        }
        guard let owned = AudioSampleConverter.makePCMBuffer(from: sampleBuffer) else {
            rejectPacket("Capture audio could not be converted; the partial recording is preserved", conversion: true)
            return
        }
        if let callback = sampleCallback {
            let presentation = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            let timestamp = synchronizationClock.map { CMSyncConvertTime(presentation, from: $0, to: CMClockGetHostTimeClock()) } ?? presentation
            guard timestamp.isNumeric, timestamp.seconds.isFinite else {
                rejectPacket("Capture timestamps are invalid; source tracks are preserved", conversion: false)
                return
            }
            let track = type == .audio ? CaptureTrack.playback : .microphone
            callback(CapturedAudioSample(track: track, presentationTime: timestamp.seconds, buffer: owned))
        } else if let canonical = audioNormalizer.normalize(owned) {
            audioCallback(canonical)
        } else {
            rejectPacket("Capture audio could not be normalized; the partial recording is preserved", conversion: false)
        }
    }

    private func rejectPacket(_ explanation: String, conversion: Bool) {
        if conversion {
            if hasLoggedConversionFailure { return }
            hasLoggedConversionFailure = true
        } else {
            if hasLoggedNormalizeFailure { return }
            hasLoggedNormalizeFailure = true
        }
        Log.capture.error("Capture packet rejected: \(explanation, privacy: .public)")
        Task { @MainActor [onError] in onError(explanation) }
    }
}

nonisolated final class SingleInputAudioNormalizer: @unchecked Sendable {
    private struct State: Sendable {
        var accepting = true
        var conversionFailed = false
        var reportedError = false
        var buffers = 0
        var bytes = 0
        var peakBuffers = 0
        var peakBytes = 0
        var rejected = 0
    }

    let id: UUID
    private let queue = DispatchQueue(label: "com.moreaki.recscribe.audio.single-input-normalizer", qos: .userInitiated)
    private let state = OSAllocatedUnfairLock(initialState: State())
    private let normalizer = AudioFormatNormalizer()
    private let maxBuffers: Int
    private let maxBytes: Int
    private let callback: @Sendable (AVAudioPCMBuffer) -> Void
    private let onError: @MainActor @Sendable (String) -> Void

    init(
        id: UUID = UUID(),
        maxBuffers: Int = 256,
        maxBytes: Int = 4 * 1_024 * 1_024,
        callback: @escaping @Sendable (AVAudioPCMBuffer) -> Void,
        onError: @escaping @MainActor @Sendable (String) -> Void
    ) {
        precondition(maxBuffers > 0 && maxBytes > 0)
        self.id = id
        self.maxBuffers = maxBuffers
        self.maxBytes = maxBytes
        self.callback = callback
        self.onError = onError
    }

    var metrics: (peakBuffers: Int, peakBytes: Int, rejected: Int) {
        state.withLock { ($0.peakBuffers, $0.peakBytes, $0.rejected) }
    }

    func accept(_ buffer: AVAudioPCMBuffer) {
        guard buffer.frameLength > 0 else { return }
        let bytes = Int(buffer.frameCapacity) * Int(buffer.format.channelCount) * MemoryLayout<Float>.size
        let transferred = TransferredPCMBuffer(value: buffer)
        let onError = self.onError
        state.withLock { s in
            guard s.accepting, !s.conversionFailed else { return }
            guard s.buffers < maxBuffers, bytes <= maxBytes - s.bytes else {
                s.rejected += 1
                s.accepting = false
                if !s.reportedError {
                    s.reportedError = true
                    let message = AudioRecorderError.bufferLimit.localizedDescription
                    Task { @MainActor in
                        onError(message)
                    }
                }
                return
            }
            s.buffers += 1
            s.bytes += bytes
            s.peakBuffers = max(s.peakBuffers, s.buffers)
            s.peakBytes = max(s.peakBytes, s.bytes)
            queue.async {
                self.process(transferred.value, bytes: bytes)
            }
        }
    }

    private func process(_ buffer: AVAudioPCMBuffer, bytes: Int) {
        defer {
            state.withLock {
                $0.buffers -= 1
                $0.bytes -= bytes
            }
        }
        guard state.withLock({ !$0.conversionFailed }) else { return }
        guard let normalized = normalizer.normalize(buffer) else {
            let shouldReport = state.withLock { s -> Bool in
                s.conversionFailed = true
                s.accepting = false
                guard !s.reportedError else { return false }
                s.reportedError = true
                return true
            }
            if shouldReport {
                let onError = self.onError
                Task { @MainActor in
                    onError("Capture audio could not be normalized; the partial recording is preserved")
                }
            }
            return
        }
        callback(normalized)
    }

    func finish() async {
        await withCheckedContinuation { continuation in
            state.withLock { s in
                s.accepting = false
                queue.async {
                    continuation.resume()
                }
            }
        }
    }
}
