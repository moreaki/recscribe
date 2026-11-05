import Observation
import Darwin
import Foundation
import RecScribeCore
import os

nonisolated enum LiveTranscriptionPolicy {
    static let chunkChoices = [10, 20, 30]
    static let defaultChunkSeconds = 20
    static let overlapSeconds = 1
    static let threadRange = NativeWhisperEngine.Policy.threadRange
    static let defaultThreads = NativeWhisperEngine.Policy.defaultThreads
    static let sampleRate = NativeAudioPreparer.sampleRate
    static let conversionFrames = NativeAudioPreparer.bufferFrames
    static let previewSegments = 80
    static let previewCharacters = 48_000
    static let maximumResultBytes = 4 * 1_024 * 1_024
    static let timeout: TimeInterval = 300
    static let pollInterval: Duration = .seconds(1)
    /// Retry malformed local ASR output once, always at the committed cursor.
    static let maximumLocalChunkAttempts = 2
    /// Bounds a single disposable working-file cleanup pass so large Live trees cannot stall shutdown.
    static let maximumCleanupDraftDirectories = 256
    static let maximumCleanupEntriesPerDirectory = 256
    static let maximumCleanupEntries = 4_096
}

nonisolated struct LiveSegment: Codable, Identifiable, Sendable, Equatable {
    enum TimingIssue: String, Codable, Sendable {
        case missingDuration

        var label: String { "Time range unclear · recognizer returned no duration" }
    }

    let id: UUID
    let startSeconds: Double
    let endSeconds: Double
    let channel: Int
    let language: String?
    let text: String
    /// Optional for older checkpoints. Equal times retain the recognizer's point,
    /// not a measured speech interval; never infer a duration from nearby words.
    var timingIssue: TimingIssue? = nil
    /// The local live preview is one derived mix, not a physical source channel.
    /// Absent on older and channel-preserving cloud evidence.
    var mixedSourceChannels: Int? = nil
}

nonisolated extension LiveSegment {
    var channelLabel: String { mixedSourceChannels == nil ? "channel \(channel + 1)" : "Live mix" }
    func seekTarget(recording: Bool, sourceAvailable: Bool) -> Double? {
        guard !recording, sourceAvailable, startSeconds.isFinite, endSeconds.isFinite,
              startSeconds >= 0, endSeconds >= startSeconds else { return nil }
        return startSeconds
    }
    func containsPlayback(_ position: Double) -> Bool {
        // A point with unknown duration is seekable; never invent a highlight interval.
        timingIssue == nil && seekTarget(recording: false, sourceAvailable: true) != nil &&
            endSeconds > startSeconds && position >= startSeconds && position < endSeconds
    }
}

nonisolated struct LiveChunkResult: Codable, Sendable {
    var schemaVersion = 1
    var needsReview = true
    var engine = "whisper.cpp"
    var sourceManifest: URL?
    var model: String?
    /// Absent in older evidence. Zero means every channel was digital silence,
    /// not merely that the recognizer returned no words.
    var asrRuns: Int? = nil
    var mixedSourceChannels: Int? = nil
    var mixFallbackChannel: Int? = nil
    let startFrame: Int64
    let endFrame: Int64
    let availableFrames: Int64
    let sampleRate: Int
    let durationSeconds: Double
    let segments: [LiveSegment]
    let directory: URL
}

nonisolated struct LiveChunkTiming: Sendable {
    let wallSeconds: Double
    let audioSeconds: Double
    let asrRuns: Int?

    var label: String {
        let time = Duration.seconds(wallSeconds).formatted(.units(allowed: [.seconds, .milliseconds],
                                                                 width: .abbreviated, maximumUnitCount: 1))
        let audio = Duration.seconds(audioSeconds).formatted(.units(allowed: [.seconds], width: .abbreviated))
        let detail = asrRuns == 0 ? " · digital silence, ASR skipped" : ""
        return "\(time) processing / \(audio) audio\(detail)"
    }
}

