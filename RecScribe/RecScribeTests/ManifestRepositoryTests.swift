import Foundation
import Testing
@testable import RecScribe

@MainActor
struct ManifestRepositoryTests {
    @MainActor final class Gate<Value: Sendable> {
        var pending: [URL: CheckedContinuation<Value, any Error>] = [:]
        func read(_ url: URL) async throws -> Value {
            try await withCheckedThrowingContinuation { pending[url] = $0 }
        }
        func finish(_ url: URL, _ value: Value) { pending.removeValue(forKey: url)?.resume(returning: value) }
        func fail(_ url: URL, _ error: any Error) { pending.removeValue(forKey: url)?.resume(throwing: error) }
    }

    @Test func concurrentRefreshAndCloseDiscardStaleResults() async {
        let gate = Gate<SessionSnapshot>()
        let library = SessionLibrary(readSessions: { try await gate.read($0) })
        let first = URL(fileURLWithPath: "/first"), second = URL(fileURLWithPath: "/second")
        library.load(first)
        await waitUntil("first refresh") { gate.pending[first] != nil }
        library.load(second)
        await waitUntil("second refresh") { gate.pending[second] != nil }
        gate.finish(second, SessionSnapshot(failures: [.init(id: second, message: "new result")]))
        await waitUntil("new snapshot") { !library.refreshing }
        gate.finish(first, SessionSnapshot(failures: [.init(id: first, message: "stale")]))
        await settle()
        #expect(library.readFailures.first?.id == second)
        library.load(first)
        await waitUntil("closing refresh") { gate.pending[first] != nil }
        library.cancelRefresh()
        gate.finish(first, SessionSnapshot())
        await settle()
        #expect(library.readFailures.first?.id == second)
        await library.shutdown()
    }

    @Test func jobPollingUsesGenerationAndInjectedScheduler() async {
        let gate = Gate<JobSnapshot>(), ticks = Gate<Bool>()
        let first = URL(fileURLWithPath: "/first"), second = URL(fileURLWithPath: "/second")
        let clock = URL(fileURLWithPath: "/clock")
        let monitor = JobProgressMonitor(read: { try await gate.read($0) }, wait: { _ = try await ticks.read(clock) })
        var states: [JobState] = [], failures: [String] = []
        monitor.start(first, update: { states.append($0.state) }, failure: { failures.append($0) })
        await waitUntil("old job read") { gate.pending[first] != nil }
        monitor.start(second, update: { states.append($0.state) }, failure: { failures.append($0) })
        await waitUntil("new job read") { gate.pending[second] != nil }
        gate.finish(first, .init(schemaVersion: "future", state: .completed, progress: 1))
        gate.finish(second, .init(schemaVersion: "1.0", state: .transcribing, progress: 0.3))
        await waitUntil("poll scheduler") { ticks.pending[clock] != nil }
        #expect(states == [.transcribing])
        #expect(failures.isEmpty)
        ticks.finish(clock, true)
        await waitUntil("next tick read") { gate.pending[second] != nil }
        monitor.stop()
        gate.finish(second, .init(schemaVersion: "1.0", state: .completed, progress: 1))
        await settle()
        #expect(states == [.transcribing])
    }

    @Test(arguments: [NSFileNoSuchFileError, NSFileReadNoSuchFileError])
    func missingJobManifestIsExpectedOnlyDuringStartup(code: Int) async {
        let gate = Gate<JobSnapshot>(), ticks = Gate<Bool>()
        let manifest = URL(fileURLWithPath: "/synthetic/manifest.json"), clock = URL(fileURLWithPath: "/clock")
        let monitor = JobProgressMonitor(read: { try await gate.read($0) }, wait: { _ = try await ticks.read(clock) })
        var failures: [String] = [], states: [JobState] = []
        monitor.start(manifest, update: { states.append($0.state) }, failure: { failures.append($0) })
        await waitUntil("startup read") { gate.pending[manifest] != nil }
        gate.fail(manifest, NSError(domain: NSCocoaErrorDomain, code: code))
        await waitUntil("await manifest creation") { ticks.pending[clock] != nil }
        #expect(failures.isEmpty)
        ticks.finish(clock, true)
        await waitUntil("created manifest read") { gate.pending[manifest] != nil }
        gate.finish(manifest, .init(schemaVersion: "1.0", state: .transcribing, progress: 0.3))
        await waitUntil("next poll") { ticks.pending[clock] != nil }
        #expect(states == [.transcribing])
        ticks.finish(clock, true)
        await waitUntil("disappeared manifest read") { gate.pending[manifest] != nil }
        gate.fail(manifest, NSError(domain: NSCocoaErrorDomain, code: code))
        await waitUntil("missing after startup") { ticks.pending[clock] != nil }
        #expect(failures.count == 1)
        monitor.stop()
        ticks.finish(clock, true)
        await settle()
    }

    @Test func largeLibraryIsReadOffMainAndCorruptionRemainsVisible() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let count = 300
        let session = RecordingSession(sampleRate: 48_000, channels: 2, channelMap: ["L", "R"], options: .init())
        for index in 0..<count { try session.save(root.appendingPathComponent("\(index).recscribe.json")) }
        try Data("broken json".utf8).write(to: root.appendingPathComponent("broken.recscribe.json"))
        var future = session
        future.schemaVersion += 1
        try future.save(root.appendingPathComponent("future.recscribe.json"))
        let repository = ManifestRepository(readSession: { url in
            #expect(!Thread.isMainThread)
            return try RecordingSession.read(url)
        })
        let start = ContinuousClock.now
        let result = try await repository.sessions(in: root)
        print("MANIFEST_BENCH sessions=\(count) wall=\(start.duration(to: .now)) executor=background_actor")
        #expect(result.entries.count == count)
        #expect(result.failures.count == 2)
        await #expect(throws: (any Error).self) { try await repository.sessions(in: root.appendingPathComponent("missing")) }
        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await repository.sessions(in: root)
        }
        await #expect(throws: CancellationError.self) { try await cancelled.value }
    }

    @Test func jobManifestContractRejectsUnknownOrInvalidSuccess() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("manifest.json"), repository = ManifestRepository()
        for json in [#"{"schema_version":"2.0","state":"completed","progress":1}"#,
                     #"{"schema_version":"1.0","state":"future","progress":1}"#,
                     #"{"schema_version":"1.0","state":"completed","progress":0.5}"#,
                     #"{"schema_version":"1.0","state":"transcribing","progress":-1}"#, "broken"] {
            try Data(json.utf8).write(to: file)
            await #expect(throws: (any Error).self) { try await repository.job(at: file) }
        }
        try FileManager.default.removeItem(at: file)
        await #expect(throws: (any Error).self) { try await repository.job(at: file) }
    }
}
