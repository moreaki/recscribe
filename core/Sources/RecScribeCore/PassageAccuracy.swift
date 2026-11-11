import Foundation

/// Offline research only. A learned word/character quality estimate is not a
/// probability of an error-free passage, and is never canonical model confidence.
public enum PassageAccuracy {
    public static let featureVersion = "whisper-lexical-quality-v1"
    public static let maximumRows = 2_000
    public enum Split: String, Codable, Sendable { case training, calibration, evaluation }
    public enum Unit: String, Codable, Sendable { case utterance, studioSegment }
    public struct Scope: Codable, Equatable, Sendable {
        public let modelSHA256: String
        public let runtimeSHA256: String
        public let decodingSHA256: String
        public let language: String
        public let scoringPolicy: String
        public let unit: Unit
        public let referenceTask: String
    }
    public struct Row: Codable, Sendable {
        public let id: String
        public let split: Split
        public let recordingID: String
        public let sessionID: String
        public let channel: Int
        public let speakerIDs: [String]
        /// Include every ancestor of a derived mixture; these are split groups.
        public let sourceIDs: [String]
        public let audioSHA256: String
        public let referenceSHA256: String
        public let lexicalReviewEvidence: String
        public let permissionEvidence: String
        public let alignmentReviewed: Bool
        public let reference: String
        /// Exactly one original whisper.cpp JSON transcription entry, never a rewrite.
        public let recognition: JSONValue
    }
    public struct Dataset: Codable, Sendable {
        public let version: Int
        public let scope: Scope
        public let rows: [Row]
    }
    public struct Metrics: Codable, Sendable {
        public struct Bin: Codable, Sendable {
            public let count: Int
            public let predictedMean: Double?
            public let observedMean: Double?
        }
        public let count: Int
        public let recordingGroups: Int
        public let meanAbsoluteError: Double
        public let calibrationError: Double
        public let bins: [Bin]

        func validate() throws {
            guard (1...PassageAccuracy.maximumRows).contains(count), (1...count).contains(recordingGroups),
                  meanAbsoluteError.isFinite, (0...1).contains(meanAbsoluteError),
                  calibrationError.isFinite, (0...1).contains(calibrationError), bins.count == 10,
                  bins.enumerated().allSatisfy({ index, bin in
                      guard (0...count).contains(bin.count) else { return false }
                      if bin.count == 0 { return bin.predictedMean == nil && bin.observedMean == nil }
                      guard let p = bin.predictedMean, let y = bin.observedMean else { return false }
                      return p.isFinite && y.isFinite && (0...1).contains(p) && (0...1).contains(y)
                          && p >= Double(index) / 10 - 1e-10 && p <= Double(index + 1) / 10 + 1e-10
                  }), bins.map(\.count).reduce(0, +) == count else {
                throw CoreFailure("Invalid accuracy evaluation evidence")
            }
            let error = bins.reduce(0.0) { $0 + Double($1.count) * abs(($1.predictedMean ?? 0) - ($1.observedMean ?? 0)) } / Double(count)
            guard abs(error - calibrationError) < 1e-10, calibrationError <= meanAbsoluteError + 1e-10 else {
                throw CoreFailure("Contradictory accuracy evaluation evidence")
            }
        }
    }
    public struct Artifact: Codable, Sendable {
        public let version: Int
        public let purpose: String
        public let featureVersion: String
        public let scope: Scope
        public let datasetSHA256: String
        public let linear: AccuracyCalibrationMath.LinearModel
        public let isotonic: AccuracyCalibrationMath.IsotonicMap
        public let evaluation: Metrics
        public var metric: String { scope.scoringPolicy == TranscriptAccuracy.Policy.chineseCERv2.rawValue ? "bounded character accuracy" : "bounded word accuracy" }

        /// No production artifact is issued by this first implementation. Bootstrap
        /// uncertainty, independent reviewed evaluation and risk-slice gates are pending.
        public var studioPercentage: Int? { nil }
        public var availabilityReason: String { "Research only; independently reviewed Studio calibration and release validation are pending" }

        public func researchPercentage(for recognition: JSONValue, expectedScope: Scope) throws -> Int {
            guard version == 1, purpose == "research_only", featureVersion == PassageAccuracy.featureVersion,
                  scope == expectedScope, PassageAccuracy.valid(scope),
                  PassageAccuracy.hash(datasetSHA256) else {
                throw CoreFailure("Accuracy artifact does not match this model/runtime/decoding/language/unit")
            }
            try evaluation.validate()
            let score = try linear.predict(PassageAccuracy.features(recognition))
            return Int((try isotonic.predict(score) * 100).rounded())
        }
    }

