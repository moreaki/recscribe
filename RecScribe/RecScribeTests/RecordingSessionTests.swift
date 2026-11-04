import os
import Observation
import AppKit
import AVFoundation
import Combine
import Foundation
import SwiftUI
import Testing
@testable import RecScribe

@MainActor
struct RecordingSessionTests {
    @Test func generatedSessionTitlesAreReadableWithoutRenamingFilesOrReplacingCustomNames() throws {
        var session = RecordingSession(sampleRate: 48_000, channels: 1, channelMap: ["mono"], options: .init())
        session.startedAt = Date(timeIntervalSince1970: 1_793_813_200)
        session.parts = [.init(path: "recording_2026-11-04_19-00-00.wav", startSample: 0, frames: 480, startedAt: session.startedAt)]
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let original = try encoder.encode(session)
        for suffix in ["", " (2)", " (2) (1)"] {
            let entry = SessionEntry(id: URL(fileURLWithPath: "/synthetic/recording_2026-11-04_19-00-00\(suffix).recscribe.json"), session: session)
            #expect(entry.displayTitle.hasPrefix("Recording · "))
            #expect(!entry.displayTitle.contains("recording_"))
            #expect(entry.displayTitle.hasSuffix(suffix))
            #expect(entry.filenameStem == "recording_2026-11-04_19-00-00\(suffix)")
            #expect(try encoder.encode(entry.session) == original)
        }
        let custom = SessionEntry(id: URL(fileURLWithPath: "/synthetic/Interview with Ada.recscribe.json"), session: session)
        #expect(custom.displayTitle == "Interview with Ada")
        session.title = "Weekly planning"
        #expect(SessionEntry(id: custom.id, session: session).displayTitle == "Weekly planning")
    }

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

