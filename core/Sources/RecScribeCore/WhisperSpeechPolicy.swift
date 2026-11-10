import Foundation

/// Opt-in Silero processing in whisper.cpp. It changes only the derived input
/// processed by the recognizer; RecScribe never removes captured source frames.
public struct WhisperSpeechPolicy: Sendable, Equatable {
    public enum Mode: String, Sendable { case none, silero }
    public let mode: Mode
    public let model: URL?
    public let threshold: Double
    public let minimumSpeechMilliseconds: Int
    public let minimumSilenceMilliseconds: Int
    public let maximumSpeechSeconds: Double
    public let paddingMilliseconds: Int
    public let overlapSeconds: Double

    public static let none = try! WhisperSpeechPolicy(json: ["mode": "none"])
    public var isBaseline: Bool { mode == .none }

    public init(json: JSONValue) throws {
        let allowed: Set<String> = ["mode", "vad_model", "threshold", "min_speech_ms", "min_silence_ms", "max_speech_seconds", "padding_ms", "overlap_seconds"]
        guard let values = json.object, Set(values.keys).isSubset(of: allowed),
              let mode = Mode(rawValue: json["mode"].string ?? "") else {
            throw CoreFailure("Speech policy must be none or silero with supported explicit parameters")
        }
        if mode == .none, values.keys.contains(where: { $0 != "mode" }) {
            throw CoreFailure("No-VAD control does not accept speech-processing parameters")
        }
        func number(_ key: String, _ fallback: Double, range: ClosedRange<Double>) throws -> Double {
            guard let value = values[key] else { return fallback }
            guard let result = value.double, result.isFinite, range.contains(result) else {
                throw CoreFailure("Speech parameter \(key) is outside its supported bounds")
            }
            return result
        }
        func integer(_ key: String, _ fallback: Int, range: ClosedRange<Int>) throws -> Int {
            guard let value = values[key] else { return fallback }
            guard let result = value.integer, result >= Int64(range.lowerBound), result <= Int64(range.upperBound) else {
                throw CoreFailure("Speech parameter \(key) must be an integer within its supported bounds")
            }
            return Int(result)
        }
        self.mode = mode
        if let path = values["vad_model"] {
            guard let text = path.string, text.hasPrefix("/"), !text.contains("\0") else {
                throw CoreFailure("Use an absolute local Silero model path in the private speech profile")
            }
            model = URL(fileURLWithPath: text).standardizedFileURL
        } else { model = nil }
        threshold = try number("threshold", 0.5, range: 0.05...0.95)
        minimumSpeechMilliseconds = try integer("min_speech_ms", 250, range: 0...2_000)
        minimumSilenceMilliseconds = try integer("min_silence_ms", 100, range: 20...2_000)
        maximumSpeechSeconds = try number("max_speech_seconds", 30, range: 1...60)
        paddingMilliseconds = try integer("padding_ms", 30, range: 0...1_000)
        overlapSeconds = try number("overlap_seconds", 0.1, range: 0...1)
        guard Double(minimumSpeechMilliseconds + 2 * paddingMilliseconds) < maximumSpeechSeconds * 1_000 else {
            throw CoreFailure("Speech padding/minimum duration must fit within the maximum speech window")
        }
    }

    public var json: JSONValue {
        guard mode == .silero else { return ["mode": "none"] }
        var value: JSONValue = ["mode": "silero", "threshold": .number(threshold),
            "min_speech_ms": .integer(Int64(minimumSpeechMilliseconds)), "min_silence_ms": .integer(Int64(minimumSilenceMilliseconds)),
            "max_speech_seconds": .number(maximumSpeechSeconds), "padding_ms": .integer(Int64(paddingMilliseconds)),
            "overlap_seconds": .number(overlapSeconds)]
        if let model { value["vad_model"] = .string(model.path) }
        return value
    }

    private func selectedModel(_ fallback: URL?) throws -> URL? {
        if let model, let fallback,
           model.resolvingSymlinksInPath() != fallback.standardizedFileURL.resolvingSymlinksInPath() {
            throw CoreFailure("Speech profile and selected VAD model disagree; select one explicit model")
        }
        let selected = model ?? fallback
        guard isBaseline || selected != nil else {
            throw CoreFailure("Silero speech processing requires a local VAD model; the no-VAD control remains available")
        }
        return selected
    }

    public func validateModel(fallback: URL?) throws {
        guard !isBaseline else { return }
        if let selected = try selectedModel(fallback) {
            guard FileManager.default.isReadableFile(atPath: selected.path) else {
                throw CoreFailure("Selected Silero VAD model is missing or unreadable; choose a local VAD model or the no-VAD control")
            }
            try WhisperVAD.validate(selected.path)
        }
    }

    /// Fail before inference if a configured runtime lacks an experiment flag.
    /// This is feature detection, not a guessed mapping from a version number.
    public func validate(help: String) throws {
        guard !isBaseline else { return }
        for flag in ["--vad", "--vad-model", "--vad-threshold", "--vad-min-speech-duration-ms", "--vad-min-silence-duration-ms", "--vad-max-speech-duration-s", "--vad-speech-pad-ms", "--vad-samples-overlap"] {
            guard help.split(whereSeparator: \.isWhitespace).contains(Substring(flag)) else {
                throw CoreFailure("Installed whisper-cli does not advertise required speech option \(flag)")
            }
        }
    }

    public func arguments(vad: URL?) throws -> [String] {
        guard !isBaseline, let selected = try selectedModel(vad) else { return [] }
        return ["--vad", "--vad-model", selected.path, "--vad-threshold", String(threshold),
            "--vad-min-speech-duration-ms", String(minimumSpeechMilliseconds),
            "--vad-min-silence-duration-ms", String(minimumSilenceMilliseconds),
            "--vad-max-speech-duration-s", String(maximumSpeechSeconds),
            "--vad-speech-pad-ms", String(paddingMilliseconds), "--vad-samples-overlap", String(overlapSeconds)]
    }

    public var evidence: JSONValue {
        ["configuration": json, "source_audio_modified": false,
         "boundary_method": isBaseline ? "fixed_input; no additional VAD boundary processing" : "upstream Silero padding and timestamp mapping",
         "rejected_regions": nil, "rejected_regions_status": "unavailable_in_whisper_cli_json; retain private raw process log",
         "vad_probabilities": nil, "uncertain_detection_is_silence": false,
         "timing_limit": "Recognizer offsets use milliseconds; upstream VAD maps to original input time; no word alignment is inferred"]
    }
}
