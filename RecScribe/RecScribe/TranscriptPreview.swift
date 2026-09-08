import Foundation

/// A read-only projection of the versioned canonical document. Rendering never
/// changes source text, and absent derived text falls back to the raw words.
nonisolated struct TranscriptPreview: Decodable, Sendable {
    static let currentSchemaVersion = "1.0"
    struct Segment: Decodable, Sendable {
        let id: String
        let sourceText: String
        let normalizedText: String?
        let translatedText: String?
        let needsReview: Bool
    }
    struct Processing: Decodable, Sendable {
        struct Engine: Decodable, Sendable { let model: String; let detectedLanguage: String? }
        let mode: TranscriptionMode
        let sourceLanguage: String?
        let enginePasses: [Engine]?
        let localOnly: Bool?
    }
    struct Source: Decodable, Sendable {
        let path: String
        let durationMs: Int64
        let channels: Int
        let sampleRate: Int
    }
    struct Summary: Decodable, Sendable {
        struct Note: Decodable, Sendable { let text: String; let segmentIds: [String] }
        let notes: [Note]
        let processor: String?
    }
    struct Language: Decodable, Sendable { let processor: String? }
    let schemaVersion: String
    let processing: Processing
    let source: Source?
    let segments: [Segment]
    let summary: Summary?
    let languageProcessing: Language?
    let reviewReasons: [String]
    var sourceURL: URL? { source.map { URL(fileURLWithPath: $0.path) } }
    var includesCloudText: Bool {
        processing.localOnly == false || languageProcessing?.processor?.hasPrefix("openai:") == true || summary?.processor?.hasPrefix("openai:") == true
    }
    var recognitionLabel: String {
        let models = Array(Set(processing.enginePasses?.map(\.model) ?? [])).sorted().joined(separator: ", ")
        let languages = Array(Set(processing.enginePasses?.compactMap(\.detectedLanguage) ?? [])).sorted().joined(separator: ", ")
        return [models, languages.isEmpty ? processing.sourceLanguage ?? "" : languages].filter { !$0.isEmpty }.joined(separator: " · ")
    }

    static func read(_ directory: URL) async throws -> Self {
        let worker = Task.detached(priority: .utility) {
            try Task.checkCancellation()
            let file = try FileHandle(forReadingFrom: directory.appendingPathComponent("transcript.json"))
            defer { try? file.close() }
            let data = try file.read(upToCount: RecordingSession.maximumManifestBytes + 1) ?? Data()
            guard data.count <= RecordingSession.maximumManifestBytes else { throw SessionError.invalid("Transcript is too large for the preview; open its artifacts") }
            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            let result = try decoder.decode(Self.self, from: data)
            guard result.schemaVersion == Self.currentSchemaVersion else { throw SessionError.invalid("Unsupported transcript version") }
            try Task.checkCancellation()
            return result
        }
        return try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
    }

    var text: String {
        segments.map { segment in
            let text = switch processing.mode {
            case .normalize: segment.normalizedText ?? segment.sourceText
            case .translate: segment.translatedText ?? segment.sourceText
            case .verbatim: segment.sourceText
            }
            return (segment.needsReview ? "[Review] " : "") + text.trimmingCharacters(in: .whitespacesAndNewlines)
        }.joined(separator: "\n\n")
    }
    var summaryText: String {
        summary?.notes.map { "\($0.text)\nSources: \($0.segmentIds.joined(separator: ", "))" }.joined(separator: "\n\n") ?? ""
    }
}
