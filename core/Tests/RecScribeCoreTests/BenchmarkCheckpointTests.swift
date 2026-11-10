import Foundation
import Testing
@testable import RecScribeCore

@Suite struct BenchmarkCheckpointTests {
    private struct Fixture {
        let directory: URL
        let metadata: JSONValue
        let planned: [JSONValue]
        let prior: JSONValue
        let bytes: Data
        var digest: String { TextJob.hash(bytes) }
        func load(metadata: JSONValue? = nil, planned: [JSONValue]? = nil) throws -> BenchmarkCheckpoint.Imported {
            try BenchmarkCheckpoint.load(directory: directory, expectedSHA256: digest,
                metadata: metadata ?? self.metadata, planned: planned ?? self.planned, check: {})
        }
    }

    private func fixture(_ directory: URL, statuses: [String]) throws -> Fixture {
        let config = Data("synthetic configuration".utf8), corpus = Data("synthetic corpus".utf8)
        let profile = Data("synthetic profile".utf8), freeze = Data("synthetic freeze".utf8)
        for (name, bytes) in [("experiment.original.json", config), ("corpus.original.json", corpus),
                              ("profile-control.json", profile), ("freeze.original.json", freeze)] {
            try bytes.write(to: directory.appendingPathComponent(name))
        }
        let hash = String(repeating: "a", count: 64)
        let metadata: JSONValue = ["schema_version": "1.0", "dry_run": false, "baseline_revision": .string(String(repeating: "b", count: 40)),
            "configuration_sha256": .string(TextJob.hash(config)), "corpus_sha256": .string(TextJob.hash(corpus)),
            "profile_sha256": ["control": .string(TextJob.hash(profile))], "freeze_sha256": .string(TextJob.hash(freeze)),
            "split": "held_out", "threads": 2, "serial_jobs": true, "measurement_scope": "quality_and_resources",
            "runner_sha256": .string(hash), "whisper_binary_sha256": .string(hash)]
        let planned: [JSONValue] = statuses.indices.map { index in
            ["id": .string("source-\(index)"), "language": "en", "task": "transcription", "source_channel": 0,
             "model": "small", "model_sha256": .string(hash), "profile": "control", "profile_kind": "baseline",
             "profile_sha256": .string(TextJob.hash(profile)), "whisper_binary_sha256": .string(hash),
             "transcription_runner_sha256": .string(hash), "threads": 2, "language_mode": "known", "path": "final", "repeat": 1,
             "source_sha256": .string(hash), "reference_sha256": .string(hash), "measurement_scope": "quality_and_resources",
             "scoring_policy": "synthetic-scorer", "status": "queued"]
        }
        var rows = planned
        for (index, status) in statuses.enumerated() {
            rows[index]["status"] = .string(status)
            if ["completed", "completed_with_review"].contains(status) {
                let measurement: JSONValue = ["status": .string(status), "id": planned[index]["id"], "source_sha256": .string(hash),
                    "reference_sha256": .string(hash), "scoring_version": "synthetic-scorer", "engine_passes": [], "word_errors": 3]
                rows[index]["measurement"] = measurement
                rows[index]["runner_sha256"] = .string(hash)
                rows[index]["engine_identity_observations"] = 0
                rows[index]["evidence_directory"] = .string("cell-\(index)")
                let evidence = directory.appendingPathComponent("cell-\(index)")
                try FileManager.default.createDirectory(at: evidence, withIntermediateDirectories: false)
                try JSONValue.object(["runner_sha256": .string(hash), "results": [measurement]]).encoded()
                    .write(to: evidence.appendingPathComponent("results.json"))
            }
        }
        var prior = metadata; prior["rows"] = .array(rows)
        let bytes = try prior.encoded(); try bytes.write(to: directory.appendingPathComponent("matrix.json"))
        return Fixture(directory: directory, metadata: metadata, planned: planned, prior: prior, bytes: bytes)
    }

