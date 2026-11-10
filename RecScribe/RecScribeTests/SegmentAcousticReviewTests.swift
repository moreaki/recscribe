import AVFoundation
import Foundation
import RecScribeCore
import Synchronization
import Testing
@testable import RecScribe

@MainActor struct SegmentAcousticReviewTests {
    private struct Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("acoustic-studio-tests-\(UUID())")
        var job: URL { root.appendingPathComponent("job") }
        var audio: URL { root.appendingPathComponent("stereo.wav") }
        var reviews: URL { root.appendingPathComponent("Review") }
        var evidence: URL { root.appendingPathComponent("Acoustic") }
        init(musicName: String = "piano") throws {
            try FileManager.default.createDirectory(at: job, withIntermediateDirectories: true)
            let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
                .deletingLastPathComponent().appendingPathComponent("core/Tests/RecScribeCoreTests/Fixtures/Acoustic")
            // Locate PCM through the WAV layout; source files have extra header chunks.
            let left = try Self.samples(fixtures.appendingPathComponent(musicName + ".wav"))
            let right = try Self.samples(fixtures.appendingPathComponent("speech-en.wav"))
            #expect(!left.isEmpty && left.count == right.count)
            #expect(left.count == 128_000)
            var data = try PCM16WAV(sampleRate: 16_000, channels: 2, payloadBytes: UInt64(left.count * 4)).header
            for (a, b) in zip(left, right) {
                for value in [a, b] { var value = value.littleEndian; withUnsafeBytes(of: &value) { data.append(contentsOf: $0) } }
            }
            try data.write(to: audio)
            #expect(try AVAudioFile(forReading: audio).length == 128_000)
            try Data("Preserved raw hallucination".utf8).write(to: job.appendingPathComponent("raw.json"))
            try JSONSerialization.data(withJSONObject: ["schema_version": "1.0",
                "processing": ["mode": "verbatim", "source_language": "auto", "engine_passes": [["model": "fixture", "detected_language": "ja"]]],
                "source": ["path": audio.path, "duration_ms": 8000, "channels": 2, "sample_rate": 16000],
                "segments": [ReadingFixtures.segment("music", "Hallucinated words", channel: 0, start: 0, end: 8000),
                             ReadingFixtures.segment("speech", "Actual speech", channel: 1, start: 0, end: 8000)],
                "review_reasons": []], options: .sortedKeys).write(to: job.appendingPathComponent("transcript.json"))
        }
        private static func samples(_ url: URL) throws -> [Int16] {
            let layout = try WAVAudio.layout(url)
            #expect(layout.channels == 1 && layout.rate == 16_000 && layout.width == 2)
            let data = try Data(contentsOf: url)
            return data.withUnsafeBytes { bytes in
                (0..<Int(layout.frames)).map {
                    Int16(littleEndian: bytes.loadUnaligned(fromByteOffset: Int(layout.dataOffset) + $0 * 2, as: Int16.self))
                }
            }
        }
    }

    @Test func selectedChannelAnalysisNeedsConfirmationAndMusicLanguageOverlaySurvivesReload() async throws {
        let f = try Fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let paths = [f.audio, f.job.appendingPathComponent("transcript.json"), f.job.appendingPathComponent("raw.json")]
        let originals = try paths.map { try Data(contentsOf: $0) }
        let document = try await TranscriptPreview.read(f.job)
        let worker = SegmentAcousticReview(root: f.evidence)
        let state = SegmentAcousticState(analyze: { try await worker.run($0) })
        let review = TranscriptReviewState(store: .init(root: f.reviews))
        await review.load(job: f.job, document: document)
        state.request(job: f.job, document: document, segmentID: "music")
        await waitUntil("local analysis finished") { !state.busy }
        #expect(state.error == nil)
        let candidate = try #require(state.result)
        #expect(candidate.correction != nil && review.corrections.isEmpty)
        #expect(candidate.report.assessment.voiceGuardCompleted == true && candidate.report.voiceGuardWindowSeconds == 1)
        var legacyJSON = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(candidate.report)) as? [String: Any])
        var assessmentJSON = try #require(legacyJSON["assessment"] as? [String: Any])
        assessmentJSON.removeValue(forKey: "voiceGuardWindows"); assessmentJSON.removeValue(forKey: "voiceGuardCompleted")
        legacyJSON["assessment"] = assessmentJSON
        legacyJSON.removeValue(forKey: "voiceGuardWindowSeconds"); legacyJSON.removeValue(forKey: "voiceGuardOverlap")
        let legacyReport = try JSONDecoder().decode(LocalSoundClassifier.Report.self, from: JSONSerialization.data(withJSONObject: legacyJSON))
        let legacy = SegmentAcousticCandidate(selection: candidate.selection, report: legacyReport,
            reference: candidate.reference, evidence: candidate.evidence)
        #expect(legacy.report.assessment.outcome == .instrumentalMusicCandidate && legacy.correction == nil)
        #expect(document.text.contains("Hallucinated words"))
        #expect(FileManager.default.fileExists(atPath: candidate.evidence.appendingPathComponent("report.json").path))
        state.confirmMusicOnly(in: review)
        await waitUntil("music-only correction saved") { !state.busy && !review.saving }
        #expect(review.error == nil)
        let snapshot = try await TranscriptReviewStore(root: f.reviews).loadSnapshot(TranscriptReviewContext(job: f.job, document: document))
        let edited = document.applying(snapshot.corrections)
        #expect(edited.text.contains("[Music only]") && edited.text.contains("Actual speech"))
        #expect(!edited.text.contains("Hallucinated words"))
        #expect(!edited.recognitionLabel.contains("ja") && edited.languageLabel == "Not verified for remaining speech")
        #expect(edited.originalRecognitionLabel.contains("ja"))
        #expect(snapshot.corrections["music"]?.acoustic == candidate.reference)
        #expect(!edited.includesCloudAudio)
        let allMusic = document.applying(["music": .musicOnly, "speech": .musicOnly])
        #expect(allMusic.languageLabel == "No spoken language · music only")
        #expect(!allMusic.recognitionLabel.contains("ja"))
        review.setCorrection(nil, for: "music")
        await waitUntil("restoration saved") { !review.saving }
        #expect(document.applying(review.corrections).text == document.text)
        #expect(document.applying(review.corrections).recognitionLabel == document.originalRecognitionLabel)
        #expect(try paths.map { try Data(contentsOf: $0) } == originals)

        let voice = try await worker.run(SegmentCloudSelection.prepare(job: f.job, document: document, segmentID: "speech"))
        #expect(voice.report.assessment.outcome == .voiceOrMixed && voice.correction == nil)
    }

    @Test func blockingCancellationAndNewerEditsCannotApplyStaleSoundResults() async throws {
        let f = try Fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let document = try await TranscriptPreview.read(f.job), worker = SegmentAcousticReview(root: f.evidence)
        let returning = Mutex(false)
        let state = SegmentAcousticState(analyze: { selection in
            // Simulate a framework returning after cancellation; generation still drops it.
            let result = try await worker.run(selection)
            returning.withLock { $0 = true }
            try? await Task.sleep(for: .milliseconds(150))
            return result
        })
        state.setBlocked(true)
        state.request(job: f.job, document: document, segmentID: "music")
        #expect(!state.busy && state.result == nil)
        state.setBlocked(false)
        state.request(job: f.job, document: document, segmentID: "music")
        await waitUntil("framework returned before cancellation") { returning.withLock { $0 } }
        state.reset()
        try await Task.sleep(for: .milliseconds(250))
        #expect(!state.busy && state.result == nil)
        state.request(job: f.job, document: document, segmentID: "music")
        await waitUntil("sound result arrived") { !state.busy }
        #expect(state.result != nil)
        let review = TranscriptReviewState(store: .init(root: f.reviews))
        await review.load(job: f.job, document: document)
        review.setCorrection(.init(kind: .text, text: "Newer edit"), for: "music")
        await waitUntil("new edit saved") { !review.saving }
        state.confirmMusicOnly(in: review)
        #expect(state.error != nil && review.corrections["music"]?.text == "Newer edit")
        let original = document.applying(review.corrections)
        #expect(!original.hasMusicOnlyPassages && original.recognitionLabel.contains("ja"))
    }

    @Test func invalidAcousticReferencesAndTextWithAcousticProvenanceAreRejected() {
        let bad = SegmentAcousticReference(id: UUID(), classifier: "unverified", startMs: 0, endMs: 8000,
            channel: 0, audioSHA256: String(repeating: "a", count: 64), reportSHA256: String(repeating: "b", count: 64))
        #expect(!TranscriptCorrection(kind: .musicOnly, text: nil, acoustic: bad).valid)
        #expect(!TranscriptCorrection(kind: .text, text: "Words", acoustic: bad).valid)
        let extreme = SegmentAcousticReference(id: UUID(), classifier: "SoundAnalysis.version1", startMs: .max,
            endMs: .min, channel: 0, audioSHA256: "", reportSHA256: "")
        #expect(!extreme.valid)
    }

    @Test func longerContextViolinResultKeepsWordsAndCannotApplyMusicOnly() async throws {
        let f = try Fixture(musicName: "violin"); defer { try? FileManager.default.removeItem(at: f.root) }
        let document = try await TranscriptPreview.read(f.job)
        let original = try Data(contentsOf: f.job.appendingPathComponent("transcript.json"))
        let worker = SegmentAcousticReview(root: f.evidence)
        let state = SegmentAcousticState(analyze: { try await worker.run($0) })
        let review = TranscriptReviewState(store: .init(root: f.reviews))
        await review.load(job: f.job, document: document)
        state.request(job: f.job, document: document, segmentID: "music")
        await waitUntil("violin evidence arrived") { !state.busy }
        #expect(state.error == nil)
        let result = try #require(state.result)
        #expect(result.report.assessment.outcome == .musicNeedsListeningReview)
        #expect(result.report.contextWindowSeconds == 8 && result.report.assessment.contextWindows?.isEmpty == false)
        #expect(result.correction == nil)
        state.confirmMusicOnly(in: review)
        #expect(!state.busy && !review.saving && review.corrections.isEmpty)
        #expect(document.applying(review.corrections).text == document.text)
        #expect(try Data(contentsOf: f.job.appendingPathComponent("transcript.json")) == original)
    }
}
