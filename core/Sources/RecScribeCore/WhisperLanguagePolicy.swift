import Foundation

/// Language experiments never restrict Whisper's supported language set or
/// carry a permanent language lock between windows, sessions or source channels.
public enum WhisperLanguagePolicy: String, Sendable, Equatable {
    case currentAuto = "current_auto"
    case speechAwareAuto = "speech_aware_auto"

    public init(json: JSONValue) throws {
        guard let value = json.string, let policy = Self(rawValue: value) else {
            throw CoreFailure("Language policy must be current_auto or speech_aware_auto; preference lists and confidence thresholds are not supported by this CLI")
        }
        self = policy
    }

    public var isBaseline: Bool { self == .currentAuto }
    public var json: JSONValue { .string(rawValue) }

    /// The speech-before-language ordering was inspected in this pinned
    /// upstream release. New releases require review rather than a guessed
    /// compatibility claim from the presence of similarly named flags.
    public func validateRuntime(version: String) throws {
        guard self != .speechAwareAuto || version == "1.9.5" else {
            throw CoreFailure("Speech-aware language ordering is verified only for whisper.cpp 1.9.5; use current_auto or review the selected runtime")
        }
    }

    public static func baseLanguage(_ configured: String) throws -> String {
        let value = configured.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if value.isEmpty || value == "auto" { return "auto" }
        guard value.range(of: "^[a-z]{2,3}(-[a-z0-9]{2,8})*$", options: .regularExpression) != nil else {
            throw CoreFailure("Choose auto or a valid source-language tag; language preferences are not a whitelist")
        }
        return String(value.split(separator: "-", maxSplits: 1)[0])
    }

    /// whisper.cpp 1.9.5 runs Silero over the derived input before automatic
    /// detection. Keeping -l auto permits out-of-set speech and later switches.
    public func effectiveArgument(configured: String, speech: WhisperSpeechPolicy) throws -> String {
        let language = try Self.baseLanguage(configured)
        if self == .speechAwareAuto, language == "auto", speech.isBaseline {
            throw CoreFailure("Speech-aware automatic language requires an explicit Silero speech profile; current_auto remains available")
        }
        return language
    }

    public func provenance(configured: String, detected: JSONValue) -> JSONValue {
        let effective = try? Self.baseLanguage(configured)
        return ["policy": json, "configured": .string(configured),
            "effective_argument": effective.map(JSONValue.string) ?? .null,
            "recognizer_language": detected.string.map(JSONValue.string) ?? .null,
            "confidence": nil, "confidence_status": "unavailable_in_whisper_cli_json",
            "scope": "this recognizer invocation and source channel only; mixed live preview is separate",
            "persistent_lock": false, "preference_list": nil,
            "fallback": "auto uses the runtime multilingual detector; explicit user language is preserved",
            "swiss_german": "de is a base-language argument; it does not establish dialect identity or wording fidelity"]
    }

    /// Automatic decisions can change on every call. Do not condition an
    /// undetected next window on earlier-language text, which would bias ID.
    public static func permitsPreviousText(previousLanguage: String?, configured: String, detectedLanguage: String?) -> Bool {
        guard let effective = try? baseLanguage(configured), effective != "auto",
              let previousLanguage, let detectedLanguage,
              previousLanguage == effective, detectedLanguage == effective else { return false }
        return true
    }
}
