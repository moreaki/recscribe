import AVFoundation
import Combine
import Foundation
import os
import RecScribeCore

@MainActor
final class SessionLibrary: ObservableObject {
    private static let logger = Logger(subsystem: "com.moreaki.recscribe", category: "Pipeline")
    typealias Entry = SessionEntry
    @Published private(set) var readFailures: [ManifestFailure] = []
    @Published private(set) var refreshing = false
    private var refreshTask: Task<Void, Never>?
    private var refreshID = UUID()
    private let readSessions: @Sendable (URL) async throws -> SessionSnapshot
    private let readJob: @Sendable (URL) async throws -> JobSnapshot
    private let settings: () -> AppSettings.Values
    private let progressMonitor: JobProgressMonitor
    @Published private(set) var entries: [Entry] = []
    @Published private(set) var activity = "Ready"
    @Published private(set) var progress = 0.0
    @Published private(set) var recordingActive = false
    @Published private(set) var liveWorkActive = false
    @Published private(set) var latestJob: URL?
    @Published private(set) var latestSource: URL?
    @Published private(set) var previousJob: URL?
    @Published private(set) var busy = false
    @Published var pendingTextRequest: TextProcessingRequest?
    @Published var errorMessage: String?
    private struct PendingSession {
        let manifest: URL
        let recover: Bool
        let issue: String?
    }
    private var pending: [PendingSession] = []
    private var task: Task<Void, Never>?
    private var cancellation: WorkCancellation?
    private var shuttingDown = false
    private let exportSession: @Sendable (URL, URL, WorkCancellation) throws -> URL
    private let cancelRuntime: () -> Void
    private let rememberJob: (URL, URL) -> Void

    init(exportSession: @escaping @Sendable (URL, URL, WorkCancellation) throws -> URL = { manifest, directory, token in
        try SessionExporter().export(manifest, to: directory, checkCancellation: token.check)
    }, cancelRuntime: @escaping () -> Void = {},
         settings: @escaping () -> AppSettings.Values = { .init() },
         readSessions: (@Sendable (URL) async throws -> SessionSnapshot)? = nil,
         readJob: (@Sendable (URL) async throws -> JobSnapshot)? = nil,
         initialJob: URL? = nil, initialSource: URL? = nil,
         rememberJob: @escaping (URL, URL) -> Void = { _, _ in }) {
        let repository = ManifestRepository()
        let jobReader: @Sendable (URL) async throws -> JobSnapshot = readJob ?? { try await repository.job(at: $0) }
        self.exportSession = exportSession
        self.cancelRuntime = cancelRuntime
        self.settings = settings
        self.rememberJob = rememberJob
        self.latestJob = initialJob
        self.latestSource = initialSource
        if initialJob != nil { self.progress = 1 }
        self.readSessions = readSessions ?? { try await repository.sessions(in: $0) }
        self.readJob = jobReader
        self.progressMonitor = JobProgressMonitor(read: jobReader)
    }

