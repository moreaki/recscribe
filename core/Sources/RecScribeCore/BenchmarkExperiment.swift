import Darwin
import Foundation

/// A serial matrix around CorpusBenchmark, never a second recognition pipeline.
/// Paths and private configuration are retained in the protected result directory.
public enum BenchmarkExperiment {
    public static let requiredModels = ["tiny", "base", "small", "large-v3-turbo", "large-v3"]
    public static let maximumRows = 20_000

    static func read(_ url: URL) throws -> (Data, JSONValue) {
        let file = try FileHandle(forReadingFrom: url); defer { try? file.close() }
        let data = try file.read(upToCount: 4 * 1_024 * 1_024 + 1) ?? Data()
        guard data.count <= 4 * 1_024 * 1_024 else { throw CoreFailure("Benchmark configuration exceeds 4 MiB") }
        return (data, try JSONDecoder().decode(JSONValue.self, from: data))
    }

    static func resolve(_ path: String?, relativeTo config: URL) -> URL? {
        guard let path, !path.isEmpty else { return nil }
        return path.hasPrefix("/") ? URL(fileURLWithPath: path) : config.deletingLastPathComponent().appendingPathComponent(path).standardizedFileURL
    }

    static func safe(_ text: String?) -> Bool {
        guard let text, !text.isEmpty, text.count <= 80 else { return false }
        return text.range(of: "^[a-zA-Z0-9_-]+$", options: .regularExpression) != nil
    }