    @Test func onlyNeverAttemptedCellsRemainQueuedAndOriginalOutcomesStayUnchanged() throws {
        let root = try AudioFixture.folder(); defer { try? FileManager.default.removeItem(at: root) }
        let f = try fixture(root, statuses: ["completed_with_review", "failed", "cancelled", "pending", "queued"])
        let imported = try f.load()
        let old = try #require(f.prior["rows"].array)
        #expect(imported.rows.map { $0["status"] } == old.map { $0["status"] })
        #expect(imported.rows[0]["measurement"] == old[0]["measurement"])
        #expect(imported.rows[0]["evidence_directory"] == .string(root.appendingPathComponent("cell-0").path))
        for index in 1..<old.count { #expect(imported.rows[index] == old[index]) }
        #expect(imported.provenance["unstarted_cells"] == 1 && imported.provenance["inference_retries"] == 0)
        #expect(imported.snapshot == f.bytes)
        #expect(try Data(contentsOf: root.appendingPathComponent("matrix.json")) == f.bytes)
    }

    @Test func queuedEvidenceAndRunningStatesCannotBecomeRetries() throws {
        let root = try AudioFixture.folder(); defer { try? FileManager.default.removeItem(at: root) }
        let f = try fixture(root, statuses: ["running", "queued", "queued", "queued"])
        try FileManager.default.createDirectory(at: root.appendingPathComponent("cell-1"), withIntermediateDirectories: false)
        var prior = f.prior, rows = try #require(prior["rows"].array)
        rows[2]["measurement"] = ["error": "possible prior launch"]
        prior["rows"] = .array(rows)
        let data = try prior.encoded(); try data.write(to: root.appendingPathComponent("matrix.json"))
        let imported = try BenchmarkCheckpoint.load(directory: root, expectedSHA256: TextJob.hash(data),
            metadata: f.metadata, planned: f.planned, check: {})
        #expect(imported.rows.map { $0["status"] } == ["pending", "pending", "pending", "queued"])
        #expect(imported.provenance["uncertain_prior_attempts"] == 3 && imported.provenance["unstarted_cells"] == 1)
        #expect(try Data(contentsOf: root.appendingPathComponent("matrix.json")) == data)
    }

    @Test func changedInputsRuntimeScorerOrGridAreRejected() throws {
        let root = try AudioFixture.folder(); defer { try? FileManager.default.removeItem(at: root) }
        let f = try fixture(root, statuses: ["queued"])
        for field in ["configuration_sha256", "corpus_sha256", "freeze_sha256", "runner_sha256", "threads"] {
            var metadata = f.metadata; metadata[field] = "changed"
            #expect(throws: CoreFailure.self) { try f.load(metadata: metadata) }
        }
        for field in ["source_sha256", "reference_sha256", "model_sha256", "runtime_settings_sha256", "scoring_policy", "language_mode"] {
            var planned = f.planned; planned[0][field] = "changed"
            #expect(throws: CoreFailure.self) { try f.load(planned: planned) }
        }
        #expect(throws: CoreFailure.self) { try f.load(planned: []) }
        var planned = f.planned; planned[0]["status"] = "pending"
        #expect(throws: CoreFailure.self) { try f.load(planned: planned) }
    }

    @Test func explicitChecksumAndRetainedSnapshotBytesAreRequired() throws {
        let root = try AudioFixture.folder(); defer { try? FileManager.default.removeItem(at: root) }
        let f = try fixture(root, statuses: ["queued"])
        #expect(throws: CoreFailure.self) {
            try BenchmarkCheckpoint.load(directory: root, expectedSHA256: String(repeating: "0", count: 64),
                metadata: f.metadata, planned: f.planned, check: {})
        }
        for name in ["experiment.original.json", "corpus.original.json", "profile-control.json", "freeze.original.json"] {
            let url = root.appendingPathComponent(name), original = try Data(contentsOf: url)
            try Data("changed".utf8).write(to: url)
            #expect(throws: CoreFailure.self) { try f.load() }
            try original.write(to: url)
        }
    }

