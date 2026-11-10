import Foundation

/// Observations only: no inferred GPU allocation, cold-cache status or first-token latency.
public enum WhisperBenchmarkMetrics {
    public static let timingVersion = "whisper-cpp-print-timings-v1"

    public static func artifact(_ model: URL, download: URL? = nil,
                                check: @Sendable () throws -> Void = { try Task.checkCancellation() }) throws -> JSONValue {
        try check()
        let values = try model.resourceValues(forKeys: [.fileSizeKey, .fileAllocatedSizeKey, .isRegularFileKey])
        guard values.isRegularFile == true, let size = values.fileSize else {
            throw CoreFailure("Model artifact must be a regular local file")
        }
        var result: JSONValue = ["model_file_bytes": .integer(Int64(size)),
            "filesystem_allocated_bytes": values.fileAllocatedSize.map { .integer(Int64($0)) } ?? .null,
            "download_artifact_bytes": nil, "incremental_bundle_bytes": nil,
            "bundle_size_status": "unmeasured; no candidate app bundle assembled",
            "parameter_count": nil, "parameter_count_status": "requires inspected tensor inventory"]
        if let download {
            let compressed = try download.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            guard compressed.isRegularFile == true, let bytes = compressed.fileSize else {
                throw CoreFailure("Download artifact must be a regular local file")
            }
            result["download_artifact_bytes"] = .integer(Int64(bytes))
            result["download_artifact_sha256"] = .string(try WAVAudio.hash(download, check: check))
        }
        return result
    }

    /// Upstream timers are retained individually; overlapping phases are never summed/subtracted.
    /// The pinned format is emitted by whisper_print_timings in whisper.cpp 1.9.5.
    public static func timings(log: String) -> JSONValue {
        let expression = try! NSRegularExpression(pattern:
            #"^whisper_print_timings:\s+(load|mel|sample|encode|decode|batchd|prompt|total) time\s*=\s*([0-9]+(?:\.[0-9]+)?) ms(?:\s*/\s*([0-9]+) runs)?(?:\s*\(\s*[0-9.]+ ms per run\))?\s*$"#)
        var observations: [String: [JSONValue]] = [:]
        for line in log.split(separator: "\n") {
            let text = String(line)
            let range = NSRange(text.startIndex..<text.endIndex, in: text)
            guard let match = expression.firstMatch(in: text, range: range),
                  let nameRange = Range(match.range(at: 1), in: text),
                  let valueRange = Range(match.range(at: 2), in: text),
                  let milliseconds = Double(text[valueRange]), milliseconds.isFinite else { continue }
            let key = String(text[nameRange])
            var observation: JSONValue = ["seconds": .number(milliseconds / 1_000)]
            if let runRange = Range(match.range(at: 3), in: text), let runs = Int64(text[runRange]) {
                observation["runs"] = .integer(runs)
            }
            observations[key, default: []].append(observation)
        }
        return ["parser_version": .string(timingVersion),
            "observations": .object(observations.mapValues(JSONValue.array)),
            "status": observations.isEmpty ? "unavailable; retain raw log" : "observed upstream timers",
            "model_load_scope": "upstream model-load timer; not total process initialization",
            "first_result_latency_seconds": nil,
            "first_result_latency_status": "unobserved; file-output CLI does not expose first-token events",
            "total_unified_gpu_memory_bytes": nil]
    }

    /// Read logs retained by both the original control CLI and current adapter.
    /// Only commands rooted in this job are eligible; no arbitrary path is followed.
    public static func retainedPasses(_ value: JSONValue, job: URL,
                                     check: @Sendable () throws -> Void = { try Task.checkCancellation() }) throws -> JSONValue {
        var results: [JSONValue] = []
        func visit(_ value: JSONValue) throws {
            try check()
            if let object = value.object {
                if let command = value["command"].array?.compactMap(\.string),
                   let position = command.firstIndex(of: "-of"), position + 1 < command.count {
                    let logURL = URL(fileURLWithPath: command[position + 1]).appendingPathExtension("log").resolvingSymlinksInPath()
                    let root = job.resolvingSymlinksInPath().path + "/"
                    guard logURL.path.hasPrefix(root) else { throw CoreFailure("Engine log escapes its benchmark job") }
                    var metrics: JSONValue = ["log": .string(String(logURL.path.dropFirst(root.count))),
                        "native_invocation_wall_seconds": value["duration_seconds"]]
                    if FileManager.default.isReadableFile(atPath: logURL.path) {
                        let file = try FileHandle(forReadingFrom: logURL); defer { try? file.close() }
                        let bytes = try file.read(upToCount: 256 * 1_024 + 1) ?? Data()
                        guard bytes.count <= 256 * 1_024 else { throw CoreFailure("Retained timing log exceeds its bounded limit") }
                        metrics["runtime_timings"] = timings(log: String(decoding: bytes, as: UTF8.self))
                    } else { metrics["runtime_timings"] = ["status": "unavailable; raw job evidence retained"] }
                    results.append(metrics)
                }
                for child in object.values { try visit(child) }
            } else if let values = value.array { for child in values { try visit(child) } }
        }
        try visit(value)
        return .array(results)
    }
}