    func load(_ directory: URL) {
        guard !shuttingDown else { return }
        refreshTask?.cancel()
        let id = UUID(), read = readSessions
        refreshID = id
        refreshing = true
        refreshTask = Task(priority: .utility) { [weak self] in
            do {
                let snapshot = try await read(directory)
                guard !Task.isCancelled, self?.refreshID == id else { return }
                self?.entries = snapshot.entries
                self?.readFailures = snapshot.failures
            } catch is CancellationError { }
            catch {
                guard self?.refreshID == id else { return }
                self?.readFailures = [ManifestFailure(id: directory, message: error.localizedDescription)]
            }
            guard self?.refreshID == id else { return }
            self?.refreshing = false
            self?.refreshTask = nil
        }
    }
    func cancelRefresh() {
        refreshID = UUID()
        refreshTask?.cancel()
        refreshTask = nil
        refreshing = false
    }
    func setRecording(_ active: Bool) {
        recordingActive = active
        if active { cancellation?.cancel(); task?.cancel(); progressMonitor.stop(); cancelRuntime(); activity = "Background work paused for recording" }
        else { startNext() }
    }
    func setLiveWork(_ active: Bool) {
        liveWorkActive = active
        if active { cancellation?.cancel(); task?.cancel(); progressMonitor.stop() }
        else { startNext() }
    }
    func enqueue(_ url: URL, recover: Bool = false, issue: String? = nil) {
        guard !shuttingDown else { return }
        if !pending.contains(where: { $0.manifest == url }) { pending.append(.init(manifest: url, recover: recover, issue: issue)) }
        load(url.deletingLastPathComponent())
        startNext()
    }
    func cancel() {
        guard let cancellation else { return }
        cancellation.cancel()
        task?.cancel()
        progressMonitor.stop()
        activity = "Cancelling…"
    }
    func rememberOpenedTranscript(_ job: URL, source: URL?) {
        if let source { rememberJob(job, source) }
    }
    func acceptCloudTranscript(_ job: URL, source: URL) {
        previousJob = latestJob; latestJob = job; latestSource = source
        progress = 1
        activity = "Cloud transcript ready · estimated timing, review required"
        rememberJob(job, source)
    }
    func shutdown() async {
        shuttingDown = true
        cancelRefresh()
        progressMonitor.stop()
        pending.removeAll()
        cancellation?.cancel()
        task?.cancel()
        await task?.value
    }

    private func startNext() {
        guard !shuttingDown, !recordingActive, !liveWorkActive, task == nil, !pending.isEmpty else { return }
        let item = pending.removeFirst()
        let token = WorkCancellation()
        cancellation = token
        let settings = settings()
        errorMessage = nil
        activity = item.recover ? "Recovering recording parts…" : "Verifying recording and archive…"
        task = Task(priority: .utility) {
            do {
                let result = try await Task.detached(priority: .utility) {
                    try SessionProcessing.process(item.manifest, ffmpeg: URL(fileURLWithPath: settings.ffmpegPath), cancel: token, recover: item.recover, issue: item.issue)
                }.value
                activity = result.status == .completed ? "Recording verified; originals retained" : "Recording needs review; inspect session issues"
                if settings.autoTranscribe && settings.processingLocation != .cloud && !recordingActive { try await runTranscription(item.manifest, settings: settings, cancel: token) }
            } catch is CancellationError {
                if (recordingActive || liveWorkActive) && !shuttingDown { pending.insert(item, at: 0) }
                activity = recordingActive ? "Paused for recording" : "Cancelled; originals retained"
            } catch { errorMessage = error.localizedDescription; activity = "Needs attention" }
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
            catch is CancellationError { activity = "Transcription cancelled; partial job retained" }
            catch { errorMessage = error.localizedDescription; activity = "Transcription failed" }
            task = nil
            cancellation = nil
            startNext()
        }
    }

