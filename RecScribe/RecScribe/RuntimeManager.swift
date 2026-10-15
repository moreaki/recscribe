import AppKit
import Combine
import Foundation
import Metal
import os
import RecScribeCore

nonisolated struct WhisperModel: Identifiable, Sendable {
    let id: String
    let bytes: Int64
    let sha256: String
    var filename: String { "ggml-\(id).bin" }
    var url: URL { URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/\(filename)")! }
    func verifyAndInstall(_ temporary: URL, to destination: URL, cancel: WorkCancellation) throws {
        guard Int64(try temporary.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? -1) == bytes,
              try RecordingSession.hash(temporary, check: cancel.check) == sha256 else { throw SessionError.invalid("Model checksum or size mismatch") }
        try cancel.check()
        try FileManager.default.moveItem(at: temporary, to: destination)
    }
    static let catalogVersion = 1
    static let catalog: [Self] = [
        .init(id: "tiny", bytes: 77_691_713, sha256: "be07e048e1e599ad46341c8d2a135645097a538221678b7acdd1b1919c6e1b21"),
        .init(id: "base", bytes: 147_951_465, sha256: "60ed5bc3dd14eea856493d334349b405782ddcaf0028d4b5df4088345fba2efe"),
        .init(id: "small", bytes: 487_601_967, sha256: "1be3a9b2063867b937e64e2ec7483364a79917e157fa98c5d94b5c1fffea987b"),
        .init(id: "large-v3-turbo", bytes: 1_624_555_275, sha256: "1fc70f774d38eb169993ac391eea357ef47c88757ef72ee5943879b7e8e2bc69")
    ]
}

nonisolated final class DownloadProgress: NSObject, URLSessionDownloadDelegate, Sendable {
    typealias Output = (URL, URLResponse)
    let update: @Sendable (Double) -> Void
    private let expectedBytes: Int64
    private struct State {
        var continuation: CheckedContinuation<Output, any Error>?
        var task: URLSessionDownloadTask?
        var cancelled = false
        var lastPercent = -1
    }
    private let state = OSAllocatedUnfairLock(initialState: State())
    init(expectedBytes: Int64, update: @escaping @Sendable (Double) -> Void) {
        self.expectedBytes = expectedBytes
        self.update = update
    }

    /// Completion-handler/async downloads do not deliver download progress to
    /// their task delegate. Use a session delegate and bridge completion instead.
    func download(_ request: URLRequest) async throws -> Output {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
                let task = session.downloadTask(with: request)
                let start = state.withLock { state in
                    guard !state.cancelled else { return false }
                    state.continuation = continuation
                    state.task = task
                    return true
                }
                if start { task.resume() }
                else {
                    session.invalidateAndCancel()
                    continuation.resume(throwing: CancellationError())
                }
            }
        } onCancel: {
            let task = self.state.withLock { state in
                state.cancelled = true
                return state.task
            }
            task?.cancel()
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        do {
            guard let response = downloadTask.response else { throw SessionError.invalid("Model download returned no response") }
            // URLSession removes its file when this callback returns. Retain it
            // under our own name until the caller verifies and installs it.
            let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.moveItem(at: location, to: temporary)
            complete(.success((temporary, response)), session: session)
        } catch { complete(.failure(error), session: session) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        complete(.failure(error ?? SessionError.invalid("Model download returned no file")), session: session)
    }

    private func complete(_ result: Result<Output, any Error>, session: URLSession) {
        let (continuation, cancelled) = state.withLock { state in
            let continuation = state.continuation
            state.continuation = nil
            state.task = nil
            return (continuation, state.cancelled)
        }
        session.finishTasksAndInvalidate()
        guard let continuation else { return }
        if cancelled {
            if case .success(let output) = result { try? FileManager.default.removeItem(at: output.0) }
            continuation.resume(throwing: CancellationError())
        } else { continuation.resume(with: result) }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        let total = totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : expectedBytes
        if total > 0 {
            let fraction = min(1, max(0, Double(totalBytesWritten) / Double(total)))
            let percent = Int(fraction * 100)
            let changed = state.withLock { state in
                guard !state.cancelled, percent > state.lastPercent else { return false }
                state.lastPercent = percent; return true
            }
            if changed { update(fraction) }
        }
    }
}

nonisolated enum LocalSoftware: String, Hashable, Sendable {
    case pipeline, ffmpeg, ollama
    case whisperCPP = "whisper-cpp"
}

@MainActor
final class RuntimeManager: ObservableObject {
    private let settings: AppSettings
    private let aiModels: @Sendable () async throws -> [String]
    var isRecording: () -> Bool = { false }
    @Published private(set) var detectedTools: [String: String] = [:]
    @Published private(set) var availability: RuntimeAvailability?
    @Published private(set) var checkingAvailability = false
    private var availabilityGeneration = UUID()

    func dependency(_ software: LocalSoftware) -> RuntimeAvailability.Dependency? {
        guard availability?.paths == RuntimeAvailability.Paths(settings.values) else { return nil }
        return availability?.tools[software]
    }
    func localModel(_ model: WhisperModel) -> RuntimeAvailability.Model? {
        guard availability?.paths == RuntimeAvailability.Paths(settings.values) else { return nil }
        return availability?.models[model.id]
    }
    var availabilityCurrent: Bool { availability?.paths == RuntimeAvailability.Paths(settings.values) }

    func refreshAvailability() async {
        let generation = UUID(); availabilityGeneration = generation
        checkingAvailability = true
        defer { if availabilityGeneration == generation { checkingAvailability = false } }
        let paths = RuntimeAvailability.Paths(settings.values)
        let probeVersions = !isRecording()
        let cancel = WorkCancellation()
        let result = await withTaskCancellationHandler {
            await Task.detached(priority: .utility) {
                try? RuntimeAvailability.scan(paths: paths, support: AppSettings.supportDirectory,
                                              cancel: cancel, probeVersions: probeVersions)
            }.value
        } onCancel: { cancel.cancel() }
        guard !Task.isCancelled, generation == availabilityGeneration,
              paths == RuntimeAvailability.Paths(settings.values), let result else { return }
        availability = result
        detectedTools = Dictionary(uniqueKeysWithValues: [(LocalSoftware.whisperCPP, "whisper-cli"), (.ffmpeg, "ffmpeg")].compactMap { software, name in
            result.tools[software].map { (name, $0.path) }
        })
    }

    func useDependency(_ software: LocalSoftware) {
        guard !busy, !isRecording(), let found = dependency(software) else { return }
        switch software {
        case .ffmpeg: settings.values.ffmpegPath = found.path
        case .whisperCPP: settings.values.whisperPath = found.path
        case .pipeline: settings.values.pythonPath = found.path
        case .ollama: break
        }
    }

    func forgetPipelineSelection() {
        guard !busy, !isRecording() else { return }
        settings.values.pythonPath = ""
        availability = nil
        status = "Pipeline selection cleared; existing environments and jobs are retained."
    }

    init(settings: AppSettings, aiModels: @escaping @Sendable () async throws -> [String] = {
        try await IntelligenceClient().models(provider: .ollama)
    }) { self.settings = settings; self.aiModels = aiModels }
    @Published private(set) var status = "Detection has not run"
    @Published private(set) var diagnostics = ""
    @Published private(set) var localAIModels: [String] = []
    @Published private(set) var localAIAvailable = false
    @Published private(set) var progress = 0.0
    @Published private(set) var busy = false
    private var task: Task<Void, Never>?
    private var token: WorkCancellation?
    private let logger = Logger(subsystem: "com.moreaki.recscribe", category: "Runtime")

    func cancel() { token?.cancel(); task?.cancel() }
    func shutdown() async { cancel(); await task?.value }
    private func perform(_ label: String, work: @escaping @MainActor (WorkCancellation) async throws -> Void) {
        guard !busy, !isRecording() else { return }
        busy = true; status = label; progress = 0
        let cancellation = WorkCancellation()
        token = cancellation
        task = Task {
            let start = ContinuousClock.now
            do { try await work(cancellation); try cancellation.check(); try Task.checkCancellation(); status = "\(label) — complete"; progress = 1 }
            catch { status = error is CancellationError ? "Cancelled" : error.localizedDescription }
            logger.notice("Operation id=\(cancellation.id) \(label, privacy: .public) elapsed=\(String(describing: start.duration(to: .now)), privacy: .public)")
            busy = false; token = nil; task = nil
        }
    }

    func detect() {
        perform("Detect local tools") { [self] token in
            let values = settings.values
            detectedTools = await Task.detached(priority: .utility) {
                Dictionary(uniqueKeysWithValues: ["whisper-cli", "ffmpeg"].compactMap { name in
                    LocalToolDiscovery.executable(name).map { (name, $0) }
                })
            }.value
            guard let path = values.whisperPath.isEmpty ? detectedTools["whisper-cli"] : values.whisperPath else {
                throw SessionError.invalid("whisper-cli not found; install it or choose its executable")
            }
            let binary = URL(fileURLWithPath: path)
            let metal = MTLCreateSystemDefaultDevice()?.name ?? "unavailable"
            let output = try await Task.detached(priority: .utility) {
                try LocalProcessRunner.run(binary, ["--help"], in: FileManager.default.temporaryDirectory, cancel: token, timeout: RuntimeInstallation.Policy.toolDetection)
            }.value
            diagnostics = "64-bit process · Metal device: \(metal)\nwhisper-cli: \(binary.path)\n\(output.contains("ggml_metal") ? "Whisper Metal backend detected" : "Whisper Metal backend not confirmed by CLI")\nInference acceleration must be checked in each job’s ASR log.\n\n\(output.prefix(RuntimeInstallation.Policy.diagnosticCharacters))"
        }
    }

    func useDetectedTools() {
        if let path = detectedTools["whisper-cli"] { settings.values.whisperPath = path }
        if let path = detectedTools["ffmpeg"] { settings.values.ffmpegPath = path }
    }

    func detectAI() {
        perform("Detect local AI") { [self] token in
            localAIAvailable = false
            let models = try await aiModels()
            try token.check()
            localAIAvailable = true
            localAIModels = models
            diagnostics = "Ollama · 127.0.0.1:11434\nLocal models: \(localAIModels.joined(separator: ", "))\nRemote/cloud models are excluded; no transcript was sent."
        }
    }

    func install(_ software: LocalSoftware, reinitialize: Bool = false) {
        guard software != .pipeline else { installPipeline(reinitialize: reinitialize); return }
        let formula = software.rawValue
        perform("Install \(formula) with Homebrew") { [self] token in
            guard software != .ollama || !localAIAvailable else {
                throw SessionError.invalid("Ollama is already available at 127.0.0.1:11434. Recheck the local service instead.")
            }
            let paths = RuntimeAvailability.Paths(settings.values)
            diagnostics = try await Task.detached(priority: .utility) {
                guard RuntimeAvailability.toolPath(software, paths: paths) == nil else {
                    throw SessionError.invalid("\(formula) is already available. Recheck or select the existing executable instead.")
                }
                return try RuntimeInstallation.install(software, cancel: token)
            }.value
        }
    }

    func installPipeline(reinitialize: Bool = false) {
        perform("Install local pipeline runtime") { [self] token in
            guard reinitialize || !RuntimeAvailability.executable(settings.values.pythonPath) else {
                throw SessionError.invalid("A Python runtime is already selected. Recheck it or explicitly reinitialize the pipeline.")
            }
            guard let archive = Bundle.main.url(forResource: "pipeline", withExtension: "tar.gz") else {
                throw SessionError.invalid("Bundled pipeline sources are missing; rebuild or reinstall RecScribe")
            }
            let executable = try await Task.detached(priority: .utility) {
                try RuntimeInstallation.pipeline(archive: archive, support: AppSettings.supportDirectory, cancel: token)
            }.value
            try token.check()
            settings.values.pythonPath = executable.path
        }
    }

    func download(_ model: WhisperModel) {
        perform("Download and verify \(model.id)") { [self] token in
            let paths = RuntimeAvailability.Paths(settings.values)
            let directory = AppSettings.supportDirectory.appendingPathComponent("Models")
            let destination = try await Task.detached(priority: .utility) {
                guard RuntimeAvailability.model(model, paths: paths, support: AppSettings.supportDirectory) == nil else {
                    throw SessionError.invalid("A local \(model.id) model file was found. Select or review the existing file instead.")
                }
                return try RuntimeInstallation.modelDestination(model, directory: directory, cancel: token)
            }.value
            try token.check()
            let delegate = DownloadProgress(expectedBytes: model.bytes) { [weak self] fraction in
                Task { @MainActor in
                    guard self?.token === token else { return }
                    guard let self else { return }
                    self.progress = max(self.progress, fraction * RuntimeInstallation.Policy.downloadProgressShare)
                }
            }
            let (temporary, response) = try await delegate.download(URLRequest(url: model.url))
            defer { try? FileManager.default.removeItem(at: temporary) }
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw SessionError.invalid("Model download failed") }
            status = "Verifying model SHA-256…"
            progress = RuntimeInstallation.Policy.downloadProgressShare
            try await Task.detached(priority: .utility) {
                try model.verifyAndInstall(temporary, to: destination, cancel: token)
            }.value
            try token.check()
            settings.values.modelPath = destination.path
        }
    }
}