/// Owns one serial utility worker. Turning off never stops recording; turning
/// back on catches up from the last committed cursor, including audio recorded
/// before opt-in. The retained UI preview is bounded; raw chunks stay on disk.
@MainActor
@Observable final class LiveTranscription {
    private static let logger = Logger(subsystem: "com.moreaki.recscribe", category: "LiveTranscription")
    private nonisolated static let activeDirectoryRegistry = OSAllocatedUnfairLock(initialState: [UUID: Set<String>]())
    struct CloudRequest: Identifiable {
        let id: UUID
        let source: URL
        let model: String
    }
    private(set) var pendingCloudRequest: CloudRequest?
    private(set) var isCloudDraft = false
    private(set) var cloudAudioActive = false
    private(set) var enabled = false
    private(set) var busy = false
    private(set) var status = "Live transcription is off"
    private(set) var segments: [LiveSegment] = []
    private(set) var errorMessage: String?
    private(set) var directory: URL?
    private(set) var lagSeconds = 0.0
    private(set) var lastChunk: LiveChunkTiming?
    private(set) var captureNeedsReview = false
    private(set) var sourceURL: URL?
    private(set) var modelName: String?
    private(set) var audioSeconds: Double = 0
    private(set) var lastCleanupReport = LiveCleanupReport()
    var lastCleanupFailures: [LiveCleanupFailure] { lastCleanupReport.failures }
    private(set) var cursor: Int64 = 0
    private let instanceID = UUID()
    private let liveRoot: URL
    private var activeWorkerDirectory: URL?
    private var manifest: URL?
    private var capturing = false
    private var generation = UUID()
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var token: WorkCancellation?
    @ObservationIgnored private var cleanupTask: Task<LiveCleanupReport, Never>?
    @ObservationIgnored private var cleanupToken: WorkCancellation?
    let drafts: LiveDraftStore
    private let settings: () -> AppSettings.Values
    private let work: @Sendable (URL, URL, Int64, Bool, AppSettings.Values, WorkCancellation) async throws -> LiveChunkResult?
    private let wait: @Sendable () async throws -> Void
    private let cloudKey: () throws -> Data
    private let cloudClient: RealtimeTranscriber
    private var cloudWorker: CloudTranscriptionWorker?
    var onBusyChange: (Bool) -> Void = { _ in }
    var onCloudTranscript: (URL, URL) -> Void = { _, _ in }

    init(liveRoot: URL = AppSettings.supportDirectory.appendingPathComponent("Live", isDirectory: true),
         settings: @escaping () -> AppSettings.Values = { .init() },
         draftGate: CaptureSessionGate = CaptureSessionGate(),
         work: @escaping @Sendable (URL, URL, Int64, Bool, AppSettings.Values, WorkCancellation) async throws -> LiveChunkResult? = { source, output, cursor, final, settings, token in
             try await Task.detached(priority: .utility) {
                 try LiveWhisperTranscriber.step(manifest: source, directory: output, cursor: cursor,
                                                 finished: final, settings: settings, cancel: token)
             }.value
         }, wait: @escaping @Sendable () async throws -> Void = { try await Task.sleep(for: LiveTranscriptionPolicy.pollInterval) },
         cloudKey: @escaping () throws -> Data = { try IntelligenceCredentials().key() },
         cloudClient: RealtimeTranscriber = .init()) {
        self.liveRoot = liveRoot
        self.drafts = LiveDraftStore(root: liveRoot, gate: draftGate, isActive: Self.isActiveDraft)
        self.settings = settings
        self.work = work
        self.wait = wait
        self.cloudKey = cloudKey
        self.cloudClient = cloudClient
        drafts.onRemoved = { [weak self] draft in self?.forgetDraft(draft) }
    }

    deinit {
        token?.cancel()
        task?.cancel()
        cleanupToken?.cancel()
        cleanupTask?.cancel()
        let id = instanceID
        let worker = task
        Task {
            await worker?.value
            Self.activeDirectoryRegistry.withLock { _ = $0.removeValue(forKey: id) }
        }
    }

    nonisolated static func isActiveDraft(_ directory: URL) -> Bool {
        let path = directory.standardizedFileURL.path
        return activeDirectoryRegistry.withLock { registry in registry.values.contains { $0.contains(path) } }
    }

    func forgetDraft(_ draft: URL) {
        guard directory?.standardizedFileURL.path == draft.standardizedFileURL.path, !capturing, !busy else { return }
        setEnabled(false)
        invalidate()
        directory = liveRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
        cursor = 0; segments = []; lastChunk = nil
        status = "Live draft moved to Trash · original recording retained"
        syncActiveDirectoryRegistration()
    }

    var activeDirectories: Set<URL> {
        var urls: Set<URL> = []
        if capturing || busy || task != nil || pendingCloudRequest != nil, let directory {
            urls.insert(directory.standardizedFileURL)
        }
        if let activeWorkerDirectory {
            urls.insert(activeWorkerDirectory.standardizedFileURL)
        }
        return urls
    }

    private func syncActiveDirectoryRegistration() {
        let paths = Self.normalizedPaths(for: activeDirectories)
        let id = instanceID
        Self.activeDirectoryRegistry.withLock { registry in
            if paths.isEmpty {
                registry.removeValue(forKey: id)
            } else {
                registry[id] = paths
            }
        }
    }