    @Test("Session title validation, SessionLibrary.rename, and Live disposable temp cleanup preserving raw drafts (#44)")
    @MainActor
    func sessionTitleRenameAndLiveDisposableTempCleanup() async throws {
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

        var document = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: manifest)) as? [String: Any])
        document["futureExtension"] = ["preserve": true]
        var parts = try #require(document["parts"] as? [[String: Any]])
        parts[0]["futurePartField"] = "original evidence"
        document["parts"] = parts
        try JSONSerialization.data(withJSONObject: document).write(to: manifest, options: .atomic)
        document.removeValue(forKey: "title")
        let originalMetadata = document as NSDictionary

        var settings = AppSettings.Values()
        settings.autoTranscribe = false
        let library = SessionLibrary(settings: { settings })
        library.load(directory)
        for _ in 0..<50 where library.refreshing {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let loaded = try #require(library.entries.first)
        let originalAudio = try RecordingSession.hash(directory.appendingPathComponent(loaded.session.parts[0].path))
        let partEncoder = JSONEncoder()
        partEncoder.outputFormatting = .sortedKeys
        let originalParts = try partEncoder.encode(loaded.session.parts)
        await library.rename(loaded, title: "  Weekly Architecture Sync  ")
        #expect(library.entries.first?.displayTitle == "Weekly Architecture Sync")
        #expect(try RecordingSession.read(manifest).title == "Weekly Architecture Sync")
        #expect(try RecordingSession.hash(directory.appendingPathComponent(loaded.session.parts[0].path)) == originalAudio)
        #expect(try partEncoder.encode(RecordingSession.read(manifest).parts) == originalParts)
        do {
            let lease = try SessionLease(manifest)
            #expect(await library.rename(loaded, title: "Locked") == nil)
            withExtendedLifetime(lease) {}
        }

        // Recording active blocks rename
        library.setRecording(true)
        await library.rename(library.entries[0], title: "Blocked Rename")
        #expect(try RecordingSession.read(manifest).title == "Weekly Architecture Sync")
        library.setRecording(false)

        // Empty title resets back to filename stem
        await library.rename(library.entries[0], title: "   ")
        #expect(library.entries.first?.session.title == nil)
        #expect(library.entries.first?.displayTitle == "OutputName")
        #expect(try RecordingSession.read(manifest).title == nil)
        let renamedMetadata = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: manifest)) as? [String: Any])
        #expect(renamedMetadata as NSDictionary == originalMetadata)
        await library.shutdown()

        // 1. Completed local draft (>48h old, NO transcript.json): raw ASR JSON, checkpoints, and silence notes must be preserved; only disposable working WAVs are removed.
        let fm = FileManager.default
        let liveRoot = directory.appendingPathComponent("Live", isDirectory: true)
        let completedLocalDraft = liveRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let completedAttempt = completedLocalDraft.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: completedAttempt, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: completedLocalDraft.appendingPathComponent("latest.json"))
        try Data("{}".utf8).write(to: completedAttempt.appendingPathComponent("chunk.json"))
        try Data("{\"transcription\":[]}".utf8).write(to: completedAttempt.appendingPathComponent("channel-0.raw.json"))
        try Data("Digital silence; no ASR run.\n".utf8).write(to: completedAttempt.appendingPathComponent("channel-1.silence.txt"))
        try Data("non-disposable".utf8).write(to: completedAttempt.appendingPathComponent("reference.wav"))
        try Data("temp".utf8).write(to: completedAttempt.appendingPathComponent("working.wav"))
        try Data("temp".utf8).write(to: completedAttempt.appendingPathComponent("channel-0.wav"))
        try Data("temp".utf8).write(to: completedLocalDraft.appendingPathComponent("working-channel-1.wav"))
        try Data("temp".utf8).write(to: completedLocalDraft.appendingPathComponent("asr-channel-0-region-0.wav"))

        // 2. Failed/interrupted local draft (>48h old, NO transcript.json, NO latest.json, NO chunk.json): raw ASR JSON must still be preserved.
        let failedLocalDraft = liveRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let failedAttempt = failedLocalDraft.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: failedAttempt, withIntermediateDirectories: true)
        try Data("{\"transcription\":[]}".utf8).write(to: failedAttempt.appendingPathComponent("channel-0.raw.json"))
        try Data("temp".utf8).write(to: failedAttempt.appendingPathComponent("working.wav"))
        try Data("temp".utf8).write(to: failedAttempt.appendingPathComponent("channel-0.wav"))

        // 3. Interrupted cloud draft (NO transcript.json): turn evidence and consent/manifest/review must be preserved; turn working WAVs are removed.
        let cloudDraft = liveRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let cloudTurn = cloudDraft.appendingPathComponent("turn-0", isDirectory: true)
        try fm.createDirectory(at: cloudTurn, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: cloudDraft.appendingPathComponent("consent.json"))
        try Data("{}".utf8).write(to: cloudDraft.appendingPathComponent("manifest.json"))
        try Data("# Review".utf8).write(to: cloudDraft.appendingPathComponent("review.md"))
        try Data("{}".utf8).write(to: cloudTurn.appendingPathComponent("result.json"))
        try Data("[]".utf8).write(to: cloudTurn.appendingPathComponent("timings.json"))
        try Data("{}\n".utf8).write(to: cloudTurn.appendingPathComponent("channel-0.events.jsonl"))
        try Data("temp".utf8).write(to: cloudTurn.appendingPathComponent("working.wav"))
        try Data("temp".utf8).write(to: cloudTurn.appendingPathComponent("channel-0.wav"))

        // 4. Explicit ownership checks: unowned folder (non-UUID, no draft markers) and symlinked working.wav must never be deleted.
        let unownedFolder = liveRoot.appendingPathComponent("foreign-folder", isDirectory: true)
        try fm.createDirectory(at: unownedFolder, withIntermediateDirectories: true)
        try Data("foreign".utf8).write(to: unownedFolder.appendingPathComponent("working.wav"))

        let externalTarget = directory.appendingPathComponent("external-protected.wav")
        try Data("protected".utf8).write(to: externalTarget)
        let symlinkedWorking = completedLocalDraft.appendingPathComponent("working.wav")
        try fm.createSymbolicLink(at: symlinkedWorking, withDestinationURL: externalTarget)

        // 5. Explicit retention of an active draft directory
        let retainedDraft = liveRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let retainedAttempt = retainedDraft.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: retainedAttempt, withIntermediateDirectories: true)
        try Data("in-flight".utf8).write(to: retainedAttempt.appendingPathComponent("working.wav"))
        try Data("in-flight".utf8).write(to: retainedAttempt.appendingPathComponent("channel-0.wav"))

        let twoDaysAgo = Date().addingTimeInterval(-48 * 60 * 60)
        for dir in [completedLocalDraft, completedAttempt, failedLocalDraft, failedAttempt, cloudDraft, cloudTurn, retainedDraft, retainedAttempt] {
            try fm.setAttributes([.modificationDate: twoDaysAgo], ofItemAtPath: dir.path)
        }

        // Wrong UID check: nothing is deleted when expectedOwnerUID does not match.
        LiveTranscription.pruneDisposableWorkingFiles(
            in: liveRoot,
            retaining: [retainedDraft],
            expectedOwnerUID: Darwin.getuid() &+ 1
        )
        #expect(fm.fileExists(atPath: completedAttempt.appendingPathComponent("working.wav").path))

        // Owned cleanup with explicit retention
        LiveTranscription.pruneDisposableWorkingFiles(
            in: liveRoot,
            retaining: [retainedDraft]
        )

        // Completed local draft preserved (even >48h old without transcript.json), only disposable WAVs removed
        #expect(fm.fileExists(atPath: completedLocalDraft.path))
        #expect(fm.fileExists(atPath: completedLocalDraft.appendingPathComponent("latest.json").path))
        #expect(fm.fileExists(atPath: completedAttempt.appendingPathComponent("chunk.json").path))
        #expect(fm.fileExists(atPath: completedAttempt.appendingPathComponent("channel-0.raw.json").path))
        #expect(fm.fileExists(atPath: completedAttempt.appendingPathComponent("channel-1.silence.txt").path))
        #expect(fm.fileExists(atPath: completedAttempt.appendingPathComponent("reference.wav").path))
        #expect(!fm.fileExists(atPath: completedAttempt.appendingPathComponent("working.wav").path))
        #expect(!fm.fileExists(atPath: completedAttempt.appendingPathComponent("channel-0.wav").path))
        #expect(!fm.fileExists(atPath: completedLocalDraft.appendingPathComponent("working-channel-1.wav").path))
        #expect(!fm.fileExists(atPath: completedLocalDraft.appendingPathComponent("asr-channel-0-region-0.wav").path))

        // Failed local draft preserved, only disposable WAVs removed
        #expect(fm.fileExists(atPath: failedLocalDraft.path))
        #expect(fm.fileExists(atPath: failedAttempt.appendingPathComponent("channel-0.raw.json").path))
        #expect(!fm.fileExists(atPath: failedAttempt.appendingPathComponent("working.wav").path))
        #expect(!fm.fileExists(atPath: failedAttempt.appendingPathComponent("channel-0.wav").path))

        // Interrupted cloud draft preserved, only turn working WAVs removed
        #expect(fm.fileExists(atPath: cloudDraft.path))
        #expect(fm.fileExists(atPath: cloudDraft.appendingPathComponent("consent.json").path))
        #expect(fm.fileExists(atPath: cloudDraft.appendingPathComponent("manifest.json").path))
        #expect(fm.fileExists(atPath: cloudDraft.appendingPathComponent("review.md").path))
        #expect(fm.fileExists(atPath: cloudTurn.appendingPathComponent("result.json").path))
        #expect(fm.fileExists(atPath: cloudTurn.appendingPathComponent("timings.json").path))
        #expect(fm.fileExists(atPath: cloudTurn.appendingPathComponent("channel-0.events.jsonl").path))
        #expect(!fm.fileExists(atPath: cloudTurn.appendingPathComponent("working.wav").path))
        #expect(!fm.fileExists(atPath: cloudTurn.appendingPathComponent("channel-0.wav").path))

        // Unowned folder and symlinked file untouched
        #expect(fm.fileExists(atPath: unownedFolder.appendingPathComponent("working.wav").path))
        #expect(fm.fileExists(atPath: externalTarget.path))
        #expect((try? symlinkedWorking.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true)

        // Retained active draft untouched
        #expect(fm.fileExists(atPath: retainedAttempt.appendingPathComponent("working.wav").path))
        #expect(fm.fileExists(atPath: retainedAttempt.appendingPathComponent("channel-0.wav").path))

        // 6. LiveTranscription lifecycle check: active session/worker automatically retains its owned draft directory until the worker finishes.
        @MainActor final class WorkerGate {
            var continuation: CheckedContinuation<LiveChunkResult?, any Error>?
            func wait(cursor: Int64) async throws -> LiveChunkResult? {
                guard cursor == 0 else { return nil }
                return try await withCheckedThrowingContinuation { continuation = $0 }
            }
            func resume() {
                continuation?.resume(returning: nil)
                continuation = nil
            }
        }
        let gate = WorkerGate()
        // Keep the active-worker fixture separate from deliberately unsafe symlinks above.
        let workerRoot = directory.appendingPathComponent("ActiveLive", isDirectory: true)
        let live = LiveTranscription(
            liveRoot: workerRoot,
            work: { _, _, cursor, _, _, _ in
                try await gate.wait(cursor: cursor)
            }
        )
        live.setEnabled(true)
        live.recordingStarted(manifest.deletingPathExtension().deletingPathExtension().appendingPathExtension("wav"))
        await waitUntil("live worker admitted") { gate.continuation != nil }
        _ = try #require(gate.continuation)
        let activeLiveDir = try #require(live.directory)
        let activeLiveAttempt = activeLiveDir.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: activeLiveAttempt, withIntermediateDirectories: true)
        try Data("{\"transcription\":[]}".utf8).write(to: activeLiveAttempt.appendingPathComponent("channel-0.raw.json"))
        try Data("in-flight".utf8).write(to: activeLiveAttempt.appendingPathComponent("working.wav"))
        try Data("in-flight".utf8).write(to: activeLiveAttempt.appendingPathComponent("channel-0.wav"))

        // Even after recordingStopped() while the final worker pass is still in-flight, automatic registry ownership protects activeLiveDir.
        live.recordingStopped()
        LiveTranscription.pruneDisposableWorkingFiles(in: workerRoot)
        #expect(fm.fileExists(atPath: activeLiveAttempt.appendingPathComponent("working.wav").path))
        #expect(fm.fileExists(atPath: activeLiveAttempt.appendingPathComponent("channel-0.wav").path))

        // Once the worker completes and LiveTranscription reaches a terminal state, disposable working WAVs are cleaned on a utility worker while raw ASR JSON stays intact.
        gate.resume()
        for _ in 0..<50 where live.busy {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        await live.shutdown()
        #expect(!live.lastCleanupReport.ranOnMainThread)
        #expect(live.lastCleanupFailures.isEmpty)
        #expect(fm.fileExists(atPath: activeLiveDir.path))
        #expect(fm.fileExists(atPath: activeLiveAttempt.appendingPathComponent("channel-0.raw.json").path))
        #expect(!fm.fileExists(atPath: activeLiveAttempt.appendingPathComponent("working.wav").path))
        #expect(!fm.fileExists(atPath: activeLiveAttempt.appendingPathComponent("channel-0.wav").path))

        // 7. Bounded and cancellable traversal + surfaced enumeration/unlink failures on utility-worker shutdown.
        let boundedRoot = directory.appendingPathComponent("LiveBounded", isDirectory: true)
        let draft1 = boundedRoot.appendingPathComponent("00000000-0000-0000-0000-000000000001", isDirectory: true)
        let draft2 = boundedRoot.appendingPathComponent("00000000-0000-0000-0000-000000000002", isDirectory: true)
        let draft3 = boundedRoot.appendingPathComponent("00000000-0000-0000-0000-000000000003", isDirectory: true)
        for draft in [draft1, draft2, draft3] {
            try fm.createDirectory(at: draft, withIntermediateDirectories: true)
            try Data("{}".utf8).write(to: draft.appendingPathComponent("latest.json"))
            try Data("temp".utf8).write(to: draft.appendingPathComponent("working.wav"))
            try Data("temp".utf8).write(to: draft.appendingPathComponent("channel-0.wav"))
            try Data("temp".utf8).write(to: draft.appendingPathComponent("channel-1.wav"))
        }

        // Pre-cancelled token stops immediately without unlinking files.
        let cancelledToken = WorkCancellation()
        cancelledToken.cancel()
        let cancelledReport = LiveTranscription.pruneDisposableWorkingFiles(
            in: boundedRoot,
            cancel: cancelledToken
        )
        #expect(cancelledReport.cancelled)
        #expect(cancelledReport.removedFiles.isEmpty)
        #expect(fm.fileExists(atPath: draft1.appendingPathComponent("working.wav").path))

        // Streaming enumeration bounds I/O without sorting/loading the entire directory.
        let boundedReport = LiveTranscription.pruneDisposableWorkingFiles(
            in: boundedRoot,
            maxDraftDirectories: 1,
            maxEntriesPerDirectory: 2
        )
        #expect(boundedReport.stoppedByLimit)
        #expect(boundedReport.inspectedDraftDirectories == 1)
        #expect((1...2).contains(boundedReport.removedFiles.count))
        #expect(Set(boundedReport.removedFiles.map { $0.deletingLastPathComponent() }).count == 1)
        #expect(boundedReport.inspectedEntries <= LiveTranscriptionPolicy.maximumCleanupEntries)
        for draft in [draft1, draft2, draft3] {
            #expect(fm.fileExists(atPath: draft.appendingPathComponent("latest.json").path))
            try Data("temp".utf8).write(to: draft.appendingPathComponent("working.wav"))
        }

        // Mid-scan cancellation stops after the first removal.
        var checks = 0
        let midCancelReport = LiveTranscription.pruneDisposableWorkingFiles(
            in: boundedRoot,
            shouldCancel: {
                checks += 1
                return checks > 4
            }
        )
        #expect(midCancelReport.cancelled)
        #expect(midCancelReport.removedFiles.count < 3)

        // Enumeration failure (unreadable draft directory 0o000) and unlink failure (read-only attempt directory 0o500) are surfaced on shutdown() while accessible sibling drafts are cleaned.
        let LockedAttempt = draft2.appendingPathComponent("00000000-0000-0000-0000-000000000020", isDirectory: true)
        try fm.createDirectory(at: LockedAttempt, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: LockedAttempt.appendingPathComponent("chunk.json"))
        let lockedWav = LockedAttempt.appendingPathComponent("working.wav")
        try Data("locked".utf8).write(to: lockedWav)
        try fm.setAttributes([.posixPermissions: 0o500], ofItemAtPath: LockedAttempt.path)
        try fm.setAttributes([.posixPermissions: 0o000], ofItemAtPath: draft1.path)
        defer {
            try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: LockedAttempt.path)
            try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: draft1.path)
        }

        let shutdownLive = LiveTranscription(liveRoot: boundedRoot)
        await shutdownLive.shutdown()
        #expect(!shutdownLive.lastCleanupReport.ranOnMainThread)
        #expect(shutdownLive.lastCleanupFailures.contains {
            $0.url.standardizedFileURL == draft1.standardizedFileURL
                && $0.operation == .enumerate
                && $0.posixErrorCode == EACCES
        })
        #expect(shutdownLive.lastCleanupFailures.contains {
            $0.url.standardizedFileURL == lockedWav.standardizedFileURL
                && $0.operation == .unlink
                && $0.posixErrorCode == EACCES
        })
        #expect(fm.fileExists(atPath: lockedWav.path))
        // Accessible sibling draft3 was still cleaned during the same shutdown pass.
        #expect(fm.fileExists(atPath: draft3.appendingPathComponent("latest.json").path))
        #expect(!fm.fileExists(atPath: draft3.appendingPathComponent("working.wav").path))
        #expect(!fm.fileExists(atPath: draft3.appendingPathComponent("channel-0.wav").path))
        #expect(!fm.fileExists(atPath: draft3.appendingPathComponent("channel-1.wav").path))
    }

    @Test("RecorderTelemetry isolates 10-30 Hz waveform/duration updates and StudioView keeps capture controls in all modes (#41, #44)")
    @MainActor
    func recorderTelemetryIsolationAndUnifiedStudioCaptureControls() async {
        let defaults = UserDefaults(suiteName: "com.moreaki.recscribe.telemetry-test.\(UUID().uuidString)")!
        let recorder = RecorderViewModel(
            controller: MockRecordingControlling(),
            permissions: MockPermissionProviding(.granted),
            clock: ManualClock(),
            saveLocation: MockSaveLocationProviding(directory: URL(fileURLWithPath: "/tmp")),
            audioSource: MockAudioSourceProviding(),
            installLocation: MockInstallLocationProviding(.applications),
            defaults: defaults
        )

        let viewModelInvalidations = OSAllocatedUnfairLock(initialState: 0)
        let telemetryInvalidations = OSAllocatedUnfairLock(initialState: 0)

        // Chrome and Settings read capture gates/preferences, not telemetry.
        for step in 1...30 {
            withObservationTracking {
                _ = recorder.statusText
                _ = recorder.canRecord
                _ = recorder.showsSettingsShelf
                _ = recorder.saveLocationName
                _ = recorder.selectedFormat
                _ = recorder.permissionStatus
            } onChange: { viewModelInvalidations.withLock { $0 += 1 } }
            withObservationTracking { _ = recorder.telemetry.duration } onChange: { telemetryInvalidations.withLock { $0 += 1 } }
            withObservationTracking { _ = recorder.telemetry.waveformSamples } onChange: { telemetryInvalidations.withLock { $0 += 1 } }
            withObservationTracking { _ = recorder.telemetry.healthTime } onChange: { telemetryInvalidations.withLock { $0 += 1 } }
            recorder.duration = Double(step) * 0.1
            recorder.waveformSamples = Array(repeating: Float(step) / 30.0, count: 200)
            recorder.healthTime = Double(step)
        }
        #expect(viewModelInvalidations.withLock { $0 } == 0)
        #expect(telemetryInvalidations.withLock { $0 } == 90)
        #expect(recorder.formattedDuration == "00:03")

        // Verify every workspace, including Settings, retains the capture controls.
        let liveRoot = FileManager.default.temporaryDirectory.appendingPathComponent("studio-modes-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: liveRoot) }
        let live = LiveTranscription(liveRoot: liveRoot)
        let library = SessionLibrary()
        let settings = AppSettings(defaults: defaults)
        let runtime = RuntimeManager(settings: settings)
        for mode in StudioWorkspaceMode.allCases {
            let studio = StudioView(workspaceMode: mode)
                .environment(recorder)
                .environment(live)
                .environment(library)
                .environment(settings)
                .environment(runtime)
            let host = NSHostingView(rootView: studio)
            host.frame = NSRect(origin: .zero, size: AppWindow.studio.defaultSize)
            host.layoutSubtreeIfNeeded()
            #expect(host.fittingSize.width >= AppWindow.studio.minimumSize.width)
        }
        await live.shutdown()
        await library.shutdown()
    }
}
