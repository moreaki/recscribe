import Darwin
import Foundation
import Testing
@testable import RecScribe

@MainActor
struct TranscriptReviewTests {
    private struct Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("recscribe-review-\(UUID())")
        var job: URL { root.appendingPathComponent("job") }
        var reviews: URL { root.appendingPathComponent("Review") }
        var canonical: URL { job.appendingPathComponent("transcript.json") }
        var raw: URL { job.appendingPathComponent("transcript.raw.json") }
        var audio: URL { root.appendingPathComponent("original.audio") }
        init() throws {
            try FileManager.default.createDirectory(at: job, withIntermediateDirectories: true)
            try Data("original audio bytes".utf8).write(to: audio)
            try Data("original recognizer bytes".utf8).write(to: raw)
            try JSONSerialization.data(withJSONObject: ["schema_version": "1.0", "processing": ["mode": "verbatim"],
                "source": ["path": audio.path, "duration_ms": 8000, "channels": 2, "sample_rate": 16000],
                "segments": [ReadingFixtures.segment("s1", "Monday"), ReadingFixtures.segment("s2", "Tuesday", channel: 1),
                             ReadingFixtures.segment("s3", "A separate passage", start: 5000, end: 8000)],
                "review_reasons": ["confidence_unavailable"]], options: .sortedKeys).write(to: canonical)
        }
        func metadata() throws -> URL {
            try #require(FileManager.default.contentsOfDirectory(at: reviews, includingPropertiesForKeys: nil).first { $0.pathExtension == "json" })
        }
    }

    private func rejects<T>(_ operation: () async throws -> T) async {
        do { _ = try await operation(); Issue.record("Expected the review operation to fail") }
        catch { }
    }

    private func finishSaving(_ state: TranscriptReviewState) async throws {
        let clock = ContinuousClock(), deadline = ContinuousClock.now + .seconds(5)
        while state.saving && clock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        #expect(!state.saving)
    }

    @Test func acknowledgementsSurviveReloadAndReopenWithoutChangingOriginalsOrExports() async throws {
        let f = try Fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let originals = try [f.canonical, f.raw, f.audio].map { try Data(contentsOf: $0) }
        let document = try await TranscriptPreview.read(f.job)
        let context = try TranscriptReviewContext(job: f.job, document: document)
        let item = try #require(document.reviewItems.first { $0.groupID != nil })
        let exports = [document.markdownText, document.reviewPlainText, document.summaryText]
        let store = TranscriptReviewStore(root: f.reviews)
        #expect(try await store.load(context) == [])
        #expect(!FileManager.default.fileExists(atPath: f.reviews.path))
        #expect(try await store.setChecked(item.key, checked: true, in: context) == [item.key])
        let reopened = TranscriptReviewStore(root: f.reviews)
        #expect(try await reopened.load(context) == [item.key])
        #expect(try await reopened.setChecked(item.key, checked: false, in: context) == [])
        #expect(try await store.load(context) == [])
        #expect(try [f.canonical, f.raw, f.audio].map { try Data(contentsOf: $0) } == originals)
        let after = try await TranscriptPreview.read(f.job)
        #expect([after.markdownText, after.reviewPlainText, after.summaryText] == exports)
        #expect(after.segments.allSatisfy { $0.needsReview })
        let saved = try String(contentsOf: f.metadata(), encoding: .utf8)
        #expect(!saved.contains("Monday") && !saved.contains(f.audio.path))
    }

    @Test func jobIdentityAndExactRevisionPreventStaleAcknowledgements() async throws {
        let f = try Fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let document = try await TranscriptPreview.read(f.job)
        let context = try TranscriptReviewContext(job: f.job, document: document)
        let key = try #require(document.reviewItems.first?.key)
        let store = TranscriptReviewStore(root: f.reviews)
        _ = try await store.setChecked(key, checked: true, in: context)
        let other = f.root.appendingPathComponent("other-job")
        try FileManager.default.copyItem(at: f.job, to: other)
        let otherDocument = try await TranscriptPreview.read(other)
        let otherContext = try TranscriptReviewContext(job: other, document: otherDocument)
        #expect(otherContext.revision == context.revision)
        #expect(try await store.load(otherContext) == [])
        var payload = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: f.canonical)) as? [String: Any])
        payload["future_provenance"] = "new evidence not represented in the old preview schema"
        try JSONSerialization.data(withJSONObject: payload, options: .sortedKeys).write(to: f.canonical, options: .atomic)
        let changed = try await TranscriptPreview.read(f.job)
        let changedContext = try TranscriptReviewContext(job: f.job, document: changed)
        #expect(changed.text == document.text && changed.revision != document.revision)
        #expect(try await store.load(changedContext) == [])
        let saved = try Data(contentsOf: f.metadata())
        await rejects { try await store.setChecked(key, checked: false, in: context) }
        #expect(try Data(contentsOf: f.metadata()) == saved)
        #expect(try await store.setChecked(key, checked: true, in: changedContext) == [key])
    }

    @Test func reviewKeysUseReasonScopeAndEveryOriginalSegmentRatherThanListPosition() throws {
        let a = try ReadingFixtures.document([ReadingFixtures.segment("s1", "Monday"), ReadingFixtures.segment("s2", "Tuesday", channel: 1)])
        let b = try ReadingFixtures.document([ReadingFixtures.segment("other-id", "Monday"), ReadingFixtures.segment("s2", "Tuesday", channel: 1)])
        #expect(a.reviewItems.count == 1)
        #expect(a.reviewItems[0].key != b.reviewItems[0].key)
        let first = TranscriptReading.ReviewItem(id: "document-0", groupID: nil, title: "A", reasons: ["confidence_unavailable"])
        let moved = TranscriptReading.ReviewItem(id: "document-7", groupID: nil, title: "B", reasons: ["confidence_unavailable"])
        let passage = TranscriptReading.ReviewItem(id: "passage-s1", groupID: "s1", title: "A", reasons: ["confidence_unavailable"], segmentIDs: ["s1"])
        #expect(first.key == moved.key && passage.key != first.key)
    }

    @Test(arguments: ["corrupt", "future-version", "oversized", "symlink", "fifo"])
    func unusableReviewFilesFailWithoutOverwritingEvidence(scenario: String) async throws {
        let f = try Fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let document = try await TranscriptPreview.read(f.job)
        let context = try TranscriptReviewContext(job: f.job, document: document)
        let key = try #require(document.reviewItems.first?.key), store = TranscriptReviewStore(root: f.reviews)
        _ = try await store.setChecked(key, checked: true, in: context)
        let metadata = try f.metadata(), original = try Data(contentsOf: f.canonical)
        try FileManager.default.removeItem(at: metadata)
        switch scenario {
        case "corrupt": try Data("{".utf8).write(to: metadata)
        case "future-version":
            try JSONSerialization.data(withJSONObject: ["version": 2, "revision": context.revision, "checked": [key]]).write(to: metadata)
        case "oversized": try Data(count: TranscriptReviewStore.maximumBytes + 1).write(to: metadata)
        case "symlink": try FileManager.default.createSymbolicLink(at: metadata, withDestinationURL: f.canonical)
        default: #expect(mkfifo(metadata.path, 0o600) == 0)
        }
        await rejects { try await store.load(context) }
        await rejects { try await store.setChecked(key, checked: false, in: context) }
        #expect(try Data(contentsOf: f.canonical) == original)
        if scenario == "corrupt" { #expect(try Data(contentsOf: metadata) == Data("{".utf8)) }
        if scenario == "oversized" { #expect(try metadata.resourceValues(forKeys: [.fileSizeKey]).fileSize == TranscriptReviewStore.maximumBytes + 1) }
    }

    @Test func serializedSavesRetainOtherItemsAndLockedWritesDoNotReportSuccess() async throws {
        let f = try Fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let document = try await TranscriptPreview.read(f.job)
        let context = try TranscriptReviewContext(job: f.job, document: document)
        let store = TranscriptReviewStore(root: f.reviews)
        try await withThrowingTaskGroup(of: Void.self) { group in
            for item in document.reviewItems {
                group.addTask { _ = try await store.setChecked(item.key, checked: true, in: context) }
            }
            try await group.waitForAll()
        }
        #expect(try await store.load(context) == context.keys)
        let metadata = try f.metadata(), saved = try Data(contentsOf: metadata)
        let lock = Darwin.open(metadata.appendingPathExtension("lock").path, O_RDWR)
        #expect(lock >= 0); defer { Darwin.close(lock) }
        #expect(flock(lock, LOCK_EX | LOCK_NB) == 0)
        let key = try #require(context.keys.first)
        await rejects { try await TranscriptReviewStore(root: f.reviews).setChecked(key, checked: false, in: context) }
        #expect(try Data(contentsOf: metadata) == saved)
    }

    @Test func cancellationUnknownItemsAndNonregularTranscriptsCannotSave() async throws {
        let f = try Fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let document = try await TranscriptPreview.read(f.job)
        let context = try TranscriptReviewContext(job: f.job, document: document)
        let store = TranscriptReviewStore(root: f.reviews), key = try #require(context.keys.first)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await store.setChecked(key, checked: true, in: context)
        }
        await rejects { try await task.value }
        #expect(!FileManager.default.fileExists(atPath: f.reviews.path))
        await rejects { try await store.setChecked("unknown", checked: true, in: context) }
        try FileManager.default.removeItem(at: f.canonical)
        #expect(mkfifo(f.canonical.path, 0o600) == 0)
        await rejects { try await store.setChecked(key, checked: true, in: context) }
        #expect(try FileManager.default.contentsOfDirectory(at: f.reviews, includingPropertiesForKeys: nil).allSatisfy { $0.pathExtension != "json" })
    }

    @Test(arguments: ["duplicate-sources", "too-many-items"])
    func ambiguousOrExcessiveReviewScopesCannotCreateAcknowledgements(scenario: String) async throws {
        let f = try Fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        var payload = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: f.canonical)) as? [String: Any])
        if scenario == "duplicate-sources" {
            payload["segments"] = [ReadingFixtures.segment("duplicate", "Monday"), ReadingFixtures.segment("duplicate", "Tuesday", channel: 1)]
        } else {
            payload["review_reasons"] = (0...TranscriptReviewStore.maximumItems).map { "note_\($0)" }
        }
        try JSONSerialization.data(withJSONObject: payload).write(to: f.canonical)
        let document = try await TranscriptPreview.read(f.job)
        #expect(throws: SessionError.self) { try TranscriptReviewContext(job: f.job, document: document) }
        #expect(!FileManager.default.fileExists(atPath: f.reviews.path))
    }

    @Test func stateShowsOnlyPersistedChecksAndRecoversAfterWriteFailureOrContextSwitch() async throws {
        let f = try Fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let document = try await TranscriptPreview.read(f.job), item = try #require(document.reviewItems.first)
        let state = TranscriptReviewState(store: TranscriptReviewStore(root: f.reviews))
        await state.load(job: f.job, document: document)
        #expect(state.context != nil && state.checked.isEmpty)
        try Data("blocked directory".utf8).write(to: f.reviews)
        state.setChecked(item, checked: true)
        #expect(state.saving && state.checked.isEmpty)
        try await finishSaving(state)
        #expect(state.error != nil && state.checked.isEmpty)
        try FileManager.default.removeItem(at: f.reviews)
        await state.load(job: f.job, document: document)
        state.setChecked(item, checked: true)
        #expect(state.saving && state.checked.isEmpty)
        try await finishSaving(state)
        #expect(state.error == nil && state.checked == [item.key])
        state.setChecked(item, checked: false)
        state.reset() // Cancel before the queued save can run on the main actor.
        for _ in 0..<10 { await Task.yield() }
        #expect(state.context == nil && state.checked.isEmpty && state.error == nil)
        await state.load(job: f.job, document: document)
        #expect(state.checked == [item.key])
        let other = f.root.appendingPathComponent("other-job")
        try FileManager.default.copyItem(at: f.job, to: other)
        await state.load(job: other, document: try await TranscriptPreview.read(other))
        let expectedContext = try TranscriptReviewContext(job: other, document: try await TranscriptPreview.read(other))
        #expect(state.context == expectedContext)
        #expect(state.checked.isEmpty && state.error == nil)
    }
}