    func setEnabled(_ value: Bool) {
        enabled = value
        errorMessage = nil
        if value {
            if settings().processingLocation == .cloud { requestCloudAudio() }
            else { status = capturing ? "Waiting for a complete audio chunk…" : "Armed for the next recording"; start() }
        } else {
            pendingCloudRequest = nil; cloudWorker = nil; cloudAudioActive = false
            invalidate(); status = capturing ? "Live transcription is off · audio is still recorded" : "Live transcription is off"
        }
        syncActiveDirectoryRegistration()
    }

    func configurationChanged() {
        // A preference change revokes consent, never silently switches an active adapter.
        if enabled || busy || pendingCloudRequest != nil { setEnabled(false) }
    }

    private func requestCloudAudio() {
        guard capturing, let manifest else { status = "Cloud armed · approval required when recording starts"; return }
        pendingCloudRequest = CloudRequest(id: generation, source: manifest, model: settings().cloudTranscriptionModel)
        status = "Waiting for cloud audio approval · recording stays local"
        syncActiveDirectoryRegistration()
    }

    func dismissCloudAudio() {
        guard pendingCloudRequest != nil else { return }
        setEnabled(false)
    }

    func confirmCloudAudio() {
        guard let request = pendingCloudRequest, request.id == generation, capturing, enabled,
              settings().processingLocation == .cloud, settings().cloudTranscriptionModel == request.model,
              task == nil else { return }
        pendingCloudRequest = nil
        let token = WorkCancellation(), client = cloudClient
        let key: Data
        do { key = try cloudKey() }
        catch { enabled = false; errorMessage = error.localizedDescription; status = "Cloud setup needs attention"; syncActiveDirectoryRegistration(); return }
        self.token = token
        busy = true; onBusyChange(true)
        syncActiveDirectoryRegistration()
        task = Task { [weak self] in
            do {
                let consent = try await Task.detached(priority: .utility) {
                    let session = try RecordingSession.read(request.source)
                    let position = try LiveAudioReader.position(manifest: request.source, cancel: token)
                    return CloudAudioConsent(sourceSessionID: session.id, approvedAt: Date(), startSample: position, model: request.model)
                }.value
                try token.check()
                guard let self, generation == request.id, capturing else { throw CancellationError() }
                cursor = consent.startSample
                directory = liveRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
                segments = []; lastChunk = nil; lagSeconds = 0
                isCloudDraft = true; modelName = consent.model
                cloudWorker = CloudTranscriptionWorker(consent: consent, key: key, client: client)
                syncActiveDirectoryRegistration()
            } catch is CancellationError {
                if let self, generation == request.id, !capturing {
                    enabled = false; status = "Recording ended before cloud approval was prepared; no audio sent"
                }
            }
            catch {
                if let self, generation == request.id { enabled = false; errorMessage = error.localizedDescription }
            }
            guard let self else { return }
            task = nil; self.token = nil; busy = false; onBusyChange(false)
            syncActiveDirectoryRegistration()
            start()
        }
    }

    func recordingStarted(_ audio: URL) {
        cleanupToken?.cancel()
        cleanupTask?.cancel()
        invalidate()
        pendingCloudRequest = nil; cloudWorker = nil; cloudAudioActive = false; isCloudDraft = false
        manifest = RecordingSession.manifestURL(for: audio)
        sourceURL = manifest
        modelName = nil
        audioSeconds = 0
        directory = liveRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
        cursor = 0
        segments = []
        lagSeconds = 0
        lastChunk = nil
        captureNeedsReview = false
        capturing = true
        errorMessage = nil
        syncActiveDirectoryRegistration()
        if enabled { setEnabled(true) }
        else { status = "Live transcription is off · audio is still recorded" }
    }

    func recordingStopped(needsReview: Bool = false) {
        capturing = false
        if pendingCloudRequest != nil { dismissCloudAudio() }
        captureNeedsReview = captureNeedsReview || needsReview
        if enabled { status = "Finishing remaining audio chunks…"; start() }
        else { status = errorMessage == nil ? "Live transcription is off" : "Live transcription needs attention · draft is incomplete" }
        syncActiveDirectoryRegistration()
        scheduleBackgroundCleanup()
    }

    private func scheduleBackgroundCleanup() { _ = startCleanup() }

