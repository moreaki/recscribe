import Foundation
import Testing
@testable import RecScribe

@MainActor
struct TranscriptStorageTests {
    private func fixture() throws -> (root: URL, jobs: URL, job: URL, source: URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let jobs = root.appendingPathComponent("Jobs", isDirectory: true)
        let job = jobs.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: job, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("recording.recscribe.json")
        var session = RecordingSession(sampleRate: 16_000, channels: 1, channelMap: ["mic"], options: .init())
        session.parts = [.init(path: "recording.wav", startSample: 0, startedAt: Date())]
        try session.save(source)
        try Data("original audio".utf8).write(to: root.appendingPathComponent("recording.wav"))
        try JSONSerialization.data(withJSONObject: ["schema_version": "1.0", "processing": ["mode": "verbatim"],
            "source": ["path": source.path, "duration_ms": 1000, "channels": 1, "sample_rate": 16000],
            "segments": [], "review_reasons": []]).write(to: job.appendingPathComponent("transcript.json"))
        try JSONSerialization.data(withJSONObject: ["schema_version": "1.0", "state": "completed", "progress": 1])
            .write(to: job.appendingPathComponent("manifest.json"))
        try Data("raw evidence".utf8).write(to: job.appendingPathComponent("transcript.raw.json"))
        return (root, jobs, job, source)
    }

    @Test(arguments: ["valid", "missing-source", "missing-part", "missing-job", "corrupt-transcript"])
    func startupOnlyRestoresUsableRecordings(scenario: String) async throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        switch scenario {
        case "missing-source": try FileManager.default.removeItem(at: f.source)
        case "missing-part": try FileManager.default.removeItem(at: f.root.appendingPathComponent("recording.wav"))
        case "missing-job": try FileManager.default.removeItem(at: f.job)
        case "corrupt-transcript": try Data("broken".utf8).write(to: f.job.appendingPathComponent("transcript.json"))
        default: break
        }
        var persisted: [(URL?, URL?)] = []
        let library = SessionLibrary(initialJob: f.job, initialSource: f.source,
            rememberJob: { persisted.append(($0, $1)) }, jobsDirectory: f.jobs)
        #expect(library.latestJob == nil)
        #expect(library.latestSource == nil)
        #expect(library.progress == 0)
        await waitUntil("startup validation") { !library.restoringTranscript }
        if scenario == "valid" {
            #expect(library.latestJob == f.job)
            #expect(library.latestSource == f.source)
            #expect(library.progress == 1)
            #expect(persisted.isEmpty)
        } else {
            #expect(library.latestJob == nil)
            #expect(library.latestSource == nil)
            #expect(library.previousJob == nil)
            #expect(library.progress == 0)
            #expect(library.errorMessage == nil)
            #expect(library.activity == "Ready")
            #expect(persisted.count == 1)
            #expect(persisted.last?.0 == nil)
            #expect(persisted.last?.1 == nil)
            if scenario != "missing-job" { #expect(FileManager.default.fileExists(atPath: f.job.path)) }
        }
        await library.shutdown()
    }

    @Test func freshStartAndCancelledRestorationStayEmpty() async throws {
        let empty = SessionLibrary()
        #expect(!empty.restoringTranscript)
        #expect(empty.latestJob == nil)
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let library = SessionLibrary(initialJob: f.job, initialSource: f.source)
        library.setRecording(true)
        await settle()
        #expect(!library.restoringTranscript)
        #expect(library.latestJob == nil)
        #expect(library.latestSource == nil)
        await library.shutdown()
    }

    @Test(arguments: [false, true])
    func transcriptDeletionPreservesAudioAndOnlyClearsStateOnSuccess(failure: Bool) async throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        var remembered: URL? = f.job
        let library = SessionLibrary(initialJob: f.job, initialSource: f.source,
            rememberJob: { job, _ in remembered = job }, jobsDirectory: f.jobs)
        await waitUntil("restored transcript") { !library.restoringTranscript }
        let trashed = f.root.appendingPathComponent("Trashed")
        let result = await library.deleteTranscript(f.job) { job in
            if failure { throw POSIXError(.EACCES) }
            try FileManager.default.moveItem(at: job, to: trashed)
        }
        #expect(result == !failure)
        #expect(try Data(contentsOf: f.root.appendingPathComponent("recording.wav")) == Data("original audio".utf8))
        #expect(FileManager.default.fileExists(atPath: f.source.path))
        if failure {
            #expect(library.latestJob == f.job)
            #expect(remembered == f.job)
            #expect(library.errorMessage != nil)
            #expect(FileManager.default.fileExists(atPath: f.job.path))
        } else {
            #expect(library.latestJob == nil)
            #expect(library.latestSource == nil)
            #expect(library.progress == 0)
            #expect(remembered == nil)
            #expect(try Data(contentsOf: trashed.appendingPathComponent("transcript.raw.json")) == Data("raw evidence".utf8))
        }
        await library.shutdown()
    }

    @Test func activeCaptureAndJobsCannotBeDeletedAndExternalFoldersAreProtected() async throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let library = SessionLibrary(jobsDirectory: f.jobs)
        library.setRecording(true)
        #expect(!(await library.deleteTranscript(f.job)))
        library.setRecording(false)
        library.setLiveWork(true)
        #expect(!(await library.deleteTranscript(f.job)))
        library.setLiveWork(false)
        try JSONSerialization.data(withJSONObject: ["schema_version": "1.0", "state": "transcribing", "progress": 0.5])
            .write(to: f.job.appendingPathComponent("manifest.json"))
        #expect(!(await library.deleteTranscript(f.job)))
        #expect(FileManager.default.fileExists(atPath: f.job.path))
        #expect(!library.canDeleteTranscript(f.root))
        let link = f.jobs.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: f.job)
        #expect(!(await library.deleteTranscript(link)))
        #expect(FileManager.default.fileExists(atPath: f.job.path))
        await library.shutdown()
    }
}
