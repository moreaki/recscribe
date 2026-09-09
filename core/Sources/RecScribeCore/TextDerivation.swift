import CryptoKit
import Foundation

public struct TextDerivationOptions: Sendable {
    public var provider: TextProvider
    public var model: String
    public var mode: TextMode
    public var targetLanguage: String?
    public var summarize: Bool
    public var cloudConsent: Bool
    public init(provider: TextProvider, model: String, mode: TextMode, targetLanguage: String? = nil,
                summarize: Bool = false, cloudConsent: Bool = false) {
        self.provider = provider; self.model = model; self.mode = mode
        self.targetLanguage = targetLanguage; self.summarize = summarize; self.cloudConsent = cloudConsent
    }
}

/// Bounded, source-linked transformations; the model never chooses file paths or mutates ASR evidence.
struct TextDerivation {
    let client: IntelligenceClient
    let options: TextDerivationOptions

    func apply(to original: JSONValue, in directory: URL, key: Data?,
               progress: (Int, Int) throws -> Void = { _, _ in }) async throws -> JSONValue {
        guard options.mode != .verbatim || options.summarize else { throw CoreFailure("Choose a text transformation or summary") }
        guard options.mode == .verbatim || !(options.targetLanguage ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw CoreFailure("Choose a target language")
        }
        let info = try await client.modelInfo(provider: options.provider, model: options.model, key: key, cloudConsent: options.cloudConsent)
        let metadata = try info.encoded()
        try TextJob.write(metadata, named: "ai-model.json", in: directory)
        let processor = options.provider.rawValue + ":" + options.model
        var document = original, segments = original["segments"].array ?? []
        let field = options.mode == .normalize ? "normalized_text" : options.mode == .translate ? "translated_text" : nil
        var notes: [JSONValue] = [], derivations: [JSONValue] = []
        let batches = try batch(segments)
        try progress(0, batches.count)
        for (index, indices) in batches.enumerated() {
            try Task.checkCancellation()
            let prompt: JSONValue = [
                "mode": .string(options.mode.rawValue), "source_language": original["processing"]["source_language"],
                "target_language": options.targetLanguage.map(JSONValue.string) ?? .null, "summarize": .bool(options.summarize),
                "untrusted_transcript": .array(indices.map {
                    ["id": segments[$0]["id"], "text": segments[$0]["source_text"], "needs_review": segments[$0]["needs_review"]]
                })
            ]
            let encoded = try prompt.encoded(), suffix = String(format: "%04d", index)
            try TextJob.write(encoded, named: "ai-input-\(suffix).json", in: directory)
            let started = ContinuousClock.now
            let raw = try await client.generate(provider: options.provider, model: options.model,
                prompt: String(decoding: encoded, as: UTF8.self), key: key, cloudConsent: options.cloudConsent)
            let rawData = try raw.encoded(), rawName = "ai-raw-\(suffix).json"
            try TextJob.write(rawData, named: rawName, in: directory)
            let text = try IntelligenceClient.resultText(raw, provider: options.provider)
            guard let result = try? JSONDecoder().decode(JSONValue.self, from: Data(text.utf8)) else { throw CoreFailure("AI returned invalid JSON") }
            let expected = Set(indices.compactMap { segments[$0]["id"].string })
            let outputs = try validate(result, expected: expected)
            let evidence: JSONValue = [
                "processor": .string(processor), "source_sha256": .string(TextJob.hash(encoded)),
                "raw_path": .string(rawName), "raw_sha256": .string(TextJob.hash(rawData)),
                "duration_seconds": .number(TextJob.seconds(since: started)),
                "model_metadata_path": "ai-model.json", "model_metadata_sha256": .string(TextJob.hash(metadata)),
                "prompt_tokens": options.provider == .openai ? raw["usage"]["input_tokens"] : raw["prompt_eval_count"],
                "output_tokens": options.provider == .openai ? raw["usage"]["output_tokens"] : raw["eval_count"],
                "human_verified": false
            ]
            if let field {
                for i in indices {
                    segments[i]["normalized_text"] = .null
                    segments[i]["translated_text"] = .null
                    segments[i][field] = outputs[segments[i]["id"].string ?? ""] ?? .null
                    var reasons = (segments[i]["review_reasons"].array ?? []).filter { !($0.string ?? "").hasSuffix("_processor_not_configured") }
                    if !reasons.contains("ai_derived_text_unverified") { reasons.append("ai_derived_text_unverified") }
                    segments[i]["review_reasons"] = .array(reasons)
                    segments[i]["needs_review"] = true
                    var derivation = evidence
                    derivation["segment_id"] = segments[i]["id"]; derivation["field"] = .string(field)
                    derivations.append(derivation)
                }
            }
            if options.summarize {
                for var note in result["notes"].array ?? [] { note["provenance"] = evidence; notes.append(note) }
            }
            try progress(index + 1, batches.count)
        }
        document["segments"] = .array(segments)
        if field != nil {
            document["language_processing"] = ["mode": .string(options.mode.rawValue), "status": "completed",
                "processor": .string(processor), "derivations": .array(derivations)]
            document["processing"]["mode"] = .string(options.mode.rawValue)
            document["processing"]["target_language"] = options.targetLanguage.map(JSONValue.string) ?? .null
        }
        var reasons = (document["review_reasons"].array ?? []).filter {
            $0 != "ai_summary_unverified" && (field == nil || !($0.string ?? "").hasSuffix("_processor_not_configured"))
        }
        if options.summarize {
            document["summary"] = ["status": "needs_review", "processor": .string(processor), "notes": .array(notes)]
            reasons.append("ai_summary_unverified")
        } else {
            var fields = document.object ?? [:]; fields.removeValue(forKey: "summary"); document = .object(fields)
        }
        document["review_reasons"] = .array(reasons)
        document["status"] = .string(!reasons.isEmpty || segments.contains { $0["needs_review"] == true } ? "completed_with_review" : "completed")
        return document
    }

