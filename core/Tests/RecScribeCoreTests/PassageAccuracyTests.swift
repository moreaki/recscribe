import Foundation
import Darwin
import Testing
@testable import RecScribeCore
@testable import RecScribeTextCLI

@Suite struct PassageAccuracyTests {
    private func scope(_ unit: PassageAccuracy.Unit = .studioSegment) -> PassageAccuracy.Scope {
        .init(modelSHA256: String(repeating: "a", count: 64), runtimeSHA256: String(repeating: "b", count: 64),
            decodingSHA256: String(repeating: "c", count: 64), language: "en",
            scoringPolicy: TranscriptAccuracy.Policy.unicodeV2.rawValue, unit: unit, referenceTask: "verbatim")
    }
    private func entry(_ text: String, p: Double = 0.8) -> JSONValue {
        ["text": .string(text), "offsets": ["from": 0, "to": 5_000],
         "tokens": [["text": "[_SOT_]", "p": .number(1)], ["text": .string(text), "p": .number(p)]]]
    }
    private func dataset() -> PassageAccuracy.Dataset {
        var rows: [PassageAccuracy.Row] = []
        for split in [PassageAccuracy.Split.training, .calibration, .evaluation] {
            for quality in 0...1 {
                let id = "\(split.rawValue)-\(quality)"
                let reference = "\(id) good words"
                rows.append(.init(id: id, split: split, recordingID: id, sessionID: id, channel: 0, speakerIDs: [id], sourceIDs: [id],
                    audioSHA256: TextJob.hash(Data(id.utf8)), referenceSHA256: TextJob.hash(Data(reference.utf8)),
                    lexicalReviewEvidence: "synthetic unit-test reference only", permissionEvidence: "test generated text",
                    alignmentReviewed: true, reference: reference,
                    recognition: entry(quality == 1 ? reference : "\(id) wrong word", p: quality == 1 ? 0.95 : 0.3)))
            }
        }
        return .init(version: 1, scope: scope(), rows: rows)
    }
    private func changed(_ dataset: PassageAccuracy.Dataset, row index: Int,
                         _ key: String, _ value: JSONValue) throws -> PassageAccuracy.Dataset {
        var json = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(dataset))
        var rows = json["rows"].array!; rows[index][key] = value; json["rows"] = .array(rows)
        return try JSONDecoder().decode(PassageAccuracy.Dataset.self, from: json.encoded())
    }

    @Test func featuresExcludeSpecialTokensAndNeverInventMissingProbability() throws {
        let values = try PassageAccuracy.features(entry("good words", p: 0.5))
        #expect(values.count == 6 && abs(values[0] - log(0.5)) < 1e-10 && values[5] == 0)
        var partial = entry("speech")
        partial["tokens"] = [["text": "one", "p": .number(0.99)], ["text": "two"]]
        let missing = try PassageAccuracy.features(partial)
        #expect(missing[0] == 0 && missing[1] == 0 && missing[5] == 1)
        partial["tokens"] = [["text": "speech", "p": .number(1.1)]]
        #expect(throws: CoreFailure.self) { try PassageAccuracy.features(partial) }
        partial = entry("speech"); partial["offsets"] = ["from": -1, "to": 5000]
        #expect(throws: CoreFailure.self) { try PassageAccuracy.features(partial) }
    }

    @Test func benchmarkUtterancePoolsOriginalSegmentsWithoutInventingSegmentTargets() throws {
        var first = entry("first"); first["offsets"] = ["from": 0, "to": 2_000]
        var second = entry("second"); second["offsets"] = ["from": 2_000, "to": 4_000]
        let pooled = try PassageAccuracy.utterance(from: ["transcription": .array([first, second])], durationMs: 5_000)
        #expect(pooled["text"] == "first second" && pooled["offsets"]["to"] == 5_000)
        second["offsets"] = ["from": 1_000, "to": 4_000]
        #expect(throws: CoreFailure.self) { try PassageAccuracy.utterance(from: ["transcription": .array([first, second])], durationMs: 5_000) }
        first["tokens"] = .array(Array(repeating: ["text": "x", "p": .number(0.5)], count: 4_097))
        #expect(throws: CoreFailure.self) { try PassageAccuracy.utterance(from: ["transcription": .array([first])], durationMs: 5_000) }
    }

    @Test func fitRoundTripReportsHeldOutQualityWithoutPublishingAnAppPercentage() throws {
        let data = dataset(), artifact = try PassageAccuracy.fit(data)
        #expect(artifact.purpose == "research_only" && artifact.studioPercentage == nil && artifact.availabilityReason.contains("Research only"))
        #expect(artifact.evaluation.count == 2 && artifact.evaluation.recordingGroups == 2)
        #expect(artifact.evaluation.bins.map(\.count).reduce(0, +) == 2)
        #expect((0...1).contains(artifact.evaluation.meanAbsoluteError))
        #expect((0...1).contains(artifact.evaluation.calibrationError))
        let loaded = try JSONDecoder().decode(PassageAccuracy.Artifact.self, from: JSONEncoder().encode(artifact))
        let high = try loaded.researchPercentage(for: entry("new good words", p: 0.95), expectedScope: scope())
        let low = try loaded.researchPercentage(for: entry("bad wrong words", p: 0.3), expectedScope: scope())
        #expect(high >= low && (0...100).contains(high))
        #expect(throws: CoreFailure.self) { try loaded.researchPercentage(for: entry("hello"), expectedScope: scope(.utterance)) }
        var corrupt = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(artifact))
        corrupt["evaluation"]["count"] = 0
        let invalid = try JSONDecoder().decode(PassageAccuracy.Artifact.self, from: corrupt.encoded())
        #expect(throws: CoreFailure.self) { try invalid.researchPercentage(for: entry("hello"), expectedScope: scope()) }
        corrupt = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(artifact))
        corrupt["purpose"] = "qualified"
        let falselyQualified = try JSONDecoder().decode(PassageAccuracy.Artifact.self, from: corrupt.encoded())
        #expect(falselyQualified.studioPercentage == nil)
        #expect(throws: CoreFailure.self) { try falselyQualified.researchPercentage(for: entry("hello"), expectedScope: scope()) }
        let bins = (0..<10).map { index in PassageAccuracy.Metrics.Bin(count: index == 0 ? 1 : 0,
            predictedMean: index == 0 ? 0.95 : nil, observedMean: index == 0 ? 0.95 : nil) }
        let mislabelled = PassageAccuracy.Metrics(count: 1, recordingGroups: 1, meanAbsoluteError: 0, calibrationError: 0, bins: bins)
        #expect(throws: CoreFailure.self) { try mislabelled.validate() }
    }

    @Test(arguments: ["recordingID", "sessionID", "speakerIDs", "sourceIDs", "audioSHA256", "referenceSHA256"])
    func splitLeakageAndDerivedSourceReuseAreRejected(field: String) throws {
        let original = dataset()
        let json = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(original))
        let overlapping = try changed(original, row: 2, field, json["rows"].array![0][field])
        #expect(throws: CoreFailure.self) { try PassageAccuracy.fit(overlapping) }
    }

    @Test(arguments: ["lexicalReviewEvidence", "permissionEvidence", "speakerIDs", "sourceIDs", "alignmentReviewed"])
    func missingReviewPermissionAlignmentOrGroupsCannotFit(field: String) throws {
        let value: JSONValue = field == "alignmentReviewed" ? false : field.hasSuffix("IDs") ? [] : ""
        #expect(throws: CoreFailure.self) { try PassageAccuracy.fit(changed(dataset(), row: 0, field, value)) }
    }

    @Test func referenceChangeEmptyReferenceAndCancellationDoNotProduceAnArtifact() throws {
        #expect(throws: CoreFailure.self) { try PassageAccuracy.fit(changed(dataset(), row: 0, "reference", "changed")) }
        var empty = try changed(dataset(), row: 0, "reference", "")
        empty = try changed(empty, row: 0, "referenceSHA256", .string(TextJob.hash(Data())))
        #expect(throws: CoreFailure.self) { try PassageAccuracy.fit(empty) }
        #expect(throws: CancellationError.self) { try PassageAccuracy.fit(dataset(), check: { throw CancellationError() }) }
        #expect(throws: CoreFailure.self) { try PassageAccuracy.fit(changed(dataset(), row: 0, "audioSHA256", .string(String(repeating: "A", count: 64)))) }
        #expect(throws: CoreFailure.self) { try PassageAccuracy.fit(changed(dataset(), row: 0, "audioSHA256", .string(String(repeating: "ａ", count: 64)))) }
    }

    @Test func localCLIRejectsCloudOptionsAndPreservesInputsAndExistingOutput() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("accuracy-tests-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("dataset.json"), output = directory.appendingPathComponent("artifact.json")
        let original = try JSONEncoder().encode(dataset()); try original.write(to: source)
        let args = try RecScribeTextCLI.Arguments(["fit-accuracy", source.path, "--output", output.path])
        try await RecScribeTextCLI.run(args)
        let saved = try Data(contentsOf: output)
        do { try await RecScribeTextCLI.run(args); Issue.record("Existing calibration output was overwritten") } catch { }
        #expect(try Data(contentsOf: source) == original && Data(contentsOf: output) == saved)
        for flag in ["--key-stdin", "--allow-cloud-text", "--model", "--whisper-cli"] {
            #expect(throws: CoreFailure.self) { try RecScribeTextCLI.Arguments(["fit-accuracy", source.path, flag]) }
        }
        let fifo = directory.appendingPathComponent("pipe")
        #expect(mkfifo(fifo.path, 0o600) == 0)
        do {
            try await RecScribeTextCLI.run(RecScribeTextCLI.Arguments(["fit-accuracy", fifo.path, "--output", output.path]))
            Issue.record("Nonregular input was accepted")
        } catch { }
    }
}
