import Foundation
import Testing
@testable import RecScribe

@MainActor
struct LiveDraftStorageTests {
    private func fixture() throws -> (URL, URL, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let live = root.appendingPathComponent("Live"), draft = live.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: draft, withIntermediateDirectories: true)
        try Data("immutable raw evidence".utf8).write(to: draft.appendingPathComponent("chunk.raw.json"))
        try Data("original audio".utf8).write(to: root.appendingPathComponent("original.wav"))
        return (root, live, draft)
    }

    @Test func inventoryIsBoundedMetadataOnlyAndQuotaNeverRemovesEvidence() throws {
        let (root, live, draft) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let raw = try Data(contentsOf: draft.appendingPathComponent("chunk.raw.json"))
        let snapshot = try LiveDraftStorage.scan(live, cancel: WorkCancellation())
        #expect(snapshot.entries.count == 1 && snapshot.bytes == raw.count)
        #expect(!LiveDraftStorage.permits(snapshot, draft: live.appendingPathComponent(UUID().uuidString), maximumDrafts: 1))
        #expect(LiveDraftStorage.permits(snapshot, draft: draft, maximumDrafts: 1))
        #expect(!LiveDraftStorage.permits(snapshot, draft: draft, maximumBytes: 1))
        let limited = try LiveDraftStorage.scan(live, cancel: WorkCancellation(), maximumEntries: 1)
        #expect(limited.incomplete)
        #expect(!LiveDraftStorage.permits(limited, draft: draft))
        #expect(try Data(contentsOf: draft.appendingPathComponent("chunk.raw.json")) == raw)
        let cancel = WorkCancellation(); cancel.cancel()
        #expect(throws: CancellationError.self) { try LiveDraftStorage.scan(live, cancel: cancel) }
    }

    @Test func symlinksAndRecordingManifestsProtectOriginals() async throws {
        let (root, live, draft) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createSymbolicLink(at: draft.appendingPathComponent("link"), withDestinationURL: root.appendingPathComponent("original.wav"))
        let snapshot = try LiveDraftStorage.scan(live, cancel: WorkCancellation())
        #expect(snapshot.incomplete)
        try FileManager.default.removeItem(at: draft.appendingPathComponent("link"))
        try Data("recording manifest".utf8).write(to: draft.appendingPathComponent("take.recscribe.json"))
        let store = LiveDraftStore(root: live)
        await store.refresh()
        let entry = try #require(store.inventory.entries.first)
        #expect(store.isProtected(entry))
        #expect(!(await store.trash(entry, move: { _ in Issue.record("Must not move recordings") })))
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("original.wav").path))
    }

    @Test func explicitTrashPreservesOriginalAndChecksActivityGateLeaseAndChangedContents() async throws {
        let (root, live, draft) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let gate = CaptureSessionGate(), captureOwner = UUID()
        let store = LiveDraftStore(root: live, gate: gate)
        await store.refresh()
        let entry = try #require(store.inventory.entries.first)
        try gate.acquire(captureOwner)
        #expect(!(await store.trash(entry, move: { _ in Issue.record("Capture gate must win") })))
        gate.release(captureOwner)
        do {
            let lease = try LiveDraftStorage.lease(draft, in: live)
            #expect(!(await store.trash(entry, move: { _ in Issue.record("Active worker lease must win") })))
            withExtendedLifetime(lease) {}
        }
        // Revalidate after confirmation; a newly added recording must prevent Trash.
        let manifest = draft.appendingPathComponent("take.recscribe.json")
        try Data().write(to: manifest)
        #expect(!(await store.trash(entry, move: { _ in Issue.record("Changed contents must be checked") })))
        try FileManager.default.removeItem(at: manifest)
        let trash = root.appendingPathComponent("Trashed")
        #expect(await store.trash(entry, move: { try FileManager.default.moveItem(at: $0, to: trash) }))
        #expect(try String(contentsOf: trash.appendingPathComponent("chunk.raw.json"), encoding: .utf8) == "immutable raw evidence")
        #expect(try String(contentsOf: root.appendingPathComponent("original.wav"), encoding: .utf8) == "original audio")
        #expect(store.inventory.entries.isEmpty && store.errorMessage == nil)
    }

    @Test func backgroundScratchCleanupDefersToWorkerLeaseAndRetainsRawEvidence() throws {
        let (root, live, draft) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let working = draft.appendingPathComponent("working.wav")
        try Data("scratch".utf8).write(to: working)
        do {
            let lease = try LiveDraftStorage.lease(draft, in: live)
            let report = LiveTranscription.pruneDisposableWorkingFiles(in: live)
            #expect(report.deferredForActivity && report.removedFiles.isEmpty)
            #expect(FileManager.default.fileExists(atPath: working.path))
            withExtendedLifetime(lease) {}
        }
        let report = LiveTranscription.pruneDisposableWorkingFiles(in: live)
        #expect(report.removedFiles.contains(working))
        #expect(try String(contentsOf: draft.appendingPathComponent("chunk.raw.json"), encoding: .utf8) == "immutable raw evidence")
    }

    @Test func forgettingTrashedDraftNormalizesDirectoryURLHintsAndKeepsOriginalSource() async throws {
        let (root, liveRoot, _) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let live = LiveTranscription(liveRoot: liveRoot)
        live.recordingStarted(root.appendingPathComponent("original.wav"))
        live.recordingStopped()
        await live.shutdown()
        let draft = try #require(live.directory)
        let source = live.sourceURL
        live.forgetDraft(URL(fileURLWithPath: draft.path, isDirectory: false))
        #expect(live.directory?.path != draft.path)
        #expect(live.sourceURL == source && !live.enabled && live.segments.isEmpty)
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("original.wav").path))
    }

    @Test func trashedCloudDraftIsForgottenAcrossDirectoryURLHints() async {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let draft = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        var remembered: URL?
        let library = SessionLibrary(rememberJob: { job, _ in remembered = job }, jobsDirectory: root)
        library.acceptCloudTranscript(draft, source: root.appendingPathComponent("original.recscribe.json"))
        #expect(library.latestJob == draft && remembered == draft)
        library.forgetTranscript(URL(fileURLWithPath: draft.path, isDirectory: false))
        #expect(library.latestJob == nil && library.latestSource == nil && remembered == nil && library.progress == 0)
        await library.shutdown()
    }

    @Test func quotaPausesOnlyOptionalLiveWorkAndRawDraftsStayIntact() async throws {
        let (root, liveRoot, draft) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        for _ in 1..<LiveDraftStorage.maximumDrafts {
            try FileManager.default.createDirectory(at: liveRoot.appendingPathComponent(UUID().uuidString), withIntermediateDirectories: false)
        }
        let live = LiveTranscription(liveRoot: liveRoot, work: { _, _, _, _, _, _ in
            Issue.record("Quota must prevent ASR work"); return nil
        })
        live.setEnabled(true)
        live.recordingStarted(root.appendingPathComponent("original.wav"))
        await waitUntil("storage quota") { live.errorMessage != nil && !live.busy }
        #expect(!live.enabled)
        #expect(live.errorMessage?.contains("storage") == true)
        #expect(!live.captureNeedsReview)
        #expect(FileManager.default.fileExists(atPath: draft.appendingPathComponent("chunk.raw.json").path))
        #expect(try String(contentsOf: root.appendingPathComponent("original.wav"), encoding: .utf8) == "original audio")
        live.recordingStopped()
        await live.shutdown()
    }
}
