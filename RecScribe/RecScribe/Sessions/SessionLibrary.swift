import Observation
import AVFoundation
import Foundation
import os
import RecScribeCore

@MainActor
@Observable final class SessionLibrary {
    private static let logger = Logger(subsystem: "com.moreaki.recscribe", category: "Pipeline")
    typealias Entry = SessionEntry
    private(set) var readFailures: [ManifestFailure] = []
    private(set) var refreshing = false
    private var refreshTask: Task<Void, Never>?
    private var refreshID = UUID()
    private let readSessions: @Sendable (URL) async throws -> SessionSnapshot
    private let readJob: @Sendable (URL) async throws -> JobSnapshot
    private let settings: () -> AppSettings.Values
    private let progressMonitor: JobProgressMonitor
    private(set) var entries: [Entry] = []
    private var operationActivity = "Ready"
    private(set) var progress = 0.0
    private(set) var recordingActive = false
    private(set) var liveWorkActive = false
    private(set) var latestJob: URL?
    private(set) var latestSource: URL?
    private(set) var previousJob: URL?
    private(set) var busy = false
    var pendingTextRequest: TextProcessingRequest?
    var errorMessage: String?
    private struct PendingSession {
        let manifest: URL
        let recover: Bool
        let issue: String?
    }
    private var pending: [PendingSession] = []
    private var pendingTranscriptions: [URL] = []
    private var recoveryAttempts = Set<URL>()
    private var pendingRecoveryDirectory: URL?
    private var activeManifest: URL?
    private var resumeInterruptedSession = false
    @ObservationIgnored private var task: Task<Void, Never>?
    private var cancellation: WorkCancellation?
    private var shuttingDown = false
    private let exportSession: @Sendable (URL, URL, WorkCancellation) throws -> URL
    private let processSession: @Sendable (URL, URL, WorkCancellation, Bool, String?) throws -> RecordingSession
    private let cancelRuntime: () -> Void
    private let rememberJob: (URL?, URL?) -> Void
    @ObservationIgnored private var restorationTask: Task<Void, Never>?
    private(set) var restoringTranscript = false
    private var rememberedJob: URL?
    private let jobsDirectory: URL

    init(exportSession: @escaping @Sendable (URL, URL, WorkCancellation) throws -> URL = { manifest, directory, token in
        try SessionExporter().export(manifest, to: directory, checkCancellation: token.check)
    }, cancelRuntime: @escaping () -> Void = {},
         settings: @escaping () -> AppSettings.Values = { .init() },
         processSession: @escaping @Sendable (URL, URL, WorkCancellation, Bool, String?) throws -> RecordingSession = {
             try SessionProcessing.process($0, ffmpeg: $1, cancel: $2, recover: $3, issue: $4)
         },
         readSessions: (@Sendable (URL) async throws -> SessionSnapshot)? = nil,
         readJob: (@Sendable (URL) async throws -> JobSnapshot)? = nil,
         initialJob: URL? = nil, initialSource: URL? = nil,
         rememberJob: @escaping (URL?, URL?) -> Void = { _, _ in }, jobsDirectory: URL? = nil) {
        let repository = ManifestRepository()
        let jobReader: @Sendable (URL) async throws -> JobSnapshot = readJob ?? { try await repository.job(at: $0) }
        self.exportSession = exportSession
        self.processSession = processSession
        self.cancelRuntime = cancelRuntime
        self.settings = settings
        self.rememberJob = rememberJob
        self.jobsDirectory = jobsDirectory ?? AppSettings.supportDirectory.appendingPathComponent("Jobs", isDirectory: true)
        self.rememberedJob = initialJob
        self.readSessions = readSessions ?? { try await repository.sessions(in: $0) }
        self.readJob = jobReader
        self.progressMonitor = JobProgressMonitor(read: jobReader)
        if let initialJob {
            restoringTranscript = true
            restorationTask = Task { [weak self] in
                do {
                    let preview = try await TranscriptPreview.read(initialJob)
                    guard let source = preview.sourceURL ?? initialSource else {
                        throw SessionError.invalid("Transcript has no recording source")
                    }
                    try await Task.detached(priority: .utility) {
                        try TranscriptStorage.validateSource(source)
                    }.value
                    try Task.checkCancellation()
                    guard let self else { return }
                    self.latestSource = source
                    self.progress = 1
                    self.latestJob = initialJob
                } catch is CancellationError {
                    return
                } catch {
                    guard !Task.isCancelled, let self else { return }
                    // A failed restore leaves the workspace ready for a new take.
                    // Keep inaccessible-volume selections available for a later launch.
                    let cocoaError = error as NSError
                    if error is DecodingError || error is SessionError || cocoaError.domain != NSCocoaErrorDomain ||
                        [NSFileNoSuchFileError, NSFileReadNoSuchFileError, NSFileReadCorruptFileError].contains(cocoaError.code) {
                        self.persistJob(nil, nil)
                    }
                }
                self?.restoringTranscript = false
                self?.restorationTask = nil
            }
        }
    }

