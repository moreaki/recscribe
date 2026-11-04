import Combine
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
final class LiveTranscription: ObservableObject {
    private static let logger = Logger(subsystem: "com.moreaki.recscribe", category: "LiveTranscription")
    private nonisolated static let activeDirectoryRegistry = OSAllocatedUnfairLock(initialState: [UUID: Set<String>]())
    private nonisolated static let draftMarkerFiles: Set<String> = [
        "latest.json", "consent.json", "manifest.json", "chunk.json", "review.md",
        "audio-report.json", "source-session.snapshot.json", "transcript.raw.json", "transcript.json"
    ]
    private nonisolated static let attemptOrTurnMarkerFiles: Set<String> = [
        "chunk.json", "result.json", "timings.json"
    ]
    struct CloudRequest: Identifiable {
        let id: UUID
        let source: URL
        let model: String
    }
    @Published private(set) var pendingCloudRequest: CloudRequest?
    @Published private(set) var isCloudDraft = false
    @Published private(set) var cloudAudioActive = false
    @Published private(set) var enabled = false
    @Published private(set) var busy = false
    @Published private(set) var status = "Live transcription is off"
    @Published private(set) var segments: [LiveSegment] = []
    @Published private(set) var errorMessage: String?
    @Published private(set) var directory: URL?
    @Published private(set) var lagSeconds = 0.0
    @Published private(set) var lastChunk: LiveChunkTiming?
    @Published private(set) var captureNeedsReview = false
    @Published private(set) var sourceURL: URL?
    @Published private(set) var modelName: String?
    @Published private(set) var audioSeconds: Double = 0
    private(set) var cursor: Int64 = 0
    private let instanceID = UUID()
    private let liveRoot: URL
    private var activeWorkerDirectory: URL?
    private var manifest: URL?
    private var capturing = false
    private var generation = UUID()
    private var task: Task<Void, Never>?
    private var token: WorkCancellation?
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
         work: @escaping @Sendable (URL, URL, Int64, Bool, AppSettings.Values, WorkCancellation) async throws -> LiveChunkResult? = { source, output, cursor, final, settings, token in
             try await Task.detached(priority: .utility) {
                 try LiveWhisperTranscriber.step(manifest: source, directory: output, cursor: cursor,
                                                 finished: final, settings: settings, cancel: token)
             }.value
         }, wait: @escaping @Sendable () async throws -> Void = { try await Task.sleep(for: LiveTranscriptionPolicy.pollInterval) },
         cloudKey: @escaping () throws -> Data = { try IntelligenceCredentials().key() },
         cloudClient: RealtimeTranscriber = .init()) {
        self.liveRoot = liveRoot
        self.settings = settings
        self.work = work
        self.wait = wait
        self.cloudKey = cloudKey
        self.cloudClient = cloudClient
    }

    deinit {
        let id = instanceID
        Self.activeDirectoryRegistry.withLock { _ = $0.removeValue(forKey: id) }
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
        let root = liveRoot
        let retained = activeDirectories
        Task.detached(priority: .utility) {
            Self.pruneDisposableWorkingFiles(in: root, retaining: retained)
        }
    }

    /// Removes only provably disposable temporary working audio files (`working.wav`,
    /// `channel-<N>.wav`, `working-channel-<N>.wav`, region working WAV slices) inside
    /// inactive owned `Live/<UUID>` draft directories (#44). Raw draft directories, raw ASR
    /// JSON, chunk checkpoints, silence markers, cloud journals, and canonical transcripts
    /// are always preserved regardless of age or `transcript.json` presence.
    nonisolated static func pruneDisposableWorkingFiles(
        in root: URL = AppSettings.supportDirectory.appendingPathComponent("Live", isDirectory: true),
        retaining activeDirectory: URL?,
        expectedOwnerUID: uid_t = Darwin.getuid()
    ) {
        pruneDisposableWorkingFiles(
            in: root,
            retaining: activeDirectory.map { [$0] } ?? [],
            expectedOwnerUID: expectedOwnerUID
        )
    }

    nonisolated static func pruneDisposableWorkingFiles(
        in root: URL = AppSettings.supportDirectory.appendingPathComponent("Live", isDirectory: true),
        retaining activeDirectories: Set<URL> = [],
        expectedOwnerUID: uid_t = Darwin.getuid()
    ) {
        var rootStat = Darwin.stat()
        guard Darwin.lstat(root.path, &rootStat) == 0,
              (rootStat.st_mode & S_IFMT) == S_IFDIR,
              rootStat.st_uid == expectedOwnerUID else {
            return
        }
        let fm = FileManager.default
        guard let children = try? fm.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return }

        let retainedPaths = activeDirectoryRegistry.withLock { registry in
            Set(registry.values.joined()).union(normalizedPaths(for: activeDirectories))
        }
        let rootPrefix = root.standardizedFileURL.path.hasSuffix("/")
            ? root.standardizedFileURL.path
            : root.standardizedFileURL.path + "/"

        for child in children {
            guard isOwnedNonSymlinkDirectory(child, expectedOwnerUID: expectedOwnerUID),
                  !isRetained(child, in: retainedPaths) else {
                continue
            }
            let childEntries = (try? fm.contentsOfDirectory(
                at: child,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )) ?? []
            guard isOwnedDraftDirectory(child, entries: childEntries, expectedOwnerUID: expectedOwnerUID) else {
                continue
            }
            for entry in childEntries {
                if isDisposableWorkingAudioName(entry.lastPathComponent) {
                    unlinkDisposableFileIfOwned(entry, rootPrefix: rootPrefix, expectedOwnerUID: expectedOwnerUID)
                    continue
                }
                guard isOwnedNonSymlinkDirectory(entry, expectedOwnerUID: expectedOwnerUID),
                      !isRetained(entry, in: retainedPaths) else {
                    continue
                }
                let subEntries = (try? fm.contentsOfDirectory(
                    at: entry,
                    includingPropertiesForKeys: nil,
                    options: [.skipsHiddenFiles]
                )) ?? []
                guard isOwnedAttemptOrTurnDirectory(entry, entries: subEntries, expectedOwnerUID: expectedOwnerUID) else {
                    continue
                }
                for subFile in subEntries where isDisposableWorkingAudioName(subFile.lastPathComponent) {
                    unlinkDisposableFileIfOwned(subFile, rootPrefix: rootPrefix, expectedOwnerUID: expectedOwnerUID)
                }
            }
        }
    }

    nonisolated static func isDisposableWorkingAudioName(_ name: String) -> Bool {
        if name == "working.wav" { return true }
        guard name.hasSuffix(".wav") else { return false }
        let stem = String(name.dropLast(4))
        for prefix in ["channel-", "working-channel-"] where stem.hasPrefix(prefix) {
            let digits = stem.dropFirst(prefix.count)
            return !digits.isEmpty && digits.allSatisfy(\.isASCII) && digits.allSatisfy(\.isNumber)
        }
        for prefix in ["asr-channel-", "verify-channel-"] where stem.hasPrefix(prefix) {
            let remainder = stem.dropFirst(prefix.count)
            guard let range = remainder.range(of: "-region-") else { return false }
            let channelDigits = remainder[..<range.lowerBound]
            let regionDigits = remainder[range.upperBound...]
            return !channelDigits.isEmpty && channelDigits.allSatisfy { $0.isASCII && $0.isNumber }
                && !regionDigits.isEmpty && regionDigits.allSatisfy { $0.isASCII && $0.isNumber }
        }
        return false
    }

    private nonisolated static func isTurnDirectoryName(_ name: String) -> Bool {
        guard name.hasPrefix("turn-") else { return false }
        let digits = name.dropFirst(5)
        return !digits.isEmpty && digits.allSatisfy { $0.isASCII && $0.isNumber }
    }

    private nonisolated static func isRawChannelEvidenceName(_ name: String) -> Bool {
        guard name.hasPrefix("channel-") else { return false }
        for suffix in [".raw.json", ".silence.txt", ".events.jsonl"] where name.hasSuffix(suffix) {
            let middle = name.dropFirst("channel-".count).dropLast(suffix.count)
            return !middle.isEmpty && middle.allSatisfy { $0.isASCII && $0.isNumber }
        }
        return false
    }

    private nonisolated static func isOwnedNonSymlinkDirectory(_ url: URL, expectedOwnerUID: uid_t) -> Bool {
        var st = Darwin.stat()
        guard Darwin.lstat(url.path, &st) == 0 else { return false }
        return (st.st_mode & S_IFMT) == S_IFDIR && st.st_uid == expectedOwnerUID
    }

    private nonisolated static func isOwnedNonSymlinkRegularFile(_ url: URL, expectedOwnerUID: uid_t) -> Bool {
        var st = Darwin.stat()
        guard Darwin.lstat(url.path, &st) == 0 else { return false }
        return (st.st_mode & S_IFMT) == S_IFREG && st.st_uid == expectedOwnerUID
    }

    private nonisolated static func isOwnedDraftDirectory(_ url: URL, entries: [URL], expectedOwnerUID: uid_t) -> Bool {
        if UUID(uuidString: url.lastPathComponent) != nil { return true }
        for entry in entries {
            let name = entry.lastPathComponent
            if draftMarkerFiles.contains(name), isOwnedNonSymlinkRegularFile(entry, expectedOwnerUID: expectedOwnerUID) {
                return true
            }
            if isOwnedNonSymlinkDirectory(entry, expectedOwnerUID: expectedOwnerUID) {
                let subEntries = (try? FileManager.default.contentsOfDirectory(
                    at: entry,
                    includingPropertiesForKeys: nil,
                    options: [.skipsHiddenFiles]
                )) ?? []
                if isOwnedAttemptOrTurnDirectory(entry, entries: subEntries, expectedOwnerUID: expectedOwnerUID) {
                    return true
                }
            }
        }
        return false
    }

    private nonisolated static func isOwnedAttemptOrTurnDirectory(_ url: URL, entries: [URL], expectedOwnerUID: uid_t) -> Bool {
        let name = url.lastPathComponent
        if UUID(uuidString: name) != nil || isTurnDirectoryName(name) { return true }
        for entry in entries {
            let fileName = entry.lastPathComponent
            if (attemptOrTurnMarkerFiles.contains(fileName) || isRawChannelEvidenceName(fileName)),
               isOwnedNonSymlinkRegularFile(entry, expectedOwnerUID: expectedOwnerUID) {
                return true
            }
        }
        return false
    }

    private nonisolated static func unlinkDisposableFileIfOwned(_ file: URL, rootPrefix: String, expectedOwnerUID: uid_t) {
        guard file.standardizedFileURL.path.hasPrefix(rootPrefix),
              isOwnedNonSymlinkRegularFile(file, expectedOwnerUID: expectedOwnerUID) else {
            return
        }
        _ = Darwin.unlink(file.path)
    }

    private nonisolated static func normalizedPaths(for urls: Set<URL>) -> Set<String> {
        Set(urls.flatMap { url in
            [url.standardizedFileURL.path, url.resolvingSymlinksInPath().standardizedFileURL.path]
        })
    }

    private nonisolated static func isRetained(_ url: URL, in retainedPaths: Set<String>) -> Bool {
        retainedPaths.contains(url.standardizedFileURL.path)
            || retainedPaths.contains(url.resolvingSymlinksInPath().standardizedFileURL.path)
    }

    func shutdown() async {
        enabled = false
        pendingCloudRequest = nil; cloudWorker = nil; cloudAudioActive = false
        invalidate()
        await task?.value
        syncActiveDirectoryRegistration()
        Self.pruneDisposableWorkingFiles(in: liveRoot, retaining: activeDirectories)
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
            let root = liveRoot
            let retained = activeDirectories
            Task.detached(priority: .utility) {
                Self.pruneDisposableWorkingFiles(in: root, retaining: retained)
            }
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
