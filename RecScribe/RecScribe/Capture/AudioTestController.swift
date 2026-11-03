import AVFoundation
import Combine
import CoreMedia
import Foundation

/// Owns the explicit preflight workflow. It never enters the recording or ASR
/// queues. Capture startup/teardown are single-flight, including cancellation.
@MainActor
final class AudioTestController: ObservableObject {
    enum State: String { case idle, starting, testing, sampling, stopping, verifying, ready, keeping }
    struct Sample: Sendable {
        let entry: SessionEntry
        let folder: URL
        let warnings: [String]
        let sources: [String]
    }
    @Published private(set) var state: State = .idle
    @Published private(set) var health: [SourceRecordingHealth] = []
    @Published private(set) var meters: [CaptureTrack: CaptureSourceMeters] = [:]
    @Published private(set) var mixMeter = CapturePeakMeter()
    @Published private(set) var elapsed = 0.0
    @Published private(set) var now = ProcessInfo.processInfo.systemUptime
    @Published private(set) var errorMessage: String?
    @Published private(set) var notice: String?
    @Published private(set) var sample: Sample?
    let playback: SessionPlayback
    var canStart: () -> Bool = { true }
    var onActivity: (Bool) -> Void = { _ in }
    var onRetained: (URL) -> Void = { _ in }
    var locksSources: Bool { ![.idle, .ready].contains(state) }
    var isCapturing: Bool { state == .testing || state == .sampling }

    private let capture: AudioCapturing
    private let source: AudioSourceProviding
    private let permissions: PermissionProviding
    private let levels: AudioLevels
    private let monitor: CapturedAudioMonitor
    private let gate: CaptureSessionGate
    private let owner = UUID()
    private let temporaryRoot: URL
    private let saveDirectory: () -> URL
    private var worker: MultiSourceRecorder?
    private var folder: URL?
    private var runID = UUID()
    private var startTask: Task<Void, Never>?
    private var stopTask: Task<Void, Never>?
    private var pollTask: Task<Void, Never>?
    private var startedAt = 0.0
    private var sampleStartedAt: Double?
    private var closed = false
    private var recordingRequested = false
    private var sampleRun = false
    private let previewLimit: TimeInterval
    private let sampleSeconds: TimeInterval

    init(capture: AudioCapturing = ScreenCaptureAudioManager(), source: AudioSourceProviding,
         permissions: PermissionProviding = PermissionManager(), levels: AudioLevels = .shared,
         monitor: CapturedAudioMonitor = .shared, gate: CaptureSessionGate = CaptureSessionGate(),
         playback: SessionPlayback? = nil, temporaryRoot: URL? = nil,
         saveDirectory: @escaping () -> URL, sampleSeconds: TimeInterval = 10, previewLimit: TimeInterval = 600) {
        precondition(sampleSeconds > 0 && sampleSeconds <= 10 && previewLimit > 0 && previewLimit <= 600)
        self.capture = capture; self.source = source; self.permissions = permissions
        self.levels = levels; self.monitor = monitor; self.gate = gate
        self.playback = playback ?? SessionPlayback()
        self.temporaryRoot = temporaryRoot ?? FileManager.default.temporaryDirectory.appendingPathComponent("com.moreaki.recscribe-audio-tests", isDirectory: true)
        self.saveDirectory = saveDirectory; self.sampleSeconds = sampleSeconds; self.previewLimit = previewLimit
    }

    func opened() { closed = false }
    func startPreview() async { await start(sample: false) }

    /// A deliberately fresh take, using the real writers and a shared host-clock epoch.
    /// No competing capture engine is left running during the ten-second sample.
    func recordSample() async {
        guard sample == nil, state == .idle || state == .testing else { return }
        await stop()
        await start(sample: true)
    }

    private func start(sample: Bool) async {
        guard !closed, !recordingRequested, canStart(), !locksSources, self.sample == nil,
              startTask == nil, stopTask == nil else { return }
        state = .starting; errorMessage = nil; notice = nil
        health = []; meters = [:]; mixMeter = .init(); elapsed = 0
        let id = UUID(); runID = id
        let task = Task { await self.runStart(sample: sample, id: id) }
        startTask = task
        await task.value
        startTask = nil
    }