    /// Waiting is derived from actual queued work, never retained as an idle label.
    var activity: String {
        if !pending.isEmpty, recordingActive {
            return "Recording verification/recovery queued (\(pending.count)) · waiting for recording"
        }
        if !pendingTranscriptions.isEmpty, recordingActive || liveWorkActive {
            return "Final transcription queued · waiting for \(recordingActive ? "recording" : "live transcription")"
        }
        return operationActivity
    }

    var workInProgress: Bool {
        cancellation != nil && !recordingActive && (activeManifest != nil || !liveWorkActive)
    }

    var canCancelWork: Bool {
        !pendingTranscriptions.isEmpty || (activeManifest == nil && cancellation != nil && cancellation?.isCancelled == false)
    }

    func load(_ directory: URL) {
        refresh(directory, recoverUnfinalized: pendingRecoveryDirectory == directory)
    }

    func recoverUnfinalizedSessions(in directory: URL) {
        refresh(directory, recoverUnfinalized: !recordingActive)
    }

    private func refresh(_ directory: URL, recoverUnfinalized: Bool) {
        guard !shuttingDown else { return }
        refreshTask?.cancel()
        let id = UUID(), read = readSessions
        refreshID = id
        refreshing = true
        pendingRecoveryDirectory = (recoverUnfinalized && !recordingActive) ? directory : nil
        refreshTask = Task(priority: .utility) { [weak self] in
            do {
                let snapshot = try await read(directory)
                guard !Task.isCancelled, let self, self.refreshID == id else { return }
                self.entries = snapshot.entries
                self.readFailures = snapshot.failures
                let shouldRecover = self.pendingRecoveryDirectory == directory
                self.pendingRecoveryDirectory = nil
                if shouldRecover, !self.shuttingDown, !self.recordingActive {
                    var enqueued = false
                    for entry in snapshot.entries where entry.needsRecovery || entry.session.status == .finalized
                        || entry.session.parts.contains(where: { $0.status == .finalized }) {
                        if self.activeManifest != entry.id, !self.pending.contains(where: { $0.manifest == entry.id }),
                           self.recoveryAttempts.insert(entry.id).inserted {
                            self.pending.append(.init(manifest: entry.id, recover: entry.needsRecovery, issue: nil))
                            enqueued = true
                        }
                    }
                    if enqueued {
                        self.startNext()
                    }
                }
            } catch is CancellationError {
            } catch {
                guard let self, self.refreshID == id else { return }
                self.pendingRecoveryDirectory = nil
                self.readFailures = [ManifestFailure(id: directory, message: error.localizedDescription)]
            }
            guard let self, self.refreshID == id else { return }
            self.refreshing = false
            self.refreshTask = nil
        }
    }

    func cancelRefresh() {
        refreshID = UUID()
        pendingRecoveryDirectory = nil
        refreshTask?.cancel()
        refreshTask = nil
        refreshing = false
    }
    var canDeleteRecording: Bool {
        !shuttingDown && !recordingActive && !liveWorkActive && task == nil
    }