    private func batch(_ segments: [JSONValue]) throws -> [[Int]] {
        guard client.policy.maximumBatchSegments > 0, client.policy.maximumBatchScalars > 0 else { throw CoreFailure("Invalid AI batch policy") }
        var batches: [[Int]] = [], current: [Int] = [], size = 0
        for index in segments.indices {
            let count = segments[index]["source_text"].string?.unicodeScalars.count ?? 0
            guard count <= client.policy.maximumBatchScalars else { throw CoreFailure("ASR segment exceeds the AI context budget") }
            if !current.isEmpty && (size + count > client.policy.maximumBatchScalars || current.count >= client.policy.maximumBatchSegments) {
                batches.append(current); current = []; size = 0
            }
            current.append(index); size += count
        }
        if !current.isEmpty { batches.append(current) }
        return batches
    }

    private func validate(_ result: JSONValue, expected: Set<String>) throws -> [String: JSONValue] {
        guard Set(result.object?.keys.map { $0 } ?? []) == ["segments", "notes"],
              let outputs = result["segments"].array, let notes = result["notes"].array,
              outputs.count == expected.count, Set(outputs.compactMap { $0["id"].string }) == expected else {
            throw CoreFailure("AI output must reference every input segment exactly once")
        }
        func validText(_ value: JSONValue) -> Bool {
            guard let text = value.string else { return false }
            return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && text.unicodeScalars.count <= client.policy.maximumOutputScalars
        }
        guard outputs.allSatisfy({ Set($0.object?.keys.map { $0 } ?? []) == ["id", "text"] && validText($0["text"]) }) else {
            throw CoreFailure("Invalid AI segment text")
        }
        guard !options.summarize || !notes.isEmpty else { throw CoreFailure("AI returned no source-linked summary notes") }
        for note in notes {
            guard Set(note.object?.keys.map { $0 } ?? []) == ["text", "segment_ids"], validText(note["text"]),
                  let ids = note["segment_ids"].array, !ids.isEmpty, ids.allSatisfy({ $0.string != nil }),
                  Set(ids.compactMap(\.string)).count == ids.count,
                  Set(ids.compactMap(\.string)).isSubset(of: expected) else { throw CoreFailure("Summary contains invalid source references") }
        }
        return Dictionary(uniqueKeysWithValues: outputs.map { ($0["id"].string!, $0["text"]) })
    }
}
