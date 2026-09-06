import AVFoundation
import Foundation
import Testing
@testable import RecScribe

@MainActor
struct SessionExportTests {
    private struct Fixture {
        let root: URL
        let manifest: URL
        let exports: URL
        let session: RecordingSession
        let manifestBytes: Data

        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("export-test-\(UUID())")
            exports = root.appendingPathComponent("exports")
            try FileManager.default.createDirectory(at: exports, withIntermediateDirectories: true)
            let writer = SessionWAVWriter(options: .init(maximumPartBytes: 2048))
            try writer.createFile(at: root.appendingPathComponent("Test.wav"), sampleRate: 48000, channels: 2)
            try writer.writeBuffer(SampleBufferFixtures.makePCMBuffer(channels: 2, frames: 1024, sampleRate: 48000, interleaved: false) { channel, frame in
                Float((channel + frame) % 100) / 100
            })
            try writer.finalize()
            manifest = try #require(writer.manifestURL)
            var verified = try SessionProcessing.process(manifest, ffmpeg: URL(fileURLWithPath: "/unused"), cancel: WorkCancellation())
            // Export treats derived artifacts as opaque, checksum-verified files.
            let artifact = root.appendingPathComponent("Synthetic.flac")
            let content = Data("synthetic archive fixture".utf8)
            try content.write(to: artifact)
            verified.artifacts.append(.init(path: artifact.lastPathComponent, format: .flac,
                                           sha256: try RecordingSession.hash(artifact), sizeBytes: Int64(content.count), verification: "test_fixture"))
            try verified.save(manifest)
            session = verified
            manifestBytes = try Data(contentsOf: manifest)
        }

        func checkOriginals() throws {
            #expect(try Data(contentsOf: manifest) == manifestBytes)
            for part in session.parts {
                #expect(try RecordingSession.hash(root.appendingPathComponent(part.path)) == part.sha256)
            }
            for artifact in session.artifacts {
                #expect(try RecordingSession.hash(root.appendingPathComponent(artifact.path)) == artifact.sha256)
            }
        }