    @discardableResult
    func rename(_ entry: Entry, title: String) async -> Entry? {
        defer { startNext() }
        guard let session = await editSession(activity: "Renaming recording…", operation: { token in
            try RecordingSession.rename(entry.id, title: title, cancel: token)
        }) else { return nil }
        if let index = entries.firstIndex(where: { $0.id == entry.id }) {
            entries[index].session = session
        }
        operationActivity = session.title == nil ? "Recording title reset" : "Recording renamed"
        return Entry(id: entry.id, session: session)
    }

    /// Metadata edits use the same cancellation and capture-priority gate as other jobs.
    private func editSession<Value: Sendable>(activity: String,
        operation: @escaping @Sendable (WorkCancellation) throws -> Value) async -> Value? {
        guard canDeleteRecording else {
            errorMessage = "Wait for capture/background work to finish before editing a recording"
            return nil
        }
        cancelRefresh()
        errorMessage = nil
        self.operationActivity = activity
        busy = true
        let token = WorkCancellation()
        cancellation = token
        let worker = Task.detached(priority: .utility) { try operation(token) }
        var result: Value?
        let edit = Task {
            do {
                let value = try await withTaskCancellationHandler {
                    try await worker.value
                } onCancel: { token.cancel(); worker.cancel() }
                result = value
            } catch is CancellationError {
                self.operationActivity = "Cancelled; originals retained"
            } catch {
                self.errorMessage = error.localizedDescription
                self.operationActivity = "Needs attention"
            }
        }
        task = edit
        await edit.value
        task = nil
        cancellation = nil
        busy = false
        return result
    }

    func moveToTrash(_ entry: Entry, includeDerivedJobs: Bool = false) async {
        defer { load(entry.id.deletingLastPathComponent()); startNext() }
        let jobs = includeDerivedJobs ? jobsDirectory : nil
        guard let trashedJobs = await editSession(activity: "Moving recording to Trash…", operation: { token in
            try SessionDeletion.moveToTrash(entry.id, jobsDirectory: jobs, cancel: token)
        }) else { return }
        pending.removeAll { $0.manifest == entry.id }
        entries.removeAll { $0.id == entry.id }
        if let latestJob, trashedJobs.contains(where: { $0.standardizedFileURL.path == latestJob.standardizedFileURL.path }) {
            self.latestJob = nil
            latestSource = nil
            progress = 0
            persistJob(nil, nil)
        }
        if let previousJob, trashedJobs.contains(where: { $0.standardizedFileURL.path == previousJob.standardizedFileURL.path }) { self.previousJob = nil }
        operationActivity = trashedJobs.isEmpty ? "Recording moved to Trash; transcripts retained" : "Recording and \(trashedJobs.count) verified transcript jobs moved to Trash"
    }
    func setRecording(_ active: Bool) {
        recordingActive = active
        if active {
            cancelRestoration()
            pendingRecoveryDirectory = nil
            if activeManifest != nil, cancellation?.isCancelled == false {
                resumeInterruptedSession = true
            }
            cancellation?.cancel()
            task?.cancel()
            progressMonitor.stop()
            cancelRuntime()
            if cancellation != nil { operationActivity = "Stopping background work for recording…" }
        } else {
            startNext()
        }
    }
    func setLiveWork(_ active: Bool) {
        liveWorkActive = active
        if active {
            cancelRestoration()
            // Live ASR preempts optional jobs, never finalized-audio verification.
            if activeManifest == nil {
                cancellation?.cancel()
                task?.cancel()
                progressMonitor.stop()
                if cancellation != nil { operationActivity = "Stopping background work for live transcription…" }
            }
        } else {
            startNext()
        }
    }
    func enqueue(_ url: URL, recover: Bool = false, issue: String? = nil) {
        guard !shuttingDown else { return }
        if activeManifest != url, !pending.contains(where: { $0.manifest == url }) {
            pending.append(.init(manifest: url, recover: recover, issue: issue))
        }
        load(url.deletingLastPathComponent())
        startNext()
    }
    func cancel() {
        guard canCancelWork else { return }
        pendingTranscriptions.removeAll()
        // Audio verification is required, even when optional text work is cancelled.
        guard activeManifest == nil else { return }
        cancellation?.cancel()
        task?.cancel()
        progressMonitor.stop()
        operationActivity = cancellation == nil ? "Cancelled; originals retained" : "Cancelling…"
    }
    func cancelRestoration() {
        restorationTask?.cancel()
        restorationTask = nil
        restoringTranscript = false
    }

