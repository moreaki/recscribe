import CryptoKit
import Darwin
import Foundation
import os

/// A new private job for each text action. Parent JSON/audio/raw ASR are never overwritten.
public struct TextJob: Sendable {
    public static let version = "swift-core-0.1.0"
    public static let maximumTranscriptBytes = 16 * 1_024 * 1_024
    private let client: IntelligenceClient
    public init(client: IntelligenceClient = .init()) { self.client = client }

    @concurrent public func run(source: URL, output: URL, options: TextDerivationOptions, key: Data? = nil) async throws {
        try Task.checkCancellation()
        if options.provider == .openai && !options.cloudConsent { throw CoreFailure("Cloud text processing requires explicit consent") }
        try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard mkdir(output.path, 0o700) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let started = ContinuousClock.now, id = UUID().uuidString
        defer { Logger(subsystem: "com.moreaki.recscribe", category: "Intelligence").notice("Text job id=\(id, privacy: .public) elapsed=\(Self.seconds(since: started))") }
        var manifest: JSONValue = ["schema_version": "1.0", "job_id": .string(id), "pipeline_version": .string(Self.version),
            "source_path": .string(source.path), "created_at": .string(Self.now), "history": [], "artifacts": [:], "error": nil,
            "options": ["mode": .string(options.mode.rawValue), "target_language": options.targetLanguage.map(JSONValue.string) ?? .null,
                "local_only": .bool(options.provider == .ollama), "allow_cloud_text": .bool(options.cloudConsent),
                "summarize": .bool(options.summarize), "provider": .string(options.provider.rawValue), "model": .string(options.model)]]
        func transition(_ state: String, _ progress: Double) throws {
            manifest["state"] = .string(state); manifest["progress"] = .number(progress); manifest["updated_at"] = .string(Self.now)
            manifest["history"] = .array((manifest["history"].array ?? []) + [["state": .string(state), "at": .string(Self.now), "elapsed_seconds": .number(Self.seconds(since: started))]])
            try Self.write(manifest.encoded(), named: "manifest.json", in: output)
        }
        do {
            try transition("queued", 0)
            let data = try Self.readTranscript(source)
            let original = try CanonicalTranscript(JSONDecoder().decode(JSONValue.self, from: data)).value
            guard try Self.hash(Self.readTranscript(source)) == Self.hash(data) else { throw CoreFailure("Parent transcript changed during loading") }
            let parent: JSONValue = ["path": .string(source.path), "sha256": .string(Self.hash(data))]
            manifest["parent_transcript"] = parent; manifest["source_path"] = original["source"]["path"]
            try Self.write(data, named: "input-transcript.json", in: output)
            let rawReference: JSONValue = ["schema_version": "1.0", "kind": "parent_transcript_reference", "parent": parent, "raw_asr_unchanged": true]
            try Self.write(rawReference.encoded(), named: "transcript.raw.json", in: output)
            try Self.write(original["source"].encoded(), named: "audio-report.json", in: output)
            var inherited = original
            // Summary-only retains the text rendition and its evidence in the parent job.
            if options.mode == .verbatim {
                inherited["language_processing"]["derivations"] = .array((original["language_processing"]["derivations"].array ?? []).map { entry in
                    var entry = entry
                    for field in ["raw_path", "model_metadata_path"] {
                        if let path = entry[field].string, !path.hasPrefix("/") {
                            entry[field] = .string(source.deletingLastPathComponent().appendingPathComponent(path).standardizedFileURL.path)
                        }
                    }
                    return entry
                })
            }
            try transition("post-processing", 0.7)
            var document = try await TextDerivation(client: client, options: options).apply(to: inherited, in: output, key: key)
            document["job_id"] = .string(id)
            var processing = document["processing"].object ?? [:]
            for field in ["openai_model", "ollama_model", "allow_cloud_text"] { processing.removeValue(forKey: field) }
            processing[options.provider == .openai ? "openai_model" : "ollama_model"] = .string(options.model)
            processing["local_only"] = .bool(options.provider == .ollama && processing["allow_cloud_audio"] != true)
            if options.provider == .openai { processing["allow_cloud_text"] = true }
            processing["summarize"] = .bool(options.summarize)
            processing["pipeline_version"] = .string(Self.version)
            processing["started_at"] = manifest["created_at"]
            processing["duration_ms"] = .integer(Int64(Self.seconds(since: started) * 1_000))
            document["processing"] = .object(processing); manifest["options"] = .object(processing)
            try Task.checkCancellation()
            try transition("validating", 0.8)
            let validated = try CanonicalTranscript(document)
            let encoded = try document.encoded()
            guard encoded.count <= Self.maximumTranscriptBytes else { throw CoreFailure("Derived transcript exceeds the supported size limit") }
            try Self.write(encoded, named: "transcript.json", in: output)
            try transition("rendering", 0.9)
            for (name, text) in TranscriptRenderer.render(validated) {
                try Task.checkCancellation()
                try Self.write(Data(text.utf8), named: name, in: output)
            }
            try Task.checkCancellation()
            manifest["artifacts"] = try Self.inventory(output)
            manifest["duration_seconds"] = .number(Self.seconds(since: started))
            try transition(document["status"].string!, 1)
        } catch {
            let cancelled = Task.isCancelled || error is CancellationError
            let state = cancelled ? "cancelled" : "failed"
            // Error details stay private and never include provider bodies or transcript content.
            let message = cancelled ? "Cancelled; previous transcript retained" : error.localizedDescription
            manifest["error"] = ["type": .string(state), "message": .string(message)]
            try? Self.write(Data("# Post-processing \(state)\n\nOriginal transcript retained.\n\n\(message)\n".utf8), named: "review.md", in: output)
            manifest["artifacts"] = (try? Self.inventory(output)) ?? [:]
            try? transition(state, manifest["progress"].double ?? 0)
            if cancelled { throw CancellationError() }
            throw error
        }
    }

    static var now: String { Date().ISO8601Format(.iso8601(timeZone: .gmt, includingFractionalSeconds: true)) }
    static func seconds(since start: ContinuousClock.Instant) -> Double {
        let parts = start.duration(to: .now).components
        return Double(parts.seconds) + Double(parts.attoseconds) / 1e18
    }
    static func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    static func write(_ data: Data, named name: String, in directory: URL) throws {
        try data.write(to: directory.appendingPathComponent(name), options: .atomic)
    }
    static func readTranscript(_ source: URL) throws -> Data {
        let handle = try FileHandle(forReadingFrom: source)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: maximumTranscriptBytes + 1) ?? Data()
        guard data.count <= maximumTranscriptBytes else { throw CoreFailure("Transcript exceeds the post-processing size limit") }
        try Task.checkCancellation()
        return data
    }
    static func inventory(_ directory: URL) throws -> JSONValue {
        var entries: [String: JSONValue] = [:]
        for url in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isRegularFileKey]) where url.lastPathComponent != "manifest.json" {
            guard try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else { continue }
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            var digest = SHA256(), size: Int64 = 0
            while let chunk = try handle.read(upToCount: 1_024 * 1_024), !chunk.isEmpty { digest.update(data: chunk); size += Int64(chunk.count) }
            entries[url.lastPathComponent] = ["sha256": .string(digest.finalize().map { String(format: "%02x", $0) }.joined()), "size_bytes": .integer(size)]
        }
        return .object(entries)
    }
}
