import Darwin
import Foundation

/// Engine-independent lexical scores. These do not measure speaker or semantic accuracy.
public enum TranscriptAccuracy {
    static func normalized(_ text: String) -> String {
        let folded = text.precomposedStringWithCanonicalMapping.folding(options: .caseInsensitive, locale: Locale(identifier: "en_US_POSIX"))
        return String(String.UnicodeScalarView(folded.unicodeScalars.map {
            CharacterSet.alphanumerics.contains($0) || $0 == "_" ? $0 : " "
        })).split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    static func distance<T: Equatable>(_ reference: [T], _ hypothesis: [T]) -> Int {
        var previous = Array(0...hypothesis.count)
        for (i, token) in reference.enumerated() {
            var current = [i + 1]
            for (j, other) in hypothesis.enumerated() {
                current.append(min(current[j] + 1, previous[j + 1] + 1, previous[j] + (token == other ? 0 : 1)))
            }
            previous = current
        }
        return previous.last!
    }

    public static func score(reference: String, hypothesis: String) -> JSONValue {
        let ref = normalized(reference), hyp = normalized(hypothesis)
        let words = ref.split(separator: " "), chars = Array(ref.unicodeScalars.filter { $0 != " " })
        let wordErrors = distance(words, hyp.split(separator: " "))
        let charErrors = distance(chars, Array(hyp.unicodeScalars.filter { $0 != " " }))
        return ["wer": words.isEmpty ? nil : .number(Double(wordErrors) / Double(words.count)),
            "cer": chars.isEmpty ? nil : .number(Double(charErrors) / Double(chars.count)),
            "word_errors": .integer(Int64(wordErrors)), "reference_words": .integer(Int64(words.count)),
            "character_errors": .integer(Int64(charErrors)), "reference_characters": .integer(Int64(chars.count)),
            "false_speech_words": words.isEmpty ? .integer(Int64(hyp.split(separator: " ").count)) : nil,
            "normalization": "swift-nfc-casefold-alphanumeric-v1; punctuation to spaces, collapsed whitespace; CER omits spaces"]
    }
}

/// Each measured case launches the native CLI in a fresh process. No downloads or providers.
public enum CorpusBenchmark {
    public enum Policy { public static let caseTimeout: TimeInterval = 86_400 }
    public static func run(manifest: URL, output: URL, cli: URL, whisper: URL?, model: URL?,
                           threads: Int, dryRun: Bool, timeout: TimeInterval = Policy.caseTimeout) throws -> JSONValue {
        guard NativeWhisperEngine.Policy.threadRange.contains(threads), timeout > 0 else {
            throw CoreFailure("Choose a supported thread budget and positive case timeout")
        }
        let data = try Data(contentsOf: manifest)
        let document = try JSONDecoder().decode(JSONValue.self, from: data)
        guard document["schema_version"] == "1.0", let cases = document["cases"].array else {
            throw CoreFailure("Expected corpus schema_version 1.0 and cases array")
        }
        var ids = Set<String>()
        for item in cases {
            guard let id = item["id"].string, !id.isEmpty, id.range(of: "^[a-zA-Z0-9_-]+$", options: .regularExpression) != nil,
                  ids.insert(id).inserted, item["category"].string != nil else {
                throw CoreFailure("Corpus cases need unique safe IDs and a category")
            }
        }
        try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard mkdir(output.path, 0o700) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        var results: [JSONValue] = []
        func persist() throws -> JSONValue {
            #if arch(arm64)
            let architecture = "arm64"
            #elseif arch(x86_64)
            let architecture = "x86_64"
            #else
            let architecture = "unknown"
            #endif
            let report: JSONValue = ["schema_version": "1.0", "manifest_sha256": .string(TextJob.hash(data)),
                "machine": ["os": .string(ProcessInfo.processInfo.operatingSystemVersionString),
                            "architecture": .string(architecture),
                            "processors": .integer(Int64(ProcessInfo.processInfo.processorCount))],
                "results": .array(results)]
            try TextJob.write(report.encoded(), named: "results.json", in: output)
            return report
        }
        for item in cases {
            let id = item["id"].string!
            let job = output.appendingPathComponent(id)
            var row: JSONValue = ["id": .string(id), "category": item["category"], "status": "pending_corpus"]
            let check: @Sendable () throws -> Void = {
                if Task.isCancelled || FileManager.default.fileExists(atPath: output.appendingPathComponent("cancel.request").path) {
                    if FileManager.default.fileExists(atPath: job.path) {
                        try Data().write(to: job.appendingPathComponent("cancel.request"))
                    }
                    throw CancellationError()
                }
            }
            do {
                try check()
                if let audio = item["audio"].string, let reference = item["reference"].string,
                   let digest = item["sha256"].string, !(item["license"].string ?? "").isEmpty {
                    func resolve(_ path: String) -> URL {
                        path.hasPrefix("/") ? URL(fileURLWithPath: path) : manifest.deletingLastPathComponent().appendingPathComponent(path).standardizedFileURL
                    }
                    let source = resolve(audio), truth = resolve(reference)
                    if FileManager.default.fileExists(atPath: source.path), FileManager.default.fileExists(atPath: truth.path) {
                        guard try WAVAudio.hash(source, check: check) == digest else { throw CoreFailure("Audio checksum mismatch: \(id)") }
                        if dryRun { row["status"] = "ready" }
                        else {
                            guard let whisper, let model else { throw CoreFailure("A measured run requires --whisper-cli and --model") }
                            let timing = output.appendingPathComponent("\(id).time.txt")
                            let started = ContinuousClock.now
                            _ = try AudioChildProcess.run(URL(fileURLWithPath: "/usr/bin/time"),
                                ["-l", "-o", timing.path, cli.path, "transcribe", source.path, "--output", job.path,
                                 "--source-language", item["language"].string ?? "auto", "--whisper-cli", whisper.path,
                                 "--model", model.path, "--threads", String(threads), "--local-only"],
                                directory: output, log: output.appendingPathComponent("\(id).log"), timeout: timeout, check: check)
                            let elapsed = started.duration(to: .now)
                            let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
                            let transcript = try CanonicalTranscript(JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: job.appendingPathComponent("transcript.json"))))
                            let value = transcript.value
                            let hypothesis = (value["segments"].array ?? []).compactMap { $0["source_text"].string }.joined(separator: " ")
                            row = .object((row.object ?? [:]).merging(TranscriptAccuracy.score(reference: try String(contentsOf: truth, encoding: .utf8), hypothesis: hypothesis).object ?? [:]) { _, new in new })
                            let timingText = try String(contentsOf: timing, encoding: .utf8)
                            let rss = timingText.split(separator: "\n").first { $0.contains("maximum resident set size") }?.split(whereSeparator: \.isWhitespace).first.flatMap { Int64($0) }
                            let duration = value["source"]["duration_ms"].double ?? 0
                            row["status"] = value["status"]; row["wall_seconds"] = .number(seconds)
                            row["real_time_factor"] = duration > 0 ? .number(seconds / (duration / 1000)) : nil
                            row["peak_rss_bytes"] = rss.map(JSONValue.integer) ?? .null
                            row["memory_method"] = "macOS time -l; maximum process RSS, not summed concurrent memory"
                            row["source_sha256"] = .string(digest); row["reference_sha256"] = .string(try WAVAudio.hash(truth, check: check))
                            row["engine_passes"] = value["processing"]["engine_passes"]
                            row["threads"] = .integer(Int64(threads))
                            row["reviewed_segments"] = .integer(Int64((value["segments"].array ?? []).filter { $0["needs_review"] == true }.count))
                        }
                    }
                }
            } catch is CancellationError {
                row["status"] = "cancelled"; results.append(row); _ = try persist(); throw CancellationError()
            } catch {
                // time(1) may exit before its child on failure/timeout. The native job
                // observes this marker and stops its own ASR process cooperatively.
                if FileManager.default.fileExists(atPath: job.path) {
                    try? Data().write(to: job.appendingPathComponent("cancel.request"))
                }
                row["status"] = "failed"; row["error"] = .string(error.localizedDescription)
            }
            results.append(row); _ = try persist()
        }
        let report = try persist()
        guard !results.contains(where: { $0["status"] == "failed" }) else { throw CoreFailure("Benchmark cases failed; inspect results.json and retained logs") }
        return report
    }
}
