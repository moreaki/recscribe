import Foundation
import os
import Testing
@testable import RecScribe

@MainActor struct RecordingBulkDeletionTests {
    private func fixture(_ count: Int = 3) throws -> (URL, [SessionEntry], URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let jobs = root.appendingPathComponent("Jobs", isDirectory: true)
        try FileManager.default.createDirectory(at: jobs, withIntermediateDirectories: true)
        var entries: [SessionEntry] = []
        for i in 0..<count {
            let url = root.appendingPathComponent("Take\(i).recscribe.json")
            var session = RecordingSession(sampleRate: 48_000, channels: 1, channelMap: ["mic"], options: .init())
            session.parts = [.init(path: "Take\(i).wav", startSample: 0, startedAt: Date())]
            let audio = root.appendingPathComponent("Take\(i).wav")
            try Data("original-\(i)".utf8).write(to: audio)
            session.parts[0].sha256 = try RecordingSession.hash(audio)
            session.status = .completed
            try session.save(url)
            entries.append(.init(id: url, session: session))
        }
        return (root, entries, jobs)
    }
    private func job(_ root: URL, id: UUID?, snapshot: UUID? = nil, state: String = "completed") throws -> URL {
        let url = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: ["state": state]).write(to: url.appendingPathComponent("manifest.json"))
        if let id { try JSONSerialization.data(withJSONObject: ["session_id": id.uuidString]).write(to: url.appendingPathComponent("audio-report.json")) }
        if let snapshot { try JSONSerialization.data(withJSONObject: ["id": snapshot.uuidString]).write(to: url.appendingPathComponent("source-session.snapshot.json")) }
        for name in ["transcript.raw.json", "transcript.json", "summary.txt", "edited.txt"] {
            try Data(name.utf8).write(to: url.appendingPathComponent(name))
        }
        return url
    }
    private func plan(_ entries: [SessionEntry], _ all: [SessionEntry], _ jobs: URL?) throws -> RecordingDeletionPlan {
        try RecordingDeletionPlanner.prepare(entries, library: all, jobsDirectory: jobs, cancel: WorkCancellation())
    }

    @Test func selectionRangesUseDisplayOrderAndStableIdentity() {
        let ids = (0..<5).map { URL(fileURLWithPath: "/take\($0)") }
        let some = RecordingSelection.toggling(ids[3], selected: [ids[1]], anchor: ids[1], order: ids, extend: true)
        #expect(some == Set(ids[1...3]))
        #expect(RecordingSelection.toggling(ids[1], selected: some, anchor: ids[3], order: ids, extend: true).isEmpty)
        #expect(RecordingSelection.toggling(ids[4], selected: some, anchor: URL(fileURLWithPath: "/gone"), order: ids, extend: true) == some.union([ids[4]]))
    }

    @Test func previewIncludesEveryVerifiedJobButKeepsActiveUnknownAndConflictingEvidence() throws {
        let (root, entries, jobs) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let a = try job(jobs, id: entries[0].session.id), b = try job(jobs, id: entries[0].session.id)
        let other = try job(jobs, id: entries[1].session.id)
        let active = try job(jobs, id: entries[0].session.id, state: "transcribing")
        let unknown = try job(jobs, id: nil)
        let conflicting = try job(jobs, id: entries[0].session.id, snapshot: entries[1].session.id)
        let preview = try plan([entries[0]], entries, jobs)
        #expect(Set(preview.items[0].jobs.map(\.url)) == [a,b])
        #expect(Set(preview.retained.map(\.url)) == [active,unknown,conflicting])
        #expect(!preview.items[0].jobs.contains { $0.url == other })
        #expect(entries.allSatisfy { FileManager.default.fileExists(atPath: $0.id.path) })
    }

    @Test(arguments: [false,true]) func scopesKeepOrGroupCompleteJobFolders(includeJobs: Bool) throws {
        let (root, entries, jobs) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let linked = try job(jobs, id: entries[0].session.id)
        let preview = try plan([entries[0]], entries, jobs)
        let newJob = try job(jobs, id: entries[0].session.id) // Never enroll work created after preview.
        var grouped: URL?
        let moved = try SessionDeletion.moveToTrash(entries[0].id, expected: preview.items[0], includePlannedJobs: includeJobs) { grouped = $0 }
        #expect(moved == (includeJobs ? [linked] : []))
        #expect(FileManager.default.fileExists(atPath: linked.path) == !includeJobs)
        #expect(FileManager.default.fileExists(atPath: newJob.path))
        #expect(try Data(contentsOf: #require(grouped).appendingPathComponent("Take0.wav")) == Data("original-0".utf8))
        if includeJobs {
            for name in ["transcript.raw.json", "transcript.json", "summary.txt", "edited.txt"] {
                #expect(try Data(contentsOf: #require(grouped).appendingPathComponent("Transcripts/\(linked.lastPathComponent)/\(name)")) == Data(name.utf8))
            }
        }
    }

    @Test(arguments: [false,true]) func changedRecordingOrJobRejectsFrozenPlan(changeJob: Bool) throws {
        let (root, entries, jobs) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let linked = try job(jobs, id: entries[0].session.id)
        let preview = try plan([entries[0]], entries, jobs)
        if changeJob {
            try JSONSerialization.data(withJSONObject: ["state":"transcribing"]).write(to: linked.appendingPathComponent("manifest.json"))
        } else {
            var session = entries[0].session; session.id = UUID(); try session.save(entries[0].id)
        }
        #expect(throws: SessionError.self) {
            try SessionDeletion.moveToTrash(entries[0].id, expected: preview.items[0], includePlannedJobs: true) { _ in Issue.record("Must not move changed data") }
        }
        #expect(FileManager.default.fileExists(atPath: entries[0].id.path))
        #expect(FileManager.default.fileExists(atPath: linked.path))
    }

    @Test func sharedAudioIsRejectedEvenWhenOnlyOneOwnerSelected() throws {
        let (root, entries, jobs) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        var shared = entries[1].session; shared.parts = entries[0].session.parts; try shared.save(entries[1].id)
        #expect(throws: SessionError.self) { try plan([entries[0]], entries, jobs) }
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("Take0.wav").path))
    }

    @Test func batchStopsAfterFailureRetainsUnattemptedAndClearsMovedJobPointers() async throws {
        let (root, entries, jobs) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let linked = try job(jobs, id: entries[0].session.id)
        let calls = OSAllocatedUnfairLock(initialState: 0)
        let remembered = OSAllocatedUnfairLock(initialState: [URL?]())
        let library = SessionLibrary(readSessions: { _ in .init(entries: entries, failures: []) },
            rememberJob: { job, _ in remembered.withLock { $0.append(job) } }, jobsDirectory: jobs,
            trashRecording: { _ in
                let count = calls.withLock { $0 += 1; return $0 }
                if count == 2 { throw POSIXError(.EACCES) }
            })
        library.rememberOpenedTranscript(linked, source: entries[0].id)
        let preview = try #require(await library.prepareDeletion(entries))
        let result = await library.deleteRecordings(preview, includeJobs: true)
        #expect(result.moved == [entries[0].id]); #expect(result.remaining == entries.dropFirst().map(\.id))
        #expect(result.failure != nil); #expect(calls.withLock { $0 } == 2)
        #expect(entries.dropFirst().allSatisfy { FileManager.default.fileExists(atPath: $0.id.path) })
        #expect(try Data(contentsOf: root.appendingPathComponent("Take1.wav")) == Data("original-1".utf8))
        #expect(remembered.withLock { $0.last } == .some(nil))
        await library.shutdown()
    }

    @Test(arguments: [false,true]) func captureAfterPreviewPreventsExecution(live: Bool) async throws {
        let (root, entries, jobs) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let library = SessionLibrary(jobsDirectory: jobs, trashRecording: { _ in Issue.record("Must not trash during capture") })
        let preview = try #require(await library.prepareDeletion(entries))
        if live { library.setLiveWork(true) } else { library.setRecording(true) }
        let result = await library.deleteRecordings(preview, includeJobs: false)
        #expect(result.moved.isEmpty); #expect(result.failure != nil)
        #expect(entries.allSatisfy { FileManager.default.fileExists(atPath: $0.id.path) })
        library.closeDeletionPreview(); await library.shutdown()
    }

    @Test func cancelledPreviewCannotBeExecutedAndReleasesEditReservation() async throws {
        let (root, entries, jobs) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let library = SessionLibrary(jobsDirectory: jobs, trashRecording: { _ in Issue.record("Cancelled plan must not execute") })
        let preview = try #require(await library.prepareDeletion(entries))
        #expect(!library.canDeleteRecording)
        library.closeDeletionPreview()
        #expect(library.canDeleteRecording)
        let result = await library.deleteRecordings(preview, includeJobs: false)
        #expect(result.moved.isEmpty); #expect(result.failure != nil)
        await library.shutdown()
    }
    @Test(arguments: [false,true]) func stopAndCaptureInterruptionKeepRemainingRecordings(capture: Bool) async throws {
        let (root, entries, jobs) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let started = AsyncStream<Void>.makeStream()
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let calls = OSAllocatedUnfairLock(initialState: 0)
        let library = SessionLibrary(jobsDirectory: jobs, trashRecording: { _ in
            calls.withLock { $0 += 1 }
            started.continuation.yield(())
            guard release.wait(timeout: .now() + 10) == .success else { throw POSIXError(.ETIMEDOUT) }
        })
        let preview = try #require(await library.prepareDeletion(entries))
        let work = Task { await library.deleteRecordings(preview, includeJobs: false) }
        var iterator = started.stream.makeAsyncIterator(); _ = await iterator.next()
        #expect(library.isDeleting(entries[0].id)); #expect(!library.canDeleteRecording)
        if capture { library.setRecording(true) } else { library.stopDeletionAfterCurrent() }
        release.signal()
        let result = await work.value
        #expect(result.moved == [entries[0].id]); #expect(result.stopped)
        #expect(result.remaining == entries.dropFirst().map(\.id)); #expect(calls.withLock { $0 } == 1)
        #expect(!library.isDeleting(entries[0].id))
        #expect(entries.dropFirst().allSatisfy { FileManager.default.fileExists(atPath: $0.id.path) })
        await library.shutdown()
    }

    @Test func changedUnselectedOwnerRejectsPreviewRatherThanMovingSharedAudio() throws {
        let (root, entries, jobs) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let preview = try plan([entries[0]], entries, jobs)
        var changed = entries[1].session; changed.parts = entries[0].session.parts; try changed.save(entries[1].id)
        #expect(throws: SessionError.self) {
            try SessionDeletion.moveToTrash(entries[0].id, expected: preview.items[0]) { _ in Issue.record("Must preserve newly shared files") }
        }
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("Take0.wav").path))
    }

    @Test func sourceTracksAndTheirJobsStayWithParentAndRestoreOnFailure() throws {
        let (root, entries, jobs) = try fixture(2); defer { try? FileManager.default.removeItem(at: root) }
        var parent = entries[0].session, child = entries[1].session
        parent.schemaVersion = 3; parent.captureEpoch = 100
        child.parentSessionID = parent.id; child.captureEpoch = 100
        parent.sourceTracks = [.init(role: .input("mic"), name: "Microphone", manifestPath: entries[1].id.lastPathComponent, channels: 1)]
        try child.save(entries[1].id); try parent.save(entries[0].id)
        let linked = try job(jobs, id: child.id)
        let parentEntry = SessionEntry(id: entries[0].id, session: parent)
        let preview = try plan([parentEntry], [parentEntry], jobs)
        #expect(preview.jobCount == 1)
        #expect(throws: POSIXError.self) {
            try SessionDeletion.moveToTrash(parentEntry.id, expected: preview.items[0], includePlannedJobs: true) { bundle in
                #expect(try Data(contentsOf: bundle.appendingPathComponent("Take1.wav")) == Data("original-1".utf8))
                #expect(FileManager.default.fileExists(atPath: bundle.appendingPathComponent("Transcripts/\(linked.lastPathComponent)/transcript.raw.json").path))
                throw POSIXError(.EACCES)
            }
        }
        #expect(try Data(contentsOf: root.appendingPathComponent("Take1.wav")) == Data("original-1".utf8))
        #expect(FileManager.default.fileExists(atPath: linked.path))
        #expect(FileManager.default.fileExists(atPath: entries[0].id.path))
        #expect(FileManager.default.fileExists(atPath: entries[1].id.path))
    }

    @Test func replacedJobSymlinkIsRejectedWithoutCreatingSidecarsInItsTarget() throws {
        let (root, entries, jobs) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let linked = try job(jobs, id: entries[0].session.id)
        let preview = try plan([entries[0]], entries, jobs)
        let external = root.appendingPathComponent("external")
        try FileManager.default.moveItem(at: linked, to: external)
        try FileManager.default.createSymbolicLink(at: linked, withDestinationURL: external)
        #expect(throws: SessionError.self) {
            try SessionDeletion.moveToTrash(entries[0].id, expected: preview.items[0], includePlannedJobs: true) { _ in Issue.record("Must not trash symlinks") }
        }
        #expect(!FileManager.default.fileExists(atPath: external.appendingPathComponent(".manifest.json.lock").path))
        #expect(FileManager.default.fileExists(atPath: entries[0].id.path))
    }

    @Test func realMacOSTrashBundleCanBeRestoredWithOriginalAudioAndJobEvidence() throws {
        let (root, entries, jobs) = try fixture(1)
        var trashed: URL?
        defer {
            if let trashed { try? FileManager.default.removeItem(at: trashed) }
            try? FileManager.default.removeItem(at: root)
        }
        let linked = try job(jobs, id: entries[0].session.id)
        let preview = try plan(entries, entries, jobs)
        try SessionDeletion.moveToTrash(entries[0].id, expected: preview.items[0], includePlannedJobs: true) { bundle in
            var destination: NSURL?
            try FileManager.default.trashItem(at: bundle, resultingItemURL: &destination)
            trashed = try #require(destination as URL?)
        }
        let bundle = try #require(trashed)
        #expect(bundle.lastPathComponent.hasPrefix("Take0-Deleted-"))
        #expect(!FileManager.default.fileExists(atPath: entries[0].id.path))
        #expect(try Data(contentsOf: bundle.appendingPathComponent("Take0.wav")) == Data("original-0".utf8))
        let dataFolder = bundle.appendingPathComponent("Transcripts/\(linked.lastPathComponent)")
        try FileManager.default.moveItem(at: dataFolder, to: linked)
        for name in ["Take0.wav", "Take0.recscribe.json"] {
            try FileManager.default.moveItem(at: bundle.appendingPathComponent(name), to: root.appendingPathComponent(name))
        }
        #expect(try RecordingSession.read(entries[0].id).id == entries[0].session.id)
        #expect(try RecordingSession.hash(root.appendingPathComponent("Take0.wav")) == entries[0].session.parts[0].sha256)
        #expect(try Data(contentsOf: linked.appendingPathComponent("transcript.raw.json")) == Data("transcript.raw.json".utf8))
    }

}
