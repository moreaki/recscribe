import Foundation

public struct NativeWhisperEngine: TranscriptEngine {
    public let binary: URL
    public let model: URL
    let vad: URL?
    public let threads: Int
    public let metadata: JSONValue
    let versionOutput: String
    private static let markers: Set<String> = ["[blank_audio]", "[silence]", "[no_speech]"]

    public enum Policy {
        public static let threadRange = 1...4
        public static let defaultThreads = 2
    }
    public init(binary: URL, model: URL, vad: URL? = nil, threads: Int = Policy.defaultThreads,
                check: @Sendable () throws -> Void = { try Task.checkCancellation() }) throws {
        guard Policy.threadRange.contains(threads) else { throw CoreFailure("Choose 1–4 transcription threads") }
        guard FileManager.default.isExecutableFile(atPath: binary.path), FileManager.default.isReadableFile(atPath: model.path) else {
            throw CoreFailure("Choose an installed whisper-cli and local model in Settings → Models")
        }
        try WhisperVAD.validate(vad?.path ?? "")
        self.binary = binary; self.model = model; self.vad = vad; self.threads = threads
        versionOutput = try AudioChildProcess.run(binary, ["--version"], directory: FileManager.default.temporaryDirectory,
                                                     timeout: AudioChildProcess.versionTimeout, check: check)
        let prefix = "whisper.cpp version:"
        let version = versionOutput.split(separator: "\n").first(where: { $0.contains(prefix) })
            .flatMap { $0.components(separatedBy: prefix).last?.split(whereSeparator: \.isWhitespace).first.map(String.init) }
        metadata = ["engine": "whisper.cpp", "version": .string(version ?? "unknown; see version log"),
            "binary_sha256": .string(try WAVAudio.hash(binary, check: check)), "model": .string(model.lastPathComponent),
            "model_sha256": .string(try WAVAudio.hash(model, check: check)),
            "vad_model_sha256": try vad.map { .string(try WAVAudio.hash($0, check: check)) } ?? .null, "local_only": true]
    }

    public func transcribe(_ audio: URL, output: URL, language: String,
                    check: @Sendable () throws -> Void) throws -> AudioEngineResult {
        try check()
        let raw = output.appendingPathExtension("json")
        guard !FileManager.default.fileExists(atPath: raw.path) else { throw CoreFailure("Refusing to overwrite raw ASR evidence") }
        let configured = language.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = configured.split(separator: "-", maxSplits: 1).first.map { $0.lowercased() } ?? "auto"
        var arguments = ["-m", model.path, "-f", audio.path, "-l", base, "-ojf", "-of", output.path,
                         "-t", String(threads), "-tp", "0", "-mc", "0"]
        if let vad { arguments += ["--vad", "-vm", vad.path] }
        try Data(versionOutput.utf8).write(to: output.appendingPathExtension("version.log"), options: .withoutOverwriting)
        let started = ContinuousClock.now
        _ = try AudioChildProcess.run(binary, arguments, directory: output.deletingLastPathComponent(),
                                     log: output.appendingPathExtension("log"), timeout: AudioChildProcess.recognitionTimeout, check: check)
        let (response, segments) = try Self.read(raw)
        var provenance = metadata
        provenance["asr_language"] = .string(base)
        provenance["detected_language"] = response["result"]["language"]
        provenance["command"] = .array(([binary.path] + arguments).map(JSONValue.string))
        provenance["duration_seconds"] = .number(TextJob.seconds(since: started))
        return AudioEngineResult(segments: segments, rawPath: raw, provenance: provenance)
    }

    public static func parse(_ raw: URL) throws -> [JSONValue] {
        try read(raw).1
    }

    private static func read(_ raw: URL) throws -> (JSONValue, [JSONValue]) {
        let file = try FileHandle(forReadingFrom: raw)
        defer { try? file.close() }
        let data = try file.read(upToCount: TextJob.maximumTranscriptBytes + 1) ?? Data()
        guard data.count <= TextJob.maximumTranscriptBytes else { throw CoreFailure("Whisper output exceeds the transcript size limit") }
        let value = try JSONDecoder().decode(JSONValue.self, from: data)
        guard let entries = value["transcription"].array else { throw CoreFailure("Unsupported Whisper output") }
        let segments: [JSONValue] = try entries.compactMap { entry in
            guard let start = entry["offsets"]["from"].integer, let end = entry["offsets"]["to"].integer,
                  let text = entry["text"].string, start >= 0, end >= start else { throw CoreFailure("Invalid Whisper timestamps or speech") }
            if end == start && (text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || markers.contains(text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())) { return nil }
            // Canonical v1 requires a real interval. Preserve raw words and fail
            // visibly rather than invent a duration or discard untimed speech.
            guard end > start else { throw CoreFailure("Speech has no duration; raw output retained for timing review") }
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return ["start_ms": .integer(start), "end_ms": .integer(end), "source_text": .string(text),
                    "confidence": nil, "speaker": nil, "words": []]
        }
        return (value, segments)
    }
}
