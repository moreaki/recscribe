import CryptoKit
import Foundation
import Testing
@testable import RecScribeCore
@testable import RecScribeTextCLI

@Suite struct AcousticFixtureTests {
    @Test func reviewedMusicAndSpeechChallengeFixturesKeepVoiceAndOriginalBytes() throws {
        let root = try #require(Bundle.module.resourceURL).appendingPathComponent("Fixtures/Acoustic")
        let manifest = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: root.appendingPathComponent("manifest.json")))
        let cases = try #require(manifest["fixtures"].array)
        #expect(cases.count == 8)
        #expect(manifest["automatic_suppression_approved"] == false)
        for fixture in cases {
            let name = try #require(fixture["audio"].string)
            let url = root.appendingPathComponent(name)
            let before = try Data(contentsOf: url)
            let hash = SHA256.hash(data: before).map { String(format: "%02x", $0) }.joined()
            #expect(hash == fixture["sha256"].string)
            let report = try LocalSoundClassifier.assess(url)
            if fixture["id"].string == "piano" {
                #expect(report.assessment.outcome == .instrumentalMusicCandidate, "\(name): \(report.assessment.reason)")
                #expect(report.assessment.musicOnlyConfirmationAllowed && report.voiceGuardWindowSeconds == 1)
                #expect(report.voiceGuardOverlap == 0.5 && report.assessment.voiceGuardCompleted == true)
            } else if fixture["expected"].string == "instrumental" {
                #expect(report.assessment.outcome == .musicNeedsListeningReview)
                #expect(report.contextWindowSeconds == 8)
                #expect(report.assessment.contextWindows?.isEmpty == false)
            } else {
                #expect(report.assessment.outcome == .voiceOrMixed, "\(name): voice must be retained")
            }
            #expect(!report.assessment.automaticSuppressionAllowed)
            #expect(report.sourceSHA256 == hash)
            #expect(try Data(contentsOf: url) == before)
        }
    }

    @Test func fractionalTailUsesOnlyThePassageAndHasCompleteCoverage() throws {
        let root = try AudioFixture.folder(); defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("fractional.wav")
        try AudioFixture.wav(url, frames: 79_683) { _, _ in 0 }
        let report = try LocalSoundClassifier.assess(url)
        #expect(report.assessment.windows.map(\.start).min() == 0)
        let end = try #require(report.assessment.windows.map(\.end).max())
        #expect(abs(end - 79_683.0 / 16_000) < 0.000_001)
        #expect(report.assessment.outcome != .instrumentalMusicCandidate)
    }

    @Test func quietSpeechOverViolinNeverBecomesAMusicOnlyCandidate() throws {
        let root = try #require(Bundle.module.resourceURL).appendingPathComponent("Fixtures/Acoustic/ViolinChallenges")
        let manifest = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: root.appendingPathComponent("manifest.json")))
        let cases = try #require(manifest["cases"].array)
        #expect(cases.count == 9)
        for fixture in cases {
            let name = try #require(fixture["audio"].string)
            let url = root.appendingPathComponent(name)
            let hash = try WAVAudio.hash(url)
            #expect(hash == fixture["sha256"].string)
            let report = try LocalSoundClassifier.assess(url)
            let outcome = report.assessment.outcome
            #expect(outcome == .voiceOrMixed || outcome == .musicNeedsListeningReview, "\(name): keep known speech")
            #expect(outcome != .instrumentalMusicCandidate && !report.assessment.automaticSuppressionAllowed)
            #expect(try WAVAudio.hash(url) == hash)
        }
    }

    @Test func shortQuietSpeechMixturesRetainRecognitionAndBindInputHashes() throws {
        let root = try #require(Bundle.module.resourceURL).appendingPathComponent("Fixtures/Acoustic/ShortSpeechChallenges")
        let manifest = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: root.appendingPathComponent("manifest.json")))
        let cases = try #require(manifest["cases"].array)
        #expect(cases.count == 9 && manifest["automatic_suppression_approved"] == false)
        for fixture in cases {
            let name = try #require(fixture["audio"].string), url = root.appendingPathComponent(name)
            #expect(try WAVAudio.hash(url) == fixture["sha256"].string)
            let report = try LocalSoundClassifier.assess(url)
            #expect(report.assessment.outcome == .voiceOrMixed, "\(name): short speech source retained")
            #expect(!report.assessment.musicOnlyConfirmationAllowed && !report.assessment.automaticSuppressionAllowed)
            #expect(try WAVAudio.hash(url) == fixture["sha256"].string)
        }
    }

    @Test func inspectionCLIRejectsAnyUploadOrProcessingOptions() throws {
        let parsed = try RecScribeTextCLI.Arguments(["inspect-sound", "/local.wav"])
        #expect(parsed.command == "inspect-sound")
        for flag in ["--allow-cloud-text", "--key-stdin", "--output", "--source-language"] {
            #expect(throws: CoreFailure.self) { try RecScribeTextCLI.Arguments(["inspect-sound", "/local.wav", flag]) }
        }
    }
}
