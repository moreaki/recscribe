import Combine
import Foundation
import RecScribeCore

nonisolated enum ProcessingLocation: String, Codable, CaseIterable, Sendable {
    case local, hybrid, cloud
    var label: String { rawValue.capitalized }
    var detail: String {
        switch self {
        case .local: "Audio and AI text processing stay on this Mac."
        case .hybrid: "Local transcription; cloud text processing requires separate approval."
        case .cloud: "Optional OpenAI audio streaming; approval is required for each recording activation."
        }
    }
}

nonisolated enum TranscriptionMode: String, Codable, CaseIterable, Sendable {
    case verbatim, normalize, translate
}
nonisolated enum RecognitionProfile: String, Codable, CaseIterable, Sendable {
    case fast, verified
}
nonisolated enum IntelligenceProvider: String, Codable, CaseIterable, Sendable {
    case ollama, openai
    var label: String { self == .ollama ? "Ollama · on this Mac" : "OpenAI · cloud text only" }
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
        // Legacy preference retained for migration only; never executed by the app.
        var pythonPath = ""
        var modelPath = ""
        var verificationModelPath = ""
        var vadModelPath = ""
        var sourceLanguage = "auto"
        var targetLanguage = "de"
        var mode = TranscriptionMode.verbatim
        var profile = RecognitionProfile.fast
        var autoTranscribe = false
        var liveChunkSeconds = LiveTranscriptionPolicy.defaultChunkSeconds
        var liveThreads = LiveTranscriptionPolicy.defaultThreads
        var aiEnabled = false
        var aiProvider = IntelligenceProvider.ollama
        var openaiModel = ""
        var ollamaModel = ""
        var summarize = false
        var processingLocation = ProcessingLocation.local
        var cloudTranscriptionModel = RealtimePolicy.model
        var migrationWarnings: [String] = []

        init() {}
        private enum CodingKeys: String, CodingKey { case storage, whisperPath, ffmpegPath, pythonPath, modelPath, verificationModelPath, vadModelPath, sourceLanguage, targetLanguage, mode, profile, autoTranscribe, liveChunkSeconds, liveThreads, aiEnabled, aiProvider, openaiModel, ollamaModel, summarize, processingLocation, cloudTranscriptionModel }
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            var reader = PreferenceReader(container: container)
            if container.contains(.storage) {
                do {
                    let storageContainer = try container.nestedContainer(keyedBy: RecordingStorageOptions.CodingKeys.self, forKey: .storage)
                    var nested = PreferenceReader(container: storageContainer)
                    storage.maximumPartBytes = nested.value(.maximumPartBytes, storage.maximumPartBytes) {
                        (RecordingStorageOptions.minimumPartBytes...RecordingStorageOptions.hardCap).contains($0)
                    }
                    storage.archiveFormat = nested.value(.archiveFormat, storage.archiveFormat)
                    storage.bitrateKbps = nested.value(.bitrateKbps, storage.bitrateKbps, valid: RecordingStorageOptions.bitrateRange.contains)
                    storage.flacCompression = nested.value(.flacCompression, storage.flacCompression, valid: RecordingStorageOptions.flacCompressionRange.contains)
                    migrationWarnings += nested.warnings.map { "storage." + $0 }
                } catch { migrationWarnings.append("storage: invalid object; defaults restored") }
            }
            whisperPath = reader.value(.whisperPath, whisperPath)
            ffmpegPath = reader.value(.ffmpegPath, ffmpegPath)
            pythonPath = reader.value(.pythonPath, pythonPath)
            modelPath = reader.value(.modelPath, modelPath)
            verificationModelPath = reader.value(.verificationModelPath, verificationModelPath)
            vadModelPath = reader.value(.vadModelPath, vadModelPath)
            sourceLanguage = reader.value(.sourceLanguage, sourceLanguage)
            targetLanguage = reader.value(.targetLanguage, targetLanguage)
            mode = reader.value(.mode, mode)
            profile = reader.value(.profile, profile)
            autoTranscribe = reader.value(.autoTranscribe, autoTranscribe)
            liveChunkSeconds = reader.value(.liveChunkSeconds, liveChunkSeconds, valid: LiveTranscriptionPolicy.chunkChoices.contains)
            liveThreads = reader.value(.liveThreads, liveThreads, valid: LiveTranscriptionPolicy.threadRange.contains)
            aiEnabled = reader.value(.aiEnabled, aiEnabled)
            aiProvider = reader.value(.aiProvider, aiProvider)
            openaiModel = reader.value(.openaiModel, openaiModel)
            ollamaModel = reader.value(.ollamaModel, ollamaModel)
            summarize = reader.value(.summarize, summarize)
            // Existing explicit cloud-text selection becomes Hybrid, never Cloud audio.
            if !container.contains(.processingLocation), aiProvider == .openai { processingLocation = .hybrid }
            else { processingLocation = reader.value(.processingLocation, .local) }
            cloudTranscriptionModel = reader.value(.cloudTranscriptionModel, cloudTranscriptionModel) { $0 == RealtimePolicy.model }
            migrationWarnings += reader.warnings
        }
    }
    @Published var values: Values {
        didSet { if let data = try? JSONEncoder().encode(values) { defaults.set(data, forKey: Self.persistenceKey) } }
    }
    @Published private(set) var validationMessage: String?
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.persistenceKey) {
            do { values = try JSONDecoder().decode(Values.self, from: data) }
            catch {
                values = Values()
                values.migrationWarnings = ["Settings could not be decoded; defaults restored. The original saved data is retained until you change a setting."]
            }
        } else { values = Values() }
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
    static func executable(_ name: String, directories: [String] = searchDirectories,
                           isExecutable: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }) -> String? {
        directories.map { URL(fileURLWithPath: $0).appendingPathComponent(name).path }
            .first(where: isExecutable)
    }
}

