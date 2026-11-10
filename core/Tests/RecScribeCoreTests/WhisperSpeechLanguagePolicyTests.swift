import Foundation
import Testing
@testable import RecScribeCore

@Suite struct WhisperSpeechLanguagePolicyTests {
    private let help = """
    --vad --vad-model --vad-threshold --vad-min-speech-duration-ms
    --vad-min-silence-duration-ms --vad-max-speech-duration-s
    --vad-speech-pad-ms --vad-samples-overlap
    """

    @Test func noVADControlAndMissingCapabilitiesAreExplicit() throws {
        let control = WhisperSpeechPolicy.none
        #expect(control.isBaseline && control.json == ["mode": "none"])
        #expect(try control.arguments(vad: nil).isEmpty)
        try control.validate(help: "")
        let silero = try WhisperSpeechPolicy(json: ["mode": "silero"])
        #expect(throws: CoreFailure.self) { try silero.arguments(vad: nil) }
        #expect(throws: CoreFailure.self) { try silero.validateModel(fallback: URL(fileURLWithPath: "/missing/silero.bin")) }
        #expect(throws: CoreFailure.self) { try silero.validate(help: "--vad --vad-model") }
        try silero.validate(help: help)
        // A substring is not a supported option.
        #expect(throws: CoreFailure.self) { try silero.validate(help: help.replacingOccurrences(of: "--vad-model", with: "--vad-model-unsupported")) }
        #expect(silero.evidence["rejected_regions"] == .null)
        #expect(silero.evidence["uncertain_detection_is_silence"] == false)
    }

    @Test func paddingAndLimitsAreExplicitAndInvalidPoliciesFailBeforeInference() throws {
        let model = URL(fileURLWithPath: "/private/silero.bin")
        let policy = try WhisperSpeechPolicy(json: ["mode": "silero", "vad_model": .string(model.path),
            "threshold": .number(0.4), "padding_ms": 300, "min_speech_ms": 100, "max_speech_seconds": 20])
        let args = try policy.arguments(vad: nil)
        #expect(args[try #require(args.firstIndex(of: "--vad-speech-pad-ms")) + 1] == "300")
        #expect(args[try #require(args.firstIndex(of: "--vad-max-speech-duration-s")) + 1] == "20.0")
        #expect(try WhisperSpeechPolicy(json: policy.json) == policy)
        #expect(try policy.arguments(vad: model) == args)
        #expect(throws: CoreFailure.self) { try policy.arguments(vad: URL(fileURLWithPath: "/different.bin")) }
        let invalidPolicies: [JSONValue] = [
            ["mode": "energy_gate"], ["mode": "none", "threshold": .number(0.5)],
            ["mode": "silero", "vad_model": "relative.bin"], ["mode": "silero", "vad_model": nil],
            ["mode": "silero", "threshold": .number(0)], ["mode": "silero", "threshold": .number(.infinity)],
            ["mode": "silero", "padding_ms": 1001], ["mode": "silero", "padding_ms": .number(1.5)],
            ["mode": "silero", "min_silence_ms": 0], ["mode": "silero", "max_speech_seconds": 61],
            ["mode": "silero", "overlap_seconds": .number(1.1)],
            ["mode": "silero", "padding_ms": 1000, "max_speech_seconds": 1],
            ["mode": "silero", "discard_quiet_audio": true]
        ]
        for invalid in invalidPolicies {
            #expect(throws: CoreFailure.self) { try WhisperSpeechPolicy(json: invalid) }
        }
    }

    @Test func modelValidationRetainsExistingSileroHeaderContract() throws {
        let root = try AudioFixture.folder(); defer { try? FileManager.default.removeItem(at: root) }
        let model = root.appendingPathComponent("silero.bin")
        var bytes = Data([0x6c, 0x6d, 0x67, 0x67, 10, 0, 0, 0]) + Data("silero-16k".utf8)
        for value in [UInt32(1), 0, 0, 512, 64, 4] {
            var encoded = value.littleEndian
            withUnsafeBytes(of: &encoded) { bytes.append(contentsOf: $0) }
        }
        try bytes.write(to: model)
        let policy = try WhisperSpeechPolicy(json: ["mode": "silero", "vad_model": .string(model.path)])
        try policy.validateModel(fallback: nil)
        try Data("a Whisper model is not a Silero model".utf8).write(to: model)
        #expect(throws: CoreFailure.self) { try policy.validateModel(fallback: nil) }
    }

    @Test func languageControlKeepsExplicitChoicesAndAutomaticSwitches() throws {
        let current = try WhisperLanguagePolicy(json: "current_auto")
        let speechAware = try WhisperLanguagePolicy(json: "speech_aware_auto")
        let speech = try WhisperSpeechPolicy(json: ["mode": "silero"])
        #expect(current.isBaseline && !speechAware.isBaseline)
        try current.validateRuntime(version: "unknown")
        try speechAware.validateRuntime(version: "1.9.5")
        #expect(throws: CoreFailure.self) { try speechAware.validateRuntime(version: "unknown") }
        #expect(throws: CoreFailure.self) { try speechAware.validateRuntime(version: "1.10.0") }
        #expect(try current.effectiveArgument(configured: " AUTO ", speech: .none) == "auto")
        #expect(try current.effectiveArgument(configured: "", speech: .none) == "auto")
        #expect(throws: CoreFailure.self) { try speechAware.effectiveArgument(configured: "auto", speech: .none) }
        #expect(try speechAware.effectiveArgument(configured: "auto", speech: speech) == "auto")
        for (configured, expected) in [(" de-CH ", "de"), ("ZH-Hant-TW", "zh"), ("pt-BR", "pt"), ("YUE", "yue")] {
            #expect(try current.effectiveArgument(configured: configured, speech: .none) == expected)
            #expect(try speechAware.effectiveArgument(configured: configured, speech: speech) == expected)
        }
        for language in ["de", "de", "de", "en", "ar", "zh", "xx"] {
            let provenance = speechAware.provenance(configured: "auto", detected: .string(language))
            #expect(provenance["effective_argument"] == "auto")
            #expect(provenance["recognizer_language"] == .string(language))
            #expect(provenance["persistent_lock"] == false && provenance["confidence"] == .null)
        }
        #expect(current.provenance(configured: "auto", detected: nil)["recognizer_language"] == .null)
        #expect(throws: CoreFailure.self) { try WhisperLanguagePolicy(json: ["preferences": ["de", "en"]]) }
        #expect(throws: CoreFailure.self) { try WhisperLanguagePolicy(json: "lock_after_three") }
        #expect(throws: CoreFailure.self) { try current.effectiveArgument(configured: "de --translate", speech: .none) }
    }

    @Test func languageChangesUnknownsAndAutomaticModeCannotReusePreviousLanguageText() {
        #expect(WhisperLanguagePolicy.permitsPreviousText(previousLanguage: "de", configured: "de-CH", detectedLanguage: "de"))
        let cases: [(String?, String, String?)] = [
            ("de", "en", "en"), ("de", "auto", "de"), ("de", "auto", "en"),
            (nil, "de", "de"), ("de", "de", nil), ("de", "de", "en")
        ]
        for (previous, configured, detected) in cases {
            #expect(!WhisperLanguagePolicy.permitsPreviousText(previousLanguage: previous, configured: configured, detectedLanguage: detected))
        }
    }
}
