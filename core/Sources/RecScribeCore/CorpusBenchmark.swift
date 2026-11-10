import Darwin
import Foundation

/// Each measured case launches the native CLI in a fresh process. No downloads or providers.
public enum CorpusBenchmark {
    public enum Policy {
        public static let caseTimeout: TimeInterval = 86_400
    }

    public static func run(
        manifest: URL,
        output: URL,
        cli: URL,
        whisper: URL?,
        model: URL?,
        threads: Int,
        dryRun: Bool,
        timeout: TimeInterval = Policy.caseTimeout,
        sourceLanguage: String? = nil,
        caseIDs: Set<String>? = nil,
        whisperProfile: URL? = nil,
        resourcesOnly: Bool = false,
        externalCheck: @escaping @Sendable () throws -> Void = { try Task.checkCancellation() }
    ) throws -> JSONValue {
        guard NativeWhisperEngine.Policy.threadRange.contains(threads), timeout > 0 else {
            throw CoreFailure("Choose a supported thread budget and positive case timeout")
        }
        let data = try read(manifest, maximum: 4 * 1_024 * 1_024)
        let document = try JSONDecoder().decode(JSONValue.self, from: data)
        let allCases = try CorpusManifest.validate(document)
        let cases = allCases.filter { caseIDs == nil || caseIDs!.contains($0["id"].string!) }
        if let caseIDs, Set(cases.compactMap { $0["id"].string }) != caseIDs {
            throw CoreFailure("Unknown benchmark case selection")
        }
        try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard mkdir(output.path, 0o700) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }

        let runnerHash = try WAVAudio.hash(cli, check: externalCheck)
        var results: [JSONValue] = []
        func persist() throws -> JSONValue {
            #if arch(arm64)
            let architecture = "arm64"
            #elseif arch(x86_64)
            let architecture = "x86_64"
            #else
            let architecture = "unknown"
            #endif
            let report: JSONValue = [
                "schema_version": "1.0",
                "manifest_sha256": .string(TextJob.hash(data)),
                "corpus_version": document["corpus_version"],
                "measurement_scope": resourcesOnly ? "resources_only" : "quality_and_resources",
                "runner_sha256": .string(runnerHash),
                "machine": [
                    "os": .string(ProcessInfo.processInfo.operatingSystemVersionString),
                    "architecture": .string(architecture),
                    "processors": .integer(Int64(ProcessInfo.processInfo.processorCount))
                ],
                "results": .array(results),
                "aggregation": resourcesOnly ? ["status": "UNMEASURED; resource-only probe"] : TranscriptAccuracy.aggregate(results)
            ]
            try TextJob.write(report.encoded(), named: "results.json", in: output)
            return report
        }