    /// Dry runs perform no engine calls. Unavailable cells stay explicit, without scores.
    public static func run(manifest: URL, configuration: URL, output: URL, cli: URL,
                           dryRun: Bool, check: @escaping @Sendable () throws -> Void = { try Task.checkCancellation() }) throws -> JSONValue {
        let (configData, config) = try read(configuration)
        let (manifestData, corpus) = try read(manifest)
        let allCases = try CorpusManifest.validate(corpus)
        guard config["schema_version"] == "1.0",
              let revision = config["baseline_revision"].string,
              revision.range(of: "^[0-9a-f]{40}$", options: .regularExpression) != nil,
              let models = config["models"].array, !models.isEmpty,
              let modes = config["language_modes"].array, !modes.isEmpty,
              let paths = config["paths"].array, !paths.isEmpty,
              let profiles = config["profiles"].array, !profiles.isEmpty,
              let repeats = config["repetitions"].integer, (3...10).contains(repeats),
              let threads = config["threads"].integer, (1...4).contains(threads),
              ["development", "held_out"].contains(config["split"].string ?? "") else {
            throw CoreFailure("Invalid experiment: require revision, model/profile matrix, split, 3–10 repeats and 1–4 threads")
        }
        guard Set(models.compactMap { $0["id"].string }).count == models.count,
              Set(profiles.compactMap { $0["id"].string }).count == profiles.count,
              models.allSatisfy({ safe($0["id"].string) }), profiles.allSatisfy({ safe($0["id"].string) }),
              modes.allSatisfy({ ["known", "auto"].contains($0.string ?? "") }), Set(modes.compactMap { $0.string }).count == modes.count,
              paths.allSatisfy({ ["final", "live-replay"].contains($0.string ?? "") }), Set(paths.compactMap { $0.string }).count == paths.count else {
            throw CoreFailure("Unsafe/duplicate matrix IDs or unsupported language/input mode")
        }
        let cases = allCases.filter { $0["split"] == config["split"] || corpus["schema_version"] == "1.0" }
        let rowCount = cases.count * models.count * modes.count * paths.count * profiles.count * Int(repeats)
        guard rowCount <= maximumRows else { throw CoreFailure("Experiment exceeds 20,000 serial cells; split the plan") }
        let whisper = resolve(config["whisper_cli"].string, relativeTo: configuration)
        let baselineCLI = resolve(config["baseline_cli"].string, relativeTo: configuration)
        func executableIdentity(_ url: URL?) throws -> (hash: String?, failure: String?) {
            guard let url, FileManager.default.isExecutableFile(atPath: url.path) else { return (nil, nil) }
            do { return (try WAVAudio.hash(url, check: check), nil) }
            catch is CancellationError { throw CancellationError() }
            catch { return (nil, error.localizedDescription) }
        }
        let baselineIdentity = try executableIdentity(baselineCLI)
        let baselineHash = baselineIdentity.hash
        let baselineFailure: String? = baselineIdentity.failure ?? config["baseline_cli_sha256"].string.flatMap { expected in
            guard let baselineHash, expected != baselineHash else { return nil }
            return "Untouched baseline binary checksum mismatch"
        }
        let whisperIdentity = try executableIdentity(whisper)
        let whisperHash = whisperIdentity.hash
        let runnerHash = try WAVAudio.hash(cli, check: check)
        let split = config["split"].string!
        var profileFiles: [String: URL] = [:]
        var profileSnapshots: [String: Data] = [:]
        var profileHashes: [String: String] = [:]
        var effectiveProfileHashes: [String: String] = [:]
        var profileVADModels: [String: URL] = [:]
        var profileVADHashes: [String: String] = [:]
        var profileResourceErrors: [String: String] = [:]
        var freezeSnapshot: Data?
        for profile in profiles {
            guard ["baseline", "candidate"].contains(profile["kind"].string ?? "") else { throw CoreFailure("Profile kind must be baseline or candidate") }
            if profile["kind"] == "baseline" {
                guard profile["settings"] == .null, profile["source_revision"] == .string(revision) else {
                    throw CoreFailure("Untouched baseline must use the baseline revision and no settings overrides")
                }
            } else {
                guard let file = resolve(profile["settings"].string, relativeTo: configuration),
                      let sourceRevision = profile["source_revision"].string,
                      sourceRevision.range(of: "^[0-9a-f]{40}$", options: .regularExpression) != nil else {
                    throw CoreFailure("Candidates require a private profile file and exact source revision")
                }
                let id = profile["id"].string!
                let (bytes, json) = try read(file)
                let validated = try WhisperDecodingProfile(json: json)
                profileFiles[id] = file
                profileSnapshots[id] = bytes
                profileHashes[id] = TextJob.hash(bytes)
                effectiveProfileHashes[id] = validated.provenance["profile_sha256"].string!
                do {
                    try validated.speech.validateModel(fallback: nil)
                    if let vad = validated.speech.model, !validated.speech.isBaseline {
                        profileVADModels[id] = vad
                        profileVADHashes[id] = try WAVAudio.hash(vad, check: check)
                    }
                } catch is CancellationError { throw CancellationError() }
                catch { profileResourceErrors[id] = error.localizedDescription }
            }
        }
        if split == "held_out" {
            guard let freezeURL = resolve(config["freeze"].string, relativeTo: configuration) else {
                throw CoreFailure("Held-out evaluation requires a predeclared frozen configuration and budgets")
            }
            let (freezeBytes, freeze) = try read(freezeURL)
            freezeSnapshot = freezeBytes
            guard corpus["frozen"] == true, freeze["experiment_sha256"] == .string(TextJob.hash(configData)),
                  freeze["schema_version"] == "1.0", freeze["corpus_sha256"] == .string(TextJob.hash(manifestData)),
                  freeze["budgets"].object?.isEmpty == false, freeze["frozen_before_held_out"] == true else {
                throw CoreFailure("Held-out freeze lacks matching corpus hash, predeclared budgets or review attestation")
            }
            for profile in profiles where profile["kind"] == "candidate" {
                let id = profile["id"].string!
                guard freeze["profiles"][id] == .string(profileHashes[id]!) else {
                    throw CoreFailure("Candidate settings differ from frozen profile: \(id)")
                }
            }
        }
        if !dryRun {
            guard config["capture_inactive"] == true, !(config["workload_attestation"].string ?? "").isEmpty else {
                throw CoreFailure("Measured runs require a fresh idle-capture/workload attestation; never stop recording to benchmark")
            }
        }
        try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard mkdir(output.path, 0o700) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        try configData.write(to: output.appendingPathComponent("experiment.original.json"), options: .withoutOverwriting)
        try manifestData.write(to: output.appendingPathComponent("corpus.original.json"), options: .withoutOverwriting)
        try freezeSnapshot?.write(to: output.appendingPathComponent("freeze.original.json"), options: .withoutOverwriting)
        for (id, bytes) in profileSnapshots {
            try bytes.write(to: output.appendingPathComponent("profile-\(id).json"), options: .withoutOverwriting)
        }
        let host = try hostEvidence(output: output, check: check)
        var rows: [JSONValue] = []
        var metadata: JSONValue = ["schema_version": "1.0", "baseline_revision": .string(revision),
            "source_revision_verification": "Declared revisions; bind binary hashes to the retained build record",
            "configuration_sha256": .string(TextJob.hash(configData)), "corpus_sha256": .string(TextJob.hash(manifestData)),
            "corpus_version": corpus["corpus_version"], "host": host, "split": .string(split),
            "threads": .integer(threads), "serial_jobs": true, "dry_run": .bool(dryRun),
            "capture_inactive_attestation": config["capture_inactive"], "workload_attestation": config["workload_attestation"],
            "required_models_missing_from_plan": .array(requiredModels.filter { name in !models.contains { $0["id"] == .string(name) } }.map(JSONValue.string)),
            "limitations": ["Fresh processes do not establish cold filesystem caches", "Peak RSS excludes total unified GPU memory", "Live replay is unsupported until the real app replay adapter is integrated", "Human critical-content, semantic and timing review remain unmeasured"],
            "runner_sha256": .string(runnerHash), "profile_sha256": .object(profileHashes.mapValues(JSONValue.string)),
            "freeze_sha256": freezeSnapshot.map { .string(TextJob.hash($0)) } ?? .null]
        metadata["whisper_binary_sha256"] = whisperHash.map(JSONValue.string) ?? .null
        var readiness: [String: CorpusManifest.Eligibility] = [:]
        var corpusFailures: [String: String] = [:]
        for item in cases {
            let id = item["id"].string!
            do {
                readiness[id] = try CorpusManifest.eligibility(item, manifest: manifest, schemaVersion: corpus["schema_version"].string!, check: check)
            } catch is CancellationError { throw CancellationError() }
            catch {
                corpusFailures[id] = error.localizedDescription
                readiness[id] = CorpusManifest.Eligibility(status: "failed", reason: error.localizedDescription,
                    audio: nil, reference: nil, audioSHA256: nil, referenceSHA256: nil)
            }
        }
        for model in models {
            let modelURL = resolve(model["path"].string, relativeTo: configuration)
            var modelHash: String?, modelFailure: String?
            do {
                modelHash = try modelURL.flatMap { FileManager.default.isReadableFile(atPath: $0.path) ? try WAVAudio.hash($0, check: check) : nil }
                if let expected = model["sha256"].string, let modelHash, expected != modelHash {
                    modelFailure = "Model checksum mismatch: \(model["id"].string!)"
                }
            } catch is CancellationError { throw CancellationError() }
            catch { modelFailure = error.localizedDescription }
            for profile in profiles { for mode in modes { for path in paths { for item in cases { for repeatIndex in 1...Int(repeats) {
                let ready = readiness[item["id"].string!]!
                var gaps: [JSONValue] = []
                var failures = [modelFailure, corpusFailures[item["id"].string!], whisperIdentity.failure].compactMap { $0 }
                if profile["kind"] == "baseline", let baselineFailure { failures.append(baselineFailure) }
                if let resourceError = profileResourceErrors[profile["id"].string!] {
                    gaps.append("unsupported_profile_resources")
                    gaps.append(.string(resourceError))
                }
                if ready.status != "ready" { gaps.append(.string(ready.status)) }
                if modelHash == nil { gaps.append("pending_model") }
                if model["sha256"].string == nil { gaps.append("pending_model_hash_lock") }
                if !nonempty(model["precision"].string) || !nonempty(model["checkpoint"].string) { gaps.append("pending_model_identity") }
                if whisperHash == nil { gaps.append("pending_whisper_binary") }
                if path == "live-replay" { gaps.append("unsupported_live_replay") }
                if profile["kind"] == "baseline", config["baseline_cli_sha256"].string == nil { gaps.append("pending_untouched_binary_hash_lock") }
                if profile["kind"] == "baseline", baselineCLI == nil || !FileManager.default.isExecutableFile(atPath: baselineCLI!.path) { gaps.append("pending_untouched_binary") }
                if mode == "known", item["language"] == "auto" || !(item["code_switches"].array ?? []).isEmpty || item["language"] == "und" { gaps.append("unsupported_known_language_control") }
                if item["task"] != .null && item["task"] != "transcription" && item["task"] != "dialect_transcription" && item["task"] != "non_speech" { gaps.append("unsupported_output_task") }
                rows.append(["id": item["id"], "language": item["language"], "conditions": item["conditions"], "task": item["task"],
                    "model": model["id"], "model_sha256": modelHash.map(JSONValue.string) ?? .null,
                    "precision": model["precision"], "checkpoint": model["checkpoint"], "profile": profile["id"],
                    "profile_kind": profile["kind"], "profile_sha256": profileHashes[profile["id"].string!].map(JSONValue.string) ?? .null,
                    "effective_profile_sha256": effectiveProfileHashes[profile["id"].string!].map(JSONValue.string) ?? .null,
                    "vad_model_sha256": profileVADHashes[profile["id"].string!].map(JSONValue.string) ?? .null,
                    "baseline_runner_sha256": baselineHash.map(JSONValue.string) ?? .null, "source_revision": profile["source_revision"], "language_mode": mode, "path": path, "repeat": .integer(Int64(repeatIndex)),
                    "source_sha256": ready.audioSHA256.map(JSONValue.string) ?? .null,
                    "reference_sha256": ready.referenceSHA256.map(JSONValue.string) ?? .null,
                    "scoring_policy": .string(try TranscriptAccuracy.policy(for: item, schemaVersion: corpus["schema_version"].string!).rawValue), "gaps": .array(gaps),
                    "readiness_reason": ready.reason.map(JSONValue.string) ?? .null,
                    "errors": .array(failures.map(JSONValue.string)),
                    "status": !failures.isEmpty ? "failed" : (gaps.isEmpty ? (dryRun ? "ready" : "queued") : "pending")])
            } } } } }
        }
        func persist() throws -> JSONValue {
            var report = metadata
            report["rows"] = .array(rows)
            report["repeat_summary"] = summarize(rows)
            report["paired_comparisons"] = paired(rows)
            let scored: [JSONValue] = rows.compactMap { row in
                guard completed(row), var measurement = row["measurement"].object else { return nil }
                measurement["configuration_id"] = .string([row["model"].string!, row["profile"].string!, row["language_mode"].string!, row["path"].string!].joined(separator: "/"))
                return .object(measurement)
            }
            report["quality_aggregation"] = TranscriptAccuracy.aggregate(scored)
            try TextJob.write(report.encoded(), named: "matrix.json", in: output)
            return report
        }
        _ = try persist()
        if !dryRun {
            for index in rows.indices where rows[index]["status"] == "queued" {
                let row = rows[index]
                let job = output.appendingPathComponent("cell-\(index)")
                rows[index]["evidence_directory"] = .string(job.lastPathComponent)
                let cancellation: @Sendable () throws -> Void = {
                    try check()
                    if FileManager.default.fileExists(atPath: output.appendingPathComponent("cancel.request").path) { throw CancellationError() }
                }
                do {
                    try cancellation()
                    let model = models.first { $0["id"] == row["model"] }!
                    let profile = profiles.first { $0["id"] == row["profile"] }!
                    let binary = profile["kind"] == "baseline" ? baselineCLI! : cli
                    let expectedRunner = profile["kind"] == "baseline" ? baselineHash! : runnerHash
                    let modelURL = resolve(model["path"].string, relativeTo: configuration)!
                    try requireHash(manifest, expected: TextJob.hash(manifestData), label: "Corpus manifest", check: cancellation)
                    try requireHash(binary, expected: expectedRunner, label: "Native transcription binary", check: cancellation)
                    try requireHash(whisper!, expected: whisperHash!, label: "Whisper binary", check: cancellation)
                    try requireHash(modelURL, expected: row["model_sha256"].string!, label: "Whisper model", check: cancellation)
                    let profileID = row["profile"].string!
                    if let expectedProfile = profileHashes[profileID] {
                        try requireHash(output.appendingPathComponent("profile-\(profileID).json"), expected: expectedProfile,
                                        label: "Frozen profile snapshot", check: cancellation)
                    }
                    if let vad = profileVADModels[profileID], let expectedVAD = profileVADHashes[profileID] {
                        try requireHash(vad, expected: expectedVAD, label: "Silero model", check: cancellation)
                    }
                    let report = try CorpusBenchmark.run(manifest: manifest, output: job, cli: binary,
                        whisper: whisper, model: resolve(model["path"].string, relativeTo: configuration), threads: Int(threads), dryRun: false,
                        sourceLanguage: row["language_mode"] == "auto" ? "auto" : row["language"].string,
                        caseIDs: [row["id"].string!], whisperProfile: profileFiles[row["profile"].string!].map { _ in output.appendingPathComponent("profile-\(row["profile"].string!).json") },
                        externalCheck: cancellation)
                    let result = report["results"].array!.first!
                    rows[index]["measurement"] = result
                    let observed = try validateEngineIdentity(result["engine_passes"], binaryHash: whisperHash!,
                        modelHash: row["model_sha256"].string!, vadHash: profileVADHashes[profileID], profileHash: effectiveProfileHashes[profileID])
                    rows[index]["engine_identity_observations"] = .integer(Int64(observed))
                    rows[index]["status"] = result["status"]
                    rows[index]["runner_sha256"] = report["runner_sha256"]
                } catch is CancellationError {
                    rows[index]["status"] = "cancelled"; _ = try persist(); throw CancellationError()
                } catch {
                    rows[index]["status"] = "failed"; rows[index]["error"] = .string(error.localizedDescription)
                }
                _ = try persist()
            }
        }
        let report = try persist()
        if rows.contains(where: { $0["status"] == "failed" }) { throw CoreFailure("Experiment has failed cells; inspect matrix.json") }
        return report
    }

