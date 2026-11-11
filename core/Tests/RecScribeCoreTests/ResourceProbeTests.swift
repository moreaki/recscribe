import Foundation
import Testing
@testable import RecScribeCore

@Suite struct ResourceProbeTests {
    private var cli: URL {
        var directory = Bundle.module.bundleURL
        while directory.path != "/" {
            let candidate = directory.appendingPathComponent("recscribe-text")
            if FileManager.default.isExecutableFile(atPath: candidate.path) { return candidate }
            directory.deleteLastPathComponent()
        }
        return directory.appendingPathComponent("missing-recscribe-text")
    }

    @Test func measuredResourceMatrixRunsNativeASRWithoutReadingOrScoringReferences() throws {
        let root = try AudioFixture.folder(); defer { try? FileManager.default.removeItem(at: root) }
        let audio = root.appendingPathComponent("source.wav")
        try AudioFixture.wav(audio, frames: 16000) { frame, _ in Int64(1000 + frame % 7) }
        let binary = root.appendingPathComponent("whisper-cli"), model = root.appendingPathComponent("model.bin")
        let script = #"""
        #!/bin/sh
        if [ "$1" = "--version" ]; then echo 'whisper.cpp version: synthetic'; exit 0; fi
        while [ "$#" -gt 0 ]; do
          if [ "$1" = "-of" ]; then shift; prefix="$1"; fi
          shift
        done
        printf '%s\n' '{"result":{"language":"en"},"transcription":[{"offsets":{"from":0,"to":100},"text":"Resource probe words"}]}' > "$prefix.json"
        """# + "\n"
        try Data(script.utf8).write(to: binary)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: binary.path)
        try Data("synthetic".utf8).write(to: model)
        let manifest = root.appendingPathComponent("corpus.json"), config = root.appendingPathComponent("config.json")
        try JSONValue.object(["schema_version": "1.0", "cases": [["id": "source", "category": "synthetic", "language": "en",
            "audio": "source.wav", "sha256": .string(try WAVAudio.hash(audio)), "license": "synthetic test", "source_channel": 0]]]).encoded().write(to: manifest)
        let revision = String(repeating: "a", count: 40)
        try JSONValue.object(["schema_version": "1.0", "measurement_scope": "resources_only", "baseline_revision": .string(revision),
            "baseline_cli": .string(cli.path), "baseline_cli_sha256": .string(try WAVAudio.hash(cli)), "whisper_cli": .string(binary.path),
            "split": "development", "threads": 2, "repetitions": 1, "language_modes": ["auto"], "paths": ["final"],
            "capture_inactive": true, "workload_attestation": "Synthetic fixture; no capture or model inference",
            "profiles": [["id": "control", "kind": "baseline", "source_revision": .string(revision), "settings": nil]],
            "models": [["id": "small", "checkpoint": "synthetic", "precision": "synthetic", "path": .string(model.path),
                        "sha256": .string(try WAVAudio.hash(model))]]]).encoded().write(to: config)
        let output = root.appendingPathComponent("matrix")
        let report = try BenchmarkExperiment.run(manifest: manifest, configuration: config, output: output, cli: cli, dryRun: false)
        let row = try #require(report["rows"].array?.first)
        #expect([JSONValue.string("completed"), "completed_with_review"].contains(row["status"]))
        #expect(row["engine_identity_observations"] == 1)
        #expect(row["measurement"]["scoring_version"] == "unscored-resources-v1")
        #expect(row["measurement"]["wer"] == .null && row["measurement"]["cer"] == .null)
        #expect(row["reference_sha256"] == .null)
        #expect(report["quality_aggregation"]["status"].string?.contains("UNMEASURED") == true)
        #expect(FileManager.default.fileExists(atPath: output.appendingPathComponent("cell-0/source/asr-channel-0.json").path))
    }

    @Test func resourceScopeIsExplicitAndPlansNoQualityEligibility() throws {
        let root = try AudioFixture.folder(); defer { try? FileManager.default.removeItem(at: root) }
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let (_, original) = try BenchmarkExperiment.read(repo.appendingPathComponent("benchmarks/manifests/experiment.template.json"))
        let audio = root.appendingPathComponent("audio.wav"); try AudioFixture.wav(audio, frames: 1600)
        let manifest = root.appendingPathComponent("corpus.json"), configURL = root.appendingPathComponent("config.json")
        try JSONValue.object(["schema_version": "1.0", "cases": [["id": "no-reference", "category": "synthetic",
            "language": "en", "audio": "audio.wav", "license": "synthetic", "sha256": .string(try WAVAudio.hash(audio))]]]).encoded().write(to: manifest)
        var config = original; config["measurement_scope"] = "resources_only"
        try config.encoded().write(to: configURL)
        let report = try BenchmarkExperiment.run(manifest: manifest, configuration: configURL,
            output: root.appendingPathComponent("plan"), cli: configURL, dryRun: true)
        let rows = try #require(report["rows"].array)
        #expect(report["measurement_scope"] == "resources_only")
        #expect(rows.allSatisfy { $0["source_sha256"].string?.count == 64 && $0["reference_sha256"] == .null && $0["scoring_policy"] == "unscored-resources-v1" })
        for invalid: JSONValue in ["resource_only_typo", true, nil] {
            config["measurement_scope"] = invalid; try config.encoded().write(to: configURL)
            #expect(throws: CoreFailure.self) {
                try BenchmarkExperiment.run(manifest: manifest, configuration: configURL,
                    output: root.appendingPathComponent(UUID().uuidString), cli: configURL, dryRun: true)
            }
        }
    }

    @Test func audioOnlyAdmissionDoesNotApproveOrReadReferences() throws {
        let root = try AudioFixture.folder(); defer { try? FileManager.default.removeItem(at: root) }
        let audio = root.appendingPathComponent("source.wav")
        try AudioFixture.wav(audio, frames: 1600) { _, _ in 0 }
        let manifest = root.appendingPathComponent("manifest.json")
        var item: JSONValue = ["id": "unreviewed", "audio": "source.wav", "sha256": .string(try WAVAudio.hash(audio)),
            "license": "synthetic test", "duration_seconds": .number(0.1), "source_channel": 0, "reviewed": false,
            "reference": "/must-not-be-read", "reference_sha256": .string(String(repeating: "a", count: 64))]
        let ready = try CorpusManifest.resourceEligibility(item, manifest: manifest)
        #expect(ready.status == "ready" && ready.reference == nil && ready.referenceSHA256 == nil)
        #expect(ready.reason?.contains("not assessed") == true)
        #expect(try CorpusManifest.eligibility(item, manifest: manifest, schemaVersion: "2.0").status == "pending_corpus")
        item["sha256"] = .string(String(repeating: "0", count: 64))
        #expect(throws: CoreFailure.self) { try CorpusManifest.resourceEligibility(item, manifest: manifest) }
    }

    @Test func resourceProbeRetainsTimingWithoutInventingSilenceOrQualityScores() throws {
        let root = try AudioFixture.folder(); defer { try? FileManager.default.removeItem(at: root) }
        let audio = root.appendingPathComponent("source.wav")
        try AudioFixture.wav(audio, frames: 1600) { _, _ in 0 }
        let binary = root.appendingPathComponent("whisper-cli"), model = root.appendingPathComponent("model.bin")
        try Data("#!/bin/sh\necho 'whisper.cpp synthetic'\n".utf8).write(to: binary)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: binary.path)
        try Data("synthetic".utf8).write(to: model)
        let manifest = root.appendingPathComponent("manifest.json")
        try JSONValue.object(["schema_version": "1.0", "cases": [["id": "source", "category": "synthetic",
            "audio": "source.wav", "sha256": .string(try WAVAudio.hash(audio)), "language": "en",
            "source_channel": 0, "license": "synthetic test"]]]).encoded().write(to: manifest)
        let report = try CorpusBenchmark.run(manifest: manifest, output: root.appendingPathComponent("probe"),
            cli: cli, whisper: binary, model: model, threads: 2, dryRun: false, resourcesOnly: true)
        let row = try #require(report["results"].array?.first)
        #expect(row["measurement_scope"] == "resources_only")
        #expect(row["wall_seconds"].double.map { $0 > 0 } == true)
        #expect(row["wer"] == .null && row["cer"] == .null && row["false_speech_words"] == .null)
        #expect(row["reference_sha256"] == .null)
        #expect(row["quality_status"].string?.contains("UNMEASURED") == true)
        #expect(report["aggregation"]["status"].string?.contains("UNMEASURED") == true)
    }

    @Test func resourceAdmissionRejectsInvalidChannelsAndDurationAndKeepsCancellation() throws {
        let root = try AudioFixture.folder(); defer { try? FileManager.default.removeItem(at: root) }
        let audio = root.appendingPathComponent("source.wav")
        try AudioFixture.wav(audio, frames: 1600)
        let manifest = root.appendingPathComponent("manifest.json")
        var item: JSONValue = ["audio": "source.wav", "sha256": .string(try WAVAudio.hash(audio)), "license": "synthetic test", "source_channel": 2]
        #expect(throws: CoreFailure.self) { try CorpusManifest.resourceEligibility(item, manifest: manifest) }
        item["source_channel"] = 0; item["duration_seconds"] = 100
        #expect(throws: CoreFailure.self) { try CorpusManifest.resourceEligibility(item, manifest: manifest) }
        #expect(throws: CancellationError.self) { try CorpusManifest.resourceEligibility(item, manifest: manifest, check: { throw CancellationError() }) }
        item["audio"] = .null
        #expect(try CorpusManifest.resourceEligibility(item, manifest: manifest).status == "pending_corpus")
    }
}
