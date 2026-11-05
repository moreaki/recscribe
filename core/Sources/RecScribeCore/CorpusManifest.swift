import Foundation

/// Corpus metadata is evidence, not a request to download or approve a dataset.
public enum CorpusManifest {
    public struct Eligibility: Sendable {
        public let status: String
        public let reason: String?
        public let audio: URL?
        public let reference: URL?
        public let audioSHA256: String?
        public let referenceSHA256: String?
    }

    public static func validate(_ document: JSONValue) throws -> [JSONValue] {
        guard let version = document["schema_version"].string, ["1.0", "2.0"].contains(version),
              let cases = document["cases"].array else { throw CoreFailure("Expected corpus schema_version 1.0 or 2.0 and cases array") }
        if version == "2.0" {
            guard nonempty(document["corpus_version"]), document["frozen"].bool != nil else {
                throw CoreFailure("Corpus v2 needs corpus_version and an explicit frozen flag")
            }
        }
        var ids = Set<String>(), splits: [String: String] = [:]
        for item in cases {
            guard let id = item["id"].string, isSafeID(id), ids.insert(id).inserted, nonempty(item["category"]) else {
                throw CoreFailure("Corpus cases need unique safe IDs and a category")
            }
            guard version == "2.0" else { continue }
            let keys = ["language", "variety", "script", "task", "split", "duration_seconds", "conditions", "domain",
                        "speaker_ids", "session_id", "source_id", "source_channel", "code_switches", "audio", "reference",
                        "sha256", "reference_sha256", "license", "source_url", "reference_conventions", "reviewed", "scoring_policy"]
            guard keys.allSatisfy({ item.object?[$0] != nil }) else { throw CoreFailure("Corpus v2 case \(id) is missing required metadata fields") }
            guard let language = item["language"].string, language.range(of: "^[a-z]{2,3}(-[A-Za-z0-9]{2,8})*$", options: .regularExpression) != nil,
                  let task = item["task"].string, ["transcription", "dialect_transcription", "standard_rendering", "translation", "non_speech"].contains(task),
                  let split = item["split"].string, ["development", "held_out"].contains(split),
                  let conditions = item["conditions"].array, !conditions.isEmpty, conditions.allSatisfy(nonempty),
                  item["reviewed"].bool != nil,
                  let policy = item["scoring_policy"].string, TranscriptAccuracy.Policy(rawValue: policy) != nil,
                  let speakers = item["speaker_ids"].array, speakers.allSatisfy(nonempty),
                  item["code_switches"].array != nil else { throw CoreFailure("Invalid corpus v2 metadata: \(id)") }
            if language == "de-CH" && task == "transcription" {
                throw CoreFailure("Swiss German cases must choose standard_rendering (primary written-German target) or a separate dialect_transcription task explicitly")
            }
            if let role = item.object?["coverage_role"], ![JSONValue.string("primary"), "optional"].contains(role) {
                throw CoreFailure("coverage_role must be primary or optional: \(id)")
            }
            if let duration = item["duration_seconds"].double, !duration.isFinite || duration <= 0 {
                throw CoreFailure("Corpus duration must be positive: \(id)")
            }
            if item["duration_seconds"] != .null && item["duration_seconds"].double == nil {
                throw CoreFailure("Invalid corpus duration: \(id)")
            }
            for field in ["sha256", "reference_sha256"] {
                if let digest = item[field].string, !isSHA256(digest) { throw CoreFailure("Invalid \(field): \(id)") }
                if item[field] != .null && item[field].string == nil { throw CoreFailure("Invalid \(field): \(id)") }
            }
            for field in ["variety", "script", "domain", "session_id", "source_id", "source_url", "reference_conventions", "audio", "reference", "license"] {
                guard item[field] == .null || nonempty(item[field]) else { throw CoreFailure("Invalid \(field): \(id)") }
            }
            if let script = item["script"].string, script.range(of: "^[A-Z][a-z]{3}$", options: .regularExpression) == nil {
                throw CoreFailure("Script must use an ISO 15924 code: \(id)")
            }
            if let channel = item["source_channel"].integer {
                guard channel >= 0 else { throw CoreFailure("Invalid source channel: \(id)") }
            } else if item["source_channel"] != .null && item["source_channel"] != "mix" {
                throw CoreFailure("source_channel must be a zero-based channel, mix, or pending null: \(id)")
            }
            for event in item["code_switches"].array ?? [] {
                guard let start = event["start_seconds"].double, let end = event["end_seconds"].double,
                      start.isFinite, end.isFinite, start >= 0, end > start, nonempty(event["language"]),
                      item["duration_seconds"].double.map({ end <= $0 }) ?? true else {
                    throw CoreFailure("Invalid language-switch source interval: \(id)")
                }
            }
            var groups = speakers.compactMap(\.string).map { "speaker:\($0)" }
            for field in ["session_id", "source_id", "sha256"] {
                if let value = item[field].string { groups.append("\(field):\(value)") }
            }
            for group in groups {
                if let previous = splits[group], previous != split {
                    throw CoreFailure("Development/held-out leakage for \(group) in \(id)")
                }
                splits[group] = split
            }
        }
        return cases
    }

