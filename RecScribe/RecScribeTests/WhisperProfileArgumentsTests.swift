import Foundation
import RecScribeCore
import Testing
@testable import RecScribe

@MainActor
struct WhisperProfileArgumentsTests {
    @Test func defaultLiveSettingsRetainTheUntouchedCommand() {
        var settings = AppSettings.Values()
        settings.modelPath = "/model.bin"; settings.sourceLanguage = " DE-ch "; settings.liveThreads = 2
        // Legacy final-only VAD remains absent from the baseline live command.
        settings.vadModelPath = "/legacy-final-vad.bin"
        let arguments = LiveWhisperTranscriber.arguments(audio: URL(fileURLWithPath: "/audio.wav"),
            output: URL(fileURLWithPath: "/raw"), settings: settings)
        #expect(arguments == ["-m", "/model.bin", "-f", "/audio.wav", "-l", "de", "-ojf", "-of", "/raw", "-t", "2", "-tp", "0", "-mc", "0"])
    }

    @Test func candidateLiveArgumentsRequireCapabilitiesWithoutChangingSavedSettings() throws {
        var settings = AppSettings.Values()
        settings.modelPath = "/model.bin"; settings.sourceLanguage = "auto"
        let original = settings
        let profile = try WhisperDecodingProfile(json: ["schema_version": "1.0", "context_tokens": 32,
            "terminology": "AbsentTerm", "no_fallback": true])
        let audio = URL(fileURLWithPath: "/audio.wav"), output = URL(fileURLWithPath: "/raw")
        #expect(throws: CoreFailure.self) {
            try LiveWhisperTranscriber.arguments(audio: audio, output: output, settings: settings,
                                                  profile: profile, capabilities: "--temperature --max-context")
        }
        let arguments = try LiveWhisperTranscriber.arguments(audio: audio, output: output, settings: settings,
            profile: profile, capabilities: "--temperature --max-context --no-fallback --prompt")
        #expect(arguments.suffix(7) == ["-tp", "0", "-mc", "32", "-nf", "--prompt", "AbsentTerm"])
        #expect(settings == original)
        #expect(!LiveWhisperTranscriber.arguments(audio: audio, output: output, settings: settings).contains("AbsentTerm"))
    }
}