/// Preference fallback is deliberately distinct from strict manifest decoding.
private nonisolated struct PreferenceReader<Key: CodingKey> {
    let container: KeyedDecodingContainer<Key>
    var warnings: [String] = []
    mutating func value<T: Decodable>(_ key: Key, _ fallback: T, valid: (T) -> Bool = { _ in true }) -> T {
        guard container.contains(key) else { return fallback }
        if let value = try? container.decode(T.self, forKey: key), valid(value) { return value }
        warnings.append("\(key.stringValue): invalid value; default restored")
        return fallback
    }
}


extension AppSettings.Values {
    /// Shared by settings and job preflight. Never silently downgrade a verified job.
    nonisolated var verificationIssue: String? {
        guard profile == .verified else { return nil }
        guard !verificationModelPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return "Choose a second Whisper model in Settings → Transcription. Two-model comparison requires a different verification model."
        }
        let primary = URL(fileURLWithPath: modelPath).standardizedFileURL.resolvingSymlinksInPath()
        let verification = URL(fileURLWithPath: verificationModelPath).standardizedFileURL.resolvingSymlinksInPath()
        if primary == verification || sameFile(primary, verification) {
            return "The primary and verification models are the same. Choose a different verification model in Settings → Transcription, or explicitly select Single pass."
        }
        guard (try? verification.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true,
              FileManager.default.isReadableFile(atPath: verification.path) else {
            return "The verification model is missing or unreadable. Choose an installed Whisper model in Settings → Transcription."
        }
        return nil
    }

    private nonisolated func sameFile(_ first: URL, _ second: URL) -> Bool {
        guard let lhs = try? FileManager.default.attributesOfItem(atPath: first.path),
              let rhs = try? FileManager.default.attributesOfItem(atPath: second.path),
              let leftFile = lhs[.systemFileNumber] as? NSNumber,
              let rightFile = rhs[.systemFileNumber] as? NSNumber,
              let leftVolume = lhs[.systemNumber] as? NSNumber,
              let rightVolume = rhs[.systemNumber] as? NSNumber else { return false }
        return leftFile == rightFile && leftVolume == rightVolume
    }
}