    private static func nonempty(_ value: String?) -> Bool {
        value.map { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } ?? false
    }

    private static func completed(_ row: JSONValue) -> Bool {
        row["status"] == "completed" || row["status"] == "completed_with_review"
    }

    static func requireHash(_ url: URL, expected: String, label: String,
                            check: @Sendable () throws -> Void) throws {
        guard try WAVAudio.hash(url, check: check) == expected else {
            throw CoreFailure("\(label) changed after the experiment was planned; retained evidence cannot be paired")
        }
    }

    /// Inspect actual adapter provenance, including region indexes. Silence may have no engine pass.
    static func validateEngineIdentity(_ value: JSONValue, binaryHash: String, modelHash: String,
                                       vadHash: String? = nil, profileHash: String? = nil) throws -> Int {
        var observations = 0
        if let object = value.object {
            if let actual = object["binary_sha256"]?.string {
                guard actual == binaryHash, object["model_sha256"] == .string(modelHash) else {
                    throw CoreFailure("Effective engine/model hash differs from the paired experiment identity")
                }
                if let vadHash, object["vad_model_sha256"] != .string(vadHash) {
                    throw CoreFailure("Effective Silero hash differs from the paired experiment identity")
                }
                if let profileHash, value["decoding"]["profile_sha256"] != .string(profileHash) {
                    throw CoreFailure("Effective decoding profile differs from the frozen experiment identity")
                }
                observations += 1
            }
            for child in object.values { observations += try validateEngineIdentity(child, binaryHash: binaryHash, modelHash: modelHash, vadHash: vadHash, profileHash: profileHash) }
        } else if let array = value.array {
            for child in array { observations += try validateEngineIdentity(child, binaryHash: binaryHash, modelHash: modelHash, vadHash: vadHash, profileHash: profileHash) }
        }
        return observations
    }

