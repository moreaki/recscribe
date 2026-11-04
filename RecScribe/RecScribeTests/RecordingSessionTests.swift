import AVFoundation
import Foundation
import Testing
@testable import RecScribe

@MainActor
struct RecordingSessionTests {
    @Test func archiveCancellationAndRestartNeverPublishPrematureCompletion() throws {
        let directory = try folder(); defer { try? FileManager.default.removeItem(at: directory) }
        let manifest = try record(directory, format: .flac)
        let cancel = WorkCancellation()
        #expect(throws: CancellationError.self) {
            try SessionProcessing.process(manifest, ffmpeg: URL(fileURLWithPath: "/unused"), cancel: cancel,
                archiveWorker: { session, file, _, token in
                    #expect(session.parts.allSatisfy { $0.status == .verified })
                    #expect(try RecordingSession.read(file).status == .verified)
                    token.cancel()
                    try token.check()
                    throw SessionError.invalid("unreachable")
                })
        }
        let interrupted = try RecordingSession.read(manifest)
        #expect(interrupted.status == .verified)
        #expect(interrupted.artifacts.isEmpty)
        // A fresh worker can resume from the journal without any real subprocess.
        let resumed = try SessionProcessing.process(manifest, ffmpeg: URL(fileURLWithPath: "/unused"), cancel: WorkCancellation(),
            archiveWorker: { _, _, _, _ in
                let artifact = directory.appendingPathComponent("test.flac")
                try Data("synthetic verified archive".utf8).write(to: artifact)
                return .init(path: artifact.lastPathComponent, format: .flac, sha256: try RecordingSession.hash(artifact),
                             sizeBytes: 26, verification: "synthetic_test")
            })
        #expect(resumed.status == .completed)
        #expect(resumed.artifacts.count == 1)
        for part in resumed.parts {
            #expect(try RecordingSession.hash(directory.appendingPathComponent(part.path)) == part.sha256)
        }
        try Data("tampered".utf8).write(to: directory.appendingPathComponent(resumed.artifacts[0].path))
        let replaced = try SessionProcessing.process(manifest, ffmpeg: URL(fileURLWithPath: "/unused"), cancel: WorkCancellation(),
            archiveWorker: { _, _, _, _ in
                let artifact = directory.appendingPathComponent("replacement.flac")
                try Data("synthetic".utf8).write(to: artifact)
                return .init(path: artifact.lastPathComponent, format: .flac, sha256: try RecordingSession.hash(artifact),
                             sizeBytes: 9, verification: "synthetic_test")
            })
        #expect(replaced.status == .needsReview)
        #expect(replaced.artifacts.count == 2)
        #expect(replaced.issues.contains { $0.contains("Archive requires review") })
    }

    @Test func archiveFailureAndLeadingGapRemainReviewableAfterRestart() throws {
        let directory = try folder(); defer { try? FileManager.default.removeItem(at: directory) }
        let manifest = try record(directory, format: .flac)
        #expect(throws: POSIXError(.ENOSPC)) {
            try SessionProcessing.process(manifest, ffmpeg: URL(fileURLWithPath: "/unused"), cancel: WorkCancellation(),
                archiveWorker: { _, _, _, _ in throw POSIXError(.ENOSPC) })
        }
        var failed = try RecordingSession.read(manifest)
        #expect(failed.status == .needsReview)
        #expect(!failed.issues.isEmpty)
        failed.options.archiveFormat = .wav
        for index in failed.parts.indices { failed.parts[index].startSample += 1 }
        try failed.save(manifest)
        let reviewed = try SessionProcessing.process(manifest, ffmpeg: URL(fileURLWithPath: "/unused"), cancel: WorkCancellation())
        #expect(reviewed.status == .needsReview)
        #expect(reviewed.parts[0].status == .needsReview)
    }
    private func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("session-test-\(UUID())")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        return url
    }
    private func buffer(_ frames: Int = 100) -> AVAudioPCMBuffer {
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48000, channels: 2, interleaved: false)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))!
        buffer.frameLength = AVAudioFrameCount(frames)
        for c in 0..<2 { for f in 0..<frames { buffer.floatChannelData![c][f] = Float((f + c) % 100) / 100 } }
        return buffer
    }
    private func record(_ directory: URL, cap: Int64 = 84, format: ArchiveFormat = .wav, frames: Int = 100) throws -> URL {
        let writer = SessionWAVWriter(options: .init(maximumPartBytes: cap, archiveFormat: format))
        try writer.createFile(at: directory.appendingPathComponent("OutputName.wav"), sampleRate: 48000, channels: 2)
        try writer.writeBuffer(buffer(frames))
        try writer.finalize()
        return writer.manifestURL!
    }
    @Test("Rollover preserves exact PCM sequence and valid, identical format headers")
    func rollover() throws {
        let directory = try folder(); defer { try? FileManager.default.removeItem(at: directory) }
        let manifest = try record(directory)
        let session = try RecordingSession.read(manifest)
        #expect(session.parts.count == 10)
        #expect(session.parts[0].path == "OutputName.wav")
        #expect(session.parts[1].path == "OutputName-Part2.wav")
        #expect(session.parts[9].path == "OutputName-Part10.wav")
        var data = Data()
        for (i, part) in session.parts.enumerated() {
            let url = directory.appendingPathComponent(part.path)
            let wav = try AVAudioFile(forReading: url)
            #expect(wav.length == 10)
            #expect(wav.fileFormat.channelCount == 2)
            #expect(wav.fileFormat.sampleRate == 48000)
            #expect(part.startSample == Int64(i * 10))
            #expect(part.sizeBytes == 84)
            data.append(try Data(contentsOf: url).dropFirst(44))
        }
        let reference = directory.appendingPathComponent("reference.wav")
        let writer = WAVWriter(); try writer.createFile(at: reference, sampleRate: 48000, channels: 2)
        try writer.writeBuffer(buffer()); try writer.finalize()
        #expect(data == Data(try Data(contentsOf: reference).dropFirst(44)))
        #expect(session.totalFrames == 100)
    }
    @Test("Colliding names never overwrite an original or orphaned Part2")
    func collisions() throws {
        let directory = try folder(); defer { try? FileManager.default.removeItem(at: directory) }
        let orphan = directory.appendingPathComponent("OutputName-Part2.wav")
        try Data("keep".utf8).write(to: orphan)
        let first = try record(directory)
        let second = try record(directory)
        #expect(first != second)
        #expect(first.lastPathComponent == "OutputName (1).recscribe.json")
        #expect(try Data(contentsOf: orphan) == Data("keep".utf8))
        let writer = WAVWriter()
        #expect(throws: (any Error).self) { try writer.createFile(at: orphan, sampleRate: 48000, channels: 2) }
    }
    @Test("Low disk space at rollover preserves finalized prior parts")
    func diskFailure() throws {
        let directory = try folder(); defer { try? FileManager.default.removeItem(at: directory) }
        var checks = 0
        let writer = SessionWAVWriter(options: .init(maximumPartBytes: 84), freeBytes: { _ in checks += 1; return checks > 3 ? 0 : 1_000_000_000 })
        try writer.createFile(at: directory.appendingPathComponent("OutputName.wav"), sampleRate: 48000, channels: 2)
        #expect(throws: SessionError.self) { try writer.writeBuffer(buffer()) }
        try writer.finalize()
        let session = try RecordingSession.read(writer.manifestURL!)
        #expect(session.status == .needsReview)
        #expect(session.parts.count == 1)
        #expect(try AVAudioFile(forReading: writer.audioURL!).length == 10)
    }
    @Test("A late Part2 collision is never overwritten or enrolled in recovery")
    func lateCollision() throws {
        let directory = try folder(); defer { try? FileManager.default.removeItem(at: directory) }
        let writer = SessionWAVWriter(options: .init(maximumPartBytes: 84))
        try writer.createFile(at: directory.appendingPathComponent("OutputName.wav"), sampleRate: 48000, channels: 2)
        let collision = directory.appendingPathComponent("OutputName-Part2.wav")
        try Data("unrelated".utf8).write(to: collision)
        #expect(throws: WAVWriterError.self) { try writer.writeBuffer(buffer()) }
        try writer.finalize()
        let session = try RecordingSession.read(writer.manifestURL!)
        #expect(session.parts.count == 1)
        #expect(session.parts[0].frames == 10)
        #expect(try Data(contentsOf: collision) == Data("unrelated".utf8))
    }
    @Test("Active sessions are leased; interrupted parts recover without whole-file buffering")
    func recovery() throws {
        let directory = try folder(); defer { try? FileManager.default.removeItem(at: directory) }
        let manifest = try record(directory)
        var session = try RecordingSession.read(manifest)
        let last = directory.appendingPathComponent(session.parts.last!.path)
        var data = try Data(contentsOf: last)
        for index in [4, 5, 6, 7, 40, 41, 42, 43] { data[index] = 0 }
        data.append(0xFF) // incomplete frame is not part of the recovered timeline
        try data.write(to: last)
        session.status = .recording
        session.parts[9].status = .recording; session.parts[9].frames = 0
        try session.save(manifest)
        do {
            let lease = try SessionLease(manifest)
            #expect(throws: SessionError.self) { _ = try SessionLease(manifest) }
            withExtendedLifetime(lease) {}
        }
        let result = try SessionProcessing.process(manifest, ffmpeg: URL(fileURLWithPath: "/missing"), cancel: WorkCancellation(), recover: true)
        #expect(result.totalFrames == 100)
        #expect(result.parts[9].recovered)
        #expect(result.parts.allSatisfy { $0.status == .verified })
        #expect(result.status == .needsReview)
        #expect(try AVAudioFile(forReading: last).length == 10)
    }
    @Test("Missing or modified parts remain needs-review; no successful empty sessions")
    func damagedPart() throws {
        let directory = try folder(); defer { try? FileManager.default.removeItem(at: directory) }
        let manifest = try record(directory)
        _ = try SessionProcessing.process(manifest, ffmpeg: URL(fileURLWithPath: "/missing"), cancel: WorkCancellation())
        let part = directory.appendingPathComponent("OutputName-Part2.wav")
        try FileManager.default.removeItem(at: part)
        let result = try SessionProcessing.process(manifest, ffmpeg: URL(fileURLWithPath: "/missing"), cancel: WorkCancellation())
        #expect(result.status == .needsReview)
        #expect(result.parts[1].status == .needsReview)
        #expect(result.parts[0].status == .verified)
    }
    @Test("Verified multipart archives retain originals", arguments: [ArchiveFormat.flac, .opus, .m4a])
    func archive(_ format: ArchiveFormat) async throws {
        let ffmpeg = URL(fileURLWithPath: "/opt/homebrew/bin/ffmpeg")
        guard FileManager.default.isExecutableFile(atPath: ffmpeg.path) else { return }
        let directory = try folder(); defer { try? FileManager.default.removeItem(at: directory) }
        let manifest = try record(directory, cap: 48044, format: format, frames: 48000)
        let result = try await Task.detached(priority: .utility) {
            try SessionProcessing.process(manifest, ffmpeg: ffmpeg, cancel: WorkCancellation())
        }.value
        #expect(result.status == .completed)
        #expect(result.artifacts.count == 1)
        #expect(result.parts.count == 4)
        for part in result.parts { #expect(try RecordingSession.hash(directory.appendingPathComponent(part.path)) == part.sha256) }
        let again = try await Task.detached(priority: .utility) {
            try SessionProcessing.process(manifest, ffmpeg: ffmpeg, cancel: WorkCancellation())
        }.value
        #expect(again.artifacts.count == 1)
    }
    @Test("Model publication verifies bytes, checksum and cancellation without overwrite")
    func modelPublication() throws {
        let directory = try folder(); defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("download.tmp")
        let destination = directory.appendingPathComponent("model.bin")
        try Data("synthetic model".utf8).write(to: source)
        let model = WhisperModel(id: "test-only", bytes: 15, sha256: try RecordingSession.hash(source))
        let cancelled = WorkCancellation(); cancelled.cancel()
        #expect(throws: CancellationError.self) { try model.verifyAndInstall(source, to: destination, cancel: cancelled) }
        let bad = WhisperModel(id: "test-only", bytes: 15, sha256: String(repeating: "0", count: 64))
        #expect(throws: SessionError.self) { try bad.verifyAndInstall(source, to: destination, cancel: WorkCancellation()) }
        #expect(!FileManager.default.fileExists(atPath: destination.path))
        try Data("keep".utf8).write(to: destination)
        #expect(throws: (any Error).self) { try model.verifyAndInstall(source, to: destination, cancel: WorkCancellation()) }
        #expect(try Data(contentsOf: destination) == Data("keep".utf8))
        let fresh = directory.appendingPathComponent("fresh-model.bin")
        try model.verifyAndInstall(source, to: fresh, cancel: WorkCancellation())
        #expect(try RecordingSession.hash(fresh) == model.sha256)
    }
    @Test("SessionLibrary.recoverUnfinalizedSessions recovers interrupted .recscribe.json sessions and surfaces corrupt manifests")
    @MainActor
    func libraryRecoversUnfinalizedSessionsInDirectory() async throws {
        let directory = try folder()
        defer { try? FileManager.default.removeItem(at: directory) }
        let manifest = try record(directory)
        var session = try RecordingSession.read(manifest)
        session.status = .recording
        session.parts[9].status = .recording
        session.parts[9].frames = 0
        try session.save(manifest)
        let corrupt = directory.appendingPathComponent("corrupt.recscribe.json")
        try Data("not-valid-json".utf8).write(to: corrupt)

        var settings = AppSettings.Values()
        settings.autoTranscribe = false
        let library = SessionLibrary(settings: { settings })
        library.recoverUnfinalizedSessions(in: directory)
        for _ in 0..<50 {
            if let current = try? RecordingSession.read(manifest),
               current.status != .recording,
               !library.refreshing,
               library.entries.first?.session.status == .needsReview {
                break
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        let recovered = try RecordingSession.read(manifest)
        #expect(recovered.status == .needsReview)
        #expect(recovered.totalFrames == 100)
        #expect(recovered.parts[9].recovered)
        #expect(library.readFailures.map(\.id.lastPathComponent) == ["corrupt.recscribe.json"])
        await library.shutdown()
    }

    @Test("SessionLibrary.recoverUnfinalizedSessions protects active capture and exposes scan errors")
    @MainActor
    func libraryRecoveryRespectsActiveCaptureAndScanErrors() async throws {
        let directory = try folder()
        defer { try? FileManager.default.removeItem(at: directory) }
        let manifest = try record(directory)
        var session = try RecordingSession.read(manifest)
        session.status = .recording
        session.parts[9].status = .recording
        session.parts[9].frames = 0
        try session.save(manifest)

        var settings = AppSettings.Values()
        settings.autoTranscribe = false
        let library = SessionLibrary(settings: { settings })
        library.setRecording(true)
        library.recoverUnfinalizedSessions(in: directory)
        for _ in 0..<50 where library.refreshing {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        #expect(library.entries.count == 1)
        #expect(try RecordingSession.read(manifest).status == .recording)
        library.setRecording(false)
        try await Task.sleep(nanoseconds: 40_000_000)
        #expect(try RecordingSession.read(manifest).status == .recording)

        let missing = directory.appendingPathComponent("missing-dir", isDirectory: true)
        library.recoverUnfinalizedSessions(in: missing)
        for _ in 0..<50 where library.refreshing {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        #expect(library.readFailures.map(\.id) == [missing])
        await library.shutdown()
    }

    @Test("Session title validation, SessionLibrary.rename, and orphaned Live draft directory pruning (#44)")
    @MainActor
    func sessionTitleRenameAndOrphanedLiveDraftPruning() async throws {
        let directory = try folder()
        defer { try? FileManager.default.removeItem(at: directory) }
        let manifest = try record(directory)

        var session = try RecordingSession.read(manifest)
        #expect(session.title == nil)
        let initialEntry = SessionEntry(id: manifest, session: session)
        #expect(initialEntry.displayTitle == "OutputName")

        session.title = "   "
        #expect(throws: SessionError.self) { _ = try session.validated(beside: manifest) }
        session.title = String(repeating: "a", count: 257)
        #expect(throws: SessionError.self) { _ = try session.validated(beside: manifest) }
        session.title = "Line 1\nLine 2"
        #expect(throws: SessionError.self) { _ = try session.validated(beside: manifest) }

        var settings = AppSettings.Values()
        settings.autoTranscribe = false
        let library = SessionLibrary(settings: { settings })
        library.load(directory)
        for _ in 0..<50 where library.refreshing {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let loaded = try #require(library.entries.first)
        library.rename(loaded, title: "  Weekly Architecture Sync  ")
        #expect(library.entries.first?.displayTitle == "Weekly Architecture Sync")
        #expect(try RecordingSession.read(manifest).title == "Weekly Architecture Sync")

        // Recording active blocks rename
        library.setRecording(true)
        library.rename(library.entries[0], title: "Blocked Rename")
        #expect(try RecordingSession.read(manifest).title == "Weekly Architecture Sync")
        library.setRecording(false)

        // Empty title resets back to filename stem
        library.rename(library.entries[0], title: "   ")
        #expect(library.entries.first?.session.title == nil)
        #expect(library.entries.first?.displayTitle == "OutputName")
        #expect(try RecordingSession.read(manifest).title == nil)
        await library.shutdown()

        // Orphaned Live draft pruning preserves active, recent, and promoted cloud transcripts
        let liveRoot = directory.appendingPathComponent("Live", isDirectory: true)
        let staleDraft = liveRoot.appendingPathComponent("stale-draft", isDirectory: true)
        let stalePromoted = liveRoot.appendingPathComponent("stale-promoted", isDirectory: true)
        let recentDraft = liveRoot.appendingPathComponent("recent-draft", isDirectory: true)
        let activeDraft = liveRoot.appendingPathComponent("active-draft", isDirectory: true)
        for dir in [staleDraft, stalePromoted, recentDraft, activeDraft] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        try Data("{}".utf8).write(to: stalePromoted.appendingPathComponent("transcript.json"))
        let now = Date()
        let twoDaysAgo = now.addingTimeInterval(-48 * 60 * 60)
        for dir in [staleDraft, stalePromoted, activeDraft] {
            try FileManager.default.setAttributes([.modificationDate: twoDaysAgo], ofItemAtPath: dir.path)
        }
        LiveTranscription.pruneOrphanedDraftDirectories(
            in: liveRoot,
            retaining: activeDraft,
            olderThan: 24 * 60 * 60,
            now: now
        )
        #expect(!FileManager.default.fileExists(atPath: staleDraft.path))
        #expect(FileManager.default.fileExists(atPath: stalePromoted.path))
        #expect(FileManager.default.fileExists(atPath: recentDraft.path))
        #expect(FileManager.default.fileExists(atPath: activeDraft.path))
    }
}