        for item in cases {
            let id = item["id"].string!
            let job = output.appendingPathComponent(id)
            var row: JSONValue = [
                "id": .string(id),
                "category": item["category"],
                "language": item["language"], "conditions": item["conditions"],
                "task": item["task"], "split": item["split"],
                "status": "pending_corpus"
            ]
            let check: @Sendable () throws -> Void = {
                try externalCheck()
                let cancelMarker = output.appendingPathComponent("cancel.request").path
                if Task.isCancelled || FileManager.default.fileExists(atPath: cancelMarker) {
                    if FileManager.default.fileExists(atPath: job.path) {
                        try Data().write(to: job.appendingPathComponent("cancel.request"))
                    }
                    throw CancellationError()
                }
            }
            do {
                try check()
                let eligibility = try resourcesOnly ? CorpusManifest.resourceEligibility(item, manifest: manifest, check: check) :
                    CorpusManifest.eligibility(item, manifest: manifest, schemaVersion: document["schema_version"].string!, check: check)
                row["status"] = .string(eligibility.status)
                row["readiness_reason"] = eligibility.reason.map(JSONValue.string) ?? .null
                if let source = eligibility.audio, eligibility.status == "ready", resourcesOnly || eligibility.reference != nil {
                        if dryRun {
                            row["status"] = "ready"
                        } else {
                            guard let whisper, let model else {
                                throw CoreFailure("A measured run requires --whisper-cli and --model")
                            }
                            row["artifact_metrics"] = try WhisperBenchmarkMetrics.artifact(model, check: check)
                            let timing = output.appendingPathComponent("\(id).time.txt")
                            let started = ContinuousClock.now
                            var command = [
                                "-l", "-o", timing.path, cli.path, "transcribe", source.path,
                                "--output", job.path,
                                "--source-language", sourceLanguage ?? item["language"].string ?? "auto",
                                "--whisper-cli", whisper.path, "--model", model.path,
                                "--threads", String(threads), "--local-only"
                            ]
                            if let whisperProfile { command += ["--whisper-profile", whisperProfile.path] }
                            row["command"] = .array((["/usr/bin/time"] + command).map(JSONValue.string))
                            _ = try AudioChildProcess.run(
                                URL(fileURLWithPath: "/usr/bin/time"),
                                command,
                                directory: output,
                                log: output.appendingPathComponent("\(id).log"),
                                timeout: timeout,
                                check: check
                            )
                            let elapsed = started.duration(to: .now)
                            let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
                            let transcriptData = try read(job.appendingPathComponent("transcript.json"), maximum: TextJob.maximumTranscriptBytes)
                            let transcript = try CanonicalTranscript(JSONDecoder().decode(JSONValue.self, from: transcriptData))
                            let value = transcript.value
                            let selectedChannel = value["source"]["channels_bit_identical"] == true ? JSONValue.integer(0) : item["source_channel"]
                            let selected = (value["segments"].array ?? []).filter { item["source_channel"].integer == nil || $0["channel"] == selectedChannel }
                            let hypothesis = selected.compactMap { $0["source_text"].string }.joined(separator: " ")
                            let timingText = try String(contentsOf: timing, encoding: .utf8)
                            let rss = timingText.split(separator: "\n")
                                .first { $0.contains("maximum resident set size") }?
                                .split(whereSeparator: \.isWhitespace)
                                .first
                                .flatMap { Int64($0) }
                            let duration = value["source"]["duration_ms"].double ?? 0
                            row["status"] = value["status"]
                            row["wall_seconds"] = .number(seconds)
                            row["real_time_factor"] = duration > 0 ? .number(seconds / (duration / 1000)) : nil
                            row["source_audio_seconds"] = duration > 0 ? .number(duration / 1_000) : nil
                            row["end_to_end_audio_seconds_per_second"] = duration > 0 && seconds > 0 ? .number(duration / 1_000 / seconds) : nil
                            row["peak_rss_bytes"] = rss.map(JSONValue.integer) ?? .null
                            row["hypothesis_sha256"] = .string(TextJob.hash(Data(hypothesis.utf8)))
                            row["memory_method"] = "macOS time -l; maximum process RSS, not summed concurrent memory"
                            row["source_sha256"] = eligibility.audioSHA256.map(JSONValue.string) ?? .null
                            row["reference_sha256"] = eligibility.referenceSHA256.map(JSONValue.string) ?? .null
                            row["engine_passes"] = value["processing"]["engine_passes"]
                            row["engine_runtime_measurements"] = try WhisperBenchmarkMetrics.retainedPasses(value["processing"]["engine_passes"], job: job, check: check)
                            row["threads"] = .integer(Int64(threads))
                            if resourcesOnly {
                                guard try WAVAudio.hash(source, check: check) == eligibility.audioSHA256 else {
                                    throw CoreFailure("Resource input changed during recognition")
                                }
                                row["measurement_scope"] = "resources_only"
                                row["quality_status"] = "UNMEASURED; resource-only probe, references were not read"
                                row["scoring_version"] = "unscored-resources-v1"
                            } else {
                                let referenceData = try read(eligibility.reference!, maximum: TranscriptAccuracy.maximumScoringTextBytes)
                                guard TextJob.hash(referenceData) == eligibility.referenceSHA256,
                                      try WAVAudio.hash(source, check: check) == eligibility.audioSHA256,
                                      let referenceText = String(data: referenceData, encoding: .utf8) else {
                                    throw CoreFailure("Corpus input changed during recognition or reference is not UTF-8")
                                }
                                let score = try TranscriptAccuracy.checkedScore(reference: referenceText, hypothesis: hypothesis,
                                    policy: try TranscriptAccuracy.policy(for: item, schemaVersion: document["schema_version"].string!),
                                    durationSeconds: duration > 0 ? duration / 1_000 : nil, check: check)
                                row = .object((row.object ?? [:]).merging(score.object ?? [:]) { _, new in new })
                            }
                            let reviewedCount = (value["segments"].array ?? []).filter { $0["needs_review"] == true }.count
                            row["reviewed_segments"] = .integer(Int64(reviewedCount))
                        }
                }
            } catch is CancellationError {
                row["status"] = "cancelled"
                results.append(row)
                _ = try persist()
                throw CancellationError()
            } catch {
                if FileManager.default.fileExists(atPath: job.path) {
                    try? Data().write(to: job.appendingPathComponent("cancel.request"))
                }
                row["status"] = "failed"
                row["error"] = .string(error.localizedDescription)
            }
            results.append(row)
            _ = try persist()
        }
        let report = try persist()
        guard !results.contains(where: { $0["status"] == "failed" }) else {
            throw CoreFailure("Benchmark cases failed; inspect results.json and retained logs")
        }
        return report
    }

    private static func read(_ url: URL, maximum: Int) throws -> Data {
        let file = try FileHandle(forReadingFrom: url); defer { try? file.close() }
        let bytes = try file.read(upToCount: maximum + 1) ?? Data()
        guard bytes.count <= maximum else { throw CoreFailure("Benchmark input exceeds its bounded size limit") }
        return bytes
    }
}