    /// Repeat summaries are per exact cell identity; never mix models, languages or tasks.
    static func summarize(_ rows: [JSONValue]) -> JSONValue {
        let groups = Dictionary(grouping: rows) { row in
            ["id", "model", "profile", "language_mode", "path"].map { row[$0].string ?? "unknown" }.joined(separator: "/")
        }
        return .array(groups.keys.sorted().map { key in
            let group = groups[key]!
            let measured = group.filter { completed($0) && $0["measurement"]["wall_seconds"].double != nil }
            let seconds = measured.compactMap { $0["measurement"]["wall_seconds"].double }.sorted()
            let hashes = Set(measured.compactMap { $0["measurement"]["hypothesis_sha256"].string })
            return ["cell": .string(key), "requested_repeats": .integer(Int64(group.count)), "measured_repeats": .integer(Int64(measured.count)),
                "wall_seconds_median": seconds.isEmpty ? .null : .number(seconds.count % 2 == 0 ? (seconds[seconds.count / 2 - 1] + seconds[seconds.count / 2]) / 2 : seconds[seconds.count / 2]),
                "wall_seconds_min": seconds.first.map(JSONValue.number) ?? .null, "wall_seconds_max": seconds.last.map(JSONValue.number) ?? .null,
                "distinct_transcript_hashes": hashes.isEmpty ? .null : .integer(Int64(hashes.count)), "quality_claim": "exploratory; per-language review required"]
        })
    }

