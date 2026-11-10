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

    struct MatrixPlan {
        let models: [String: JSONValue]
        let allowedProfiles: [String: Set<String>]
        let comparisons: [JSONValue]
    }

    static func modelKind(_ model: JSONValue) -> String { model["kind"].string ?? "pretrained" }

    /// Model artifacts and runtime profiles are independent axes. A derived
    /// artifact never inherits the label or executable of an untouched control.
    static func validateMatrix(models: [JSONValue], profiles: [JSONValue], comparisons: JSONValue) throws -> MatrixPlan {
        guard !models.isEmpty, !profiles.isEmpty,
              models.allSatisfy({ safe($0["id"].string) }), profiles.allSatisfy({ safe($0["id"].string) }),
              Set(models.compactMap { $0["id"].string }).count == models.count,
              Set(profiles.compactMap { $0["id"].string }).count == profiles.count else {
            throw CoreFailure("Model and profile IDs must be unique safe identifiers")
        }
        let modelMap = Dictionary(uniqueKeysWithValues: models.map { ($0["id"].string!, $0) })
        let profileMap = Dictionary(uniqueKeysWithValues: profiles.map { ($0["id"].string!, $0) })
        let kinds = ["pretrained", "weight_edit", "compression", "conversion_control", "combined"]
        func digest(_ value: JSONValue) -> Bool {
            value.string?.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil
        }
        var assignments: [String: Set<String>] = [:]
        for model in models {
            let id = model["id"].string!, kind = modelKind(model)
            guard kinds.contains(kind), model.object?["kind"] == nil || model["kind"].string != nil else {
                throw CoreFailure("Unsupported model artifact kind: \(id)")
            }
            if let selected = model["profiles"].array {
                let names = selected.compactMap(\.string)
                guard !names.isEmpty, names.count == selected.count, Set(names).count == names.count,
                      names.allSatisfy({ profileMap[$0] != nil }) else {
                    throw CoreFailure("Model \(id) needs unique configured profile associations")
                }
                assignments[id] = Set(names)
            } else {
                guard model.object?["profiles"] == nil, kind == "pretrained" else {
                    throw CoreFailure("Derived model \(id) requires explicit profile associations")
                }
                assignments[id] = Set(profileMap.keys)
            }
            if kind == "pretrained" {
                guard model["baseline_model_id"] == .null, model["baseline_model_sha256"] == .null,
                      model["intervention_id"] == .null else {
                    throw CoreFailure("Untouched model \(id) cannot declare an adaptation lineage")
                }
                continue
            }
            guard let parentID = model["baseline_model_id"].string, parentID != id,
                  let parent = modelMap[parentID], modelKind(parent) == "pretrained",
                  digest(parent["sha256"]), digest(model["sha256"]),
                  model["baseline_model_sha256"] == parent["sha256"], safe(model["intervention_id"].string),
                  kind == "conversion_control" || model["sha256"] != parent["sha256"] else {
                throw CoreFailure("Derived model \(id) needs a hashed untouched parent and explicit intervention; recursive/cyclic lineage is unsupported")
            }
            guard assignments[id]!.allSatisfy({ profileMap[$0]?["kind"] == "candidate" }) else {
                throw CoreFailure("Derived model \(id) cannot run an untouched-baseline profile")
            }
        }
        let specifications: [JSONValue]
        if comparisons == .null { specifications = [] }
        else if let values = comparisons.array { specifications = values }
        else { throw CoreFailure("comparisons must be an array") }
        guard specifications.count <= 1_000 else { throw CoreFailure("Experiment exceeds 1,000 comparison specifications") }
        var ids = Set<String>(), coveredDerivedModels = Set<String>()
        for specification in specifications {
            guard let id = specification["id"].string, safe(id), ids.insert(id).inserted,
                  let intervention = specification["intervention"].string,
                  ["runtime", "weight_edit", "compression", "conversion_control", "combined"].contains(intervention),
                  let beforeID = specification["baseline_model_id"].string, let before = modelMap[beforeID],
                  let afterID = specification["candidate_model_id"].string, let after = modelMap[afterID],
                  let beforeProfile = specification["baseline_profile_id"].string,
                  let afterProfile = specification["candidate_profile_id"].string,
                  assignments[beforeID]!.contains(beforeProfile), assignments[afterID]!.contains(afterProfile) else {
                throw CoreFailure("Invalid comparison identity, intervention, model or profile association")
            }
            if intervention == "runtime" {
                guard beforeID == afterID else { throw CoreFailure("A runtime-only comparison must use the same model artifact") }
            } else {
                guard beforeID != afterID, modelKind(before) == "pretrained", modelKind(after) == intervention,
                      after["baseline_model_id"] == .string(beforeID), after["baseline_model_sha256"] == before["sha256"] else {
                    throw CoreFailure("Model comparison \(id) does not reference its declared untouched parent")
                }
                if intervention != "combined" {
                    guard beforeProfile == afterProfile, profileMap[beforeProfile]?["kind"] == "candidate" else {
                        throw CoreFailure("Isolated model comparison \(id) requires one shared current-runner profile")
                    }
                }
                coveredDerivedModels.insert(afterID)
            }
        }
        guard models.filter({ modelKind($0) != "pretrained" }).allSatisfy({ coveredDerivedModels.contains($0["id"].string!) }) else {
            throw CoreFailure("Every derived model needs an explicit parent comparison")
        }
        return MatrixPlan(models: modelMap, allowedProfiles: assignments, comparisons: specifications)
    }

    /// Dry runs perform no engine calls. Unavailable cells stay explicit, without scores.
    public static func run(manifest: URL, configuration: URL, output: URL, cli: URL,
                           dryRun: Bool, check: @escaping @Sendable () throws -> Void = { try Task.checkCancellation() }) throws -> JSONValue {
        let (configData, config) = try read(configuration)
        let (manifestData, corpus) = try read(manifest)
        let allCases = try CorpusManifest.validate(corpus)
        let scope = config["measurement_scope"].string ?? "quality_and_resources"
        guard ["quality_and_resources", "resources_only"].contains(scope),
              config.object?["measurement_scope"] == nil || config["measurement_scope"].string != nil else {
            throw CoreFailure("measurement_scope must be quality_and_resources or explicit resources_only")
        }
        let resourcesOnly = scope == "resources_only"
        guard config["schema_version"] == "1.0",
              let revision = config["baseline_revision"].string,
              revision.range(of: "^[0-9a-f]{40}$", options: .regularExpression) != nil,
              let models = config["models"].array, !models.isEmpty,
              let modes = config["language_modes"].array, !modes.isEmpty,
              let paths = config["paths"].array, !paths.isEmpty,
              let profiles = config["profiles"].array, !profiles.isEmpty,
              let repeats = config["repetitions"].integer, (1...10).contains(repeats),
              let threads = config["threads"].integer, (1...4).contains(threads),
              ["development", "held_out"].contains(config["split"].string ?? "") else {
            throw CoreFailure("Invalid experiment: require revision, model/profile matrix, split, 1–10 repeats and 1–4 threads")
        }
        guard Set(models.compactMap { $0["id"].string }).count == models.count,
              Set(profiles.compactMap { $0["id"].string }).count == profiles.count,
              models.allSatisfy({ safe($0["id"].string) }), profiles.allSatisfy({ safe($0["id"].string) }),
              modes.allSatisfy({ ["known", "auto"].contains($0.string ?? "") }), Set(modes.compactMap { $0.string }).count == modes.count,
              paths.allSatisfy({ ["final", "live-replay"].contains($0.string ?? "") }), Set(paths.compactMap { $0.string }).count == paths.count else {
            throw CoreFailure("Unsafe/duplicate matrix IDs or unsupported language/input mode")
        }
        let plan = try validateMatrix(models: models, profiles: profiles, comparisons: config["comparisons"])
        let cases = allCases.filter { $0["split"] == config["split"] || corpus["schema_version"] == "1.0" }
        let rowCount = cases.count * modes.count * paths.count * Int(repeats) * plan.allowedProfiles.values.reduce(0) { $0 + $1.count }
        guard rowCount <= maximumRows else { throw CoreFailure("Experiment exceeds 20,000 serial cells; split the plan") }
        guard cases.count * modes.count * paths.count * Int(repeats) * plan.comparisons.count <= maximumRows else {
            throw CoreFailure("Experiment exceeds 20,000 paired comparison cells; split the plan")
        }
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
            "threads": .integer(threads), "serial_jobs": true, "dry_run": .bool(dryRun), "measurement_scope": .string(scope),
            "capture_inactive_attestation": config["capture_inactive"], "workload_attestation": config["workload_attestation"],
            "required_models_missing_from_plan": .array(requiredModels.filter { name in !models.contains { $0["id"] == .string(name) } }.map(JSONValue.string)),
            "limitations": ["Fresh processes do not establish cold filesystem caches", "Peak RSS excludes total unified GPU memory", "Live replay is unsupported until the real app replay adapter is integrated", "Human critical-content, semantic and timing review remain unmeasured"],
            "runner_sha256": .string(runnerHash), "profile_sha256": .object(profileHashes.mapValues(JSONValue.string)),
            "freeze_sha256": freezeSnapshot.map { .string(TextJob.hash($0)) } ?? .null,
            "comparisons": .array(plan.comparisons)]
        metadata["whisper_binary_sha256"] = whisperHash.map(JSONValue.string) ?? .null
        var readiness: [String: CorpusManifest.Eligibility] = [:]
        var corpusFailures: [String: String] = [:]
        for item in cases {
            let id = item["id"].string!
            do {
                readiness[id] = try resourcesOnly ? CorpusManifest.resourceEligibility(item, manifest: manifest, check: check) :
                    CorpusManifest.eligibility(item, manifest: manifest, schemaVersion: corpus["schema_version"].string!, check: check)
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
            var artifactMetrics: JSONValue = .null
            do {
                modelHash = try modelURL.flatMap { FileManager.default.isReadableFile(atPath: $0.path) ? try WAVAudio.hash($0, check: check) : nil }
                if let expected = model["sha256"].string, let modelHash, expected != modelHash {
                    modelFailure = "Model checksum mismatch: \(model["id"].string!)"
                }
                if model["download_artifact"] != .null && !nonempty(model["download_artifact"].string) {
                    throw CoreFailure("Download artifact must be an explicit local file path")
                }
                if let modelURL, modelHash != nil {
                    artifactMetrics = try WhisperBenchmarkMetrics.artifact(modelURL,
                        download: resolve(model["download_artifact"].string, relativeTo: configuration), check: check)
                    if let expected = model["download_artifact_sha256"].string,
                       artifactMetrics["download_artifact_sha256"] != .string(expected) {
                        throw CoreFailure("Download artifact checksum mismatch: \(model["id"].string!)")
                    }
                }
            } catch is CancellationError { throw CancellationError() }
            catch { modelFailure = error.localizedDescription }
            for profile in profiles where plan.allowedProfiles[model["id"].string!]!.contains(profile["id"].string!) {
                for mode in modes { for path in paths { for item in cases { for repeatIndex in 1...Int(repeats) {
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
                if item["task"] != .null && item["task"] != "transcription" && item["task"] != "dialect_transcription" && item["task"] != "standard_rendering" && item["task"] != "non_speech" { gaps.append("unsupported_output_task") }
                let derived = modelKind(model) != "pretrained"
                rows.append(["id": item["id"], "language": item["language"], "conditions": item["conditions"], "task": item["task"],
                    "coverage_role": item["coverage_role"], "source_channel": item["source_channel"],
                    "model": model["id"], "model_sha256": modelHash.map(JSONValue.string) ?? .null,
                    "artifact_metrics": artifactMetrics,
                    "model_kind": .string(modelKind(model)),
                    "baseline_model_id": derived ? model["baseline_model_id"] : model["id"],
                    "baseline_model_sha256": derived ? model["baseline_model_sha256"] : modelHash.map(JSONValue.string) ?? .null,
                    "intervention_id": derived ? model["intervention_id"] : .null,
                    "precision": model["precision"], "checkpoint": model["checkpoint"], "profile": profile["id"],
                    "profile_kind": profile["kind"], "profile_sha256": profileHashes[profile["id"].string!].map(JSONValue.string) ?? .null,
                    "effective_profile_sha256": effectiveProfileHashes[profile["id"].string!].map(JSONValue.string) ?? .null,
                    "vad_model_sha256": profileVADHashes[profile["id"].string!].map(JSONValue.string) ?? .null,
                    "runtime_settings_sha256": .string(effectiveProfileHashes[profile["id"].string!] ?? WhisperDecodingProfile.baseline.provenance["profile_sha256"].string!),
                    "whisper_binary_sha256": whisperHash.map(JSONValue.string) ?? .null,
                    "transcription_runner_sha256": (profile["kind"] == "baseline" ? baselineHash : runnerHash).map(JSONValue.string) ?? .null,
                    "threads": .integer(threads),
                    "preparation_policy": .string("\(AudioJob.Policy.version)/fast-verbatim/AVAudioConverter/\(NativeAudioPreparer.sampleRate)Hz/s16/independent-channels"),
                    "baseline_runner_sha256": baselineHash.map(JSONValue.string) ?? .null, "source_revision": profile["source_revision"], "language_mode": mode, "path": path, "repeat": .integer(Int64(repeatIndex)),
                    "source_sha256": ready.audioSHA256.map(JSONValue.string) ?? .null,
                    "reference_sha256": ready.referenceSHA256.map(JSONValue.string) ?? .null,
                    "measurement_scope": .string(scope),
                    "scoring_policy": resourcesOnly ? "unscored-resources-v1" : .string(try TranscriptAccuracy.policy(for: item, schemaVersion: corpus["schema_version"].string!).rawValue), "gaps": .array(gaps),
                    "readiness_reason": ready.reason.map(JSONValue.string) ?? .null,
                    "errors": .array(failures.map(JSONValue.string)),
                    "status": !failures.isEmpty ? "failed" : (gaps.isEmpty ? (dryRun ? "ready" : "queued") : "pending")])
            } } } } }
        }
        func persist() throws -> JSONValue {
            var report = metadata
            report["rows"] = .array(rows)
            report["repeat_summary"] = summarize(rows)
            report["paired_comparisons"] = paired(rows, specifications: plan.comparisons)
            report["quality_aggregation"] = resourcesOnly ? ["status": "UNMEASURED; resource-only probe"] : quality(rows)
            report["quality_aggregation_selection"] = resourcesOnly ? "No references read and no quality scores produced" : "Successful repeat 1 only; no fallback to later repeats. Repeated inference is not independent corpus data."
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
                        resourcesOnly: resourcesOnly, externalCheck: cancellation)
                    let result = report["results"].array!.first!
                    rows[index]["measurement"] = result
                    guard result["source_sha256"] == row["source_sha256"],
                          result["reference_sha256"] == row["reference_sha256"],
                          result["scoring_version"] == row["scoring_policy"] else {
                        throw CoreFailure("Measured source/reference/scoring identity differs from the planned comparison")
                    }
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

    static func quality(_ rows: [JSONValue]) -> JSONValue {
        let scored: [JSONValue] = rows.compactMap { row in
            guard row["repeat"] == 1, completed(row), var measurement = row["measurement"].object else { return nil }
            measurement["configuration_id"] = .string([row["model"].string!, row["profile"].string!, row["language_mode"].string!, row["path"].string!].joined(separator: "/"))
            return .object(measurement)
        }
        return TranscriptAccuracy.aggregate(scored)
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

    /// Model comparisons retain both hashes and require explicit lineage. Runtime
    /// comparisons keep the model hash fixed. Neither path pairs different inputs.
    static func paired(_ rows: [JSONValue], specifications: [JSONValue] = []) -> JSONValue {
        func identity(_ row: JSONValue) -> String {
            let fields = ["id", "language", "language_mode", "path", "source_sha256", "reference_sha256", "scoring_policy", "task"]
            return fields.map { row[$0].string ?? "unknown" }.joined(separator: "|")
                + "|\(row["source_channel"].integer.map(String.init) ?? row["source_channel"].string ?? "unknown")|\(row["repeat"].integer ?? 0)"
        }
        func measuredIdentityMatches(_ row: JSONValue) -> Bool {
            for (observed, declared) in [("source_sha256", "source_sha256"), ("reference_sha256", "reference_sha256"), ("scoring_version", "scoring_policy")] {
                let value = row["measurement"][observed]
                if value != .null && value != row[declared] { return false }
            }
            return true
        }
        func comparison(_ matches: [JSONValue]?, row: JSONValue, specification: JSONValue) -> JSONValue {
            let intervention = specification["intervention"].string ?? "runtime"
            var comparison: JSONValue = ["identity": .string(identity(row)), "candidate_profile": row["profile"],
                "id": row["id"], "task": row["task"], "repeat": row["repeat"], "language_mode": row["language_mode"],
                "measurement_scope": row["measurement_scope"],
                "path": row["path"], "source_channel": row["source_channel"],
                "candidate_model": row["model"], "candidate_model_sha256": row["model_sha256"],
                "baseline_model": specification["baseline_model_id"] == .null ? (row["baseline_model_id"] == .null ? row["model"] : row["baseline_model_id"]) : specification["baseline_model_id"],
                "baseline_profile": specification["baseline_profile_id"],
                "comparison_id": specification["id"], "intervention": .string(intervention), "intervention_id": row["intervention_id"],
                "language": row["language"], "conditions": row["conditions"], "coverage_role": row["coverage_role"],
                "pairing_contract_version": "model-lineage-v2", "status": "pending_pair"]
            guard let matches, matches.count == 1,
                  let control = matches.first, completed(control), completed(row), control["measurement"]["wall_seconds"].double != nil,
                  row["measurement"]["wall_seconds"].double != nil,
                  measuredIdentityMatches(control), measuredIdentityMatches(row) else { return comparison }
            comparison["baseline_model"] = control["model"]
            comparison["baseline_model_sha256"] = control["model_sha256"]
            comparison["baseline_profile"] = control["profile"]
            comparison["baseline_artifact_metrics"] = control["artifact_metrics"]
            comparison["candidate_artifact_metrics"] = row["artifact_metrics"]
            for field in ["whisper_binary_sha256", "threads", "preparation_policy"] where control[field] != row[field] {
                comparison["reason"] = .string("Shared execution identity differs: \(field)")
                return comparison
            }
            if intervention == "runtime" {
                guard control["model"] == row["model"], control["model_sha256"] == row["model_sha256"] else {
                    comparison["reason"] = "Runtime comparison changes model identity"
                    return comparison
                }
            } else {
                guard row["baseline_model_id"] == control["model"], row["baseline_model_sha256"] == control["model_sha256"],
                      row["model_kind"] == .string(intervention), row["model"] != control["model"] else {
                    comparison["reason"] = "Model comparison does not match the retained parent artifact"
                    return comparison
                }
                if intervention != "combined" {
                    for field in ["runtime_settings_sha256", "vad_model_sha256", "transcription_runner_sha256"] where control[field] != row[field] {
                        comparison["reason"] = .string("Isolated model comparison changes runtime identity: \(field)")
                        return comparison
                    }
                    guard control["profile"] == row["profile"], control["runtime_settings_sha256"].string != nil,
                          control["transcription_runner_sha256"].string != nil, control["whisper_binary_sha256"].string != nil,
                          control["threads"].integer != nil, control["preparation_policy"].string != nil else {
                        comparison["reason"] = "Isolated model comparison lacks a shared verified execution identity"
                        return comparison
                    }
                }
            }
            comparison["status"] = "paired_exploratory"
            if let before = control["measurement"]["hypothesis_sha256"].string,
               let after = row["measurement"]["hypothesis_sha256"].string {
                comparison["hypothesis_exact_match"] = .bool(before == after)
            }
            for metric in ["wer", "cer", "word_insertions", "word_deletions", "character_insertions", "false_speech_characters", "wall_seconds", "real_time_factor", "peak_rss_bytes"] {
                if let before = control["measurement"][metric].double, let after = row["measurement"][metric].double {
                    comparison[metric + "_delta"] = .number(after - before)
                }
            }
            for metric in ["model_file_bytes", "filesystem_allocated_bytes", "download_artifact_bytes", "incremental_bundle_bytes"] {
                if let before = control["artifact_metrics"][metric].integer, let after = row["artifact_metrics"][metric].integer {
                    comparison[metric + "_delta"] = .integer(after - before)
                }
            }
            comparison["critical_content_review"] = "unmeasured"
            return comparison
        }
        if specifications.isEmpty {
            let controls = Dictionary(grouping: rows.filter { $0["profile_kind"] == "baseline" }, by: identity)
            return .array(rows.filter { $0["profile_kind"] == "candidate" }.map { row in
                let matches = controls[identity(row)]?.filter { $0["model"] == row["model"] && $0["model_sha256"] == row["model_sha256"] }
                return comparison(matches, row: row, specification: ["intervention": "runtime"])
            })
        }
        var values: [JSONValue] = []
        for specification in specifications {
            let controls = Dictionary(grouping: rows.filter {
                $0["model"] == specification["baseline_model_id"] && $0["profile"] == specification["baseline_profile_id"]
            }, by: identity)
            for row in rows where row["model"] == specification["candidate_model_id"] && row["profile"] == specification["candidate_profile_id"] {
                values.append(comparison(controls[identity(row)], row: row, specification: specification))
            }
        }
        return .array(values)
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
