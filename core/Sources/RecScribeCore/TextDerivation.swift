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
struct TextDerivation: Sendable {
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
        let batches = try batches(for: original)
        let concurrency = options.provider == .openai ? client.policy.maximumConcurrentCloudBatches : 1
        guard concurrency > 0 else { throw CoreFailure("Invalid AI concurrency policy") }
        let plan: JSONValue = [
            "schema_version": "1.0", "batch_count": .integer(Int64(batches.count)),
            "maximum_concurrency": .integer(Int64(concurrency)),
            "maximum_prompt_bytes": .integer(Int64(client.policy.maximumBatchPromptBytes)),
            "estimated_output_bytes_per_token": .integer(Int64(client.policy.estimatedOutputBytesPerToken)),
            "output_expansion_factor": .integer(Int64(client.policy.outputExpansionFactor)),
            "summary_reserve_tokens": .integer(Int64(options.summarize ? client.policy.summaryOutputReserveTokens : 0)),
            "segment_counts": .array(batches.map { .integer(Int64($0.count)) })
        ]
        try TextJob.write(plan.encoded(), named: "ai-batch-plan.json", in: directory)
        try progress(0, batches.count)
        // Only the parent task publishes progress. Workers own distinct artifact names;
        // results are merged in source order, never in network-completion order.
        let results = try await withThrowingTaskGroup(of: BatchResult.self) { group in
            var next = 0, results: [BatchResult] = []
            func enqueue(_ index: Int) {
                group.addTask {
                    try await generate(index: index, indices: batches[index], original: original,
                                       directory: directory, key: key, metadata: metadata, processor: processor)
                }
            }
            while next < min(concurrency, batches.count) { enqueue(next); next += 1 }
            while let result = try await group.next() {
                try Task.checkCancellation()
                results.append(result)
                try progress(results.count, batches.count)
                if next < batches.count { enqueue(next); next += 1 }
            }
            return results.sorted { $0.index < $1.index }
        }
        for batch in results {
            try Task.checkCancellation()
            let indices = batches[batch.index], evidence = batch.evidence
            if let field {
                for i in indices {
                    segments[i]["normalized_text"] = .null
                    segments[i]["translated_text"] = .null
                    segments[i][field] = batch.outputs[segments[i]["id"].string ?? ""] ?? .null
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
                for var note in batch.notes { note["provenance"] = evidence; notes.append(note) }
            }
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

    private struct BatchResult: Sendable {
        let index: Int
        let outputs: [String: JSONValue]
        let notes: [JSONValue]
        let evidence: JSONValue
    }

    private func generate(index: Int, indices: [Int], original: JSONValue, directory: URL,
                          key: Data?, metadata: Data, processor: String) async throws -> BatchResult {
        try Task.checkCancellation()
        let segments = original["segments"].array ?? []
        let encoded = try prompt(for: indices.map { segments[$0] }, original: original).encoded()
        let suffix = String(format: "%04d", index)
        try TextJob.write(encoded, named: "ai-input-\(suffix).json", in: directory)
        let started = ContinuousClock.now
        let raw = try await client.generate(provider: options.provider, model: options.model,
            prompt: String(decoding: encoded, as: UTF8.self), key: key, cloudConsent: options.cloudConsent)
        let rawData = try raw.encoded(), rawName = "ai-raw-\(suffix).json"
        try TextJob.write(rawData, named: rawName, in: directory)
        try Task.checkCancellation()
        let text = try IntelligenceClient.resultText(raw, provider: options.provider)
        guard let result = try? JSONDecoder().decode(JSONValue.self, from: Data(text.utf8)) else { throw CoreFailure("AI returned invalid JSON") }
        let outputs = try validate(result, expected: Set(indices.compactMap { segments[$0]["id"].string }))
        let evidence: JSONValue = [
            "processor": .string(processor), "source_sha256": .string(TextJob.hash(encoded)),
            "raw_path": .string(rawName), "raw_sha256": .string(TextJob.hash(rawData)),
            "duration_seconds": .number(TextJob.seconds(since: started)),
            "model_metadata_path": "ai-model.json", "model_metadata_sha256": .string(TextJob.hash(metadata)),
            "prompt_tokens": options.provider == .openai ? raw["usage"]["input_tokens"] : raw["prompt_eval_count"],
            "output_tokens": options.provider == .openai ? raw["usage"]["output_tokens"] : raw["eval_count"],
            "human_verified": false
        ]
        return BatchResult(index: index, outputs: outputs, notes: result["notes"].array ?? [], evidence: evidence)
    }

    private func prompt(for segments: [JSONValue], original: JSONValue) -> JSONValue {
        ["mode": .string(options.mode.rawValue), "source_language": original["processing"]["source_language"],
         "target_language": options.targetLanguage.map(JSONValue.string) ?? .null, "summarize": .bool(options.summarize),
         "untrusted_transcript": .array(segments.map {
             ["id": $0["id"], "text": $0["source_text"], "needs_review": $0["needs_review"]]
         })]
    }

    func batches(for original: JSONValue) throws -> [[Int]] {
        let policy = client.policy, segments = original["segments"].array ?? []
        let limit = options.provider == .openai ? policy.maximumBatchSegments : min(policy.maximumBatchSegments, policy.localMaximumBatchSegments)
        let outputTokens = options.provider == .openai ? policy.cloudOutputTokens : policy.localOutputTokens
        let reserve = options.summarize ? policy.summaryOutputReserveTokens : 0
        guard limit > 0, policy.maximumBatchScalars > 0, policy.maximumBatchPromptBytes > 0,
              policy.estimatedOutputBytesPerToken > 0, policy.outputExpansionFactor > 0,
              reserve >= 0, outputTokens > reserve else { throw CoreFailure("Invalid AI batch policy") }
        // Heuristic output headroom for translation expansion and source-linked notes.
        // Actual provider token limits and strict response validation remain authoritative.
        let outputBudget = Double(outputTokens - reserve) * Double(policy.estimatedOutputBytesPerToken)
        func fits(_ indices: [Int]) throws -> Bool {
            let entries = indices.map { segments[$0] }
            let encoded = try prompt(for: entries, original: original).encoded()
            let output: JSONValue = ["segments": .array(entries.map { ["id": $0["id"], "text": $0["source_text"]] }), "notes": []]
            let outputBytes = try output.encoded().count
            return encoded.count <= policy.maximumBatchPromptBytes
                && Double(outputBytes) * Double(policy.outputExpansionFactor) <= outputBudget
        }
        var batches: [[Int]] = [], current: [Int] = [], size = 0
        for index in segments.indices {
            let count = segments[index]["source_text"].string?.unicodeScalars.count ?? 0
            guard count <= client.policy.maximumBatchScalars else { throw CoreFailure("ASR segment exceeds the AI context budget") }
            if try !current.isEmpty && (size + count > policy.maximumBatchScalars || current.count >= limit || !fits(current + [index])) {
                batches.append(current); current = []; size = 0
            }
            if try current.isEmpty && !fits([index]) { throw CoreFailure("ASR segment exceeds the AI input/output budget") }
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
