import CryptoKit
import Darwin
import Foundation

/// A read-only projection of the versioned canonical document. Rendering never
/// changes source text, and absent derived text falls back to the raw words.
nonisolated struct TranscriptPreview: Decodable, Sendable {
    static let currentSchemaVersion = "1.0"
    struct Segment: Decodable, Sendable, Identifiable, Equatable {
        let id: String
        let sourceText: String
        let normalizedText: String?
        let translatedText: String?
        let needsReview: Bool
        let startMs: Int64?
        let endMs: Int64?
        let channel: Int?
        let reviewReasons: [String]?
        let confidence: Double?

        var confidenceLabel: String {
            guard let confidence, confidence.isFinite, (0...1).contains(confidence) else {
                return "Model confidence: unavailable"
            }
            return "Model confidence: \(Int((confidence * 100).rounded()))%"
        }
    }
    struct Processing: Decodable, Sendable {
        struct Engine: Decodable, Sendable { let model: String; let detectedLanguage: String? }
        let mode: TranscriptionMode
        let sourceLanguage: String?
        let enginePasses: [Engine]?
        let localOnly: Bool?
        let allowCloudAudio: Bool?
        let openaiModel: String?
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

    private struct Payload: Decodable {
        let schemaVersion: String
        let processing: Processing
        let source: Source?
        let segments: [Segment]
        let summary: Summary?
        let languageProcessing: Language?
        let reviewReasons: [String]
    }

    let schemaVersion: String
    let processing: Processing
    let source: Source?
    let segments: [Segment]
    let summary: Summary?
    let languageProcessing: Language?
    let reviewReasons: [String]
    let readingGroups: [TranscriptReading.Group]
    let channelGroups: [TranscriptReading.Group]
    let text: String
    let summaryText: String
    let markdownText: String
    let summaryMarkdownText: String
    let reviewPlainText: String
    let reviewMarkdownText: String
    let includesCloudAudio: Bool
    let includesCloudText: Bool
    let recognitionLabel: String
    private(set) var revision: String?
    private(set) var reviewItems: [TranscriptReading.ReviewItem] = []

    var sourceURL: URL? { source.map { URL(fileURLWithPath: $0.path) } }

    init(from decoder: Decoder) throws {
        let payload = try Payload(from: decoder)
        self.schemaVersion = payload.schemaVersion
        self.processing = payload.processing
        self.source = payload.source
        self.segments = payload.segments
        self.summary = payload.summary
        self.languageProcessing = payload.languageProcessing
        self.reviewReasons = payload.reviewReasons

        let cloudAudio = payload.processing.allowCloudAudio == true
        self.includesCloudAudio = cloudAudio
        self.includesCloudText = payload.processing.openaiModel != nil
            || (payload.processing.localOnly == false && !cloudAudio)
            || payload.languageProcessing?.processor?.hasPrefix("openai:") == true
            || payload.summary?.processor?.hasPrefix("openai:") == true

        let models = Array(Set(payload.processing.enginePasses?.map(\.model) ?? [])).sorted().joined(separator: ", ")
        let languages = Array(Set(payload.processing.enginePasses?.compactMap(\.detectedLanguage) ?? [])).sorted().joined(separator: ", ")
        self.recognitionLabel = [models, languages.isEmpty ? payload.processing.sourceLanguage ?? "" : languages]
            .filter { !$0.isEmpty }
            .joined(separator: " · ")

        let mode = payload.processing.mode
        let computedReadingGroups = TranscriptReading.groups(payload.segments)
        let computedChannelGroups = payload.segments.map { TranscriptReading.Group(segments: [$0]) }
        self.readingGroups = computedReadingGroups
        self.channelGroups = computedChannelGroups

        self.text = payload.segments.map { segment in
            let rendered = Self.displayedText(segment, mode: mode)
            return (segment.needsReview ? "[Review] " : "") + rendered.trimmingCharacters(in: .whitespacesAndNewlines)
        }.joined(separator: "\n\n")

        let computedSummaryText = payload.summary?.notes.map {
            "\($0.text)\nSources: \($0.segmentIds.joined(separator: ", "))"
        }.joined(separator: "\n\n") ?? ""
        self.summaryText = computedSummaryText
        self.summaryMarkdownText = computedSummaryText.isEmpty ? "" : "# Summary\n\n\(computedSummaryText)"

        let computedReviewPlain = payload.reviewReasons.joined(separator: "\n\n")
        self.reviewPlainText = computedReviewPlain
        let reviewBullets = payload.reviewReasons.map { "- \($0)" }.joined(separator: "\n")
        self.reviewMarkdownText = payload.reviewReasons.isEmpty ? "" : "# Review Notes\n\n\(reviewBullets)"

        var blocks: [String] = ["# Transcript"]
        for group in computedReadingGroups {
            let reviewTag = group.segments.contains(where: \.needsReview) ? " · [Review]" : ""
            blocks.append("## \(group.timing) (\(group.channels)\(reviewTag))")
            let first = group.segments[0]
            let isShared = group.segments.count <= 1 || group.segments.allSatisfy {
                $0.startMs == first.startMs
                    && $0.endMs == first.endMs
                    && $0.sourceText == first.sourceText
                    && Self.displayedText($0, mode: mode) == Self.displayedText(first, mode: mode)
            }
            if isShared {
                blocks.append(Self.displayedText(first, mode: mode).trimmingCharacters(in: .whitespacesAndNewlines))
            } else {
                let variants = group.segments.map { segment in
                    let single = TranscriptReading.Group(segments: [segment])
                    return "- **\(single.channels)** (\(single.timing)): \(Self.displayedText(segment, mode: mode).trimmingCharacters(in: .whitespacesAndNewlines))"
                }.joined(separator: "\n")
                blocks.append(variants)
            }
        }
        if !computedSummaryText.isEmpty {
            blocks.append("## Summary\n\n" + computedSummaryText)
        }
        if !payload.reviewReasons.isEmpty {
            blocks.append("## Review Notes\n\n" + reviewBullets)
        }
        self.markdownText = blocks.joined(separator: "\n\n")
        self.reviewItems = TranscriptReading.reviewItems(in: self)
    }

    static func read(_ directory: URL) async throws -> Self {
        let worker = Task.detached(priority: .utility) {
            try Task.checkCancellation()
            let data = try readData(directory)
            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            var result = try decoder.decode(Self.self, from: data)
            guard [Self.currentSchemaVersion, "1.1"].contains(result.schemaVersion) else { throw SessionError.invalid("Unsupported transcript version") }
            try Task.checkCancellation()
            result.revision = digest(data)
            return result
        }
        return try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
    }

    static func currentRevision(_ directory: URL) throws -> String {
        digest(try readData(directory))
    }

    private static func readData(_ directory: URL) throws -> Data {
        try Task.checkCancellation()
        let descriptor = Darwin.open(directory.appendingPathComponent("transcript.json").path, O_RDONLY | O_NONBLOCK)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let file = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? file.close() }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG else {
            throw SessionError.invalid("Transcript is not a regular file")
        }
        let data = try file.read(upToCount: RecordingSession.maximumManifestBytes + 1) ?? Data()
        guard data.count <= RecordingSession.maximumManifestBytes else {
            throw SessionError.invalid("Transcript is too large for the preview; open its artifacts")
        }
        try Task.checkCancellation()
        return data
    }

    private static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func displayedText(_ segment: Segment, mode: TranscriptionMode) -> String {
        switch mode {
        case .normalize: segment.normalizedText ?? segment.sourceText
        case .translate: segment.translatedText ?? segment.sourceText
        case .verbatim: segment.sourceText
        }
    }

    func displayedText(_ segment: Segment) -> String {
        Self.displayedText(segment, mode: processing.mode)
    }

    func groups(for mode: TranscriptReadingView.Mode) -> [TranscriptReading.Group] {
        mode == .reading ? readingGroups : channelGroups
    }

    func exportText(for section: TranscriptWorkspace.Section, markdown: Bool) -> String {
        switch section {
        case .summary:
            return markdown ? summaryMarkdownText : summaryText
        case .review:
            return markdown ? reviewMarkdownText : reviewPlainText
        case .transcript, .live:
            return markdown ? markdownText : text
        }
    }
}
