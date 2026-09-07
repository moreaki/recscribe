import AppKit
import Combine
import Foundation
import Metal
import os

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
    static let catalog: [Self] = [
        .init(id: "tiny", bytes: 77_691_713, sha256: "be07e048e1e599ad46341c8d2a135645097a538221678b7acdd1b1919c6e1b21"),
        .init(id: "base", bytes: 147_951_465, sha256: "60ed5bc3dd14eea856493d334349b405782ddcaf0028d4b5df4088345fba2efe"),
        .init(id: "small", bytes: 487_601_967, sha256: "1be3a9b2063867b937e64e2ec7483364a79917e157fa98c5d94b5c1fffea987b"),
        .init(id: "large-v3-turbo", bytes: 1_624_555_275, sha256: "1fc70f774d38eb169993ac391eea357ef47c88757ef72ee5943879b7e8e2bc69")
    ]
}

nonisolated final class DownloadProgress: NSObject, URLSessionDownloadDelegate, Sendable {
    let update: @Sendable (Double) -> Void
    private let lastPercent = OSAllocatedUnfairLock(initialState: -1)
    init(update: @escaping @Sendable (Double) -> Void) { self.update = update }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {}
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        if totalBytesExpectedToWrite > 0 {
            let fraction = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
            let percent = Int(fraction * 100)
            let changed = lastPercent.withLock { previous in
                guard previous != percent else { return false }
                previous = percent; return true
            }
            if changed { update(fraction) }
        }
    }
}

nonisolated enum LocalSoftware: String, Sendable {
    case pipeline, ffmpeg, ollama
    case whisperCPP = "whisper-cpp"
}

@MainActor
final class RuntimeManager: ObservableObject {
    private let settings: AppSettings
    var isRecording: () -> Bool = { false }
    @Published private(set) var detectedTools: [String: String] = [:]

    init(settings: AppSettings) { self.settings = settings }
    @Published private(set) var status = "Detection has not run"
    @Published private(set) var diagnostics = ""
    @Published private(set) var localAIModels: [String] = []
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
            do { try await work(cancellation); status = "\(label) — complete"; progress = 1 }
            catch { status = error is CancellationError ? "Cancelled" : error.localizedDescription }
            logger.notice("Operation \(label, privacy: .public) elapsed=\(String(describing: start.duration(to: .now)), privacy: .public)")
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
                try LocalProcessRunner.run(binary, ["--help"], in: FileManager.default.temporaryDirectory, cancel: token, timeout: 120)
            }.value
            diagnostics = "64-bit process · Metal device: \(metal)\nwhisper-cli: \(binary.path)\n\(output.contains("ggml_metal") ? "Whisper Metal backend detected" : "Whisper Metal backend not confirmed by CLI")\nInference acceleration must be checked in each job’s ASR log.\n\n\(output.prefix(8_000))"
        }
    }

    func useDetectedTools() {
        if let path = detectedTools["whisper-cli"] { settings.values.whisperPath = path }
        if let path = detectedTools["ffmpeg"] { settings.values.ffmpegPath = path }
    }

    func detectAI() {
        perform("Detect local AI") { [self] token in
            let python = settings.values.pythonPath
            let output = try await Task.detached(priority: .utility) {
                try LocalProcessRunner.run(URL(fileURLWithPath: python), ["-m", "recscribe.local_ai", "--list"],
                    in: FileManager.default.temporaryDirectory, cancel: token, timeout: 15)
            }.value
            localAIModels = try JSONDecoder().decode([String].self, from: Data(output.utf8))
            diagnostics = "Ollama · 127.0.0.1:11434\nLocal models: \(localAIModels.joined(separator: ", "))\nRemote/cloud models are excluded; no transcript was sent."
        }
    }

    func install(_ software: LocalSoftware) {
        guard software != .pipeline else { installPipeline(); return }
        let formula = software.rawValue
        perform("Install \(formula) with Homebrew") { [self] token in
            guard let brew = LocalToolDiscovery.executable("brew") else {
                throw SessionError.invalid("Install Homebrew from brew.sh first, then retry")
            }
            diagnostics = try await Task.detached(priority: .utility) {
                try LocalProcessRunner.run(URL(fileURLWithPath: brew), ["install", formula], in: FileManager.default.temporaryDirectory, cancel: token, timeout: 1800)
            }.value
        }
    }

    func installPipeline() {
        perform("Install local pipeline runtime") { [self] token in
            let archive = Bundle.main.resourceURL!.appendingPathComponent("pipeline.tar.gz")
            guard FileManager.default.fileExists(atPath: archive.path),
                  let python = LocalToolDiscovery.executable("python3") else {
                throw SessionError.invalid("Python 3.12+ from Homebrew and bundled pipeline sources are required")
            }
            let environment = AppSettings.supportDirectory.appendingPathComponent("Pipeline-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: AppSettings.supportDirectory, withIntermediateDirectories: true)
            let source = AppSettings.supportDirectory.appendingPathComponent("pipeline-source-\(UUID())")
            try FileManager.default.createDirectory(at: source, withIntermediateDirectories: false)
            defer { try? FileManager.default.removeItem(at: source) }
            let executable = environment.appendingPathComponent("bin/python3")
            _ = try await Task.detached(priority: .utility) {
                _ = try LocalProcessRunner.run(URL(fileURLWithPath: "/usr/bin/tar"), ["-xzf", archive.path, "-C", source.path], in: source, cancel: token, timeout: 30)
                _ = try LocalProcessRunner.run(URL(fileURLWithPath: python), ["-m", "venv", environment.path], in: AppSettings.supportDirectory, cancel: token, timeout: 120)
                return try LocalProcessRunner.run(executable, ["-m", "pip", "install", source.path], in: AppSettings.supportDirectory, cancel: token, timeout: 600)
            }.value
            settings.values.pythonPath = executable.path
        }
    }

    func download(_ model: WhisperModel) {
        perform("Download and verify \(model.id)") { [self] token in
            let directory = AppSettings.supportDirectory.appendingPathComponent("Models")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            guard let free = DiskSpace.availableBytes(at: directory), free > model.bytes + DiskSpace.minimumBytesToRecord else { throw SessionError.diskFull }
            let destination = directory.appendingPathComponent(model.filename)
            guard !FileManager.default.fileExists(atPath: destination.path) else { throw SessionError.invalid("Model already exists; select its local file instead") }
            let delegate = DownloadProgress { [weak self] fraction in Task { @MainActor in self?.progress = fraction * 0.95 } }
            let (temporary, response) = try await URLSession.shared.download(for: URLRequest(url: model.url), delegate: delegate)
            defer { try? FileManager.default.removeItem(at: temporary) }
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw SessionError.invalid("Model download failed") }
            status = "Verifying model SHA-256…"
            try await Task.detached(priority: .utility) {
                try model.verifyAndInstall(temporary, to: destination, cancel: token)
            }.value
            settings.values.modelPath = destination.path
        }
    }
}