    static func hash(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
    static func valid(_ scope: Scope) -> Bool {
        hash(scope.modelSHA256) && hash(scope.runtimeSHA256) && hash(scope.decodingSHA256)
            && !scope.language.isEmpty && scope.language != "auto" && scope.language.utf8.count <= 64
            && ["verbatim", "standard_rendering"].contains(scope.referenceTask)
            && TranscriptAccuracy.Policy(rawValue: scope.scoringPolicy) != nil
    }

    /// Versioned features use only original hypothesis/token evidence, never the
    /// reference. Missing probabilities have an explicit indicator, not fake scores.
    public static func features(_ entry: JSONValue) throws -> [Double] {
        guard let text = entry["text"].string, text.utf8.count <= 65_536,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let start = entry["offsets"]["from"].integer, let end = entry["offsets"]["to"].integer,
              start >= 0, end > start, end - start <= 120_000 else {
            throw CoreFailure("Accuracy features require one original timed speech passage of at most two minutes")
        }
        let words = text.lowercased().split(whereSeparator: \.isWhitespace)
        var probabilities: [Double] = []
        var missing = false
        if let tokens = entry["tokens"].array {
            guard tokens.count <= 4_096 else { throw CoreFailure("Accuracy token count exceeds its bound") }
            for token in tokens {
                guard let tokenText = token["text"].string else { throw CoreFailure("Invalid original token evidence") }
                // whisper.cpp special/timestamp tokens are not lexical words.
                if tokenText.hasPrefix("[_") || tokenText.hasPrefix("<|") { continue }
                if tokenText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { continue }
                if token["p"] == .null { missing = true; continue }
                guard let p = token["p"].double, p.isFinite, (0...1).contains(p) else {
                    throw CoreFailure("Invalid original token probability")
                }
                probabilities.append(log(max(p, 1e-12)))
            }
        } else if entry["tokens"] != .null { throw CoreFailure("Invalid token list") }
        else { missing = true }
        // Partial token coverage is treated as unavailable as a whole.
        let logs = missing ? [] : probabilities.sorted()
        let mean = logs.isEmpty ? 0 : logs.reduce(0, +) / Double(logs.count)
        let low = logs.isEmpty ? 0 : logs[Int(Double(logs.count - 1) * 0.1)]
        let repeatRatio = words.isEmpty ? 0 : 1 - Double(Set(words).count) / Double(words.count)
        return [mean, low, log1p(Double(words.count)), log1p(Double(end - start) / 1_000),
                repeatRatio, logs.isEmpty ? 1 : 0]
    }

    /// Explicit whole-utterance adapter for reusable benchmark references. The
    /// resulting target must never be assigned to each individual ASR segment.
    public static func utterance(from raw: JSONValue, durationMs: Int64) throws -> JSONValue {
        guard (1...120_000).contains(durationMs), let entries = raw["transcription"].array,
              (1...512).contains(entries.count) else { throw CoreFailure("Unsupported benchmark utterance") }
        var previous: Int64 = 0, texts: [String] = [], tokens: [JSONValue] = []
        var missing = false
        for entry in entries {
            guard let start = entry["offsets"]["from"].integer, let end = entry["offsets"]["to"].integer,
                  start >= previous, end > start, end <= durationMs, let text = entry["text"].string else {
                throw CoreFailure("Benchmark segment timing does not fit the reference utterance")
            }
            previous = end; texts.append(text)
            if let values = entry["tokens"].array {
                guard values.count <= 4_096 - tokens.count else { throw CoreFailure("Too many benchmark tokens") }
                tokens += values
            }
            else if entry["tokens"] == .null { missing = true }
            else { throw CoreFailure("Invalid benchmark token evidence") }
            guard tokens.count <= 4_096, texts.reduce(0, { $0 + $1.utf8.count }) <= 65_536 else {
                throw CoreFailure("Benchmark utterance exceeds feature bounds")
            }
        }
        let entry: JSONValue = ["text": .string(texts.joined(separator: " ")),
            "offsets": ["from": 0, "to": .integer(durationMs)], "tokens": missing ? .null : .array(tokens)]
        _ = try features(entry)
        return entry
    }

    /// Admission rejects leakage and missing lexical review before any fitting.
    /// Whole-clip text may be used only for an utterance artifact; a future Studio
    /// artifact needs independently aligned references at Studio segment boundaries.
    public static func fit(_ dataset: Dataset,
                           check: @escaping @Sendable () throws -> Void = { try Task.checkCancellation() }) throws -> Artifact {
        let deadline = ContinuousClock.now.advanced(by: .seconds(30))
        let checkpoint: @Sendable () throws -> Void = {
            try check()
            guard ContinuousClock.now < deadline else { throw CoreFailure("Accuracy fitting exceeded its cooperative deadline") }
        }
        try checkpoint()
        guard dataset.version == 1, valid(dataset.scope), (3...maximumRows).contains(dataset.rows.count),
              let policy = TranscriptAccuracy.Policy(rawValue: dataset.scope.scoringPolicy) else {
            throw CoreFailure("Unsupported accuracy dataset/scope or row count")
        }
        var seen: Set<String> = []
        var assignments: [String: Split] = [:]
        var values: [Split: [(Row, [Double], Double)]] = [:]
        for row in dataset.rows {
            try checkpoint()
            guard !row.id.isEmpty, row.id.utf8.count <= 1_024, seen.insert(row.id).inserted,
                  !row.recordingID.isEmpty, row.recordingID.utf8.count <= 1_024,
                  !row.sessionID.isEmpty, row.sessionID.utf8.count <= 1_024, (0..<32).contains(row.channel),
                  (1...64).contains(row.speakerIDs.count), (1...64).contains(row.sourceIDs.count),
                  (row.speakerIDs + row.sourceIDs).allSatisfy({ !$0.isEmpty && $0.utf8.count <= 1_024 }),
                  hash(row.audioSHA256), hash(row.referenceSHA256),
                  row.reference.utf8.count <= 65_536,
                  TextJob.hash(Data(row.reference.utf8)) == row.referenceSHA256,
                  !row.lexicalReviewEvidence.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  row.lexicalReviewEvidence.utf8.count <= 2_048,
                  !row.permissionEvidence.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  row.permissionEvidence.utf8.count <= 2_048, row.alignmentReviewed else {
                throw CoreFailure("Accuracy row requires frozen hashes, permission, reviewed lexical alignment and known split groups")
            }
            let groups = ["recording:" + row.recordingID, "session:" + row.sessionID, "audio:" + row.audioSHA256,
                          "reference:" + row.referenceSHA256]
                + row.speakerIDs.map { "speaker:" + $0 } + row.sourceIDs.map { "source:" + $0 }
            for group in groups {
                if let existing = assignments[group], existing != row.split {
                    throw CoreFailure("Accuracy training/calibration/evaluation groups overlap")
                }
                assignments[group] = row.split
            }
            let feature = try features(row.recognition)
            let score = try TranscriptAccuracy.checkedScore(reference: row.reference,
                hypothesis: row.recognition["text"].string!, policy: policy, check: checkpoint)
            let field = policy == .chineseCERv2 ? "cer" : "wer"
            guard let error = score[field].double, error.isFinite, error >= 0 else {
                throw CoreFailure("Empty speech references have no word/character accuracy; evaluate hallucinations separately")
            }
            values[row.split, default: []].append((row, feature, max(0, 1 - error)))
        }
        guard let training = values[.training], let calibration = values[.calibration],
              let evaluation = values[.evaluation] else { throw CoreFailure("Accuracy fitting requires three disjoint partitions") }
        let linear = try AccuracyCalibrationMath.fitLinear(features: training.map { $0.1 }, targets: training.map { $0.2 }, check: checkpoint)
        let isotonic = try AccuracyCalibrationMath.fitIsotonic(scores: calibration.map { try linear.predict($0.1) },
            targets: calibration.map { $0.2 }, check: checkpoint)
        let predictions = try evaluation.map { try isotonic.predict(linear.predict($0.1)) }
        let metrics = metrics(predictions: predictions, targets: evaluation.map { $0.2 },
            recordingGroups: Set(evaluation.map { $0.0.recordingID }).count)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return Artifact(version: 1, purpose: "research_only", featureVersion: featureVersion, scope: dataset.scope,
            datasetSHA256: TextJob.hash(try encoder.encode(dataset)), linear: linear, isotonic: isotonic, evaluation: metrics)
    }

    private static func metrics(predictions: [Double], targets: [Double], recordingGroups: Int) -> Metrics {
        var sums = Array(repeating: (count: 0, predicted: 0.0, observed: 0.0), count: 10)
        var absolute = 0.0
        for (p, y) in zip(predictions, targets) {
            absolute += abs(p - y)
            let index = min(9, Int(p * 10)); sums[index].count += 1
            sums[index].predicted += p; sums[index].observed += y
        }
        let bins = sums.map { value in Metrics.Bin(count: value.count,
            predictedMean: value.count == 0 ? nil : value.predicted / Double(value.count),
            observedMean: value.count == 0 ? nil : value.observed / Double(value.count)) }
        let calibration = sums.reduce(0.0) { $0 + abs($1.predicted - $1.observed) } / Double(predictions.count)
        return Metrics(count: predictions.count, recordingGroups: recordingGroups,
            meanAbsoluteError: absolute / Double(predictions.count), calibrationError: calibration, bins: bins)
    }
}
