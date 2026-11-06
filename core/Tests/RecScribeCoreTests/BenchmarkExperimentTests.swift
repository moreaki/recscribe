import Foundation
import Testing
@testable import RecScribeCore

@Suite struct BenchmarkExperimentTests {
    private var repo: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }
    @Test func completeDryMatrixRetainsPendingModelsInputsAndUnsupportedPaths() throws {
        let folder = try AudioFixture.folder(); defer { try? FileManager.default.removeItem(at: folder) }
        let binary = folder.appendingPathComponent("cli")
        try Data("synthetic binary; never executed".utf8).write(to: binary)
        let report = try BenchmarkExperiment.run(manifest: repo.appendingPathComponent("benchmarks/manifests/corpus.template.json"),
            configuration: repo.appendingPathComponent("benchmarks/manifests/experiment.template.json"),
            output: folder.appendingPathComponent("plan"), cli: binary, dryRun: true)
        let rows = try #require(report["rows"].array)
        #expect(!rows.isEmpty)
        #expect(Set(rows.compactMap { $0["model"].string }) == Set(BenchmarkExperiment.requiredModels))
        #expect(Set(rows.compactMap { $0["language_mode"].string }) == ["auto", "known"])
        #expect(Set(rows.compactMap { $0["path"].string }) == ["final", "live-replay"])
        #expect(rows.allSatisfy { $0["status"] == "pending" && $0["measurement"] == .null })
        #expect(report["required_models_missing_from_plan"] == [])
        #expect(rows.allSatisfy { ($0["gaps"].array ?? []).contains("pending_model") })
        #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent("plan/corpus.original.json").path))
    }
    @Test func heldOutRequiresFreezeAndMeasuredRunRequiresCaptureAttestation() throws {
        let folder = try AudioFixture.folder(); defer { try? FileManager.default.removeItem(at: folder) }
        let (_, original) = try BenchmarkExperiment.read(repo.appendingPathComponent("benchmarks/manifests/experiment.template.json"))
        let configURL = folder.appendingPathComponent("config.json")
        for heldOut in [true, false] {
            var config = original
            if heldOut { config["split"] = "held_out" }
            try config.encoded().write(to: configURL)
            #expect(throws: CoreFailure.self) {
                try BenchmarkExperiment.run(manifest: repo.appendingPathComponent("benchmarks/manifests/corpus.template.json"),
                    configuration: configURL, output: folder.appendingPathComponent(UUID().uuidString), cli: configURL, dryRun: heldOut)
            }
        }
    }
    @Test func repeatSummaryReportsMedianRangeAndVariationWithoutPoolingCells() throws {
        var rows: [JSONValue] = []
        for (index, seconds) in [4.0, 1.0, 2.0].enumerated() {
            rows.append(["id": "case", "model": "small", "profile": "control", "language_mode": "auto", "path": "final", "status": "completed",
                "measurement": ["wall_seconds": .number(seconds), "hypothesis_sha256": .string(index == 0 ? "a" : "b")]])
        }
        rows.append(["id": "case", "model": "large-v3", "profile": "control", "language_mode": "auto", "path": "final", "status": "pending"])
        let summaries = try #require(BenchmarkExperiment.summarize(rows).array)
        let small = try #require(summaries.first { $0["cell"].string?.contains("/small/") == true })
        #expect(small["wall_seconds_median"].double == 2 && small["wall_seconds_min"].double == 1 && small["wall_seconds_max"].double == 4)
        #expect(small["measured_repeats"] == 3 && small["distinct_transcript_hashes"] == 2)
        #expect(summaries.first { $0["cell"].string?.contains("/large-v3/") == true }?["wall_seconds_median"] == .null)
    }

    @Test func qualityUsesFirstRepeatWithoutInflatingSamplesOrReplacingFailures() throws {
        var rows: [JSONValue] = []
        for repeatIndex in 1...3 {
            var measurement = TranscriptAccuracy.score(reference: "a b", hypothesis: repeatIndex == 1 ? "a" : "a b", policy: .unicodeV2)
            measurement["language"] = "fr"; measurement["task"] = "transcription"
            rows.append(["id": "case", "model": "tiny", "profile": "control", "language_mode": "known", "path": "final",
                "repeat": .integer(Int64(repeatIndex)), "status": "completed", "measurement": measurement])
        }
        let quality = try #require(BenchmarkExperiment.quality(rows).array?.first)
        #expect(quality["cases"] == 1 && quality["scored_cases"] == 1)
        #expect(quality["corpus_weighted_wer"].double == 0.5 && quality["reference_words"] == 2)
        rows[0]["status"] = "failed"
        #expect(BenchmarkExperiment.quality(rows) == [])
    }

    private func experiment(_ folder: URL, split: String = "development") -> JSONValue {
        ["schema_version": "1.0", "baseline_revision": .string(String(repeating: "a", count: 40)),
         "baseline_cli": nil, "baseline_cli_sha256": nil, "whisper_cli": nil, "split": .string(split),
         "threads": 2, "repetitions": 3, "language_modes": ["auto"], "paths": ["final"],
         "capture_inactive": false, "workload_attestation": nil, "freeze": nil,
         "profiles": [["id": "control", "kind": "baseline", "source_revision": .string(String(repeating: "a", count: 40)), "settings": nil]],
         "models": [["id": "small", "checkpoint": "multilingual-small", "precision": "f16", "path": nil, "sha256": nil]]]
    }

    @Test func invalidCandidateFailsBeforeDryRunInference() throws {
        let folder = try AudioFixture.folder(); defer { try? FileManager.default.removeItem(at: folder) }
        let profile = folder.appendingPathComponent("profile.json")
        try JSONValue.object(["schema_version": "1.0", "beam_size": 99]).encoded().write(to: profile)
        var config = experiment(folder)
        config["profiles"] = [["id": "candidate", "kind": "candidate", "source_revision": .string(String(repeating: "b", count: 40)), "settings": .string(profile.path)]]
        let configURL = folder.appendingPathComponent("experiment.json")
        try config.encoded().write(to: configURL)
        #expect(throws: CoreFailure.self) {
            try BenchmarkExperiment.run(manifest: repo.appendingPathComponent("benchmarks/manifests/corpus.template.json"),
                configuration: configURL, output: folder.appendingPathComponent("invalid"), cli: configURL, dryRun: true)
        }
    }

    @Test func singleRepeatQualityPlanRetainsAllSourcesAndSafetyGates() throws {
        let folder = try AudioFixture.folder(); defer { try? FileManager.default.removeItem(at: folder) }
        let configURL = folder.appendingPathComponent("experiment.json")
        let manifest = repo.appendingPathComponent("benchmarks/manifests/corpus.template.json")
        var config = experiment(folder)
        var planned: [[JSONValue]] = []
        for repeats in [1, 3] {
            config["repetitions"] = .integer(Int64(repeats))
            try config.encoded().write(to: configURL)
            let report = try BenchmarkExperiment.run(manifest: manifest, configuration: configURL,
                output: folder.appendingPathComponent("repeat-\(repeats)"), cli: configURL, dryRun: true)
            planned.append(try #require(report["rows"].array))
        }
        #expect(!planned[0].isEmpty && planned[1].count == 3 * planned[0].count)
        #expect(planned[0].allSatisfy { $0["repeat"] == 1 && $0["measurement"] == .null })
        #expect(Set(planned[0].compactMap { $0["id"].string }) == Set(planned[1].compactMap { $0["id"].string }))
        for repeats in [0, 11] {
            config["repetitions"] = .integer(Int64(repeats))
            try config.encoded().write(to: configURL)
            #expect(throws: CoreFailure.self) {
                try BenchmarkExperiment.run(manifest: manifest, configuration: configURL,
                    output: folder.appendingPathComponent("invalid-\(repeats)"), cli: configURL, dryRun: true)
            }
        }
        config["repetitions"] = 1
        try config.encoded().write(to: configURL)
        #expect(throws: CoreFailure.self) {
            try BenchmarkExperiment.run(manifest: manifest, configuration: configURL,
                output: folder.appendingPathComponent("unattested"), cli: configURL, dryRun: false)
        }
    }

    @Test func corpusChecksumFailuresPersistFailedRowsAndOtherPendingCells() throws {
        let folder = try AudioFixture.folder(); defer { try? FileManager.default.removeItem(at: folder) }
        let audio = folder.appendingPathComponent("source.wav"), reference = folder.appendingPathComponent("reference.txt")
        try AudioFixture.wav(audio); try Data("human truth".utf8).write(to: reference)
        let manifest = folder.appendingPathComponent("corpus.json")
        try JSONValue.object(["schema_version": "1.0", "cases": [
            ["id": "bad", "category": "speech", "language": "en", "audio": .string(audio.path),
             "reference": .string(reference.path), "license": "synthetic consent", "sha256": .string(String(repeating: "a", count: 64))],
            ["id": "missing", "category": "speech", "language": "fr"]]]).encoded().write(to: manifest)
        let configURL = folder.appendingPathComponent("experiment.json")
        try experiment(folder).encoded().write(to: configURL)
        let output = folder.appendingPathComponent("failed")
        #expect(throws: CoreFailure.self) {
            try BenchmarkExperiment.run(manifest: manifest, configuration: configURL, output: output, cli: configURL, dryRun: true)
        }
        let report = try AudioFixture.read(output, "matrix.json")
        let rows = try #require(report["rows"].array)
        #expect(rows.filter { $0["id"] == "bad" }.allSatisfy { $0["status"] == "failed" && !$0["errors"].array!.isEmpty })
        #expect(rows.filter { $0["id"] == "missing" }.allSatisfy { $0["status"] == "pending" })
        #expect(rows.allSatisfy { $0["measurement"] == .null })
    }

    @Test func heldOutFreezeBindsExactValidatedProfileBytes() throws {
        let folder = try AudioFixture.folder(); defer { try? FileManager.default.removeItem(at: folder) }
        let profile = folder.appendingPathComponent("profile.json"), freezeURL = folder.appendingPathComponent("freeze.json")
        try Data("{\"schema_version\":\"1.0\",\"beam_size\":2}".utf8).write(to: profile)
        let originalHash = try WAVAudio.hash(profile)
        var config = experiment(folder, split: "held_out")
        config["profiles"] = [["id": "candidate", "kind": "candidate", "source_revision": .string(String(repeating: "b", count: 40)), "settings": .string(profile.path)]]
        config["freeze"] = .string(freezeURL.path)
        let configURL = folder.appendingPathComponent("experiment.json")
        try config.encoded().write(to: configURL)
        let (_, originalCorpus) = try BenchmarkExperiment.read(repo.appendingPathComponent("benchmarks/manifests/corpus.template.json"))
        var corpus = originalCorpus; corpus["frozen"] = true
        let manifest = folder.appendingPathComponent("corpus.json")
        try corpus.encoded().write(to: manifest)
        try JSONValue.object(["schema_version": "1.0", "frozen_before_held_out": true,
            "experiment_sha256": .string(try WAVAudio.hash(configURL)), "corpus_sha256": .string(try WAVAudio.hash(manifest)),
            "profiles": ["candidate": .string(originalHash)], "budgets": ["quality_review": "required"]]).encoded().write(to: freezeURL)
        let output = folder.appendingPathComponent("frozen")
        _ = try BenchmarkExperiment.run(manifest: manifest, configuration: configURL, output: output, cli: configURL, dryRun: true)
        #expect(try WAVAudio.hash(output.appendingPathComponent("profile-candidate.json")) == originalHash)
        #expect(try WAVAudio.hash(output.appendingPathComponent("freeze.original.json")) == WAVAudio.hash(freezeURL))
        try Data("{\"schema_version\":\"1.0\",\"beam_size\":3}".utf8).write(to: profile)
        #expect(throws: CoreFailure.self) {
            try BenchmarkExperiment.run(manifest: manifest, configuration: configURL, output: folder.appendingPathComponent("mutated"), cli: configURL, dryRun: true)
        }
    }

    @Test func lockedHashesAndEffectiveEngineMetadataRejectMutation() throws {
        let folder = try AudioFixture.folder(); defer { try? FileManager.default.removeItem(at: folder) }
        let model = folder.appendingPathComponent("model.bin")
        try Data("original".utf8).write(to: model)
        let digest = try WAVAudio.hash(model)
        try BenchmarkExperiment.requireHash(model, expected: digest, label: "Model", check: {})
        try Data("changed".utf8).write(to: model)
        #expect(throws: CoreFailure.self) { try BenchmarkExperiment.requireHash(model, expected: digest, label: "Model", check: {}) }
        let passes: JSONValue = [["provenance": ["binary_sha256": "binary", "model_sha256": "model",
            "channel_regions": [["provenance": ["binary_sha256": "binary", "model_sha256": "model"]]]]]]
        #expect(try BenchmarkExperiment.validateEngineIdentity(passes, binaryHash: "binary", modelHash: "model") == 2)
        #expect(throws: CoreFailure.self) { try BenchmarkExperiment.validateEngineIdentity(passes, binaryHash: "other", modelHash: "model") }
        #expect(throws: CoreFailure.self) { try BenchmarkExperiment.validateEngineIdentity(passes, binaryHash: "binary", modelHash: "model", profileHash: "expected-profile") }
        #expect(try BenchmarkExperiment.validateEngineIdentity([], binaryHash: "binary", modelHash: "model") == 0)
    }

    @Test func pairedScoresRequireIdenticalEvidenceAndSuccessfulBothArms() throws {
        var baseline: JSONValue = ["id": "speech", "model": "small", "model_sha256": "model", "language_mode": "auto", "path": "final",
            "source_sha256": "audio", "reference_sha256": "reference", "scoring_policy": "unicode-nfc-apostrophe-v2", "task": "transcription",
            "repeat": 1, "profile_kind": "baseline", "status": "completed", "measurement": ["wall_seconds": 2, "cer": .number(0.2)]]
        var candidate = baseline; candidate["profile_kind"] = "candidate"; candidate["profile"] = "candidate"
        candidate["measurement"] = ["wall_seconds": 3, "cer": .number(0.1)]
        #expect(BenchmarkExperiment.paired([baseline, candidate]).array?.first?["status"] == "paired_exploratory")
        for field in ["source_sha256", "reference_sha256", "scoring_policy", "model_sha256", "task"] {
            var changed = candidate; changed[field] = "changed"
            #expect(BenchmarkExperiment.paired([baseline, changed]).array?.first?["status"] == "pending_pair")
        }
        baseline["status"] = "failed"
        #expect(BenchmarkExperiment.paired([baseline, candidate]).array?.first?["status"] == "pending_pair")
    }

    private var artifactModels: [JSONValue] {
        [["id": "tiny", "kind": "pretrained", "sha256": .string(String(repeating: "a", count: 64)), "profiles": ["untouched", "current"]],
         ["id": "tiny-edited", "kind": "weight_edit", "sha256": .string(String(repeating: "b", count: 64)),
          "baseline_model_id": "tiny", "baseline_model_sha256": .string(String(repeating: "a", count: 64)),
          "intervention_id": "attention-pilot-1", "profiles": ["current"]]]
    }

    private var artifactProfiles: [JSONValue] {
        [["id": "untouched", "kind": "baseline"], ["id": "current", "kind": "candidate"]]
    }

    private var artifactComparison: JSONValue {
        ["id": "weight-pilot", "intervention": "weight_edit", "baseline_model_id": "tiny", "candidate_model_id": "tiny-edited",
         "baseline_profile_id": "current", "candidate_profile_id": "current"]
    }

    @Test func derivedModelsRequireDirectLockedLineageAndExplicitProfileAssociations() throws {
        let plan = try BenchmarkExperiment.validateMatrix(models: artifactModels, profiles: artifactProfiles, comparisons: .array([artifactComparison]))
        #expect(plan.allowedProfiles["tiny-edited"] == Set(["current"]))
        let invalidChanges: [(String, JSONValue)] = [
            ("baseline_model_id", "missing"), ("baseline_model_id", "tiny-edited"),
            ("baseline_model_sha256", .string(String(repeating: "c", count: 64))),
            ("sha256", .string(String(repeating: "a", count: 64))), ("sha256", nil),
            ("profiles", ["untouched"]), ("profiles", ["missing"]), ("profiles", nil),
            ("intervention_id", "../unsafe")
        ]
        for (field, value) in invalidChanges {
            var models = artifactModels; models[1][field] = value
            #expect(throws: CoreFailure.self) {
                try BenchmarkExperiment.validateMatrix(models: models, profiles: artifactProfiles, comparisons: .array([artifactComparison]))
            }
        }
        #expect(throws: CoreFailure.self) {
            try BenchmarkExperiment.validateMatrix(models: artifactModels, profiles: artifactProfiles, comparisons: nil)
        }
        var cycle = artifactModels
        cycle[0]["kind"] = "weight_edit"; cycle[0]["baseline_model_id"] = "tiny-edited"
        cycle[0]["baseline_model_sha256"] = cycle[1]["sha256"]; cycle[0]["intervention_id"] = "recursive"
        cycle[0]["profiles"] = ["current"]
        #expect(throws: CoreFailure.self) {
            try BenchmarkExperiment.validateMatrix(models: cycle, profiles: artifactProfiles, comparisons: .array([artifactComparison]))
        }
    }

    @Test func modelComparisonsCannotHideRuntimeChangesOrUnrelatedParents() throws {
        for (field, value) in [("baseline_model_id", JSONValue.string("tiny-edited")),
                               ("baseline_profile_id", JSONValue.string("untouched")),
                               ("intervention", JSONValue.string("runtime")),
                               ("intervention", JSONValue.string("compression"))] {
            var specification = artifactComparison; specification[field] = value
            #expect(throws: CoreFailure.self) {
                try BenchmarkExperiment.validateMatrix(models: artifactModels, profiles: artifactProfiles, comparisons: .array([specification]))
            }
        }
        #expect(throws: CoreFailure.self) {
            try BenchmarkExperiment.validateMatrix(models: artifactModels, profiles: artifactProfiles, comparisons: .array([artifactComparison, artifactComparison]))
        }
        // An unchanged export can be a conversion control, but must still state its parent.
        var conversion = artifactModels; conversion[1]["kind"] = "conversion_control"; conversion[1]["sha256"] = conversion[0]["sha256"]
        var specification = artifactComparison; specification["intervention"] = "conversion_control"
        #expect(try BenchmarkExperiment.validateMatrix(models: conversion, profiles: artifactProfiles,
            comparisons: .array([specification])).comparisons.count == 1)
    }

    @Test func dryRunExecutesOnlyDeclaredArtifactProfilesAndAcceptsSwissWrittenGermanTarget() throws {
        let folder = try AudioFixture.folder(); defer { try? FileManager.default.removeItem(at: folder) }
        let audio = folder.appendingPathComponent("source.wav"), reference = folder.appendingPathComponent("reference.txt")
        try AudioFixture.wav(audio); try Data("Das ist geschriebenes Deutsch.".utf8).write(to: reference)
        let binary = folder.appendingPathComponent("native-cli"), whisper = folder.appendingPathComponent("whisper-cli")
        try Data("synthetic; dry run must not execute inference".utf8).write(to: binary)
        try Data("synthetic whisper; dry run must not execute inference".utf8).write(to: whisper)
        for file in [binary, whisper] { try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path) }
        let before = folder.appendingPathComponent("tiny.bin"), after = folder.appendingPathComponent("edited.bin")
        try Data("original weights".utf8).write(to: before); try Data("edited weights".utf8).write(to: after)
        let profile = folder.appendingPathComponent("profile.json")
        try WhisperDecodingProfile.baseline.json.encoded().write(to: profile)
        let manifest = folder.appendingPathComponent("corpus.json")
        try JSONValue.object(["schema_version": "1.0", "cases": [["id": "swiss", "category": "speech", "language": "de-CH",
            "task": "standard_rendering", "coverage_role": "primary", "audio": .string(audio.path), "reference": .string(reference.path),
            "license": "synthetic test", "sha256": .string(try WAVAudio.hash(audio))]]]).encoded().write(to: manifest)
        var config = experiment(folder)
        config["baseline_cli"] = .string(binary.path); config["baseline_cli_sha256"] = .string(try WAVAudio.hash(binary))
        config["whisper_cli"] = .string(whisper.path)
        config["profiles"] = [["id": "untouched", "kind": "baseline", "source_revision": config["baseline_revision"], "settings": nil],
            ["id": "current", "kind": "candidate", "source_revision": config["baseline_revision"], "settings": .string(profile.path)]]
        var models = artifactModels
        for index in models.indices {
            models[index]["path"] = .string(index == 0 ? before.path : after.path)
            models[index]["sha256"] = .string(try WAVAudio.hash(index == 0 ? before : after))
            models[index]["checkpoint"] = "synthetic-test"; models[index]["precision"] = "synthetic-test"
        }
        models[1]["baseline_model_sha256"] = models[0]["sha256"]
        config["models"] = .array(models); config["comparisons"] = .array([artifactComparison])
        let configURL = folder.appendingPathComponent("experiment.json"); try config.encoded().write(to: configURL)
        let report = try BenchmarkExperiment.run(manifest: manifest, configuration: configURL, output: folder.appendingPathComponent("plan"), cli: binary, dryRun: true)
        let rows = try #require(report["rows"].array)
        #expect(rows.count == 9 && rows.allSatisfy { $0["status"] == "ready" })
        #expect(rows.allSatisfy { $0["task"] == "standard_rendering" && $0["coverage_role"] == "primary" })
        #expect(rows.filter { $0["model"] == "tiny-edited" }.allSatisfy { $0["profile"] == "current" && $0["profile_kind"] == "candidate" })
        #expect(rows.first { $0["model"] == "tiny" }?["artifact_metrics"]["model_file_bytes"].integer == 16)
        #expect(report["paired_comparisons"].array?.count == 3)
        #expect(report["paired_comparisons"].array?.allSatisfy { $0["status"] == "pending_pair" } == true)
    }

    private var artifactRows: [JSONValue] {
        let originalHash = JSONValue.string(String(repeating: "a", count: 64))
        var before: JSONValue = ["id": "speech", "language": "de-CH", "model": "tiny", "model_sha256": originalHash,
            "model_kind": "pretrained", "profile": "current", "profile_kind": "candidate", "language_mode": "auto", "path": "final",
            "source_sha256": "audio", "reference_sha256": "reference", "source_channel": 0,
            "scoring_policy": "unicode-nfc-apostrophe-v2", "task": "standard_rendering", "repeat": 1,
            "whisper_binary_sha256": "whisper", "transcription_runner_sha256": "native", "runtime_settings_sha256": "settings",
            "vad_model_sha256": nil, "preparation_policy": "native-s16", "threads": 2, "status": "completed",
            "artifact_metrics": ["model_file_bytes": 100, "download_artifact_bytes": 80, "incremental_bundle_bytes": nil],
            "measurement": ["wall_seconds": 2, "cer": .number(0.2)]]
        before["baseline_model_id"] = "tiny"; before["baseline_model_sha256"] = originalHash
        var after = before; after["model"] = "tiny-edited"; after["model_sha256"] = .string(String(repeating: "b", count: 64))
        after["model_kind"] = "weight_edit"; after["intervention_id"] = "attention-pilot-1"
        after["measurement"] = ["wall_seconds": 3, "cer": .number(0.1)]
        after["artifact_metrics"] = ["model_file_bytes": 90, "download_artifact_bytes": 75, "incremental_bundle_bytes": nil]
        return [before, after]
    }

    @Test func actualWeightComparisonRetainsBothHashesAndPairsOnlyItsExactParent() throws {
        let rows = artifactRows
        let pair = try #require(BenchmarkExperiment.paired(rows, specifications: [artifactComparison]).array?.first)
        #expect(pair["status"] == "paired_exploratory" && pair["cer_delta"].double == -0.1)
        #expect(pair["baseline_model_sha256"] == rows[0]["model_sha256"] && pair["candidate_model_sha256"] == rows[1]["model_sha256"])
        #expect(pair["baseline_model_sha256"] != pair["candidate_model_sha256"])
        #expect(pair["model_file_bytes_delta"] == -10 && pair["download_artifact_bytes_delta"] == -5)
        #expect(pair["incremental_bundle_bytes_delta"] == .null)
        for field in ["baseline_model_id", "baseline_model_sha256", "source_sha256", "reference_sha256", "source_channel", "scoring_policy",
                      "task", "language_mode", "whisper_binary_sha256", "transcription_runner_sha256", "runtime_settings_sha256", "preparation_policy", "threads"] {
            var changed = rows; changed[1][field] = "changed"
            #expect(BenchmarkExperiment.paired(changed, specifications: [artifactComparison]).array?.first?["status"] == "pending_pair")
        }
        var changed = rows
        changed[1]["measurement"]["reference_sha256"] = "different-observed-reference"
        #expect(BenchmarkExperiment.paired(changed, specifications: [artifactComparison]).array?.first?["status"] == "pending_pair")
        changed = rows; changed[0]["status"] = "failed"
        let pending = try #require(BenchmarkExperiment.paired(changed, specifications: [artifactComparison]).array?.first)
        #expect(pending["status"] == "pending_pair")
        #expect(pending["baseline_model"] == rows[0]["model"] && pending["candidate_model"] == rows[1]["model"])
        #expect(pending["id"] == rows[1]["id"] && pending["repeat"] == rows[1]["repeat"])
    }
}
