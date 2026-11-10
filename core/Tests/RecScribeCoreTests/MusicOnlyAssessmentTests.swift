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
        let result = MusicOnlyAssessment.evaluate(duration: 3, windows: covered.reversed(), completed: true)
        #expect(result.outcome == .instrumentalMusicCandidate)
        #expect(!result.automaticSuppressionAllowed)
        #expect(try JSONDecoder().decode(MusicOnlyAssessment.self, from: JSONEncoder().encode(result)) == result)
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
