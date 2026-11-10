import Foundation

/// Engine-independent lexical scores. They do not establish semantic, timing or speaker accuracy.
public enum TranscriptAccuracy {
    public enum Policy: String, CaseIterable, Sendable {
        case legacyV1 = "swift-nfc-casefold-alphanumeric-v1"
        case unicodeV2 = "unicode-nfc-apostrophe-v2"
        case chineseCERv2 = "unicode-nfc-cer-v2"
        case arabicStrictV2 = "arabic-nfc-strict-v2"
        case arabicNoDiacriticsV2 = "arabic-nfc-no-diacritics-v2"
    }

    public static func policy(for item: JSONValue, schemaVersion: String) throws -> Policy {
        if schemaVersion == "1.0" { return .legacyV1 }
        guard let name = item["scoring_policy"].string, let policy = Policy(rawValue: name) else {
            throw CoreFailure("Unknown or missing versioned corpus scoring policy")
        }
        return policy
    }

    static func normalized(_ text: String) -> String { normalized(text, policy: .legacyV1) }

    static func normalized(_ text: String, policy: Policy) -> String {
        let folded = text.precomposedStringWithCanonicalMapping.folding(
            options: .caseInsensitive, locale: Locale(identifier: "en_US_POSIX"))
        if policy == .legacyV1 {
            let scalars = folded.unicodeScalars.map {
                CharacterSet.alphanumerics.contains($0) || $0 == "_" ? $0 : " "
            }
            return String(String.UnicodeScalarView(scalars)).split(whereSeparator: \.isWhitespace).joined(separator: " ")
        }
        let scalars = Array(folded.unicodeScalars)
        var retained = String.UnicodeScalarView()
        for (index, scalar) in scalars.enumerated() {
            // This secondary Arabic policy removes only explicitly listed vocalization marks.
            // Alif/hamza/ya/ta marbuta and tatweel are deliberately not conflated.
            if policy == .arabicNoDiacriticsV2 && isArabicDiacritic(scalar) { continue }
            let apostrophe = scalar == "'" || scalar == "\u{2019}"
            let internalApostrophe = apostrophe && index > 0 && index + 1 < scalars.count
                && CharacterSet.letters.contains(scalars[index - 1]) && CharacterSet.letters.contains(scalars[index + 1])
            if internalApostrophe { retained.append("'") }
            else if CharacterSet.alphanumerics.contains(scalar) || CharacterSet.nonBaseCharacters.contains(scalar) || scalar == "_" {
                retained.append(scalar)
            } else if [0x200E, 0x200F, 0x061C, 0x202A, 0x202B, 0x202C, 0x202D, 0x202E, 0x2066, 0x2067, 0x2068, 0x2069].contains(scalar.value) {
                continue // Display-direction controls are not spoken characters.
            } else { retained.append(" ") }
        }
        return String(retained).precomposedStringWithCanonicalMapping.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    private static func isArabicDiacritic(_ scalar: Unicode.Scalar) -> Bool {
        CharacterSet.nonBaseCharacters.contains(scalar) && ((0x064B...0x065F).contains(scalar.value)
            || scalar.value == 0x0670 || (0x06D6...0x06ED).contains(scalar.value))
    }

    struct Edits: Sendable {
        var insertions = 0, deletions = 0, substitutions = 0
        var total: Int { insertions + deletions + substitutions }
    }

    /// Linear-space alignment. Ties prefer substitution, then deletion, then insertion.
    static func edits<T: Equatable>(_ reference: [T], _ hypothesis: [T]) -> Edits {
        edits(reference, hypothesis, check: {})
    }

    private static func edits<T: Equatable>(_ reference: [T], _ hypothesis: [T], check: () throws -> Void) rethrows -> Edits {
        try check()
        var previous = (0...hypothesis.count).map { Edits(insertions: $0) }
        for (index, token) in reference.enumerated() {
            try check()
            var current = [Edits(deletions: index + 1)]
            current.reserveCapacity(hypothesis.count + 1)
            for (otherIndex, other) in hypothesis.enumerated() {
                var substitution = previous[otherIndex]
                substitution.substitutions += token == other ? 0 : 1
                var deletion = previous[otherIndex + 1]; deletion.deletions += 1
                var insertion = current[otherIndex]; insertion.insertions += 1
                var best = substitution
                if deletion.total < best.total { best = deletion }
                if insertion.total < best.total { best = insertion }
                current.append(best)
            }
            previous = current
        }
        return previous.last!
    }

    static func distance<T: Equatable>(_ reference: [T], _ hypothesis: [T]) -> Int { edits(reference, hypothesis).total }

    public static let maximumAlignmentCells = 100_000_000
    public static let maximumScoringTextBytes = 1_048_576

    /// Compatibility API for existing callers. Benchmarks use checkedScore for cancellation and work bounds.
    public static func score(reference: String, hypothesis: String, policy: Policy = .legacyV1,
                             durationSeconds: Double? = nil) -> JSONValue {
        scoreImpl(reference: reference, hypothesis: hypothesis, policy: policy, durationSeconds: durationSeconds, check: {})
    }

    public static func checkedScore(reference: String, hypothesis: String, policy: Policy = .legacyV1,
                                    durationSeconds: Double? = nil,
                                    check: @Sendable () throws -> Void = { try Task.checkCancellation() }) throws -> JSONValue {
        try check()
        guard reference.utf8.count <= maximumScoringTextBytes, hypothesis.utf8.count <= maximumScoringTextBytes else {
            throw CoreFailure("Scoring text exceeds the 1 MiB per-text bound; retain evidence and report scoring pending")
        }
        let ref = normalized(reference, policy: policy), hyp = normalized(hypothesis, policy: policy)
        let wordCells = ref.split(separator: " ").count * hyp.split(separator: " ").count
        let characterCells = ref.unicodeScalars.filter { $0 != " " }.count * hyp.unicodeScalars.filter { $0 != " " }.count
        guard wordCells + characterCells <= maximumAlignmentCells else {
            throw CoreFailure("Scoring exceeds 100 million alignment cells; retain evidence and report scoring pending")
        }
        return try scoreImpl(reference: reference, hypothesis: hypothesis, policy: policy, durationSeconds: durationSeconds, check: check)
    }

    private static func scoreImpl(reference: String, hypothesis: String, policy: Policy,
                                  durationSeconds: Double?, check: () throws -> Void) rethrows -> JSONValue {
        try check()
        let ref = normalized(reference, policy: policy), hyp = normalized(hypothesis, policy: policy)
        let words = Array(ref.split(separator: " ")), hypothesisWords = Array(hyp.split(separator: " "))
        let chars = Array(ref.unicodeScalars.filter { $0 != " " }), hypothesisChars = Array(hyp.unicodeScalars.filter { $0 != " " })
        let wordEdits = try edits(words, hypothesisWords, check: check)
        let characterEdits = try edits(chars, hypothesisChars, check: check)
        let hasWER = policy != .chineseCERv2
        let noReference = chars.isEmpty
        let perMinute = durationSeconds.flatMap { $0.isFinite && $0 > 0 ? 60 / $0 : nil }
        return [
            "wer": hasWER && !words.isEmpty ? .number(Double(wordEdits.total) / Double(words.count)) : nil,
            "cer": chars.isEmpty ? nil : .number(Double(characterEdits.total) / Double(chars.count)),
            "word_errors": hasWER ? .integer(Int64(wordEdits.total)) : nil,
            "word_insertions": hasWER ? .integer(Int64(wordEdits.insertions)) : nil,
            "word_deletions": hasWER ? .integer(Int64(wordEdits.deletions)) : nil,
            "word_substitutions": hasWER ? .integer(Int64(wordEdits.substitutions)) : nil,
            "reference_words": hasWER ? .integer(Int64(words.count)) : nil,
            "character_errors": .integer(Int64(characterEdits.total)),
            "character_insertions": .integer(Int64(characterEdits.insertions)),
            "character_deletions": .integer(Int64(characterEdits.deletions)),
            "character_substitutions": .integer(Int64(characterEdits.substitutions)),
            "reference_characters": .integer(Int64(chars.count)),
            "false_speech_words": noReference && hasWER ? .integer(Int64(hypothesisWords.count)) : nil,
            "false_speech_characters": noReference ? .integer(Int64(hypothesisChars.count)) : nil,
            "false_speech_words_per_minute": noReference && hasWER ? perMinute.map { .number(Double(hypothesisWords.count) * $0) } ?? .null : nil,
            "false_speech_characters_per_minute": noReference ? perMinute.map { .number(Double(hypothesisChars.count) * $0) } ?? .null : nil,
            "scoring_version": .string(policy.rawValue),
            "word_segmentation": hasWER ? "whitespace-v1" : "unmeasured; no Chinese word segmenter",
            "character_unit": "Unicode scalar after normalization; spaces omitted",
            "normalization": .string(policy == .legacyV1
                ? "swift-nfc-casefold-alphanumeric-v1; punctuation to spaces, collapsed whitespace; CER omits spaces"
                : policy.rawValue),
            "semantic_accuracy": nil, "timestamp_accuracy": nil, "speaker_accuracy": nil, "dialect_identification_accuracy": nil
        ]
    }

    /// Never pool different output tasks, scoring versions or experiment configurations.
    /// Rows without scores stay in the denominator of readiness, not accuracy.
    public static func aggregate(_ rows: [JSONValue]) -> JSONValue {
        func key(_ row: JSONValue, condition: String?) -> String {
            [row["language"].string ?? "unknown", row["task"].string ?? "transcription",
             row["scoring_version"].string ?? "unscored", row["configuration_id"].string ?? "control",
             condition ?? "all"].joined(separator: "|")
        }
        var groups: [String: [JSONValue]] = [:]
        for row in rows {
            groups[key(row, condition: nil), default: []].append(row)
            for condition in Set((row["conditions"].array ?? []).compactMap(\.string)).sorted() {
                groups[key(row, condition: condition), default: []].append(row)
            }
        }
        let summaries: [JSONValue] = groups.keys.sorted().map { group in
            let values = groups[group]!
            var summary: JSONValue = ["group": .string(group), "cases": .integer(Int64(values.count)),
                "scored_cases": .integer(Int64(values.filter { $0["cer"].double != nil || $0["false_speech_characters"].integer != nil }.count))]
            for metric in ["word", "character"] {
                let rate = metric == "word" ? "wer" : "cer"
                let eligible = values.filter { $0[rate].double != nil }
                let errors = eligible.reduce(Int64.zero) { $0 + ($1["\(metric)_errors"].integer ?? 0) }
                let denominator = eligible.reduce(Int64.zero) { $0 + ($1["reference_\(metric)s"].integer ?? 0) }
                summary["\(rate)_scored_cases"] = .integer(Int64(eligible.count))
                summary["\(metric)_errors"] = .integer(errors)
                summary["reference_\(metric)s"] = .integer(denominator)
                summary["macro_\(rate)"] = eligible.isEmpty ? nil : .number(eligible.compactMap { $0[rate].double }.sorted().reduce(0, +) / Double(eligible.count))
                summary["corpus_weighted_\(rate)"] = denominator > 0 ? .number(Double(errors) / Double(denominator)) : nil
                for operation in ["insertions", "deletions", "substitutions"] {
                    summary["\(metric)_\(operation)"] = .integer(eligible.reduce(0) { $0 + ($1["\(metric)_\(operation)"].integer ?? 0) })
                }
            }
            summary["false_speech_characters"] = .integer(values.reduce(0) { $0 + ($1["false_speech_characters"].integer ?? 0) })
            summary["false_speech_cases"] = .integer(Int64(values.filter { $0["false_speech_characters"].integer != nil }.count))
            summary["interpretation"] = "exploratory lexical metrics; review coverage and critical content separately"
            return summary
        }
        return .array(summaries)
    }
}