    /// Pair only identical evidence/input/model/repeat cells; missing measurements remain pending.
    static func paired(_ rows: [JSONValue]) -> JSONValue {
        func identity(_ row: JSONValue) -> String {
            let fields = ["id", "model", "model_sha256", "language_mode", "path", "source_sha256", "reference_sha256", "scoring_policy", "task"]
            return fields.map { row[$0].string ?? "unknown" }.joined(separator: "|") + "|\(row["repeat"].integer ?? 0)"
        }
        let controls = Dictionary(grouping: rows.filter { $0["profile_kind"] == "baseline" }, by: identity)
        return .array(rows.filter { $0["profile_kind"] == "candidate" }.map { row in
            var comparison: JSONValue = ["identity": .string(identity(row)), "candidate_profile": row["profile"],
                "language": row["language"], "conditions": row["conditions"], "status": "pending_pair"]
            guard let matches = controls[identity(row)], matches.count == 1,
                  let control = matches.first, completed(control), completed(row), control["measurement"]["wall_seconds"].double != nil,
                  row["measurement"]["wall_seconds"].double != nil else { return comparison }
            comparison["status"] = "paired_exploratory"
            for metric in ["wer", "cer", "word_insertions", "word_deletions", "character_insertions", "false_speech_characters", "wall_seconds", "real_time_factor", "peak_rss_bytes"] {
                if let before = control["measurement"][metric].double, let after = row["measurement"][metric].double {
                    comparison[metric + "_delta"] = .number(after - before)
                }
            }
            comparison["critical_content_review"] = "unmeasured"
            return comparison
        })
    }

