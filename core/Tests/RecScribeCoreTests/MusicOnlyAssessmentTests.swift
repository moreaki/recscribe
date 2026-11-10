import Foundation
import Testing
@testable import RecScribeCore

@Suite struct MusicOnlyAssessmentTests {
    private func window(_ start: Double, _ end: Double, music: Double = 0.99,
                        voice: String? = nil) -> MusicOnlyAssessment.Window {
        var scores = Dictionary(uniqueKeysWithValues: MusicOnlyAssessment.requiredLabels.map { ($0, 0.001) })
        scores["music"] = music
        if let voice { scores[voice] = 0.2 }
        return .init(start: start, end: end, scores: scores)
    }
    private var covered: [MusicOnlyAssessment.Window] {
        [window(0, 1), window(0.5, 1.5), window(1, 2), window(1.5, 2.5), window(2, 3)]
    }

    @Test func completeInstrumentalEvidenceIsOnlyAnExperimentalCandidate() throws {
        let result = MusicOnlyAssessment.evaluate(duration: 3, windows: covered.reversed(), completed: true,
            voiceGuardWindows: covered, voiceGuardCompleted: true)
        #expect(result.outcome == .instrumentalMusicCandidate)
        #expect(result.musicOnlyConfirmationAllowed)
        #expect(!result.automaticSuppressionAllowed)
        #expect(try JSONDecoder().decode(MusicOnlyAssessment.self, from: JSONEncoder().encode(result)) == result)
    }

    @Test(arguments: Array(MusicOnlyAssessment.voiceLabels).sorted())
    func oneSecondVoiceEvidenceVetoesLongWindowMusic(_ label: String) {
        var guardWindows = covered
        guardWindows[2] = window(1, 2, music: 0.1, voice: label)
        let result = MusicOnlyAssessment.evaluate(duration: 3, windows: [window(0, 3)], completed: true,
            voiceGuardWindows: guardWindows, voiceGuardCompleted: true)
        #expect(result.outcome == .voiceOrMixed && !result.musicOnlyConfirmationAllowed)
    }

    @Test func missingIncompleteAndInvalidVoiceGuardCannotOfferMusicOnlyConfirmation() {
        let missing = MusicOnlyAssessment.evaluate(duration: 3, windows: [window(0, 3)], completed: true)
        #expect(missing.outcome == .inconclusive && !missing.musicOnlyConfirmationAllowed)
        for guards in [Array(covered.dropFirst()), Array(covered.dropLast()), [window(0, 3)], [window(-0.1, 0.9)]] {
            let result = MusicOnlyAssessment.evaluate(duration: 3, windows: [window(0, 3)], completed: true,
                voiceGuardWindows: guards, voiceGuardCompleted: true)
            #expect(result.outcome == .inconclusive && !result.musicOnlyConfirmationAllowed)
        }
        let unfinished = MusicOnlyAssessment.evaluate(duration: 3, windows: [window(0, 3)], completed: true,
            voiceGuardWindows: covered, voiceGuardCompleted: false)
        #expect(unfinished.outcome == .inconclusive)
    }

