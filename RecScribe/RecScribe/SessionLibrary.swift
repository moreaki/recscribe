import AVFoundation
import Combine
import Foundation

@MainActor
final class SessionLibrary: ObservableObject {
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

    init(exportSession: @escaping @Sendable (URL, URL, WorkCancellation) throws -> URL = { manifest, directory, token in
        try SessionExporter().export(manifest, to: directory, checkCancellation: token.check)
    }, cancelRuntime: @escaping () -> Void = {},
         settings: @escaping () -> AppSettings.Values = { .init() },
         readSessions: (@Sendable (URL) async throws -> SessionSnapshot)? = nil,
         readJob: (@Sendable (URL) async throws -> JobSnapshot)? = nil) {
        let repository = ManifestRepository()
        let jobReader: @Sendable (URL) async throws -> JobSnapshot = readJob ?? { try await repository.job(at: $0) }
        self.exportSession = exportSession
        self.cancelRuntime = cancelRuntime
        self.settings = settings
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
        if active { cancellation?.cancel(); progressMonitor.stop(); cancelRuntime(); activity = "Background work paused for recording" }
        else { startNext() }
    }
    func setLiveWork(_ active: Bool) {
        liveWorkActive = active
        if active { cancellation?.cancel(); progressMonitor.stop() }
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
        progressMonitor.stop()
        activity = "Cancelling…"
    }
    func shutdown() async {
        shuttingDown = true
        cancelRefresh()
        progressMonitor.stop()
        pending.removeAll()
        cancellation?.cancel()
        await task?.value
    }

    private func startNext() {
        guard !shuttingDown, !recordingActive, !liveWorkActive, task == nil, !pending.isEmpty else { return }
        let item = pending.removeFirst()
        let token = WorkCancellation()
        cancellation = token
        let settings = settings()
        activity = item.recover ? "Recovering recording parts…" : "Verifying recording and archive…"
        task = Task {
            do {
                let result = try await Task.detached(priority: .utility) {
                    try SessionProcessing.process(item.manifest, ffmpeg: URL(fileURLWithPath: settings.ffmpegPath), cancel: token, recover: item.recover, issue: item.issue)
                }.value
                activity = result.status == .completed ? "Recording verified; originals retained" : "Recording needs review; inspect session issues"
                if settings.autoTranscribe && !recordingActive { try await runTranscription(item.manifest, settings: settings, cancel: token) }
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
        if summarize {
            guard settings.aiEnabled, !settings.ollamaModel.isEmpty else {
                errorMessage = "Enable local AI and choose an installed model in Settings → Intelligence first"
                return
            }
            settings.summarize = true
        }
        let token = WorkCancellation()
        cancellation = token
        task = Task {
            do { try await runTranscription(source, settings: settings, cancel: token) }
            catch is CancellationError { activity = "Transcription cancelled; partial job retained" }
            catch { errorMessage = error.localizedDescription; activity = "Transcription failed" }
            task = nil
            cancellation = nil
            startNext()
        }
    }

    private func runTranscription(_ source: URL, settings: AppSettings.Values, cancel: WorkCancellation) async throws {
        let jobs = AppSettings.supportDirectory.appendingPathComponent("Jobs", isDirectory: true)
        let job = jobs.appendingPathComponent(cancel.id.uuidString)
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
        if settings.aiEnabled { args += ["--ollama-model", settings.ollamaModel] }
        if settings.aiEnabled && settings.summarize { args += ["--summarize"] }
        let arguments = args
        _ = try await Task.detached(priority: .utility) {
            guard FileManager.default.isExecutableFile(atPath: settings.pythonPath),
                  FileManager.default.isExecutableFile(atPath: settings.whisperPath),
                  FileManager.default.fileExists(atPath: settings.modelPath) else {
                throw SessionError.invalid("Configure the pipeline runtime, whisper-cli and a local model in Settings")
            }
            try FileManager.default.createDirectory(at: jobs, withIntermediateDirectories: true)
            return try LocalProcessRunner.run(URL(fileURLWithPath: settings.pythonPath), arguments, in: jobs, cancel: cancel)
        }.value
        let info = try await readJob(job.appendingPathComponent("manifest.json")).validated()
        try cancel.check()
        guard info.state.isTerminal else { throw SessionError.invalid("Pipeline exited without a terminal job state") }
        activity = info.state.label
        progress = info.progress
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
