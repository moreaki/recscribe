import CryptoKit
import Darwin
import Foundation
import Testing
@testable import RecScribe

@MainActor
struct TranscriptCorrectionTests {
    private struct Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("recscribe-corrections-\(UUID())")
        var job: URL { root.appendingPathComponent("job") }
        var reviews: URL { root.appendingPathComponent("Review") }
        var canonical: URL { job.appendingPathComponent("transcript.json") }
        var raw: URL { job.appendingPathComponent("raw.json") }
        var audio: URL { root.appendingPathComponent("original.audio") }
        init() throws {
            try FileManager.default.createDirectory(at: job, withIntermediateDirectories: true)
            try Data("original audio".utf8).write(to: audio)
            try Data("raw recognition".utf8).write(to: raw)
            var a = ReadingFixtures.segment("s1", "Original one")
            a["normalized_text"] = "Cleaned one"; a["translated_text"] = "Translated one"
            try JSONSerialization.data(withJSONObject: ["schema_version": "1.0", "processing": ["mode": "translate"],
                "segments": [a, ReadingFixtures.segment("s2", "Original two", channel: 1),
                             ReadingFixtures.segment("s3", "Other passage", start: 5000, end: 8000)],
                "summary": ["notes": [["text": "Old summary", "segment_ids": ["s1"]]]],
                "review_reasons": ["confidence_unavailable"]], options: .sortedKeys).write(to: canonical)
        }
        func metadata(revision: String) -> URL {
            let key = SHA256.hash(data: Data(job.standardizedFileURL.path.utf8)).map { String(format: "%02x", $0) }.joined()
            return reviews.appendingPathComponent(key + "-" + revision + ".json")
        }
    }

    private func context(_ f: Fixture, corrections: [String: TranscriptCorrection] = [:]) async throws -> TranscriptReviewContext {
        try TranscriptReviewContext(job: f.job, document: try await TranscriptPreview.read(f.job).applying(corrections))
    }
    private func rejects<T>(_ operation: () async throws -> T) async {
        do { _ = try await operation(); Issue.record("Expected correction operation to fail") } catch { }
    }
    private func finish(_ state: TranscriptReviewState) async {
        await waitUntil("correction persisted or failed") { !state.saving }
    }

    @Test func correctionsAndMusicPersistWithoutRewritingEvidenceAndReachEveryStudioExport() async throws {
        let f = try Fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let before = try [f.canonical, f.raw, f.audio].map { try Data(contentsOf: $0) }
        let original = try await TranscriptPreview.read(f.job)
        let store = TranscriptReviewStore(root: f.reviews)
        let correction = TranscriptCorrection(kind: .text, text: "Corrected *literal* words 日本語")
        let first = try await store.setCorrection(correction, for: "s1", in: context(f))
        let second = try await store.setCorrection(.musicOnly, for: "s2", in: context(f, corrections: first.corrections))
        let reopened = try await TranscriptReviewStore(root: f.reviews).loadSnapshot(context(f))
        #expect(reopened == second)
        let edited = original.applying(reopened.corrections)
        #expect(edited.segments == original.segments && edited.revision == original.revision)
        #expect(edited.displayedText(edited.segments[0]) == correction.text)
        #expect(edited.displayedText(edited.segments[1]) == "[Music only]")
        for markdown in [false, true] {
            let exported = edited.exportText(for: .transcript, markdown: markdown)
            #expect(exported.contains(correction.text!) && exported.contains("[Music only]"))
            #expect(!exported.contains("Original one") && !exported.contains("Original two"))
            #expect(edited.exportText(for: .summary, markdown: markdown).contains(TranscriptPreview.summaryCorrectionWarning))
        }
        #expect(edited.reviewItems.map(\.key) == original.reviewItems.map(\.key))
        let restored = try await store.setCorrection(nil, for: "s1", in: context(f, corrections: second.corrections))
        #expect(original.applying(restored.corrections).displayedText(original.segments[0]) == "Translated one")
        #expect(try [f.canonical, f.raw, f.audio].map { try Data(contentsOf: $0) } == before)
    }

    @Test func correctionAndRestoreAtomicallyReopenAffectedAndGlobalReviewsOnly() async throws {
        let f = try Fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let original = try await TranscriptPreview.read(f.job)
        let store = TranscriptReviewStore(root: f.reviews), initial = try await context(f)
        for key in initial.keys { _ = try await store.setChecked(key, checked: true, in: initial) }
        let other = try #require(original.reviewItems.first { $0.groupID == "s3" })
        let affected = try #require(original.reviewItems.first { $0.groupID == "s1" })
        let music = try await store.setCorrection(.musicOnly, for: "s1", in: initial)
        #expect(music.checked == [other.key])
        var current = try await context(f, corrections: music.corrections)
        _ = try await store.setChecked(affected.key, checked: true, in: current)
        let restored = try await store.setCorrection(nil, for: "s1", in: current)
        #expect(restored.checked == [other.key] && restored.corrections.isEmpty)
        current = try await context(f)
        #expect(try await store.load(current) == [other.key]) // Old checked status must not reappear.
        #expect(try Data(contentsOf: f.metadata(revision: current.revision)).count > 0)
    }

    @Test func staleEditorsCannotOverwriteSameSegmentOrAcknowledgeUnseenCorrections() async throws {
        let f = try Fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let first = TranscriptReviewStore(root: f.reviews), second = TranscriptReviewStore(root: f.reviews)
        let initial = try await context(f)
        _ = try await first.setCorrection(.musicOnly, for: "s1", in: initial)
        await rejects { try await second.setCorrection(.init(kind: .text, text: "Stale edit"), for: "s1", in: initial) }
        await rejects { try await second.setChecked(try #require(initial.keys.first), checked: true, in: initial) }
        // Independent segment edits merge under the lock, retaining the other editor's correction.
        let merged = try await second.setCorrection(.init(kind: .text, text: "Another edit"), for: "s2", in: initial)
        #expect(merged.corrections["s1"] == .musicOnly && merged.corrections["s2"]?.text == "Another edit")
    }

    @Test func revisionAndJobIdentityIsolateCorrectionsAndRetainPreviousRevisionFiles() async throws {
        let f = try Fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let canonical = try Data(contentsOf: f.canonical), initial = try await context(f)
        let store = TranscriptReviewStore(root: f.reviews)
        _ = try await store.setCorrection(.musicOnly, for: "s1", in: initial)
        let saved = try Data(contentsOf: f.metadata(revision: initial.revision))
        try (canonical + Data(" ".utf8)).write(to: f.canonical)
        await rejects { try await store.setCorrection(nil, for: "s1", in: initial) }
        let changed = try await context(f)
        #expect(try await store.loadSnapshot(changed).corrections.isEmpty)
        _ = try await store.setCorrection(.musicOnly, for: "s2", in: changed)
        #expect(try Data(contentsOf: f.metadata(revision: initial.revision)) == saved)
        try canonical.write(to: f.canonical)
        #expect(try await store.loadSnapshot(initial).corrections == ["s1": .musicOnly])
        let other = f.root.appendingPathComponent("other-job")
        try FileManager.default.copyItem(at: f.job, to: other)
        let otherContext = try TranscriptReviewContext(job: other, document: try await TranscriptPreview.read(other))
        #expect(try await store.loadSnapshot(otherContext).corrections.isEmpty)
    }

    @Test func legacyV1ChecksMigrateWithoutOverwritingTheLegacyFile() async throws {
        let f = try Fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let initial = try await context(f), store = TranscriptReviewStore(root: f.reviews)
        try FileManager.default.createDirectory(at: f.reviews, withIntermediateDirectories: true)
        let key = SHA256.hash(data: Data(f.job.standardizedFileURL.path.utf8)).map { String(format: "%02x", $0) }.joined()
        let legacy = f.reviews.appendingPathComponent(key + ".json")
        let old = try JSONSerialization.data(withJSONObject: ["version": 1, "revision": initial.revision, "checked": Array(initial.keys)])
        try old.write(to: legacy)
        #expect(try await store.load(initial) == initial.keys)
        _ = try await store.setCorrection(.musicOnly, for: "s1", in: initial)
        #expect(try Data(contentsOf: legacy) == old)
        let record = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: f.metadata(revision: initial.revision))) as? [String: Any])
        #expect(record["version"] as? Int == 3)
        #expect(try await store.loadSnapshot(initial).corrections["s1"] == .musicOnly)
    }

    @Test func invalidAndOversizedCorrectionsAndLockedWritesRetainSavedData() async throws {
        let f = try Fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let store = TranscriptReviewStore(root: f.reviews), initial = try await context(f)
        let first = try await store.setCorrection(.musicOnly, for: "s1", in: initial)
        let current = try await context(f, corrections: first.corrections)
        let file = f.metadata(revision: current.revision), saved = try Data(contentsOf: file)
        for value in [TranscriptCorrection(kind: .text, text: " \n"), .init(kind: .text, text: nil),
                      .init(kind: .text, text: String(repeating: "x", count: TranscriptCorrection.maximumTextBytes + 1)),
                      .init(kind: .musicOnly, text: "Hidden speech")] {
            await rejects { try await store.setCorrection(value, for: "s1", in: current) }
        }
        await rejects { try await store.setCorrection(.musicOnly, for: "unknown", in: current) }
        let lock = Darwin.open(file.appendingPathExtension("lock").path, O_RDWR)
        #expect(lock >= 0); defer { Darwin.close(lock) }
        #expect(flock(lock, LOCK_EX | LOCK_NB) == 0)
        await rejects { try await store.setCorrection(nil, for: "s1", in: current) }
        #expect(try Data(contentsOf: file) == saved)
    }

    @Test func v2ManualCorrectionsRemainReadableAndMigrateWithoutLosingText() async throws {
        let f = try Fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        var current = try await context(f)
        try FileManager.default.createDirectory(at: f.reviews, withIntermediateDirectories: true)
        let file = f.metadata(revision: current.revision)
        try JSONSerialization.data(withJSONObject: ["version": 2, "revision": current.revision, "checked": [],
            "corrections": ["s1": ["kind": "text", "text": "Existing manual correction"]]]).write(to: file)
        let store = TranscriptReviewStore(root: f.reviews)
        let loaded = try await store.loadSnapshot(current)
        #expect(loaded.corrections["s1"]?.text == "Existing manual correction" && loaded.corrections["s1"]?.cloud == nil)
        current.corrections = loaded.corrections
        _ = try await store.setChecked(try #require(current.keys.first), checked: true, in: current)
        #expect(try await store.loadSnapshot(current).corrections == loaded.corrections)
        let record = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        #expect(record["version"] as? Int == 3)
    }

    @Test func statePublishesOnlySavedCorrectionsAndResetCannotChangeAnotherTranscript() async throws {
        let f = try Fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let store = TranscriptReviewStore(root: f.reviews), state = TranscriptReviewState(store: store)
        let original = try await TranscriptPreview.read(f.job)
        await state.load(job: f.job, document: original)
        state.setCorrection(.musicOnly, for: "s1")
        #expect(state.saving && state.corrections.isEmpty)
        await finish(state)
        #expect(state.error == nil && state.corrections["s1"] == .musicOnly)
        state.setCorrection(nil, for: "s1"); state.reset()
        await settle()
        #expect(state.context == nil && state.corrections.isEmpty && !state.saving)
        await state.load(job: f.job, document: original)
        #expect(state.corrections["s1"] == .musicOnly)
        // Failed persistence keeps the displayed correction and draft context available.
        let file = f.metadata(revision: try #require(original.revision))
        try Data("corrupt".utf8).write(to: file)
        state.setCorrection(nil, for: "s1")
        await finish(state)
        #expect(state.error != nil && state.corrections["s1"] == .musicOnly)
    }

    @Test(arguments: ["unknown-segment", "unknown-kind", "missing-corrections", "symlink", "fifo"])
    func corruptCorrectionRecordsFailClosedWithoutRewritingEvidence(scenario: String) async throws {
        let f = try Fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let store = TranscriptReviewStore(root: f.reviews), initial = try await context(f)
        _ = try await store.setCorrection(.musicOnly, for: "s1", in: initial)
        let file = f.metadata(revision: initial.revision), original = try Data(contentsOf: f.canonical)
        if scenario == "symlink" || scenario == "fifo" {
            try FileManager.default.removeItem(at: file)
            if scenario == "symlink" { try FileManager.default.createSymbolicLink(at: file, withDestinationURL: f.canonical) }
            else { #expect(mkfifo(file.path, 0o600) == 0) }
        } else {
            var record: [String: Any] = ["version": 2, "revision": initial.revision, "checked": []]
            if scenario != "missing-corrections" {
                record["corrections"] = [scenario == "unknown-segment" ? "missing" : "s1": ["kind": scenario == "unknown-kind" ? "invented" : "musicOnly"]]
            }
            try JSONSerialization.data(withJSONObject: record).write(to: file)
        }
        await rejects { try await store.loadSnapshot(initial) }
        await rejects { try await store.setCorrection(.musicOnly, for: "s2", in: initial) }
        #expect(try Data(contentsOf: f.canonical) == original)
    }

    @Test func aggregateSizeLimitRejectsNewEditWithoutLosingPreviousCorrections() async throws {
        let f = try Fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        var payload = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: f.canonical)) as? [String: Any])
        payload["segments"] = (0..<20).map { ReadingFixtures.segment("s\($0)", "Original", start: $0 * 3000, end: $0 * 3000 + 1000) }
        try JSONSerialization.data(withJSONObject: payload).write(to: f.canonical)
        let store = TranscriptReviewStore(root: f.reviews)
        var current = try await context(f)
        let correction = TranscriptCorrection(kind: .text, text: String(repeating: "x", count: TranscriptCorrection.maximumTextBytes))
        for i in 0..<15 {
            let saved = try await store.setCorrection(correction, for: "s\(i)", in: current)
            current.corrections = saved.corrections
        }
        let file = f.metadata(revision: current.revision), saved = try Data(contentsOf: file)
        await rejects { try await store.setCorrection(correction, for: "s15", in: current) }
        #expect(try Data(contentsOf: file) == saved)
        #expect(try await store.loadSnapshot(current).corrections.count == 15)
    }

    @Test func manualVariantsDoNotInventRecognitionDisagreementAndRestoreRebuildsCachedExports() throws {
        var a = ReadingFixtures.segment("a", "Same"), b = ReadingFixtures.segment("b", "Same", channel: 1)
        a["needs_review"] = false; a["review_reasons"] = []; b["needs_review"] = false; b["review_reasons"] = []
        let original = try ReadingFixtures.document([a, b])
        let changed = original.applying(["a": .musicOnly])
        #expect(changed.reviewItems.isEmpty && TranscriptReading.reviewItems(in: changed).isEmpty)
        #expect(!changed.readingGroups[0].isShared(in: changed))
        #expect(changed.readingGroups[0].isShared(in: changed, originalRecognition: true))
        #expect(changed.markdownText.contains("Channel 1") && changed.markdownText.contains("[Music only]"))
        #expect(changed.applying([:]).markdownText == original.markdownText)
        #expect(changed.applying([:]).text == original.text)
    }
}