    private func runStart(sample: Bool, id: UUID) async {
        var acquired = false
        do {
            try gate.acquire(owner); acquired = true
            onActivity(true); playback.stop(); playback.setRecording(true)
            guard source.selectedSource.kind == .multiple else { throw SessionError.invalid("Enable multiple inputs + playback before testing audio.") }
            let selected = source.selectedSource
            guard await permissions.checkPermission(.screenCapture) == .granted else {
                throw SessionError.invalid("Allow Screen & System Audio Recording in System Settings before testing playback capture.")
            }
            try Task.checkCancellation()
            if selected.requiresMicrophone {
                guard await permissions.requestPermission(.microphone) else { throw SessionError.invalid("Microphone access was denied. Allow it in System Settings before testing selected inputs.") }
            }
            try Task.checkCancellation()
            try await source.validate(selected)
            try Task.checkCancellation()
            let devices = source.availableInputDevices()
            var tracks: [RecordingSession.SourceTrack] = [.init(role: .playback,
                name: selected.appBundleID.map { source.knownAppName(forBundleID: $0) ?? $0 } ?? "System playback", bundleID: selected.appBundleID)]
            tracks += selected.inputSelections.map { input in
                let device = devices.first { $0.uid == input.deviceUID }
                return .init(role: .input(input.deviceUID), name: device?.name ?? "Unavailable input", deviceUID: input.deviceUID,
                             channelRoutes: input.routes, channelLabels: device?.channelLabels)
            }
            let recorder = MultiSourceRecorder(onError: { [weak self] message in
                guard let self, self.runID == id else { return }
                self.errorMessage = message
                Task { await self.stop() }
            }, monitor: monitor)
            worker = recorder; sampleRun = sample; sampleStartedAt = nil
            capture.onSourceFailure = { [weak recorder] track, message in recorder?.sourceFailed(track, message: message) }
            capture.onStreamError = { [weak self] message in
                guard let self, self.runID == id else { return }
                self.errorMessage = message
                Task { await self.stop() }
            }
            // Configure first, then establish one epoch before starting sources.
            // Choosing the first callback's timestamp would reject an older packet
            // delivered later by a different device.
            try await capture.setupMultiCapture(source: selected) { recorder.accept($0) }
            try Task.checkCancellation()
            let epoch = CMClockGetTime(CMClockGetHostTimeClock()).seconds
            sampleStartedAt = ProcessInfo.processInfo.systemUptime
            if sample {
                try prepareTemporaryRoot()
                let directory = temporaryRoot.appendingPathComponent("sample-" + UUID().uuidString, isDirectory: true)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
                folder = directory
                let url = directory.appendingPathComponent("audio_test_" + UUID().uuidString + ".wav")
                try recorder.start(at: url, descriptors: tracks, options: .init(), epoch: epoch,
                    levels: { [levels] in levels.snapshot(for: selected) }, continueOnSourceFailure: true,
                    maximumFrames: Int64(sampleSeconds * 48_000))
            } else {
                try recorder.startPreview(descriptors: tracks, epoch: epoch, levels: { [levels] in levels.snapshot(for: selected) })
            }
            if monitor.enabled { monitor.setEnabled(true, source: selected) }
            try await capture.startCapture()
            try Task.checkCancellation()
            state = sample ? .sampling : .testing
            startedAt = ProcessInfo.processInfo.systemUptime
            refresh()
            pollTask = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(100))
                    guard !Task.isCancelled, let self, self.runID == id else { return }
                    self.refresh()
                    if self.sampleRun, let start = self.sampleStartedAt, self.now - start >= self.sampleSeconds {
                        await self.stop(); return
                    }
                    if self.now - self.startedAt >= (self.sampleRun ? self.sampleSeconds + 5 : self.previewLimit) {
                        self.notice = self.sampleRun ? "Sample test ended; check source coverage." : "Audio test stopped after ten minutes. Start another test when needed."
                        await self.stop(); return
                    }
                }
            }
        } catch {
            guard acquired else { errorMessage = error.localizedDescription; state = .idle; return }
            try? await capture.stopCapture()
            await capture.cleanup()
            try? await worker?.stop(failure: error)
            worker = nil
            await monitor.stopAndWait()
            removeTemporarySample()
            gate.release(owner); onActivity(false)
            playback.setRecording(false)
            if !(error is CancellationError) { errorMessage = error.localizedDescription }
            state = .idle
        }
    }

    private func refresh() {
        now = ProcessInfo.processInfo.systemUptime
        health = worker?.sourceHealth ?? health
        meters = worker?.sourceMeters ?? meters
        mixMeter = worker?.mixMeter ?? mixMeter
        if sampleRun, sampleStartedAt == nil, let first = health.compactMap({ $0.health.firstReceivedAt }).min() { sampleStartedAt = first }
        elapsed = max(0, now - (sampleRun ? sampleStartedAt ?? now : startedAt))
    }

    func stop() async {
        if let task = startTask { task.cancel(); await task.value }
        if let task = stopTask { await task.value; return }
        guard worker != nil else { return }
        state = .stopping
        pollTask?.cancel(); pollTask = nil
        let task = Task { await self.finish() }
        stopTask = task
        await task.value
        stopTask = nil
    }

    private func finish() async {
        await monitor.stopAndWait()
        var failure: String? = errorMessage
        do { try await capture.stopCapture() } catch { failure = error.localizedDescription }
        await capture.cleanup()
        let recorder = worker
        // The verified sample reports individual coverage/clipping issues below;
        // actual drain/write/finalize failures must still reach the user.
        do { try await recorder?.stop(reportReviewIssues: false) }
        catch { failure = failure ?? error.localizedDescription }
        refresh()
        worker = nil
        gate.release(owner)
        defer { onActivity(false); playback.setRecording(false) }
        if sampleRun, let directory = folder, let manifest = recorder?.manifestURL {
            state = .verifying
            do {
                let issue = failure
                let result = try await Task.detached(priority: .utility) {
                    try SessionProcessing.process(manifest, ffmpeg: URL(fileURLWithPath: "/unused"), cancel: WorkCancellation(), issue: issue)
                }.value
                guard result.totalFrames > 0, result.parts.allSatisfy({ $0.status == .verified }) else {
                    throw SessionError.invalid("The test sample has no verified playable audio. Check source permissions and signal.")
                }
                var warnings: [String] = []
                for track in result.sourceTracks ?? [] {
                    if let reason = track.failure { warnings.append("\(track.name): \(reason)") }
                    if track.receivedFrames == 0 { warnings.append("\(track.name): no audio received; sample coverage is incomplete.") }
                }
                if let failure { warnings.append(failure) }
                warnings += result.issues.map { issue in
                    (result.sourceTracks ?? []).reduce(issue) { $0.replacingOccurrences(of: $1.role.rawValue, with: $1.name) }
                }
                sample = Sample(entry: .init(id: manifest, session: result), folder: directory,
                                warnings: warnings, sources: (result.sourceTracks ?? []).map(\.name))
                errorMessage = nil
                state = .ready
            } catch {
                errorMessage = error.localizedDescription; removeTemporarySample(); state = .idle
            }
        } else { errorMessage = failure; state = .idle }
    }

    func playSample() {
        guard !locksSources, !recordingRequested, canStart(), let sample else { return }
        playback.play(sample.entry)
    }

    func discard() {
        guard !locksSources else { return }
        playback.stop(); sample = nil; removeTemporarySample(); state = .idle
    }

    func keepSample() async {
        guard state == .ready, let sample else { return }
        state = .keeping; playback.stop()
        let destination = saveDirectory()
        do {
            let retained = try await Task.detached(priority: .utility) {
                try Self.retain(sample, in: destination)
            }.value
            self.sample = nil; removeTemporarySample(); state = .idle
            notice = "Test sample saved to \(destination.lastPathComponent). No transcription was started."
            onRetained(retained)
        } catch { errorMessage = error.localizedDescription; state = .ready }
    }

    func prepareForRecording() async {
        recordingRequested = true
        await stop()
        playback.stop(); playback.setRecording(true)
        health = []; meters = [:]; mixMeter = .init()
    }
    func recordingFinished() { recordingRequested = false; playback.setRecording(false) }

    func close() async {
        closed = true
        await stop()
        // Retaining is already an explicit commit; do not race its file copy.
        guard state != .keeping else { return }
        discard()
    }

    private func removeTemporarySample() {
        if let folder { try? FileManager.default.removeItem(at: folder) }
        folder = nil
    }
    private func prepareTemporaryRoot() throws {
        try FileManager.default.createDirectory(at: temporaryRoot, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        // Only our expired scratch directories are removed; never library files.
        for url in try FileManager.default.contentsOfDirectory(at: temporaryRoot, includingPropertiesForKeys: [.contentModificationDateKey, .isSymbolicLinkKey]) {
            let values = try url.resourceValues(forKeys: [.contentModificationDateKey, .isSymbolicLinkKey])
            if url.lastPathComponent.hasPrefix("sample-"), values.isSymbolicLink != true,
               let date = values.contentModificationDate, date < Date().addingTimeInterval(-86_400) { try? FileManager.default.removeItem(at: url) }
        }
    }

    private nonisolated static func retain(_ sample: Sample, in destination: URL) throws -> URL {
        var copied: [URL] = []
        do {
            let files = try FileManager.default.contentsOfDirectory(at: sample.folder, includingPropertiesForKeys: [.isRegularFileKey])
                .filter { $0.pathExtension == "wav" || $0.lastPathComponent.hasSuffix(".recscribe.json") }
                .sorted { $0 == sample.entry.id ? false : $1 == sample.entry.id }
            for file in files {
                guard try file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else { throw SessionError.invalid("Unexpected test-sample file") }
                let target = destination.appendingPathComponent(file.lastPathComponent)
                try FileManager.default.copyItem(at: file, to: target); copied.append(target)
            }
            return destination.appendingPathComponent(sample.entry.id.lastPathComponent)
        } catch {
            for file in copied { try? FileManager.default.removeItem(at: file) }
            throw error
        }
    }
}
