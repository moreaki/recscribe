import Foundation

/// A bounded, read-only inventory. Presence is distinct from successful probing
/// and model presence is never presented as checksum verification.
nonisolated struct RuntimeAvailability: Sendable {
    struct Paths: Hashable, Sendable {
        var ffmpeg: String
        var whisper: String
        var python: String
        var model: String
        var verificationModel: String
        init(_ values: AppSettings.Values) {
            ffmpeg = values.ffmpegPath; whisper = values.whisperPath
            python = values.pythonPath; model = values.modelPath
            verificationModel = values.verificationModelPath
        }
    }
    struct Dependency: Sendable {
        var path: String
        var version: String?
        var issue: String?
    }
    struct Model: Sendable {
        var path: String
        var expectedSize: Bool
    }
    let paths: Paths
    var tools: [LocalSoftware: Dependency] = [:]
    var models: [String: Model] = [:]

    static func executable(_ path: String) -> Bool {
        path.hasPrefix("/") && FileManager.default.isExecutableFile(atPath: path)
            && (try? URL(fileURLWithPath: path).resolvingSymlinksInPath().resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
    }

    static func toolPath(_ software: LocalSoftware, paths: Paths,
                         directories: [String] = LocalToolDiscovery.searchDirectories) -> String? {
        let configured: String
        let name: String
        switch software {
        case .ffmpeg: configured = paths.ffmpeg; name = "ffmpeg"
        case .whisperCPP: configured = paths.whisper; name = "whisper-cli"
        case .ollama: configured = ""; name = "ollama"
        case .pipeline: return executable(paths.python) ? paths.python : nil
        }
        if executable(configured) { return configured }
        return LocalToolDiscovery.executable(name, directories: directories, isExecutable: executable)
    }

    static func model(_ model: WhisperModel, paths: Paths, support: URL) -> Model? {
        let selected = [paths.model, paths.verificationModel].filter { !$0.isEmpty }.map { URL(fileURLWithPath: $0) }
        let candidates = [support.appendingPathComponent("Models").appendingPathComponent(model.filename)]
            + selected + selected.map { $0.deletingLastPathComponent().appendingPathComponent(model.filename) }
        var existing: Model?
        for url in candidates {
            guard let info = try? url.resolvingSymlinksInPath().resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
                  info.isRegularFile == true, FileManager.default.isReadableFile(atPath: url.path) else { continue }
            let expectedSize = Int64(info.fileSize ?? -1) == model.bytes
            if url.lastPathComponent == model.filename || expectedSize {
                let found = Model(path: url.path, expectedSize: expectedSize)
                if expectedSize { return found }
                if existing == nil { existing = found }
            }
        }
        return existing
    }

    static func scan(paths: Paths, support: URL, cancel: WorkCancellation,
                     directories: [String] = LocalToolDiscovery.searchDirectories,
                     probeVersions: Bool = true,
                     probe: (@Sendable (String, [String]) throws -> String)? = nil) throws -> Self {
        let run: @Sendable (String, [String]) throws -> String = probe ?? { path, args in
            try LocalProcessRunner.run(URL(fileURLWithPath: path), args,
                in: FileManager.default.temporaryDirectory, cancel: cancel, timeout: 10)
        }
        var result = Self(paths: paths)
        for software in [LocalSoftware.ffmpeg, .whisperCPP, .ollama, .pipeline] {
            try cancel.check()
            guard let path = toolPath(software, paths: paths, directories: directories) else { continue }
            var dependency = Dependency(path: path)
            if probeVersions, software == .ffmpeg || software == .pipeline {
                do {
                    let output = try run(path, software == .ffmpeg ? ["-version"]
                        : ["-I", "-c", "from recscribe import __version__; print(__version__)"])
                    try cancel.check()
                    if software == .ffmpeg {
                        if let line = output.split(separator: "\n").first(where: { $0.hasPrefix("ffmpeg version ") }) {
                            dependency.version = String((line.dropFirst("ffmpeg version ".count).split(separator: " ").first ?? "").prefix(120))
                        } else { dependency.issue = "Executable found; FFmpeg version could not be confirmed." }
                    } else {
                        let version = output.trimmingCharacters(in: .whitespacesAndNewlines)
                        dependency.version = String(version.prefix(100))
                        if !PipelineRuntime.supportsTextActions(version) {
                            dependency.issue = "Pipeline version needs review; reinitialize the runtime to update it."
                        }
                    }
                } catch is CancellationError { throw CancellationError() }
                catch {
                    dependency.issue = software == .pipeline
                        ? "Python found; the pipeline could not be verified. Reinitialize or choose another runtime."
                        : "Executable found; version check failed. Recheck or choose another executable."
                }
            }
            result.tools[software] = dependency
        }
        for model in WhisperModel.catalog {
            try cancel.check()
            result.models[model.id] = Self.model(model, paths: paths, support: support)
        }
        return result
    }
}
