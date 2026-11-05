import Foundation

/// An opt-in, local experiment. Missing settings retain the original command,
/// including upstream search/fallback defaults; they do not imply greedy search.
/// A profile is immutable and carries no text state between sources or channels.
public struct WhisperDecodingProfile: Sendable, Equatable {
    public static let schemaVersion = "1.0"
    public static let maximumTerminologyBytes = 1_024
    public static let maximumContextTokens = 224
    public let beamSize: Int?
    public let bestOf: Int?
    public let temperature: Double
    public let temperatureIncrement: Double?
    public let noFallback: Bool
    public let contextTokens: Int
    public let terminology: String?
    public let speech: WhisperSpeechPolicy
    public let languagePolicy: WhisperLanguagePolicy

    public static let baseline = try! WhisperDecodingProfile(json: ["schema_version": "1.0"])

    public init(json: JSONValue) throws {
        let keys: Set<String> = ["schema_version", "beam_size", "best_of", "temperature", "temperature_increment",
                                 "no_fallback", "context_tokens", "terminology", "speech", "language_policy"]
        guard let values = json.object, Set(values.keys).isSubset(of: keys),
              json["schema_version"] == .string(Self.schemaVersion) else {
            throw CoreFailure("Expected Whisper profile schema_version 1.0 with supported settings")
        }
        func integer(_ key: String, default fallback: Int? = nil, range: ClosedRange<Int>) throws -> Int? {
            guard let value = values[key] else { return fallback }
            guard let number = value.integer, let count = Int(exactly: number), range.contains(count) else {
                throw CoreFailure("Whisper profile \(key) is outside its supported integer range")
            }
            return count
        }
        func number(_ key: String, default fallback: Double? = nil) throws -> Double? {
            guard let value = values[key] else { return fallback }
            guard let number = value.double, number.isFinite, (0...1).contains(number) else {
                throw CoreFailure("Whisper profile \(key) must be between 0 and 1")
            }
            return number
        }
        beamSize = try integer("beam_size", range: 1...8)
        bestOf = try integer("best_of", range: 1...8)
        temperature = try number("temperature", default: 0)!
        temperatureIncrement = try number("temperature_increment")
        contextTokens = try integer("context_tokens", default: 0, range: 0...Self.maximumContextTokens)!
        if let value = values["no_fallback"] {
            guard let enabled = value.bool else { throw CoreFailure("Whisper no_fallback must be a boolean") }
            noFallback = enabled
        } else { noFallback = false }
        guard !noFallback || temperatureIncrement == nil else {
            throw CoreFailure("Choose no_fallback or temperature_increment, not both")
        }
        if let value = values["terminology"] {
            guard let text = value.string, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  text.utf8.count <= Self.maximumTerminologyBytes, !text.contains("\0"), contextTokens > 0 else {
                throw CoreFailure("Terminology needs nonempty user text, at most 1024 UTF-8 bytes and positive context_tokens")
            }
            terminology = text
        } else { terminology = nil }
        speech = try WhisperSpeechPolicy(json: values["speech"] ?? ["mode": "none"])
        languagePolicy = try WhisperLanguagePolicy(json: values["language_policy"] ?? "current_auto")
        // Validate composition independently of any configured explicit language.
        _ = try languagePolicy.effectiveArgument(configured: "auto", speech: speech)
    }

    public var isBaseline: Bool {
        beamSize == nil && bestOf == nil && temperature == 0 && temperatureIncrement == nil && !noFallback &&
        contextTokens == 0 && terminology == nil && speech.isBaseline && languagePolicy.isBaseline
    }

    /// This exact private JSON is retained with job evidence. It may contain the
    /// user's terminology; never send it to application logs or remote services.
    public var json: JSONValue {
        var value: JSONValue = ["schema_version": .string(Self.schemaVersion)]
        if let beamSize { value["beam_size"] = .integer(Int64(beamSize)) }
        if let bestOf { value["best_of"] = .integer(Int64(bestOf)) }
        value["temperature"] = .number(temperature)
        if let temperatureIncrement { value["temperature_increment"] = .number(temperatureIncrement) }
        value["no_fallback"] = .bool(noFallback)
        value["context_tokens"] = .integer(Int64(contextTokens))
        if let terminology { value["terminology"] = .string(terminology) }
        value["speech"] = speech.json
        value["language_policy"] = languagePolicy.json
        return value
    }

    /// Initial terminology and within-invocation history both need positive
    /// max-context in whisper.cpp. Cross-window text conditioning is unavailable:
    /// no previous transcript is silently carried into another model invocation.
    public var provenance: JSONValue {
        ["profile": json, "profile_sha256": .string(TextJob.hash(try! json.encoded())),
         "context_scope": "one_native_invocation; no cross-source/channel/window text state",
         "terminology_role": terminology == nil ? .null : "user_hint_not_recognized_speech",
         "terminology_sha256": terminology.map { .string(TextJob.hash(Data($0.utf8))) } ?? .null,
         "inherited_search_fallback": .bool(beamSize == nil || bestOf == nil || temperatureIncrement == nil && !noFallback)]
    }

    public func validate(help: String) throws {
        guard !isBaseline else { return }
        var flags = ["--temperature", "--max-context"]
        if beamSize != nil { flags.append("--beam-size") }
        if bestOf != nil { flags.append("--best-of") }
        if temperatureIncrement != nil { flags.append("--temperature-inc") }
        if noFallback { flags.append("--no-fallback") }
        if terminology != nil { flags.append("--prompt") }
        let tokens = Set(help.split(whereSeparator: { $0.isWhitespace || $0 == "," }).map(String.init))
        for flag in flags where !tokens.contains(flag) {
            throw CoreFailure("Installed whisper-cli does not advertise required profile capability \(flag)")
        }
        try speech.validate(help: help)
    }

    public var decodingArguments: [String] {
        func number(_ value: Double) -> String { value == 0 ? "0" : String(value) }
        var arguments = ["-tp", number(temperature), "-mc", String(contextTokens)]
        if let beamSize { arguments += ["-bs", String(beamSize)] }
        if let bestOf { arguments += ["-bo", String(bestOf)] }
        if let temperatureIncrement { arguments += ["-tpi", number(temperatureIncrement)] }
        if noFallback { arguments.append("-nf") }
        if let terminology { arguments += ["--prompt", terminology] }
        return arguments
    }
}
