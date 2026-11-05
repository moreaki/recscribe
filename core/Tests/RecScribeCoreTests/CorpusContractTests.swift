import Foundation
import Testing
@testable import RecScribeCore

@Suite struct CorpusContractTests {
    private func item(id: String = "speech", split: String = "development") -> JSONValue {
        ["id": .string(id), "category": "short_form", "language": "fr", "variety": "French; France", "script": "Latn",
         "task": "transcription", "split": .string(split), "duration_seconds": 10, "conditions": ["short_form", "quiet_speech"],
         "domain": "consented conversation", "speaker_ids": ["speaker-1"], "session_id": "session-1", "source_id": "recording-1",
         "source_channel": 0, "code_switches": [], "audio": nil, "reference": nil, "sha256": nil, "reference_sha256": nil,
         "license": "explicit evaluation consent", "source_url": "consent:local-record-1", "reference_conventions": "human verbatim v1",
         "reviewed": true, "scoring_policy": "unicode-nfc-apostrophe-v2"]
    }
    private func document(_ items: [JSONValue]) -> JSONValue {
        ["schema_version": "2.0", "corpus_version": "test-v1", "frozen": true, "cases": .array(items)]
    }

    @Test func unicodePoliciesPreserveMeaningfulDistinctions() {
        #expect(TranscriptAccuracy.score(reference: "l’été d'aujourd'hui", hypothesis: "L'E\u{0301}TE\u{0301} d’aujourd’hui", policy: .unicodeV2)["wer"].double == 0)
        #expect(TranscriptAccuracy.score(reference: "café", hypothesis: "cafe", policy: .unicodeV2)["character_substitutions"] == 1)
        #expect(TranscriptAccuracy.score(reference: "١٢", hypothesis: "12", policy: .unicodeV2)["character_errors"] == 2)
        #expect(TranscriptAccuracy.score(reference: "سلام", hypothesis: "\u{200F}سلام\u{200E}", policy: .arabicStrictV2)["cer"].double == 0)
        let strict = TranscriptAccuracy.score(reference: "حَسَن", hypothesis: "حسن", policy: .arabicStrictV2)
        let relaxed = TranscriptAccuracy.score(reference: "حَسَن", hypothesis: "حسن", policy: .arabicNoDiacriticsV2)
        #expect(strict["character_deletions"] == 2 && relaxed["cer"].double == 0)
        #expect(TranscriptAccuracy.score(reference: "أمل", hypothesis: "امل", policy: .arabicNoDiacriticsV2)["cer"].double! > 0)
    }

    @Test func chineseHasCharacterCountsWithoutInventedWords() {
        let chinese = TranscriptAccuracy.score(reference: "中文", hypothesis: "中，文字", policy: .chineseCERv2)
        #expect(chinese["wer"] == .null && chinese["reference_words"] == .null)
        #expect(chinese["character_insertions"] == 1 && chinese["reference_characters"] == 2 && chinese["cer"].double == 0.5)
        #expect(TranscriptAccuracy.score(reference: "汉语", hypothesis: "漢語", policy: .chineseCERv2)["character_errors"] == 2)
        let noise = TranscriptAccuracy.score(reference: "", hypothesis: "你好", policy: .chineseCERv2, durationSeconds: 30)
        #expect(noise["wer"] == .null && noise["cer"] == .null && noise["false_speech_words"] == .null)
        #expect(noise["false_speech_characters"] == 2 && noise["false_speech_characters_per_minute"].double == 4)
        #expect(TranscriptAccuracy.score(reference: "", hypothesis: "two words", policy: .unicodeV2)["false_speech_words_per_minute"] == .null)
    }

    @Test func editOperationsAndAggregationAreDeterministicAndTaskSeparated() {
        let substitutions = TranscriptAccuracy.score(reference: "a b c", hypothesis: "a d c extra", policy: .unicodeV2)
        #expect(substitutions["word_substitutions"] == 1 && substitutions["word_insertions"] == 1)
        #expect(substitutions["word_deletions"] == 0 && substitutions["word_errors"] == 2)
        var one = TranscriptAccuracy.score(reference: "a b", hypothesis: "a", policy: .unicodeV2)
        one["language"] = "fr"; one["task"] = "transcription"; one["conditions"] = ["quiet_speech"]
        var two = TranscriptAccuracy.score(reference: "a", hypothesis: "b", policy: .unicodeV2)
        two["language"] = "fr"; two["task"] = "transcription"
        var rendering = one; rendering["task"] = "standard_rendering"
        let pending: JSONValue = ["language": "ar", "task": "transcription", "status": "pending_corpus"]
        let rows = [one, two, rendering, pending]
        #expect(TranscriptAccuracy.aggregate(rows) == TranscriptAccuracy.aggregate(Array(rows.reversed())))
        let group = TranscriptAccuracy.aggregate(rows).array!.first { $0["group"].string == "fr|transcription|unicode-nfc-apostrophe-v2|control|all" }!
        #expect(group["macro_wer"].double == 0.75)
        #expect(group["corpus_weighted_wer"].double == 2.0 / 3.0 && group["reference_words"] == 3)
        let unscored = TranscriptAccuracy.aggregate([pending]).array!.first!
        #expect(unscored["macro_wer"] == .null && unscored["corpus_weighted_cer"] == .null && unscored["scored_cases"] == 0)
    }