    private func startCleanup() -> Task<LiveCleanupReport, Never>? {
        guard !capturing, !busy else { return nil }
        cleanupToken?.cancel()
        cleanupTask?.cancel()
        let previousCleanup = cleanupTask
        let root = liveRoot
        let retained = activeDirectories
        let token = WorkCancellation()
        cleanupToken = token
        let worker = Task.detached(priority: .utility) { [weak self] in
            // Never overlap scans, including a cancelled pass still draining its I/O.
            _ = await previousCleanup?.value
            let report = Self.pruneDisposableWorkingFiles(in: root, retaining: retained, cancel: token)
            await self?.applyCleanupReport(report, token: token)
            return report
        }
        cleanupTask = worker
        return worker
    }

    private func applyCleanupReport(_ report: LiveCleanupReport, token: WorkCancellation) {
        guard cleanupToken?.id == token.id else { return }
        lastCleanupReport = report
        cleanupTask = nil
        cleanupToken = nil
    }

    @discardableResult
    func performCleanup() async -> LiveCleanupReport {
        guard let worker = startCleanup() else { return .init(cancelled: true) }
        let token = cleanupToken
        return await withTaskCancellationHandler {
            await worker.value
        } onCancel: {
            token?.cancel()
            worker.cancel()
        }
    }

    /// Kept here as the lifecycle entry point; all traversal runs on a utility worker.
    @discardableResult
    nonisolated static func pruneDisposableWorkingFiles(
        in root: URL = AppSettings.supportDirectory.appendingPathComponent("Live", isDirectory: true),
        retaining activeDirectories: Set<URL> = [],
        expectedOwnerUID: uid_t = Darwin.getuid(),
        maxDraftDirectories: Int = LiveTranscriptionPolicy.maximumCleanupDraftDirectories,
        maxEntriesPerDirectory: Int = LiveTranscriptionPolicy.maximumCleanupEntriesPerDirectory,
        cancel: WorkCancellation? = nil,
        shouldCancel: () -> Bool = { Task.isCancelled }
    ) -> LiveCleanupReport {
        // The same cross-process lease protects active recognition and manual Trash.
        // A busy worker postpones scratch cleanup; it never loses its working WAV.
        var rootInfo = stat()
        if lstat(root.path, &rootInfo) != 0, errno == ENOENT { return .init() }
        let lease: LiveDraftLease
        do { lease = try LiveDraftStorage.lockExistingRoot(root) }
        catch let error as POSIXError where error.code.rawValue == EWOULDBLOCK {
            return .init(deferredForActivity: true)
        } catch {
            return .init(failures: [.init(url: root, operation: .lease, posixErrorCode: nil, message: error.localizedDescription)])
        }
        defer { withExtendedLifetime(lease) {} }
        let retained = normalizedPaths(for: activeDirectories)
        return LiveWorkingAudioCleanup.run(
            in: root, ownerUID: expectedOwnerUID, maxDrafts: maxDraftDirectories,
            maxEntries: maxEntriesPerDirectory,
            isRetained: { directory in
                let path = directory.standardizedFileURL.path
                return retained.contains(path) || activeDirectoryRegistry.withLock { registry in
                    registry.values.contains { $0.contains(path) }
                }
            },
            shouldCancel: { cancel?.isCancelled == true || shouldCancel() }
        )
    }

    private nonisolated static func normalizedPaths(for urls: Set<URL>) -> Set<String> {
        Set(urls.map { $0.standardizedFileURL.path })
    }

    func shutdown() async {
        enabled = false
        pendingCloudRequest = nil; cloudWorker = nil; cloudAudioActive = false
        invalidate()
        await task?.value
        syncActiveDirectoryRegistration()
        _ = await performCleanup()
    }

    private func invalidate() {
        generation = UUID()
        token?.cancel()
        task?.cancel()
    }

