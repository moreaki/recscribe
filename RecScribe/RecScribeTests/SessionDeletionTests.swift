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

    @Test func recordingAndLiveWorkBlockLibraryDeletion() throws {
        let (root, manifest) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let entry = SessionEntry(id: manifest, session: try RecordingSession.read(manifest))
        let library = SessionLibrary()
        library.setRecording(true)
        library.moveToTrash(entry)
        #expect(library.errorMessage != nil)
        #expect(FileManager.default.fileExists(atPath: manifest.path))
        library.setRecording(false)
        library.setLiveWork(true)
        library.moveToTrash(entry)
        #expect(!library.canDeleteRecording)
        #expect(FileManager.default.fileExists(atPath: manifest.path))
    }
}
