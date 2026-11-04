import Foundation
import Testing
@testable import RecScribe

@MainActor
struct SessionDeletionTests {
    private func fixture() throws -> (URL, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        let manifest = root.appendingPathComponent("Test.recscribe.json")
        var session = RecordingSession(sampleRate: 48000, channels: 1, channelMap: ["mic"], options: .init())
        session.parts = ["Test.wav", "Test-Part2.wav", "missing.wav"].map {
            .init(path: $0, startSample: 0, startedAt: Date())
        }
        session.artifacts = [.init(path: "Test.flac", format: .flac, sha256: "", sizeBytes: 0, verification: "fixture")]
        for name in ["Test.wav", "Test-Part2.wav", "Test.flac", "unrelated.wav"] {
            try Data(name.utf8).write(to: root.appendingPathComponent(name))
        }
        try session.save(manifest)
        return (root, manifest)
    }

    @Test func groupsAllExistingPartsAndArchivesForRestoration() throws {
        let (root, manifest) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        var trashed = false
        try SessionDeletion.moveToTrash(manifest) { bundle in
            let names = try FileManager.default.contentsOfDirectory(atPath: bundle.path)
            #expect(Set(names) == ["Test.wav", "Test-Part2.wav", "Test.flac", "Test.recscribe.json"])
            #expect(try RecordingSession.read(bundle.appendingPathComponent(manifest.lastPathComponent)).parts.count == 3)
            trashed = true
        }
        #expect(trashed)
        #expect(!FileManager.default.fileExists(atPath: manifest.path))
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("unrelated.wav").path))
    }

    @Test func trashFailureRestoresOriginalFiles() throws {
        let (root, manifest) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(throws: POSIXError.self) {
            try SessionDeletion.moveToTrash(manifest) { _ in throw POSIXError(.EACCES) }
        }
        #expect(try RecordingSession.read(manifest).parts.count == 3)
        for name in ["Test.wav", "Test-Part2.wav", "Test.flac", "unrelated.wav"] {
            #expect(try Data(contentsOf: root.appendingPathComponent(name)) == Data(name.utf8))
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).allSatisfy { !$0.contains("-Deleted-") })
    }

    @Test func lockedSessionCannotBeDeleted() throws {
        let (root, manifest) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let lease = try SessionLease(manifest)
        defer { withExtendedLifetime(lease) {} }
        #expect(throws: SessionError.self) {
            try SessionDeletion.moveToTrash(manifest) { _ in Issue.record("Must not trash a locked session") }
        }
        #expect(FileManager.default.fileExists(atPath: manifest.path))
    }

    @Test func invalidPathsPreventAnyFileMoves() throws {
        let (root, manifest) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        var session = try RecordingSession.read(manifest)
        session.parts[0].path = "../outside.wav"
        try session.save(manifest)
        #expect(throws: SessionError.self) {
            try SessionDeletion.moveToTrash(manifest) { _ in Issue.record("Must not trash invalid session") }
        }
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("Test.wav").path))
    }

    @Test func recordingAndLiveWorkBlockLibraryDeletion() async throws {
        let (root, manifest) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let entry = SessionEntry(id: manifest, session: try RecordingSession.read(manifest))
        let library = SessionLibrary()
        library.setRecording(true)
        await library.moveToTrash(entry)
        #expect(library.errorMessage != nil)
        #expect(FileManager.default.fileExists(atPath: manifest.path))
        library.setRecording(false)
        library.setLiveWork(true)
        await library.moveToTrash(entry)
        #expect(!library.canDeleteRecording)
        #expect(FileManager.default.fileExists(atPath: manifest.path))
    }

    @Test(arguments: [false, true])
    func relatedJobsAreOptInIdentityCheckedAndRestoredOnFailure(failTrash: Bool) throws {
        let (root, manifest) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        var session = try RecordingSession.read(manifest)
        let part = root.appendingPathComponent(session.parts[0].path)
        session.parts[0].sha256 = try RecordingSession.hash(part)
        try session.save(manifest)
        let jobs = root.appendingPathComponent("Jobs", isDirectory: true)
        try FileManager.default.createDirectory(at: jobs, withIntermediateDirectories: false)
        func job(id: UUID?, state: String = "completed", snapshot: UUID? = nil,
                 path: String? = nil, hash: String? = nil) throws -> URL {
            let folder = jobs.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
            try JSONSerialization.data(withJSONObject: ["state": state]).write(to: folder.appendingPathComponent("manifest.json"))
            var report = ["path": path ?? manifest.path]
            if let id { report["session_id"] = id.uuidString }
            if let hash { report["sha256"] = hash }
            try JSONSerialization.data(withJSONObject: report).write(to: folder.appendingPathComponent("audio-report.json"))
            if let snapshot {
                try JSONSerialization.data(withJSONObject: ["id": snapshot.uuidString])
                    .write(to: folder.appendingPathComponent("source-session.snapshot.json"))
            }
            try Data("raw evidence".utf8).write(to: folder.appendingPathComponent("transcript.raw.json"))
            return folder
        }
        let native = try job(id: session.id)
        let cloud = try job(id: nil, snapshot: session.id)
        let legacy = try job(id: nil, path: part.path, hash: session.parts[0].sha256)
        let active = try job(id: session.id, state: "transcribing")
        let unrelated = try job(id: UUID())
        let pathOnly = try job(id: nil, path: part.path)
        let wrongHash = try job(id: nil, path: part.path, hash: String(repeating: "0", count: 64))
        let conflicting = try job(id: UUID(), snapshot: session.id)
        let link = jobs.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: native)
        let expected = Set([native, cloud, legacy])
        let related = try SessionDeletion.relatedJobs(to: session, beside: manifest, in: jobs, cancel: WorkCancellation())
        #expect(Set(related.map(\.path)) == Set(expected.map(\.path)))

        // The default leaves every job in place; a failed Trash operation restores the audio.
        #expect(throws: POSIXError.self) {
            try SessionDeletion.moveToTrash(manifest) { bundle in
                #expect(!FileManager.default.fileExists(atPath: bundle.appendingPathComponent("Transcripts").path))
                throw POSIXError(.EACCES)
            }
        }
        for folder in expected { #expect(FileManager.default.fileExists(atPath: folder.path)) }

        func trash(_ bundle: URL) throws {
            for folder in expected {
                let evidence = bundle.appendingPathComponent("Transcripts/\(folder.lastPathComponent)/transcript.raw.json")
                #expect(try Data(contentsOf: evidence) == Data("raw evidence".utf8))
            }
            if failTrash { throw POSIXError(.EACCES) }
        }
        if failTrash {
            #expect(throws: POSIXError.self) {
                try SessionDeletion.moveToTrash(manifest, jobsDirectory: jobs, trash: trash)
            }
            #expect(FileManager.default.fileExists(atPath: manifest.path))
            for folder in expected {
                #expect(try Data(contentsOf: folder.appendingPathComponent("transcript.raw.json")) == Data("raw evidence".utf8))
            }
        } else {
            let trashed = try SessionDeletion.moveToTrash(manifest, jobsDirectory: jobs, trash: trash)
            #expect(Set(trashed.map(\.path)) == Set(expected.map(\.path)))
        }
        for folder in [active, unrelated, pathOnly, wrongHash, conflicting] {
            #expect(FileManager.default.fileExists(atPath: folder.path))
        }
        #expect((try link.resourceValues(forKeys: [.isSymbolicLinkKey])).isSymbolicLink == true)
        #expect(try Data(contentsOf: root.appendingPathComponent("unrelated.wav")) == Data("unrelated.wav".utf8))
    }

    @Test func cancelledOrOverLimitScanLeavesRecordingInPlace() throws {
        let (root, manifest) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let cancelled = WorkCancellation()
        cancelled.cancel()
        #expect(throws: CancellationError.self) {
            try SessionDeletion.moveToTrash(manifest, cancel: cancelled) { _ in Issue.record("Must not trash") }
        }
        let jobs = root.appendingPathComponent("Jobs", isDirectory: true)
        try FileManager.default.createDirectory(at: jobs, withIntermediateDirectories: false)
        for _ in 0...SessionDeletion.maximumRelatedJobs {
            try FileManager.default.createDirectory(at: jobs.appendingPathComponent(UUID().uuidString), withIntermediateDirectories: false)
        }
        #expect(throws: SessionError.self) {
            try SessionDeletion.moveToTrash(manifest, jobsDirectory: jobs) { _ in Issue.record("Must not trash a partial scan") }
        }
        #expect(FileManager.default.fileExists(atPath: manifest.path))
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).allSatisfy { !$0.contains("-Deleted-") })
    }
}