    private func persistJob(_ job: URL?, _ source: URL?) {
        rememberedJob = job
        rememberJob(job, source)
    }

    func rememberOpenedTranscript(_ job: URL, source: URL?) {
        cancelRestoration()
        persistJob(job, source)
    }

    func canDeleteTranscript(_ job: URL) -> Bool {
        canDeleteRecording && TranscriptStorage.isManagedJob(job, in: jobsDirectory)
    }

    @discardableResult
    func deleteTranscript(_ job: URL,
        trash: @escaping @Sendable (URL) throws -> Void = {
            try FileManager.default.trashItem(at: $0, resultingItemURL: nil)
        }) async -> Bool {
        guard canDeleteTranscript(job) else {
            errorMessage = "Wait for capture/background work to finish. Only transcripts in RecScribe’s Jobs folder can be moved to Trash."
            return false
        }
        cancelRestoration()
        let root = jobsDirectory
        guard await editSession(activity: "Moving transcript to Trash…", operation: { token in
            try TranscriptStorage.moveToTrash(job, in: root, cancel: token, trash: trash)
            return true
        }) == true else { startNext(); return false }
        forgetTranscript(job)
        operationActivity = "Transcript moved to Trash; recording retained"
        startNext()
        return true
    }
    func forgetTranscript(_ job: URL) {
        // Enumeration and persisted URLs can carry different directory hints.
        func matches(_ candidate: URL?) -> Bool { candidate?.standardizedFileURL.path == job.standardizedFileURL.path }
        if matches(rememberedJob) { cancelRestoration() }
        if matches(latestJob) {
            latestJob = nil
            latestSource = nil
            progress = 0
        }
        if matches(previousJob) { previousJob = nil }
        if matches(rememberedJob) { persistJob(nil, nil) }
        if matches(pendingTextRequest?.transcript.deletingLastPathComponent()) { pendingTextRequest = nil }
    }
    func acceptCloudTranscript(_ job: URL, source: URL) {
        cancelRestoration()
        previousJob = latestJob; latestJob = job; latestSource = source
        progress = 1
        operationActivity = "Cloud transcript ready · estimated timing, review required"
        persistJob(job, source)
    }
    func shutdown() async {
        shuttingDown = true
        cancelRestoration()
        cancelRefresh()
        progressMonitor.stop()
        pending.removeAll()
        pendingTranscriptions.removeAll()
        cancellation?.cancel()
        task?.cancel()
        await task?.value
    }

    private func startNext() {
        guard !shuttingDown, !recordingActive, task == nil else { return }
        guard !pending.isEmpty else {
            if !liveWorkActive, !pendingTranscriptions.isEmpty {
                transcribe(pendingTranscriptions.removeFirst())
            }
            return
        }
        let item = pending.removeFirst()
        let token = WorkCancellation()
        activeManifest = item.manifest
        resumeInterruptedSession = false
        cancellation = token
        let settings = settings()
        let processSession = processSession
        errorMessage = nil
        operationActivity = item.recover ? "Recovering recording parts…" : "Verifying recording and archive…"
        task = Task(priority: .utility) {
            do {
                let result = try await Task.detached(priority: .utility) {
                    try processSession(item.manifest, URL(fileURLWithPath: settings.ffmpegPath), token, item.recover, item.issue)
                }.value
                try token.check()
                operationActivity = result.status == .completed ? "Recording verified; originals retained" : "Recording needs review; inspect session issues"
                if settings.autoTranscribe && settings.processingLocation != .cloud {
                    pendingTranscriptions.append(item.manifest)
                }
            } catch is CancellationError {
                if resumeInterruptedSession && !shuttingDown { pending.insert(item, at: 0) }
                operationActivity = "Cancelled; originals retained"
            } catch { errorMessage = error.localizedDescription; operationActivity = "Needs attention" }
            activeManifest = nil
            resumeInterruptedSession = false
            task = nil
            cancellation = nil
            load(item.manifest.deletingLastPathComponent())
            startNext()
        }
    }