    @Test func oldCandidateEvidenceWithoutVoiceGuardIsReadableButNotConfirmable() throws {
        let current = MusicOnlyAssessment.evaluate(duration: 3, windows: [window(0, 3)], completed: true,
            voiceGuardWindows: covered, voiceGuardCompleted: true)
        var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(current)) as? [String: Any])
        json.removeValue(forKey: "voiceGuardWindows"); json.removeValue(forKey: "voiceGuardCompleted")
        let old = try JSONDecoder().decode(MusicOnlyAssessment.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(old.outcome == .instrumentalMusicCandidate)
        #expect(!old.musicOnlyConfirmationAllowed && !old.automaticSuppressionAllowed)
    }

    @Test func oneSecondGuardChecksVoiceWithoutDemandingShortWindowMusicScores() {
        let guards = covered.map { window($0.start, $0.end, music: 0.01) }
        let result = MusicOnlyAssessment.evaluate(duration: 3, windows: [window(0, 3)], completed: true,
            voiceGuardWindows: guards, voiceGuardCompleted: true)
        #expect(result.musicOnlyConfirmationAllowed && result.outcome == .instrumentalMusicCandidate)
        let fractionalGuards = guards + [window(2.25, 3.25, music: 0.01)]
        let fractional = MusicOnlyAssessment.evaluate(duration: 3.25, windows: [window(0, 3), window(0.25, 3.25)], completed: true,
            voiceGuardWindows: fractionalGuards, voiceGuardCompleted: true)
        #expect(fractional.musicOnlyConfirmationAllowed)
        let excess = Array(repeating: window(0, 1), count: MusicOnlyAssessment.maximumWindows)
        let bounded = MusicOnlyAssessment.evaluate(duration: 3, windows: [window(0, 3)], completed: true,
            voiceGuardWindows: excess, voiceGuardCompleted: true)
        #expect(!bounded.musicOnlyConfirmationAllowed)
        #expect(bounded.windows.count + (bounded.voiceGuardWindows?.count ?? 0) <= MusicOnlyAssessment.maximumWindows)
    }

    @Test(arguments: Array(MusicOnlyAssessment.voiceLabels).sorted())
    func everyVoiceClassVetoesMusicOnly(_ label: String) {
        var windows = covered
        windows[2] = window(1, 2, voice: label)
        let result = MusicOnlyAssessment.evaluate(duration: 3, windows: windows, completed: true)
        #expect(result.outcome == .voiceOrMixed)
        #expect(!result.automaticSuppressionAllowed)
    }

    @Test func gapsMissingTailAndMissingBeginningAreInconclusive() {
        for windows in [[window(0, 1), window(1.01, 2), window(2, 3)],
                        Array(covered.dropLast()), Array(covered.dropFirst())] {
            #expect(MusicOnlyAssessment.evaluate(duration: 3, windows: windows, completed: true).outcome == .inconclusive)
        }
    }

    @Test func unknownScoresAndInvalidRangesCannotBeTreatedAsSilence() {
        var scores = window(0, 1).scores
        scores.removeValue(forKey: "whispering")
        var malformed: [MusicOnlyAssessment.Window] = [.init(start: 0, end: 1, scores: scores)]
        for value in [Double.nan, .infinity, -0.1, 1.1] {
            scores = window(0, 1).scores
            scores["speech"] = value
            malformed.append(.init(start: 0, end: 1, scores: scores))
        }
        malformed += [window(-0.01, 1), window(0, 3.01), window(2, 1), window(.nan, 1)]
        for invalid in malformed {
            var windows = covered
            windows[0] = invalid
            #expect(MusicOnlyAssessment.evaluate(duration: 3, windows: windows, completed: true).outcome == .inconclusive)
        }
    }

    @Test func shortEmptyUnfinishedAndExcessiveAnalysisRemainInconclusive() {
        for duration in [0.0, 2.99, 120.01, .nan, .infinity] {
            #expect(MusicOnlyAssessment.evaluate(duration: duration, windows: covered, completed: true).outcome == .inconclusive)
        }
        #expect(MusicOnlyAssessment.evaluate(duration: 3, windows: covered, completed: false).outcome == .inconclusive)
        #expect(MusicOnlyAssessment.evaluate(duration: 3, windows: [], completed: true).outcome == .inconclusive)
        #expect(MusicOnlyAssessment.evaluate(duration: 4, windows: [window(0, 4)], completed: true).outcome == .inconclusive)
        let excessive = Array(repeating: window(0, 3), count: MusicOnlyAssessment.maximumWindows + 1)
        let result = MusicOnlyAssessment.evaluate(duration: 3, windows: excessive, completed: true)
        #expect(result.outcome == .inconclusive && result.windows.count == MusicOnlyAssessment.maximumWindows)
    }

    @Test func silenceNoiseAndOneWeakWindowCannotBecomeMusicOnly() {
        for music in [0.0, 0.5, 0.849] {
            var windows = covered
            windows[2] = window(1, 2, music: music)
            #expect(MusicOnlyAssessment.evaluate(duration: 3, windows: windows, completed: true).outcome == .inconclusive)
        }
    }

    @Test func longerContextOnlyOffersListeningReviewAndCannotOverrideShortVoiceEvidence() {
        var short = (0...5).map { window(Double($0), Double($0 + 3), music: 0.72) }
        let context = [window(0, 8, music: 0.83)]
        let result = MusicOnlyAssessment.evaluate(duration: 8, windows: short, completed: true,
                                                  contextWindows: context, contextCompleted: true)
        #expect(result.outcome == .musicNeedsListeningReview)
        #expect(!result.automaticSuppressionAllowed)
        short[2] = window(2, 5, music: 0.72, voice: "whispering")
        #expect(MusicOnlyAssessment.evaluate(duration: 8, windows: short, completed: true,
            contextWindows: context, contextCompleted: true).outcome == .voiceOrMixed)
    }

    @Test(arguments: Array(MusicOnlyAssessment.voiceLabels).sorted())
    func everyLongerContextVoiceClassPreservesWords(_ label: String) {
        let short = (0...5).map { window(Double($0), Double($0 + 3), music: 0.72) }
        let result = MusicOnlyAssessment.evaluate(duration: 8, windows: short, completed: true,
            contextWindows: [window(0, 8, music: 0.99, voice: label)], contextCompleted: true)
        #expect(result.outcome == .voiceOrMixed)
    }

    @Test func incompleteContextMissingScoresAndWeakMusicNeverPromoteRecognition() {
        let short = (0...5).map { window(Double($0), Double($0 + 3), music: 0.72) }
        #expect(MusicOnlyAssessment.evaluate(duration: 8, windows: short, completed: true,
            contextWindows: [window(0, 8)], contextCompleted: false).outcome == .inconclusive)
        for context in [[window(0.01, 8)], [window(0, 7)], [window(0, 8.01)], [window(0, 8, music: 0.799)]] {
            #expect(MusicOnlyAssessment.evaluate(duration: 8, windows: short, completed: true,
                contextWindows: context, contextCompleted: true).outcome == .inconclusive)
        }
        var scores = window(0, 8).scores
        scores.removeValue(forKey: "speech")
        #expect(MusicOnlyAssessment.evaluate(duration: 8, windows: short, completed: true,
            contextWindows: [.init(start: 0, end: 8, scores: scores)], contextCompleted: true).outcome == .inconclusive)
        var weak = short; weak[0] = window(0, 3, music: 0.649)
        #expect(MusicOnlyAssessment.evaluate(duration: 8, windows: weak, completed: true,
            contextWindows: [window(0, 8)], contextCompleted: true).outcome == .inconclusive)
        let excess = Array(repeating: window(0, 8), count: MusicOnlyAssessment.maximumWindows)
        let bounded = MusicOnlyAssessment.evaluate(duration: 8, windows: short, completed: true,
            contextWindows: excess, contextCompleted: true)
        #expect(bounded.outcome == .inconclusive)
        #expect(bounded.windows.count + (bounded.contextWindows?.count ?? 0) <= MusicOnlyAssessment.maximumWindows)
    }

    @Test func localClassifierRejectsUnsupportedInputAndHonorsCancellationBeforeAnalysis() throws {
        let root = try AudioFixture.folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let stereo = root.appendingPathComponent("stereo.wav")
        try AudioFixture.wav(stereo, channels: 2, frames: 48_000)
        #expect(throws: CoreFailure.self) { try LocalSoundClassifier.assess(stereo) }
        let short = root.appendingPathComponent("short.wav")
        try AudioFixture.wav(short)
        #expect(throws: CoreFailure.self) { try LocalSoundClassifier.assess(short) }
        #expect(throws: CancellationError.self) {
            try LocalSoundClassifier.assess(root.appendingPathComponent("missing.wav")) { throw CancellationError() }
        }
    }

    @Test func builtinClassifierDoesNotCallSilenceMusicAndPreservesSource() throws {
        let root = try AudioFixture.folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("silence.wav")
        try AudioFixture.wav(source, frames: 48_000) { _, _ in 0 }
        let original = try Data(contentsOf: source)
        let report = try LocalSoundClassifier.assess(source)
        #expect(report.classifier == "SoundAnalysis.version1")
        #expect(report.assessment.outcome != .instrumentalMusicCandidate)
        #expect(!report.assessment.automaticSuppressionAllowed)
        #expect(!report.assessment.windows.isEmpty)
        #expect(report.assessment.windows.allSatisfy {
            $0.start >= 0 && $0.end <= 3 && $0.end > $0.start && $0.end - $0.start <= 3.000_001
        })
        #expect(report.assessment.windows.map(\.start).min() == 0)
        #expect(report.assessment.windows.map(\.end).max() == 3)
        #expect(report.sourceSHA256 == (try WAVAudio.hash(source)))
        #expect(try Data(contentsOf: source) == original)
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path) == ["silence.wav"])
    }
}
