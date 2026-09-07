import Combine
import Foundation

nonisolated enum TranscriptionMode: String, Codable, CaseIterable, Sendable {
    case verbatim, normalize, translate
}
nonisolated enum RecognitionProfile: String, Codable, CaseIterable, Sendable {
    case fast, verified
}

@MainActor
final class AppSettings: ObservableObject {
    nonisolated static var supportDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("RecScribe", isDirectory: true)
    }
    private static let persistenceKey = "sessionSettings.v1"
    nonisolated struct Values: Codable, Equatable, Sendable {
        var storage = RecordingStorageOptions()
        var whisperPath = ""
        var ffmpegPath = ""
        var pythonPath = ""
        var modelPath = ""
        var verificationModelPath = ""
        var vadModelPath = ""
        var sourceLanguage = "auto"
        var targetLanguage = "de"
        var mode = TranscriptionMode.verbatim
        var profile = RecognitionProfile.fast
        var autoTranscribe = false
        var aiEnabled = false
        var ollamaModel = ""
        var summarize = false

        init() {}
        private enum CodingKeys: String, CodingKey { case storage, whisperPath, ffmpegPath, pythonPath, modelPath, verificationModelPath, vadModelPath, sourceLanguage, targetLanguage, mode, profile, autoTranscribe, aiEnabled, ollamaModel, summarize }
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            func read<T: Decodable>(_ key: CodingKeys, _ fallback: T) -> T {
                (try? container.decode(T.self, forKey: key)) ?? fallback
            }
            storage = read(.storage, storage)
            whisperPath = read(.whisperPath, whisperPath)
            ffmpegPath = read(.ffmpegPath, ffmpegPath)
            pythonPath = read(.pythonPath, pythonPath)
            modelPath = read(.modelPath, modelPath)
            verificationModelPath = read(.verificationModelPath, verificationModelPath)
            vadModelPath = read(.vadModelPath, vadModelPath)
            sourceLanguage = read(.sourceLanguage, sourceLanguage)
            targetLanguage = read(.targetLanguage, targetLanguage)
            mode = read(.mode, mode)
            profile = read(.profile, profile)
            autoTranscribe = read(.autoTranscribe, autoTranscribe)
            aiEnabled = read(.aiEnabled, aiEnabled)
            ollamaModel = read(.ollamaModel, ollamaModel)
            summarize = read(.summarize, summarize)
        }
    }
    @Published var values: Values {
        didSet { if let data = try? JSONEncoder().encode(values) { defaults.set(data, forKey: Self.persistenceKey) } }
    }
    @Published private(set) var validationMessage: String?
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        values = defaults.data(forKey: Self.persistenceKey).flatMap { try? JSONDecoder().decode(Values.self, from: $0) } ?? Values()
    }

    func setPartSizeMiB(_ value: Double) {
        do {
            values.storage.maximumPartBytes = try RecordingStorageOptions.partBytes(mebibytes: value)
            validationMessage = nil
        } catch { validationMessage = error.localizedDescription }
    }
}

/// Explicit discovery, never an implicit override of persisted user selections.
nonisolated enum LocalToolDiscovery {
    static let searchDirectories = ["/opt/homebrew/bin", "/usr/local/bin"]
    static func executable(_ name: String) -> String? {
        searchDirectories.map { URL(fileURLWithPath: $0).appendingPathComponent(name).path }
            .first(where: FileManager.default.isExecutableFile)
    }
}
