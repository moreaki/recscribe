import Foundation
import Testing
@testable import RecScribeCore

@Suite struct WhisperDecodingProfileTests {
    private let help = """
    --temperature N --max-context N --beam-size N --best-of N
    --temperature-inc N --no-fallback --prompt PROMPT
    """

    @Test func baselineRetainsExactArgumentsAndInheritedDefaults() throws {
        let profile = WhisperDecodingProfile.baseline
        #expect(profile.isBaseline)
        #expect(profile.decodingArguments == ["-tp", "0", "-mc", "0"])
        try profile.validate(help: "") // Existing runtimes need no new baseline capabilities.
        #expect(profile.provenance["inherited_search_fallback"] == true)
        #expect(profile.provenance["context_scope"].string?.contains("no cross-source/channel/window") == true)
        #expect(try WhisperDecodingProfile(json: profile.json) == profile)
    }

    @Test func boundedSettingsRequireActualCapabilitiesAndPreservePrivateHints() throws {
        let profile = try WhisperDecodingProfile(json: ["schema_version": "1.0", "beam_size": 3, "best_of": 2,
            "context_tokens": 64, "no_fallback": true, "terminology": "Grüezi 阿拉伯ية Zürich"])
        try profile.validate(help: help)
        #expect(profile.decodingArguments == ["-tp", "0", "-mc", "64", "-bs", "3", "-bo", "2", "-nf", "--prompt", "Grüezi 阿拉伯ية Zürich"])
        #expect(profile.provenance["terminology_role"] == "user_hint_not_recognized_speech")
        #expect(profile.provenance["terminology_sha256"].string?.count == 64)
        #expect(profile.json["terminology"] == "Grüezi 阿拉伯ية Zürich")
        #expect(throws: CoreFailure.self) { try profile.validate(help: "--temperature --max-context --beam-size-unsupported --best-of --no-fallback --prompt") }
        let fallback = try WhisperDecodingProfile(json: ["schema_version": "1.0", "temperature": .number(0.2), "temperature_increment": .number(0.1)])
        #expect(fallback.decodingArguments == ["-tp", "0.2", "-mc", "0", "-tpi", "0.1"])
    }

    @Test func invalidOrAmbiguousSettingsNeverSilentlyFallBack() {
        let invalid: [JSONValue] = [
            ["schema_version": "2.0"], ["schema_version": "1.0", "beam_size": 9],
            ["schema_version": "1.0", "best_of": 0], ["schema_version": "1.0", "context_tokens": 225],
            ["schema_version": "1.0", "temperature": .number(-0.1)],
            ["schema_version": "1.0", "temperature_increment": .number(1.1)],
            ["schema_version": "1.0", "beam_size": .number(2.5)],
            ["schema_version": "1.0", "no_fallback": "true"],
            ["schema_version": "1.0", "no_fallback": true, "temperature_increment": .number(0.2)],
            ["schema_version": "1.0", "terminology": "ineffective without context"],
            ["schema_version": "1.0", "context_tokens": 64, "terminology": "\0"],
            ["schema_version": "1.0", "context_tokens": 64, "terminology": .string(String(repeating: "界", count: 342))],
            ["schema_version": "1.0", "invented_capability": true],
            ["schema_version": "1.0", "previous_text": "another channel"]
        ]
        for value in invalid { #expect(throws: CoreFailure.self) { try WhisperDecodingProfile(json: value) } }
    }

    @Test func nativeCandidateRecordsSettingsAndNeverInjectsHintsIntoOutput() throws {
        let root = try AudioFixture.folder(); defer { try? FileManager.default.removeItem(at: root) }
        let binary = root.appendingPathComponent("whisper-cli"), model = root.appendingPathComponent("model.bin")
        let script = #"""
        #!/bin/sh
        case "$1" in
          --version) echo 'whisper.cpp version: 1.9.5'; exit 0 ;;
          --help) echo '--temperature --max-context --beam-size --best-of --temperature-inc --no-fallback --prompt'; exit 0 ;;
        esac
        while [ "$#" -gt 0 ]; do
          if [ "$1" = '-of' ]; then shift; output="$1"; fi
          shift
        done
        printf '%s\n' '{"result":{"language":"en"},"transcription":[{"offsets":{"from":0,"to":100},"text":"actual spoken words"}]}' > "${output}.json"
        """# + "\n"
        try Data(script.utf8).write(to: binary)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: binary.path)
        try Data("synthetic test model".utf8).write(to: model)
        let profile = try WhisperDecodingProfile(json: ["schema_version": "1.0", "beam_size": 3,
            "context_tokens": 32, "terminology": "AbsentTerm"])
        let engine = try NativeWhisperEngine(binary: binary, model: model, profile: profile)
        for channel in [0, 1] {
            let output = root.appendingPathComponent("channel-\(channel)")
            let result = try engine.transcribe(root.appendingPathComponent("source.wav"), output: output,
                                               language: " EN-us ", check: {})
            #expect(result.segments.first?["source_text"] == "actual spoken words")
            #expect(result.provenance["asr_language"] == "en")
            #expect(result.provenance["detected_language"] == "en")
            #expect(result.provenance["decoding"]["terminology_sha256"].string?.count == 64)
            #expect(result.provenance["capabilities_sha256"].string?.count == 64)
            #expect(FileManager.default.fileExists(atPath: output.appendingPathExtension("profile.json").path))
            #expect(FileManager.default.fileExists(atPath: output.appendingPathExtension("capabilities.log").path))
            #expect(throws: CoreFailure.self) {
                try engine.transcribe(root.appendingPathComponent("source.wav"), output: output, language: "en", check: {})
            }
        }
        #expect(throws: CancellationError.self) {
            try engine.transcribe(root.appendingPathComponent("source.wav"), output: root.appendingPathComponent("cancelled"),
                                  language: "auto", check: { throw CancellationError() })
        }
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("cancelled.profile.json").path))
    }
}