    private func runTranscription(_ source: URL, settings: AppSettings.Values, cancel: WorkCancellation) async throws {
        if let issue = settings.verificationIssue {
            Self.logger.error("Transcription preflight rejected model configuration operation=\(cancel.id)")
            throw SessionError.invalid(issue)
        }
        busy = true
        defer { busy = false }
        try VADModel.validate(settings.vadModelPath)
        latestSource = source
        let jobs = AppSettings.supportDirectory.appendingPathComponent("Jobs", isDirectory: true)
        let job = jobs.appendingPathComponent(cancel.id.uuidString)
        previousJob = latestJob
        latestJob = job
        activity = "Starting local transcription…"
        progress = 0
        progressMonitor.start(job.appendingPathComponent("manifest.json"), update: { [weak self] value in
            self?.activity = value.state.label
            self?.progress = value.progress
        }, failure: { [weak self] message in self?.errorMessage = message })
        defer { progressMonitor.stop() }
        var args = ["-m", "recscribe", source.path, "--output", job.path,
                    "--whisper-cli", settings.whisperPath, "--model", settings.modelPath,
                    "--ffmpeg", settings.ffmpegPath, "--source-language", settings.sourceLanguage,
                    "--mode", settings.mode.rawValue, "--profile", settings.profile.rawValue, "--local-only"]
        if settings.mode != .verbatim { args += ["--target-language", settings.targetLanguage] }
        if settings.profile == .verified { args += ["--verify-model", settings.verificationModelPath] }
        if !settings.vadModelPath.isEmpty { args += ["--vad-model", settings.vadModelPath] }
        let arguments = args
        _ = try await Task.detached(priority: .utility) {
            guard FileManager.default.isExecutableFile(atPath: settings.pythonPath),
                  FileManager.default.isExecutableFile(atPath: settings.whisperPath),
                  FileManager.default.fileExists(atPath: settings.modelPath) else {
                throw SessionError.invalid("Configure the pipeline runtime, whisper-cli and a local model in Settings")
            }
            try PipelineRuntime.validate(settings.pythonPath, cancel: cancel)
            try FileManager.default.createDirectory(at: jobs, withIntermediateDirectories: true)
            return try LocalProcessRunner.run(URL(fileURLWithPath: settings.pythonPath), arguments, in: jobs, cancel: cancel)
        }.value
        let info = try await readJob(job.appendingPathComponent("manifest.json")).validated()
        try cancel.check()
        guard [.completed, .completedWithReview].contains(info.state) else { throw SessionError.invalid("Pipeline exited without a completed transcript") }
        activity = info.state.label
        progress = info.progress
        rememberJob(job, source)
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
        activity = request.isCloud ? "Sending approved transcript text to OpenAI…" : "Processing text on this Mac…"
        task = Task(priority: .utility) {
            defer { busy = false; task = nil; cancellation = nil; progressMonitor.stop(); startNext() }
            do {
                let key = request.isCloud ? try IntelligenceCredentials().key() : nil
                let preview = try await TranscriptPreview.read(request.transcript.deletingLastPathComponent())
                try token.check()
                let jobs = AppSettings.supportDirectory.appendingPathComponent("Jobs", isDirectory: true)
                let job = jobs.appendingPathComponent(token.id.uuidString)
                try await deriveText(from: request.transcript, source: preview.sourceURL, output: job,
                                     options: request.options(cloudConsent: cloudConsent), key: key)
                activity = request.isCloud ? "OpenAI text derivative ready · review required" : "Local text derivative ready · review required"
            } catch is CancellationError { activity = "Text processing cancelled; previous transcript retained" }
            catch { errorMessage = error.localizedDescription; activity = "Text processing failed; previous transcript retained" }
        }
    }

    private func deriveText(from transcript: URL, source: URL?, output: URL, options: TextDerivationOptions, key: Data?) async throws {
        latestSource = source
        previousJob = latestJob
        latestJob = output
        progress = 0
        progressMonitor.start(output.appendingPathComponent("manifest.json"), update: { [weak self] snapshot in
            self?.activity = snapshot.state.label; self?.progress = snapshot.progress
        }, failure: { [weak self] message in self?.errorMessage = message })
        defer { progressMonitor.stop() }
        try await TextJob().run(source: transcript, output: output, options: options, key: key)
        let result = try await readJob(output.appendingPathComponent("manifest.json")).validated()
        try Task.checkCancellation()
        guard [.completed, .completedWithReview].contains(result.state) else { throw SessionError.invalid("Text processing did not complete") }
        progress = result.progress
        activity = result.state.label
        if let source { rememberJob(output, source) }
    }

    func export(_ manifest: URL, to directory: URL) async throws -> URL {
        guard !shuttingDown, !recordingActive, !liveWorkActive, task == nil else {
            throw SessionError.invalid("Wait for capture/background work to finish before exporting")
        }
        let token = WorkCancellation()
        let exportSession = exportSession
        cancellation = token
        errorMessage = nil
        activity = "Exporting and verifying copies…"
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
                        activity = "Export verified; originals retained"
                        progress = 1
                        continuation.resume(returning: destination)
                    } catch is CancellationError {
                        activity = "Export cancelled; incomplete copies remain as .partial"
                        continuation.resume(throwing: CancellationError())
                    } catch {
                        activity = "Export failed; incomplete copies remain as .partial"
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