    @Test func benchmarkScoringIsBoundedAndCancellable() throws {
        #expect(try TranscriptAccuracy.checkedScore(reference: "a b", hypothesis: "a c", policy: .unicodeV2)
            == TranscriptAccuracy.score(reference: "a b", hypothesis: "a c", policy: .unicodeV2))
        #expect(throws: CancellationError.self) {
            try TranscriptAccuracy.checkedScore(reference: "a", hypothesis: "b", check: { throw CancellationError() })
        }
        #expect(throws: CoreFailure.self) {
            try TranscriptAccuracy.checkedScore(reference: String(repeating: "a", count: 10_001), hypothesis: String(repeating: "b", count: 10_001))
        }
        #expect(throws: CoreFailure.self) {
            try TranscriptAccuracy.checkedScore(reference: String(repeating: "a", count: TranscriptAccuracy.maximumScoringTextBytes + 1), hypothesis: "")
        }
    }

    @Test func manifestRequiresExplicitTasksPoliciesAndSafeMetadata() throws {
        #expect(try CorpusManifest.validate(document([item()])).count == 1)
        for field in ["script", "reference_sha256", "source_channel", "reviewed"] {
            var missing = item(); var fields = missing.object!; fields.removeValue(forKey: field); missing = .object(fields)
            #expect(throws: CoreFailure.self) { try CorpusManifest.validate(document([missing])) }
        }
        let invalidValues: [(String, JSONValue)] = [("id", "../escape"), ("duration_seconds", -1), ("sha256", "bad"), ("scoring_policy", "unknown"), ("source_channel", -1)]
        for (field, invalid) in invalidValues {
            var bad = item(); bad[field] = invalid
            #expect(throws: CoreFailure.self) { try CorpusManifest.validate(document([bad])) }
        }
        var swiss = item(); swiss["language"] = "de-CH"
        #expect(throws: CoreFailure.self) { try CorpusManifest.validate(document([swiss])) }
        swiss["task"] = "dialect_transcription"
        #expect(try CorpusManifest.validate(document([swiss])).count == 1)
        var extensionCase = item(); extensionCase["language"] = "ja"; extensionCase["scoring_policy"] = "unicode-nfc-cer-v2"
        #expect(try CorpusManifest.validate(document([extensionCase])).count == 1)
        #expect(try TranscriptAccuracy.policy(for: swiss, schemaVersion: "1.0") == .legacyV1)
    }

    @Test func heldOutSplitRejectsSpeakerSessionSourceAndAudioLeakage() throws {
        let development = item()
        for field in ["speaker_ids", "session_id", "source_id", "sha256"] {
            var held = item(id: "held", split: "held_out")
            held["speaker_ids"] = ["speaker-2"]; held["session_id"] = "session-2"; held["source_id"] = "recording-2"
            var dev = development
            if field == "sha256" { dev[field] = .string(String(repeating: "a", count: 64)); held[field] = dev[field] }
            else { held[field] = dev[field] }
            #expect(throws: CoreFailure.self) { try CorpusManifest.validate(document([dev, held])) }
        }
        var held = item(id: "held", split: "held_out")
        held["speaker_ids"] = ["speaker-2"]; held["session_id"] = "session-2"; held["source_id"] = "recording-2"
        #expect(try CorpusManifest.validate(document([development, held])).count == 2)
    }

    @Test func readinessChecksBothOriginalHashesAndHumanReviewWithoutMutations() throws {
        let root = try AudioFixture.folder(); defer { try? FileManager.default.removeItem(at: root) }
        let audio = root.appendingPathComponent("source.wav"), reference = root.appendingPathComponent("reference.txt")
        try AudioFixture.wav(audio)
        try Data("bonjour".utf8).write(to: reference)
        let audioHash = try WAVAudio.hash(audio), referenceHash = try WAVAudio.hash(reference)
        let manifest = root.appendingPathComponent("manifest.json")
        var entry = item()
        entry["audio"] = "source.wav"; entry["reference"] = "reference.txt"; entry["duration_seconds"] = 1
        entry["sha256"] = .string(audioHash); entry["reference_sha256"] = .string(referenceHash)
        let ready = try CorpusManifest.eligibility(entry, manifest: manifest, schemaVersion: "2.0")
        #expect(ready.status == "ready" && ready.referenceSHA256 == referenceHash && ready.audio == audio)
        entry["duration_seconds"] = 2
        #expect(throws: CoreFailure.self) { try CorpusManifest.eligibility(entry, manifest: manifest, schemaVersion: "2.0") }
        entry["duration_seconds"] = 1; entry["source_channel"] = 1
        #expect(throws: CoreFailure.self) { try CorpusManifest.eligibility(entry, manifest: manifest, schemaVersion: "2.0") }
        entry["source_channel"] = "mix"
        #expect(try CorpusManifest.eligibility(entry, manifest: manifest, schemaVersion: "2.0").status == "unsupported")
        entry["source_channel"] = 0; entry["reviewed"] = false
        #expect(try CorpusManifest.eligibility(entry, manifest: manifest, schemaVersion: "2.0").status == "pending_corpus")
        entry["reference_sha256"] = .string(String(repeating: "a", count: 64))
        #expect(throws: CoreFailure.self) { try CorpusManifest.eligibility(entry, manifest: manifest, schemaVersion: "2.0") }
        entry["reference_sha256"] = .string(referenceHash); entry["sha256"] = .string(String(repeating: "a", count: 64))
        #expect(throws: CoreFailure.self) { try CorpusManifest.eligibility(entry, manifest: manifest, schemaVersion: "2.0") }
        #expect(try WAVAudio.hash(audio) == audioHash && WAVAudio.hash(reference) == referenceHash)
        #expect(throws: CancellationError.self) {
            try CorpusManifest.eligibility(entry, manifest: manifest, schemaVersion: "2.0", check: { throw CancellationError() })
        }
    }
}
