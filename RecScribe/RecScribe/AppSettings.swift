import Combine
import Foundation

@MainActor
final class AppSettings: ObservableObject {
    static let shared = AppSettings()
    nonisolated static let developmentRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    nonisolated static var supportDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("RecScribe", isDirectory: true)
    }
    nonisolated struct Values: Codable, Equatable, Sendable {
        var storage = RecordingStorageOptions()
        var whisperPath = "/opt/homebrew/bin/whisper-cli"
        var ffmpegPath = "/opt/homebrew/bin/ffmpeg"
        var pythonPath = ""
        var modelPath = ""
        var verificationModelPath = ""
        var vadModelPath = ""
        var sourceLanguage = "auto"
        var targetLanguage = "de"
        var mode = "verbatim"
        var profile = "fast"
        var autoTranscribe = false
        var aiEnabled = false
        var ollamaModel = ""
        var summarize = false
    }
    @Published var values: Values { didSet { if let data = try? JSONEncoder().encode(values) { defaults.set(data, forKey: "sessionSettings.v1") } } }
    private let defaults: UserDefaults
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        values = defaults.data(forKey: "sessionSettings.v1").flatMap { try? JSONDecoder().decode(Values.self, from: $0) } ?? Values()
        if values.pythonPath.isEmpty {
            let development = Self.developmentRoot.appendingPathComponent("pipeline/.venv/bin/python3")
            values.pythonPath = FileManager.default.isExecutableFile(atPath: development.path) ? development.path
                : Self.supportDirectory.appendingPathComponent("Pipeline/bin/python3").path
        }
        if values.modelPath.isEmpty {
            let existing = Self.developmentRoot.appendingPathComponent("jobs/local-assets-small/ggml-model.bin")
            if FileManager.default.fileExists(atPath: existing.path) { values.modelPath = existing.path }
        }
    }
}