    @Test func contradictoryMeasurementAndUnsafeEvidenceAreRejected() throws {
        let root = try AudioFixture.folder(); defer { try? FileManager.default.removeItem(at: root) }
        let f = try fixture(root, statuses: ["completed"])
        let mutations: [(String, JSONValue)] = [("measurement", ["status": "completed", "scoring_version": "other"]),
                                               ("evidence_directory", "../other"), ("runner_sha256", "other")]
        for (field, value) in mutations {
            var prior = f.prior, rows = try #require(prior["rows"].array)
            rows[0][field] = value; prior["rows"] = .array(rows)
            let data = try prior.encoded(); try data.write(to: root.appendingPathComponent("matrix.json"))
            #expect(throws: CoreFailure.self) {
                try BenchmarkCheckpoint.load(directory: root, expectedSHA256: TextJob.hash(data), metadata: f.metadata, planned: f.planned, check: {})
            }
        }
        try f.bytes.write(to: root.appendingPathComponent("matrix.json"))
        try JSONValue.object(["results": []]).encoded().write(to: root.appendingPathComponent("cell-0/results.json"))
        #expect(throws: CoreFailure.self) { try f.load() }
    }

    @Test func cancellationAndInvalidResumeOptionsFailBeforeWork() throws {
        let root = try AudioFixture.folder(); defer { try? FileManager.default.removeItem(at: root) }
        let f = try fixture(root, statuses: ["queued"])
        #expect(throws: CancellationError.self) {
            try BenchmarkCheckpoint.load(directory: root, expectedSHA256: f.digest, metadata: f.metadata, planned: f.planned,
                check: { throw CancellationError() })
        }
        let invalid: [(URL?, String?, Bool)] = [(root, nil, false), (nil, f.digest, false), (root, f.digest, true), (root, "invalid", false)]
        for (resume, digest, dryRun) in invalid {
            #expect(throws: CoreFailure.self) {
                try BenchmarkExperiment.run(manifest: root, configuration: root, output: root, cli: root, dryRun: dryRun,
                    resumeFrom: resume, resumeSHA256: digest)
            }
        }
    }

    private var cli: URL {
        var directory = Bundle.module.bundleURL
        while directory.path != "/" {
            let candidate = directory.appendingPathComponent("recscribe-text")
            if FileManager.default.isExecutableFile(atPath: candidate.path) { return candidate }
            directory.deleteLastPathComponent()
        }
        return directory.appendingPathComponent("missing-recscribe-text")
    }

    @Test func nativeResumeInvokesOnlyQueuedCasesAndRetainsCancelledFirstAttempt() throws {
        let root = try AudioFixture.folder(); defer { try? FileManager.default.removeItem(at: root) }
        let audio = root.appendingPathComponent("source.wav"), reference = root.appendingPathComponent("reference.txt")
        try AudioFixture.wav(audio, frames: 16000) { frame, _ in Int64(1000 + frame % 7) }
        try Data("Checkpoint words".utf8).write(to: reference)
        let whisper = root.appendingPathComponent("whisper-cli"), model = root.appendingPathComponent("model.bin")
        let counter = root.appendingPathComponent("invocations.txt")
        func quoted(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'" }
        let script = """
        #!/bin/sh
        if [ "$1" = "--version" ]; then echo 'whisper.cpp synthetic'; exit 0; fi
        echo call >> \(quoted(counter.path))
        while [ "$#" -gt 0 ]; do
          if [ "$1" = "-of" ]; then shift; prefix="$1"; fi
          shift
        done
        printf '%s\\n' '{"result":{"language":"en"},"transcription":[{"offsets":{"from":0,"to":100},"text":"Checkpoint words"}]}' > "$prefix.json"
        """ + "\n"
        try Data(script.utf8).write(to: whisper)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: whisper.path)
        try Data("synthetic model".utf8).write(to: model)
        let revision = String(repeating: "a", count: 40)
        let manifest = root.appendingPathComponent("corpus.json"), config = root.appendingPathComponent("experiment.json")
        let cases: [JSONValue] = try (0..<5).map { index in
            ["id": .string("source-\(index)"), "category": "synthetic", "language": "en", "audio": .string(audio.path),
             "reference": .string(reference.path), "sha256": .string(try WAVAudio.hash(audio)), "license": "synthetic fixture", "source_channel": 0]
        }
        try JSONValue.object(["schema_version": "1.0", "cases": .array(cases)]).encoded().write(to: manifest)
        try JSONValue.object(["schema_version": "1.0", "baseline_revision": .string(revision), "baseline_cli": .string(cli.path),
            "baseline_cli_sha256": .string(try WAVAudio.hash(cli)), "whisper_cli": .string(whisper.path), "split": "development",
            "threads": 2, "repetitions": 1, "language_modes": ["known"], "paths": ["final"], "capture_inactive": true,
            "workload_attestation": "Synthetic fixture; no capture or real model inference",
            "profiles": [["id": "control", "kind": "baseline", "source_revision": .string(revision), "settings": nil]],
            "models": [["id": "small", "checkpoint": "synthetic", "precision": "synthetic", "path": .string(model.path),
                        "sha256": .string(try WAVAudio.hash(model))]]]).encoded().write(to: config)
        let original = root.appendingPathComponent("original"), matrix = original.appendingPathComponent("matrix.json")
        #expect(throws: CancellationError.self) {
            try BenchmarkExperiment.run(manifest: manifest, configuration: config, output: original, cli: cli, dryRun: false, check: {
                guard let data = try? Data(contentsOf: matrix), let report = try? JSONDecoder().decode(JSONValue.self, from: data) else { return }
                if (report["rows"].array ?? []).filter({ [JSONValue.string("completed"), "completed_with_review"].contains($0["status"]) }).count == 2 {
                    throw CancellationError()
                }
            })
        }
        let before = try Data(contentsOf: matrix), old = try JSONDecoder().decode(JSONValue.self, from: before)
        let oldRows = try #require(old["rows"].array)
        #expect(oldRows[2]["status"] == "cancelled" && oldRows[3]["status"] == "queued" && oldRows[4]["status"] == "queued")
        let output = root.appendingPathComponent("resumed"), coordinator = root.appendingPathComponent("new-coordinator")
        try Data("new coordinator; retained transcription executable".utf8).write(to: coordinator)
        let resumed = try BenchmarkExperiment.run(manifest: manifest, configuration: config, output: output, cli: cli, dryRun: false,
            resumeFrom: original, resumeSHA256: TextJob.hash(before), coordinator: coordinator)
        let rows = try #require(resumed["rows"].array)
        #expect(rows[2]["status"] == "cancelled" && rows[2]["measurement"] == .null)
        for index in 0..<2 { #expect(rows[index]["measurement"] == oldRows[index]["measurement"]) }
        #expect(rows[3]["status"].string?.hasPrefix("completed") == true && rows[4]["status"].string?.hasPrefix("completed") == true)
        #expect(try String(contentsOf: counter, encoding: .utf8).split(separator: "\n").count == 4)
        let coordinatorHash = try WAVAudio.hash(coordinator)
        #expect(resumed["runner_sha256"] == old["runner_sha256"] && resumed["coordinator_sha256"] == .string(coordinatorHash))
        #expect(try Data(contentsOf: output.appendingPathComponent("checkpoint.original.json")) == before)
        #expect(try Data(contentsOf: matrix) == before)
        #expect(!FileManager.default.fileExists(atPath: output.appendingPathComponent("cell-2").path))
    }
}