    static func hostEvidence(output: URL, check: @Sendable () throws -> Void) throws -> JSONValue {
        var evidence: JSONValue = ["os": .string(ProcessInfo.processInfo.operatingSystemVersionString),
            "cpu_count": .integer(Int64(ProcessInfo.processInfo.processorCount)), "physical_memory_bytes": .integer(Int64(ProcessInfo.processInfo.physicalMemory)),
            "thermal_state": .integer(Int64(ProcessInfo.processInfo.thermalState.rawValue))]
        let probes = [("hardware", "/usr/sbin/system_profiler", ["SPHardwareDataType", "SPDisplaysDataType", "-json"]),
                      ("power", "/usr/bin/pmset", ["-g", "custom"]), ("toolchain", "/usr/bin/xcodebuild", ["-version"])]
        for (name, path, args) in probes {
            do {
                let text = try AudioChildProcess.run(URL(fileURLWithPath: path), args, directory: output, timeout: 30, check: check)
                // Hardware reports can include host serial/UUID: retain privately, never application logs.
                try Data(text.utf8).write(to: output.appendingPathComponent("host-\(name).txt"), options: .withoutOverwriting)
                evidence[name + "_evidence"] = .string("host-\(name).txt")
            } catch is CancellationError { throw CancellationError() }
            catch { evidence[name + "_status"] = "unavailable" }
        }
        return evidence
    }
}