    private func start() {
        guard enabled, task == nil, let manifest, let directory else { return }
        let id = generation, token = WorkCancellation(), values = settings(), work = work, wait = wait
        let cloud = cloudWorker
        guard values.processingLocation != .cloud || cloud != nil else { return }
        self.token = token
        activeWorkerDirectory = directory
        busy = true
        onBusyChange(true)
        syncActiveDirectoryRegistration()
        task = Task { [weak self] in
            var cloudJobCreated = false
            var attempt = 0
            do {
                guard let drafts = self?.drafts else { throw CancellationError() }
                let lease = try await drafts.admit(directory, cancel: token)
                defer { withExtendedLifetime(lease) {} }
                try token.check()
                if let cloud {
                    try await CloudTranscriptArtifacts.begin(directory, source: manifest, consent: cloud.consent)
                    cloudJobCreated = true
                    try token.check()
                    guard let self, generation == id else { throw CancellationError() }
                    cloudAudioActive = true
                }
                while let self, enabled, generation == id {
                    let final = !capturing, position = cursor
                    var result: LiveChunkResult?
                    attempt = 0
                    while true {
                        try token.check()
                        attempt += 1
                        let started = ContinuousClock.now
                        do {
                            if let cloud {
                                result = try await cloud.step(manifest: manifest, directory: directory, cursor: position,
                                    finished: final, settings: values, cancel: token) { [weak self] segment in
                                        await self?.updateCloudPreview(segment, generation: id)
                                    }
                            } else { result = try await work(manifest, directory, position, final, values, token) }
                            break
                        } catch {
                            try token.check()
                            guard cloud == nil, error is LiveWhisperOutputError,
                                  attempt < LiveTranscriptionPolicy.maximumLocalChunkAttempts else { throw error }
                            let elapsed = started.duration(to: .now)
                            Self.logger.error("Retrying malformed live output operation=\(token.id) cursor_frame=\(position) attempt=\(attempt) elapsed=\(String(describing: elapsed), privacy: .public)")
                            status = "Retrying live chunk · attempt \(attempt + 1)/\(LiveTranscriptionPolicy.maximumLocalChunkAttempts) · recording is unaffected"
                        }
                    }
                    try token.check()
                    guard generation == id else { break }
                    if let result {
                        guard result.startFrame == position, result.endFrame > position, result.sampleRate > 0 else {
                            throw SessionError.invalid("Invalid live transcription cursor")
                        }
                        cursor = result.endFrame
                        if attempt > 1 {
                            Self.logger.notice("Recovered live chunk operation=\(token.id) start_frame=\(position) end_frame=\(self.cursor) attempts=\(attempt)")
                        }
                        let finalIDs = Set(result.segments.map(\.id))
                        segments = Self.preview(segments.filter { !finalIDs.contains($0.id) } + result.segments)
                        modelName = result.model.map { URL(fileURLWithPath: $0).lastPathComponent }
                        audioSeconds = Double(result.availableFrames) / Double(result.sampleRate)
                        lastChunk = LiveChunkTiming(wallSeconds: result.durationSeconds,
                            audioSeconds: Double(result.endFrame - result.startFrame) / Double(result.sampleRate),
                            asrRuns: result.asrRuns)
                        lagSeconds = Double(max(0, result.availableFrames - cursor)) / Double(result.sampleRate)
                        status = capturing ? "Live draft · \(Int(lagSeconds)) s queued at last snapshot" : "Finishing live draft…"
                        // Check between completed windows, not on the capture queue or idle poll.
                        try await drafts.checkBudget(directory, cancel: token)
                    } else if final {
                        if let cloud {
                            try await CloudTranscriptArtifacts.finish(directory, source: manifest, consent: cloud.consent, cancel: token)
                            try token.check()
                            onCloudTranscript(directory, manifest)
                        }
                        status = captureNeedsReview ? "Partial live draft · recording needs review" : "Live draft ready · verify before use"
                        break
                    } else { try await wait() }
                }
            } catch is CancellationError {
                if cloudJobCreated { await CloudTranscriptArtifacts.interrupted(directory, source: manifest, cancelled: true) }
            }
            catch {
                if cloudJobCreated { await CloudTranscriptArtifacts.interrupted(directory, source: manifest, cancelled: false) }
                if let self, generation == id {
                    let kind = String(describing: type(of: error))
                    Self.logger.error("Stopped live transcription operation=\(token.id) cursor_frame=\(self.cursor) attempts=\(attempt) error_type=\(kind, privacy: .public)")
                    errorMessage = error.localizedDescription
                    status = capturing ? "Live transcription needs attention · recording is unaffected" : "Live transcription needs attention · draft is incomplete"
                    enabled = false
                }
            }
            guard let self else { return }
            task = nil
            self.token = nil
            activeWorkerDirectory = nil
            busy = false
            cloudAudioActive = false
            if cloud != nil, generation == id { enabled = false; cloudWorker = nil }
            onBusyChange(false)
            if generation != id { start() } // A cancelled worker must exit before a replacement starts.
            syncActiveDirectoryRegistration()
            scheduleBackgroundCleanup()
        }
    }

    private func updateCloudPreview(_ segment: LiveSegment, generation id: UUID) {
        guard generation == id, enabled else { return }
        segments = Self.preview(segments.filter { $0.id != segment.id } + (segment.text.isEmpty ? [] : [segment]))
        status = "Cloud draft · estimated audio-window timing"
    }

    static func preview(_ values: [LiveSegment]) -> [LiveSegment] {
        var count = 0
        return Array(values.suffix(LiveTranscriptionPolicy.previewSegments).reversed().prefix { value in
            count += value.text.count
            return count <= LiveTranscriptionPolicy.previewCharacters
        }.reversed())
    }
}
