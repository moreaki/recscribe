import AVFoundation
import Combine
import Foundation

@MainActor
final class SessionLibrary: ObservableObject {
    static let shared = SessionLibrary()
    struct Entry: Identifiable {
        var id: URL
        var session: RecordingSession
    }
    @Published private(set) var entries: [Entry] = []
    @Published private(set) var activity = "Ready"
    @Published private(set) var progress = 0.0
    @Published private(set) var recordingActive = false
    @Published private(set) var latestJob: URL?
    @Published var errorMessage: String?
    private var pending: [(URL, Bool, String?)] = []
    private var task: Task<Void, Never>?
    private var cancellation: WorkCancellation?
    private var directory: URL?
    private var operationID = UUID()
    private var progressTask: Task<Void, Never>?
    private var shuttingDown = false
    private let exportSession: @Sendable (URL, URL, WorkCancellation) throws -> URL
    private let cancelRuntime: () -> Void

    init(exportSession: @escaping @Sendable (URL, URL, WorkCancellation) throws -> URL = { manifest, directory, token in
        try SessionExporter().export(manifest, to: directory, checkCancellation: token.check)
    }, cancelRuntime: @escaping () -> Void = { RuntimeManager.shared.cancel() }) {
        self.exportSession = exportSession
        self.cancelRuntime = cancelRuntime
    }

    func load(_ directory: URL) {
        self.directory = directory
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        entries = files.filter { $0.lastPathComponent.hasSuffix(".recscribe.json") }.compactMap {
            guard let value = try? RecordingSession.read($0) else { return nil }
            return Entry(id: $0, session: value)
        }.sorted { $0.session.startedAt > $1.session.startedAt }
    }
    func setRecording(_ active: Bool) {
        recordingActive = active
        if active { cancellation?.cancel(); cancelRuntime(); activity = "Background work paused for recording" }
        else { startNext() }
    }
    func enqueue(_ url: URL, recover: Bool = false, issue: String? = nil) {
        guard !shuttingDown else { return }
        if !pending.contains(where: { $0.0 == url }) { pending.append((url, recover, issue)) }
        load(url.deletingLastPathComponent())
        startNext()
    }
    func cancel() {
        guard let cancellation else { return }
        cancellation.cancel()
        activity = "Cancelling…"
    }
    func shutdown() async {
        shuttingDown = true
        pending.removeAll()
        cancellation?.cancel()
        await task?.value
    }

    private func startNext() {
        guard !shuttingDown, !recordingActive, task == nil, !pending.isEmpty else { return }
        let item = pending.removeFirst()
        let token = WorkCancellation()
        cancellation = token
        let settings = AppSettings.shared.values
        activity = item.1 ? "Recovering recording parts…" : "Verifying recording and archive…"
        task = Task {
            do {
                let result = try await Task.detached(priority: .utility) {
                    try SessionProcessing.process(item.0, ffmpeg: URL(fileURLWithPath: settings.ffmpegPath), cancel: token, recover: item.1, issue: item.2)
                }.value
                activity = result.status == "completed" ? "Recording verified; originals retained" : "Recording needs review; inspect session issues"
                if settings.autoTranscribe && !recordingActive { try await runTranscription(item.0, settings: settings, cancel: token) }
            } catch is CancellationError {
                if recordingActive && !shuttingDown { pending.insert(item, at: 0) }
                activity = recordingActive ? "Paused for recording" : "Cancelled; originals retained"
            } catch { errorMessage = error.localizedDescription; activity = "Needs attention" }
            task = nil
            cancellation = nil
            load(item.0.deletingLastPathComponent())
            startNext()
        }
    }

    func transcribe(_ source: URL) {
        guard !shuttingDown, !recordingActive, task == nil else { errorMessage = "Wait for capture/background work to finish"; return }
        let settings = AppSettings.shared.values
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
        guard FileManager.default.isExecutableFile(atPath: settings.pythonPath),
              FileManager.default.isExecutableFile(atPath: settings.whisperPath),
              FileManager.default.fileExists(atPath: settings.modelPath) else {
            throw SessionError.invalid("Configure the pipeline runtime, whisper-cli and a local model in Settings")
        }
        let jobs = AppSettings.supportDirectory.appendingPathComponent("Jobs", isDirectory: true)
        try FileManager.default.createDirectory(at: jobs, withIntermediateDirectories: true)
        let job = jobs.appendingPathComponent(UUID().uuidString)
        latestJob = job
        let id = UUID()
        operationID = id
        activity = "Starting local transcription…"
        progress = 0
        progressTask = Task { [weak self] in
            while !Task.isCancelled {
                if let data = try? Data(contentsOf: job.appendingPathComponent("manifest.json")),
                   let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any], self?.operationID == id {
                    self?.activity = value["state"] as? String ?? "Processing…"
                    self?.progress = value["progress"] as? Double ?? 0
                }
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
        defer { progressTask?.cancel(); progressTask = nil }
        var args = ["-m", "recscribe", source.path, "--output", job.path,
                    "--whisper-cli", settings.whisperPath, "--model", settings.modelPath,
                    "--ffmpeg", settings.ffmpegPath, "--source-language", settings.sourceLanguage,
                    "--mode", settings.mode, "--profile", settings.profile, "--local-only"]
        if settings.mode != "verbatim" { args += ["--target-language", settings.targetLanguage] }
        if settings.profile == "verified" { args += ["--verify-model", settings.verificationModelPath] }
        if !settings.vadModelPath.isEmpty { args += ["--vad-model", settings.vadModelPath] }
        if settings.aiEnabled { args += ["--ollama-model", settings.ollamaModel] }
        if settings.aiEnabled && settings.summarize { args += ["--summarize"] }
        let arguments = args
        _ = try await Task.detached(priority: .utility) {
            try LocalProcessRunner.run(URL(fileURLWithPath: settings.pythonPath), arguments, in: jobs, cancel: cancel)
        }.value
        let data = try Data(contentsOf: job.appendingPathComponent("manifest.json"))
        let info = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        activity = info?["state"] as? String ?? "Finished"
        progress = 1
    }

    func export(_ manifest: URL, to directory: URL) async throws -> URL {
        guard !shuttingDown, !recordingActive, task == nil else {
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