        func partial() throws -> URL {
            let folders = try FileManager.default.contentsOfDirectory(at: exports, includingPropertiesForKeys: nil)
            #expect(folders.count == 1)
            let directory = try #require(folders.first)
            #expect(directory.pathExtension == "partial")
            #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent(manifest.lastPathComponent).path))
            return directory
        }
    }

    @Test func verifiedMultipartExport() throws {
        let fixture = try Fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let worker = SessionExporter(blockBytes: 64)
        let first = try worker.export(fixture.manifest, to: fixture.exports, checkCancellation: {})
        let second = try worker.export(fixture.manifest, to: fixture.exports, checkCancellation: {})
        #expect(first != second)
        #expect(first.pathExtension != "partial")
        #expect(try Data(contentsOf: first.appendingPathComponent(fixture.manifest.lastPathComponent)) == Data(contentsOf: fixture.manifest))
        for part in fixture.session.parts {
            #expect(try RecordingSession.hash(first.appendingPathComponent(part.path)) == part.sha256)
        }
        for artifact in fixture.session.artifacts {
            #expect(try RecordingSession.hash(first.appendingPathComponent(artifact.path)) == artifact.sha256)
        }
        try fixture.checkOriginals()
    }

    @Test func changedCopyNeverPublishes() throws {
        let fixture = try Fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let part = try #require(fixture.session.parts.first)
        var modified = false
        #expect(throws: SessionError.self) {
            try SessionExporter(blockBytes: 64).export(fixture.manifest, to: fixture.exports) {
                guard !modified,
                      let partial = try FileManager.default.contentsOfDirectory(at: fixture.exports, includingPropertiesForKeys: nil).first else { return }
                let copy = partial.appendingPathComponent(part.path)
                guard (try? copy.resourceValues(forKeys: [.fileSizeKey]).fileSize) == Int(part.sizeBytes) else { return }
                let file = try FileHandle(forWritingTo: copy)
                defer { try? file.close() }
                try file.write(contentsOf: Data([0]))
                modified = true
            }
        }
        #expect(modified)
        _ = try fixture.partial()
        try fixture.checkOriginals()
    }

    enum CancellationStage: CaseIterable { case sourceHash, copy, copyHash }

    @Test(arguments: CancellationStage.allCases)
    func cancellationBetweenIOCalls(_ stage: CancellationStage) throws {
        let fixture = try Fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let part = try #require(fixture.session.parts.first)
        var checks = 0
        var fullCopyChecks = 0
        var interrupted = false
        #expect(throws: CancellationError.self) {
            try SessionExporter(blockBytes: 64).export(fixture.manifest, to: fixture.exports) {
                checks += 1
                let folders = try FileManager.default.contentsOfDirectory(at: fixture.exports, includingPropertiesForKeys: nil)
                let copy = folders.first?.appendingPathComponent(part.path)
                let size = copy.flatMap { try? $0.resourceValues(forKeys: [.fileSizeKey]).fileSize } ?? 0
                if size == part.sizeBytes { fullCopyChecks += 1 }
                // Stop after one hash block, not merely before hashing starts.
                // A full copy adds EOF and pre-sync checks before its hash reader.
                let shouldCancel = switch stage {
                case .sourceHash: checks == 5
                case .copy: size > 0 && size < part.sizeBytes
                case .copyHash: fullCopyChecks == 5
                }
                if shouldCancel { interrupted = true; throw CancellationError() }
            }
        }
        #expect(interrupted)
        let partial = try fixture.partial()
        if stage == .copy {
            #expect(try partial.appendingPathComponent(part.path).resourceValues(forKeys: [.fileSizeKey]).fileSize == 64)
        }
        try fixture.checkOriginals()
    }

    @Test func changedSourceAndWriteFailureNeverPublish() throws {
        let fixture = try Fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let part = try #require(fixture.session.parts.first)
        let source = fixture.root.appendingPathComponent(part.path)
        let original = try Data(contentsOf: source)
        try Data("changed".utf8).write(to: source)
        #expect(throws: SessionError.self) {
            try SessionExporter().export(fixture.manifest, to: fixture.exports, checkCancellation: {})
        }
        #expect(try Data(contentsOf: source) == Data("changed".utf8))
        _ = try fixture.partial()
        try original.write(to: source)

        let failedDirectory = fixture.root.appendingPathComponent("write-failure")
        try FileManager.default.createDirectory(at: failedDirectory, withIntermediateDirectories: false)
        #expect(throws: POSIXError.self) {
            try SessionExporter(blockBytes: 64).export(fixture.manifest, to: failedDirectory) {
                let partial = try FileManager.default.contentsOfDirectory(at: failedDirectory, includingPropertiesForKeys: nil).first
                if let partial, FileManager.default.fileExists(atPath: partial.appendingPathComponent(part.path).path) {
                    throw POSIXError(.ENOSPC)
                }
            }
        }
        let remaining = try FileManager.default.contentsOfDirectory(at: failedDirectory, includingPropertiesForKeys: nil)
        #expect(remaining.allSatisfy { $0.pathExtension == "partial" })
        #expect(!FileManager.default.fileExists(atPath: try #require(remaining.first).appendingPathComponent(fixture.manifest.lastPathComponent).path))
        try fixture.checkOriginals()
    }

    /// Deterministic worker suspension; the timeout is a test failure safeguard,
    /// not a production cancellation deadline or a timing-based assertion.
    private nonisolated final class WorkerGate: Sendable {
        let started = AsyncStream<Void>.makeStream()
        let release = DispatchSemaphore(value: 0)

        func run(_ manifest: URL, _ destination: URL, _ token: WorkCancellation) throws -> URL {
            defer { started.continuation.finish() }
            started.continuation.yield(())
            guard release.wait(timeout: .now() + 30) == .success else { throw POSIXError(.ETIMEDOUT) }
            try token.check()
            return destination
        }

        func waitForStart() async {
            var iterator = started.stream.makeAsyncIterator()
            _ = await iterator.next()
        }
    }

    enum CancellationTrigger: CaseIterable { case button, recording, caller }

    @Test(arguments: CancellationTrigger.allCases)
    func libraryOwnsExportCancellation(_ trigger: CancellationTrigger) async throws {
        let gate = WorkerGate()
        defer { gate.release.signal() }
        let library = SessionLibrary(exportSession: gate.run, cancelRuntime: {})
        let url = URL(fileURLWithPath: "/unused")
        let export = Task { try await library.export(url, to: url) }
        await gate.waitForStart()

        switch trigger {
        case .button: library.cancel()
        case .recording: library.setRecording(true)
        case .caller: export.cancel()
        }
        // Admission remains occupied until the worker exits, even after Cancel.
        await #expect(throws: SessionError.self) { try await library.export(url, to: url) }
        gate.release.signal()
        await #expect(throws: CancellationError.self) { try await export.value }
        #expect(library.errorMessage == nil)
        #expect(library.progress == 0)
        #expect(library.activity.hasPrefix("Export cancelled"))
        library.setRecording(false)
        gate.release.signal()
        #expect(try await library.export(url, to: url) == url)
        #expect(library.progress == 1)
    }

    @Test func shutdownWaitsForOwnedWorkerAndRejectsNewExports() async throws {
        let gate = WorkerGate()
        defer { gate.release.signal() }
        let library = SessionLibrary(exportSession: gate.run, cancelRuntime: {})
        let url = URL(fileURLWithPath: "/unused")
        let export = Task { try await library.export(url, to: url) }
        await gate.waitForStart()
        let shuttingDown = AsyncStream<Void>.makeStream()
        var finished = false
        let shutdown = Task {
            shuttingDown.continuation.yield(())
            await library.shutdown()
            finished = true
        }
        var iterator = shuttingDown.stream.makeAsyncIterator()
        _ = await iterator.next()
        #expect(!finished)
        await #expect(throws: SessionError.self) { try await library.export(url, to: url) }
        gate.release.signal()
        await shutdown.value
        #expect(finished)
        await #expect(throws: CancellationError.self) { try await export.value }
        await #expect(throws: SessionError.self) { try await library.export(url, to: url) }
    }

    @Test func failureReleasesAdmissionAndSetsError() async throws {
        let library = SessionLibrary(exportSession: { _, _, _ in throw POSIXError(.ENOSPC) }, cancelRuntime: {})
        let url = URL(fileURLWithPath: "/unused")
        for _ in 0..<2 {
            await #expect(throws: POSIXError.self) { try await library.export(url, to: url) }
            #expect(library.errorMessage != nil)
            #expect(library.activity.hasPrefix("Export failed"))
        }
    }

    @Test func activeExportExcludesTranscriptionAndRecordingExcludesExport() async throws {
        let gate = WorkerGate()
        defer { gate.release.signal() }
        let library = SessionLibrary(exportSession: gate.run, cancelRuntime: {})
        let url = URL(fileURLWithPath: "/unused")
        library.setRecording(true)
        await #expect(throws: SessionError.self) { try await library.export(url, to: url) }
        library.setRecording(false)
        let export = Task { try await library.export(url, to: url) }
        await gate.waitForStart()
        library.transcribe(url)
        #expect(library.errorMessage == "Wait for capture/background work to finish")
        library.cancel()
        gate.release.signal()
        await #expect(throws: CancellationError.self) { try await export.value }
    }
}