    func transcribe(_ source: URL, summarize: Bool = false) {
        guard !shuttingDown, !recordingActive, !liveWorkActive, task == nil else { errorMessage = "Wait for capture/background work to finish"; return }
        var settings = settings()
        guard settings.processingLocation != .cloud else {
            errorMessage = "Cloud mode transcribes newly approved live audio. Choose Local or Hybrid to re-transcribe a completed recording locally; no fallback or upload was started."
            return
        }
        if summarize {
            guard settings.aiEnabled, settings.aiProvider == .ollama, !settings.ollamaModel.isEmpty else {
                errorMessage = "For cloud summaries, first create a transcript, then choose Generate summary in the Studio. For local summaries, enable Ollama in Settings → Intelligence."
                return
            }
            settings.summarize = true
        }
        let token = WorkCancellation()
        cancellation = token
        errorMessage = nil
        task = Task(priority: .utility) {
            do { try await runTranscription(source, settings: settings, cancel: token) }
            catch is CancellationError { operationActivity = "Transcription cancelled; partial job retained" }
            catch { errorMessage = error.localizedDescription; operationActivity = "Transcription failed" }
            task = nil
            cancellation = nil
            startNext()
        }
    }

    private func runTranscription(_ source: URL, settings: AppSettings.Values, cancel: WorkCancellation) async throws {
        cancelRestoration()
        if let issue = settings.verificationIssue {
            Self.logger.error("Transcription preflight rejected model configuration operation=\(cancel.id)")
            throw SessionError.invalid(issue)
        }
        busy = true
        defer { busy = false }
        try WhisperVAD.validate(settings.vadModelPath)
        latestSource = source
        let jobs = jobsDirectory
        let job = jobs.appendingPathComponent(cancel.id.uuidString)
        previousJob = latestJob
        latestJob = job
        operationActivity = "Starting local transcription…"
        progress = 0
        progressMonitor.start(job.appendingPathComponent("manifest.json"), update: { [weak self] value in
            self?.operationActivity = value.displayLabel
            self?.progress = value.progress
        }, failure: { [weak self] message in self?.errorMessage = message })
        defer { progressMonitor.stop() }
        try await Task.detached(priority: .utility) {
            try NativeAudioTranscription.run(source, output: job, settings: settings, cancel: cancel)
        }.value
        let info = try await readJob(job.appendingPathComponent("manifest.json")).validated()
        try cancel.check()
        guard [.completed, .completedWithReview].contains(info.state) else { throw SessionError.invalid("Pipeline exited without a completed transcript") }
        operationActivity = info.state.label
        progress = info.progress
        persistJob(job, source)
        if settings.aiEnabled && settings.aiProvider == .ollama && (settings.mode != .verbatim || settings.summarize) {
            try cancel.check()
            try await deriveText(from: job.appendingPathComponent("transcript.json"), source: source,
                output: jobs.appendingPathComponent(UUID().uuidString),
                options: .init(provider: .ollama, model: settings.ollamaModel, mode: settings.mode.textMode,
                    targetLanguage: settings.targetLanguage, summarize: settings.summarize), key: nil)
        }
    }

    func requestTextProcessing(_ job: URL, summary: Bool, sourceName: String? = nil) {
        do {
            let request = try TextProcessingRequest(transcript: job.appendingPathComponent("transcript.json"), settings: settings(), summary: summary, sourceName: sourceName)
            if request.isCloud { pendingTextRequest = request }
            else { processText(request, cloudConsent: false) }
        } catch { errorMessage = error.localizedDescription }
    }