    public static func eligibility(_ item: JSONValue, manifest: URL, schemaVersion: String,
                                   check: @Sendable () throws -> Void = { try Task.checkCancellation() }) throws -> Eligibility {
        func pending(_ reason: String) -> Eligibility {
            Eligibility(status: "pending_corpus", reason: reason, audio: nil, reference: nil, audioSHA256: nil, referenceSHA256: nil)
        }
        try check()
        guard let audio = item["audio"].string, let reference = item["reference"].string,
              let digest = item["sha256"].string, nonempty(item["license"]) else {
            return pending("Missing audio, human reference, checksum or license/consent evidence")
        }
        func resolve(_ path: String) -> URL {
            path.hasPrefix("/") ? URL(fileURLWithPath: path) : manifest.deletingLastPathComponent().appendingPathComponent(path).standardizedFileURL
        }
        let source = resolve(audio), truth = resolve(reference)
        guard FileManager.default.isReadableFile(atPath: source.path), FileManager.default.isReadableFile(atPath: truth.path) else {
            return pending("Corpus files are unavailable locally")
        }
        let actualAudio = try WAVAudio.hash(source, check: check), actualReference = try WAVAudio.hash(truth, check: check)
        guard actualAudio == digest else { throw CoreFailure("Audio checksum mismatch: \(item["id"].string ?? "unknown")") }
        if let referenceDigest = item["reference_sha256"].string, referenceDigest != actualReference {
            throw CoreFailure("Reference checksum mismatch: \(item["id"].string ?? "unknown")")
        }
        if schemaVersion == "2.0" {
            guard item["reference_sha256"].string != nil else { return pending("Human reference hash has not been frozen") }
            let required = ["variety", "script", "domain", "session_id", "source_id", "source_url", "reference_conventions"]
            guard required.allSatisfy({ nonempty(item[$0]) }), item["duration_seconds"].double != nil,
                  item["source_channel"] != .null else { return pending("Coverage/provenance metadata is incomplete") }
            if item["task"] != "non_speech" && (item["speaker_ids"].array ?? []).isEmpty {
                return pending("Independent speaker grouping is missing")
            }
            let layout = try WAVAudio.layout(source, check: check)
            let actualDuration = Double(layout.frames) / Double(layout.rate)
            let tolerance = max(0.001, 1 / Double(layout.rate))
            guard abs(item["duration_seconds"].double! - actualDuration) <= tolerance else {
                throw CoreFailure("Corpus duration differs from original source frames: \(item["id"].string ?? "unknown")")
            }
            if let channel = item["source_channel"].integer {
                guard channel >= 0 && channel < Int64(layout.channels) else {
                    throw CoreFailure("Corpus source channel is outside original WAV channels: \(item["id"].string ?? "unknown")")
                }
            } else if item["source_channel"] == "mix" {
                return Eligibility(status: "unsupported", reason: "Final recognition preserves independent channels; a derived live-mix replay adapter is not available",
                                   audio: nil, reference: nil, audioSHA256: actualAudio, referenceSHA256: actualReference)
            }
            guard item["reviewed"] == true else { return pending("Reference conventions and permitted use need human review") }
        }
        return Eligibility(status: "ready", reason: schemaVersion == "1.0" ? "Legacy corpus; reference hash was observed, not frozen in the manifest" : nil,
                           audio: source, reference: truth, audioSHA256: actualAudio, referenceSHA256: actualReference)
    }

    public static func isSafeID(_ value: String) -> Bool {
        !value.isEmpty && value.range(of: "^[a-zA-Z0-9_-]+$", options: .regularExpression) != nil
    }
    private static func nonempty(_ value: JSONValue) -> Bool {
        value.string.map { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } ?? false
    }
    private static func isSHA256(_ value: String) -> Bool { value.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil }
}
