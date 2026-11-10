import Foundation

/// Read-only checkpoint import. Only cells with no prior attempt can be scheduled.
enum BenchmarkCheckpoint {
    static let maximumBytes = 64 * 1_024 * 1_024
    static let identityFields = ["id", "language", "task", "source_channel", "model", "model_sha256",
        "model_kind", "baseline_model_id", "baseline_model_sha256", "intervention_id", "precision", "checkpoint",
        "profile", "profile_kind", "profile_sha256", "effective_profile_sha256", "vad_model_sha256",
        "runtime_settings_sha256", "whisper_binary_sha256", "transcription_runner_sha256", "threads",
        "preparation_policy", "baseline_runner_sha256", "source_revision", "language_mode", "path", "repeat",
        "source_sha256", "reference_sha256", "measurement_scope", "scoring_policy"]

    struct Imported {
        let rows: [JSONValue]
        let provenance: JSONValue
        let snapshot: Data
    }

    static func load(directory: URL, expectedSHA256: String, metadata: JSONValue, planned: [JSONValue],
                     check: @Sendable () throws -> Void) throws -> Imported {
        try check()
        let directory = directory.standardizedFileURL
        let file = directory.appendingPathComponent("matrix.json")
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: maximumBytes + 1) ?? Data()
        guard data.count <= maximumBytes, TextJob.hash(data) == expectedSHA256 else {
            throw CoreFailure("Checkpoint exceeds 64 MiB or differs from its explicit SHA-256")
        }
        let prior = try JSONDecoder().decode(JSONValue.self, from: data)
        guard prior["schema_version"] == "1.0", prior["dry_run"] == false,
              let oldRows = prior["rows"].array, oldRows.count == planned.count else {
            throw CoreFailure("Resume requires a measured checkpoint with the exact planned grid")
        }
        for field in ["baseline_revision", "configuration_sha256", "corpus_sha256", "split", "threads",
                      "serial_jobs", "measurement_scope", "runner_sha256", "profile_sha256",
                      "freeze_sha256", "whisper_binary_sha256"] where prior[field] != metadata[field] {
            throw CoreFailure("Checkpoint execution identity differs: \(field)")
        }
        for (name, field) in [("experiment.original.json", "configuration_sha256"), ("corpus.original.json", "corpus_sha256")]
            + (prior["freeze_sha256"] == .null ? [] : [("freeze.original.json", "freeze_sha256")]) {
            try check()
            guard try WAVAudio.hash(directory.appendingPathComponent(name), check: check) == prior[field].string else {
                throw CoreFailure("Checkpoint retained snapshot differs: \(name)")
            }
        }
        for (id, digest) in prior["profile_sha256"].object ?? [:] {
            try check()
            guard BenchmarkExperiment.safe(id),
                  try WAVAudio.hash(directory.appendingPathComponent("profile-\(id).json"), check: check) == digest.string else {
                throw CoreFailure("Checkpoint retained profile differs")
            }
        }
        if let digest = prior["resume_provenance"]["checkpoint_sha256"].string {
            guard try WAVAudio.hash(directory.appendingPathComponent("checkpoint.original.json"), check: check) == digest else {
                throw CoreFailure("Checkpoint's retained predecessor snapshot differs")
            }
        }
        var imported: [JSONValue] = [], measured = 0, queued = 0, uncertain = 0
        for (index, old) in oldRows.enumerated() {
            try check()
            let current = planned[index]
            for field in identityFields where old[field] != current[field] {
                throw CoreFailure("Checkpoint cell \(index) identity differs: \(field)")
            }
            guard let status = old["status"].string,
                  ["queued", "running", "completed", "completed_with_review", "failed", "cancelled", "pending"].contains(status) else {
                throw CoreFailure("Unknown checkpoint cell state; refusing to infer an unstarted call")
            }
            var row = old
            let priorJob = directory.appendingPathComponent("cell-\(index)")
            if status == "queued" {
                // A process may die after launching recognition but before saving
                // its result. Evidence makes that first attempt uncertain, not queued.
                if FileManager.default.fileExists(atPath: priorJob.path) ||
                    ["evidence_directory", "measurement", "runner_sha256", "error", "engine_identity_observations"].contains(where: { old[$0] != .null }) {
                    row["status"] = "pending"
                    row["readiness_reason"] = "Uncertain prior attempt; never retry or replace a first result"
                    uncertain += 1
                } else {
                    guard current["status"] == "queued" else {
                        throw CoreFailure("Previously queued input is no longer eligible")
                    }
                    queued += 1
                }
            } else if status == "running" {
                row["status"] = "pending"
                row["readiness_reason"] = "Interrupted running state; first-attempt outcome is unknown"
                uncertain += 1
            } else {
                measured += 1
            }
            if ["completed", "completed_with_review"].contains(status) {
                for (observed, declared) in [("source_sha256", "source_sha256"), ("reference_sha256", "reference_sha256"), ("scoring_version", "scoring_policy")] {
                    guard old["measurement"][observed] == current[declared] else {
                        throw CoreFailure("Checkpoint measurement differs from its retained input/scorer")
                    }
                }
                guard old["measurement"]["status"] == old["status"] else {
                    throw CoreFailure("Checkpoint successful state contradicts its measurement")
                }
                guard old["runner_sha256"] == current["transcription_runner_sha256"] else {
                    throw CoreFailure("Checkpoint measurement used a different transcription executable")
                }
            }
            guard old["evidence_directory"] == .null || old["evidence_directory"].string != nil else {
                throw CoreFailure("Invalid checkpoint evidence pointer")
            }
            if let evidence = old["evidence_directory"].string {
                // Resolve the derived report's pointer, keeping the original files,
                // measurements, source times and checkpoint bytes untouched.
                if !evidence.hasPrefix("/") {
                    guard evidence == "cell-\(index)" else { throw CoreFailure("Unsafe checkpoint evidence pointer") }
                    row["evidence_directory"] = .string(priorJob.path)
                }
            }
            if ["completed", "completed_with_review"].contains(status) {
                guard let evidence = row["evidence_directory"].string else {
                    throw CoreFailure("Checkpoint successful result lacks retained evidence")
                }
                let (_, retained) = try BenchmarkExperiment.read(URL(fileURLWithPath: evidence).appendingPathComponent("results.json"))
                guard retained["results"].array == [old["measurement"]], retained["runner_sha256"] == old["runner_sha256"] else {
                    throw CoreFailure("Checkpoint measurement differs from its retained case report")
                }
                guard let binaryHash = current["whisper_binary_sha256"].string, let modelHash = current["model_sha256"].string else {
                    throw CoreFailure("Checkpoint successful result lacks effective model/binary identity")
                }
                let observations = try BenchmarkExperiment.validateEngineIdentity(old["measurement"]["engine_passes"],
                    binaryHash: binaryHash, modelHash: modelHash,
                    vadHash: current["vad_model_sha256"].string, profileHash: current["effective_profile_sha256"].string)
                guard old["engine_identity_observations"] == .integer(Int64(observations)) else {
                    throw CoreFailure("Checkpoint engine identity evidence differs")
                }
            }
            imported.append(row)
        }
        try BenchmarkExperiment.requireHash(file, expected: expectedSHA256, label: "Source checkpoint", check: check)
        return Imported(rows: imported, provenance: ["version": "unstarted-cells-v1",
            "checkpoint": .string(file.path), "checkpoint_sha256": .string(expectedSHA256),
            "retained_checkpoint_file": "checkpoint.original.json",
            "retained_nonqueued_cells": .integer(Int64(measured)), "unstarted_cells": .integer(Int64(queued)),
            "uncertain_prior_attempts": .integer(Int64(uncertain)), "inference_retries": 0,
            "original_checkpoint_modified": false, "selection": "Only queued cells with no prior evidence; all other first outcomes retained"], snapshot: data)
    }
}