    func confirmTextProcessing() {
        guard let request = pendingTextRequest else { return }
        pendingTextRequest = nil
        processText(request, cloudConsent: true)
    }

    private func processText(_ request: TextProcessingRequest, cloudConsent: Bool) {
        guard !shuttingDown, !recordingActive, !liveWorkActive, task == nil else { errorMessage = "Wait for capture/background work to finish"; return }
        guard !request.isCloud || cloudConsent else { return }
        guard !request.isCloud || settings().processingLocation != .local else {
            errorMessage = "Cloud text consent was revoked by Local mode"
            return
        }
        let token = WorkCancellation()
        cancellation = token
        busy = true
        errorMessage = nil
        operationActivity = request.isCloud ? "Sending approved transcript text to OpenAI…" : "Processing text on this Mac…"
        task = Task(priority: .utility) {
            defer { busy = false; task = nil; cancellation = nil; progressMonitor.stop(); startNext() }
            do {
                let key = request.isCloud ? try IntelligenceCredentials().key() : nil
                let preview = try await TranscriptPreview.read(request.transcript.deletingLastPathComponent())
                try token.check()
                let jobs = jobsDirectory
                let job = jobs.appendingPathComponent(token.id.uuidString)
                try await deriveText(from: request.transcript, source: preview.sourceURL, output: job,
                                     options: request.options(cloudConsent: cloudConsent), key: key)
                operationActivity = request.isCloud ? "OpenAI text derivative ready · review required" : "Local text derivative ready · review required"
            } catch is CancellationError { operationActivity = "Text processing cancelled; previous transcript retained" }
            catch { errorMessage = error.localizedDescription; operationActivity = "Text processing failed; previous transcript retained" }
        }
    }

    private func deriveText(from transcript: URL, source: URL?, output: URL, options: TextDerivationOptions, key: Data?) async throws {
        cancelRestoration()
        latestSource = source
        previousJob = latestJob
        latestJob = output
        progress = 0
        progressMonitor.start(output.appendingPathComponent("manifest.json"), update: { [weak self] snapshot in
            self?.operationActivity = snapshot.displayLabel; self?.progress = snapshot.progress
        }, failure: { [weak self] message in self?.errorMessage = message })
        defer { progressMonitor.stop() }
        try await TextJob().run(source: transcript, output: output, options: options, key: key)
        let result = try await readJob(output.appendingPathComponent("manifest.json")).validated()
        try Task.checkCancellation()
        guard [.completed, .completedWithReview].contains(result.state) else { throw SessionError.invalid("Text processing did not complete") }
        progress = result.progress
        operationActivity = result.state.label
        if let source { persistJob(output, source) }
    }

    func export(_ manifest: URL, to directory: URL) async throws -> URL {
        guard !shuttingDown, !recordingActive, !liveWorkActive, task == nil else {
            throw SessionError.invalid("Wait for capture/background work to finish before exporting")
        }
        let token = WorkCancellation()
        let exportSession = exportSession
        cancellation = token
        errorMessage = nil
        operationActivity = "Exporting and verifying copies…"
        progress = 0
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                task = Task {
                    defer {
                        task = nil
                        cancellation = nil
                        startNext()
                    }
                    do {
                        let destination = try await Task.detached(priority: .utility) {
                            try exportSession(manifest, directory, token)
                        }.value
                        operationActivity = "Export verified; originals retained"
                        progress = 1
                        continuation.resume(returning: destination)
                    } catch is CancellationError {
                        operationActivity = "Export cancelled; incomplete copies remain as .partial"
                        continuation.resume(throwing: CancellationError())
                    } catch {
                        operationActivity = "Export failed; incomplete copies remain as .partial"
                        errorMessage = error.localizedDescription
                        continuation.resume(throwing: error)
                    }
                }
            }
        } onCancel: {
            token.cancel()
        }
    }
}
