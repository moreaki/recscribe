import AVFoundation
import CryptoKit
import Darwin
import Foundation
import os

nonisolated final class WorkCancellation: Sendable {
    private let cancelled = OSAllocatedUnfairLock(initialState: false)
    func cancel() { cancelled.withLock { $0 = true } }
    func check() throws { if cancelled.withLock({ $0 }) { throw CancellationError() } }
}

/// Blocking work belongs to one utility worker, never a capture/main queue.
nonisolated enum SessionProcessing {
    private static let logger = Logger(subsystem: "com.moreaki.recscribe", category: "SessionProcessing")
    static func run(_ binary: URL, _ arguments: [String], in directory: URL,
                    cancel: WorkCancellation, timeout: TimeInterval = 86_400) throws -> String {
        try cancel.check()
        let started = ContinuousClock.now
        defer { logger.notice("Local process \(binary.lastPathComponent, privacy: .public) elapsed=\(String(describing: started.duration(to: .now)), privacy: .public)") }
        let log = directory.appendingPathComponent("process-\(UUID()).log")
        FileManager.default.createFile(atPath: log.path, contents: nil, attributes: [.posixPermissions: 0o600])
        let output = try FileHandle(forWritingTo: log)
        defer { try? output.close(); try? FileManager.default.removeItem(at: log) }
        let process = Process()
        process.executableURL = binary
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = output
        process.qualityOfService = .utility
        try process.run()
        let deadline = ContinuousClock.now.advanced(by: .seconds(timeout))
        do {
            while process.isRunning {
                try cancel.check()
                guard ContinuousClock.now < deadline else { throw SessionError.invalid("Local process timed out") }
                usleep(50_000)
            }
        } catch {
            process.terminate()
            let stop = ContinuousClock.now.advanced(by: .seconds(5))
            while process.isRunning && ContinuousClock.now < stop { usleep(20_000) }
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            process.waitUntilExit()
            throw error
        }
        process.waitUntilExit()
        try cancel.check()
        try output.synchronize()
        let file = try FileHandle(forReadingFrom: log)
        defer { try? file.close() }
        let text = String(decoding: try file.read(upToCount: 128 * 1_024) ?? Data(), as: UTF8.self)
        guard process.terminationStatus == 0 else { throw SessionError.invalid("\(binary.lastPathComponent) failed: \(text.prefix(2_000))") }
        return text
    }

    /// Recover only our fixed-layout PCM16 WAVs. Stream-copy before replacing;
    /// never load a multi-GB part into RAM or patch the only copy in place.
    static func recoverPart(_ url: URL, session: RecordingSession, cancel: WorkCancellation) throws -> Int64 {
        let input = try FileHandle(forReadingFrom: url)
        defer { try? input.close() }
        guard var header = try input.read(upToCount: 44), header.count == 44,
              header.prefix(4) == Data("RIFF".utf8), header[8..<12] == Data("WAVE".utf8),
              header[12..<16] == Data("fmt ".utf8), header[36..<40] == Data("data".utf8) else {
            throw SessionError.invalid("Unrecognized WAV header")
        }
        func number(_ offset: Int, _ count: Int) -> Int64 {
            (0..<count).reduce(0) { $0 | Int64(header[offset + $1]) << (8 * $1) }
        }
        guard number(20, 2) == 1, number(22, 2) == session.channels,
              number(24, 4) == session.sampleRate, number(34, 2) == 16 else {
            throw SessionError.invalid("Part format does not match session")
        }
        let total = try input.seekToEnd()
        let alignment = Int64(session.channels * 2)
        let payload = (Int64(total) - 44) / alignment * alignment
        guard payload >= 0, payload <= Int64(UInt32.max) - 36 else { throw SessionError.invalid("Invalid WAV size") }
        let correct = number(40, 4) == payload && number(4, 4) == payload + 36 && Int64(total) == payload + 44
        if !correct {
            let temporary = url.deletingLastPathComponent().appendingPathComponent(".repair-\(UUID()).wav")
            defer { try? FileManager.default.removeItem(at: temporary) }
            for (offset, value) in [(4, payload + 36), (40, payload)] {
                for byte in 0..<4 { header[offset + byte] = UInt8(truncatingIfNeeded: value >> (byte * 8)) }
            }
            FileManager.default.createFile(atPath: temporary.path, contents: header, attributes: [.posixPermissions: 0o600])
            let output = try FileHandle(forWritingTo: temporary)
            defer { try? output.close() }
            try output.seekToEnd()
            try input.seek(toOffset: 44)
            var remaining = payload
            while remaining > 0 {
                try cancel.check()
                guard let data = try input.read(upToCount: Int(min(remaining, 1_024 * 1_024))), !data.isEmpty else {
                    throw SessionError.invalid("Part changed during recovery")
                }
                try output.write(contentsOf: data)
                remaining -= Int64(data.count)
            }
            try output.synchronize()
            try output.close()
            _ = try FileManager.default.replaceItemAt(url, withItemAt: temporary)
        }
        return payload / alignment
    }

    static func process(_ manifest: URL, ffmpeg: URL, cancel: WorkCancellation,
                        recover: Bool = false, issue: String? = nil) throws -> RecordingSession {
        let started = ContinuousClock.now
        defer { logger.notice("Session verification elapsed=\(String(describing: started.duration(to: .now)), privacy: .public) recovery=\(recover)") }
        let lease = try SessionLease(manifest)
        defer { withExtendedLifetime(lease) {} }
        var session = try RecordingSession.read(manifest)
        if let issue, !session.issues.contains(issue) { session.issues.append(issue) }
        if session.status == "recording" && !recover { throw SessionError.invalid("Interrupted recording needs explicit recovery") }
        for index in session.parts.indices {
            try cancel.check()
            let part = session.parts[index]
            do {
                let url = try RecordingSession.safeURL(part.path, beside: manifest)
                let originalHash = try RecordingSession.hash(url, check: cancel.check)
                if let expected = part.sha256, originalHash != expected { throw SessionError.invalid("Checksum mismatch") }
                let wasInterrupted = ["opening", "recording"].contains(part.status)
                if wasInterrupted && !recover { throw SessionError.invalid("Part needs recovery") }
                let frames: Int64
                if wasInterrupted {
                    let identity = (try FileManager.default.attributesOfItem(atPath: url.path)[.systemFileNumber] as? NSNumber)?.uint64Value
                    guard let expectedID = part.fileID, identity == expectedID else {
                        throw SessionError.invalid("Interrupted part ownership cannot be established; original left untouched")
                    }
                    frames = try recoverPart(url, session: session, cancel: cancel)
                    session.parts[index].fileID = (try FileManager.default.attributesOfItem(atPath: url.path)[.systemFileNumber] as? NSNumber)?.uint64Value
                    session.parts[index].recovered = true
                    session.issues.append("Recovered part: \(part.path); inspect its end and any following boundary")
                } else {
                    let file = try AVAudioFile(forReading: url)
                    let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                    guard file.fileFormat.sampleRate == Double(session.sampleRate),
                          file.fileFormat.channelCount == session.channels,
                          size == 44 + part.frames * Int64(session.channels * 2),
                          file.length == part.frames else { throw SessionError.invalid("Part length or format mismatch") }
                    frames = file.length
                }
                guard frames > 0 else { throw SessionError.invalid("Part contains no audio") }
                if index + 1 < session.parts.count, part.startSample + frames != session.parts[index + 1].startSample {
                    throw SessionError.invalid("Gap or overlap at part boundary")
                }
                session.parts[index].frames = frames
                session.parts[index].sizeBytes = 44 + frames * Int64(session.channels * 2)
                session.parts[index].sha256 = try RecordingSession.hash(url, check: cancel.check)
                session.parts[index].status = "verified"
            } catch is CancellationError { throw CancellationError() }
            catch {
                session.parts[index].status = "needs_review"
                let message = "\(part.path): \(error.localizedDescription)"
                if !session.issues.contains(message) { session.issues.append(message) }
            }
        }
        session.endedAt = session.endedAt ?? Date()
        session.status = "verified"
        try session.save(manifest)
        if session.options.archiveFormat != .wav, session.parts.allSatisfy({ $0.status == "verified" }) {
            let exists = try session.artifacts.contains { artifact in
                guard artifact.format == session.options.archiveFormat else { return false }
                let url = try RecordingSession.safeURL(artifact.path, beside: manifest)
                return (try? RecordingSession.hash(url, check: cancel.check)) == artifact.sha256
            }
            if !exists {
                do {
                    session.artifacts.append(try archive(session, manifest: manifest, ffmpeg: ffmpeg, cancel: cancel))
                } catch is CancellationError { throw CancellationError() }
                catch {
                    session.status = "needs_review"
                    session.issues.append("Archive conversion failed; originals retained: \(error.localizedDescription)")
                    try session.save(manifest)
                    throw error
                }
            }
        }
        session.status = session.issues.isEmpty && session.parts.allSatisfy { $0.status == "verified" } ? "completed" : "needs_review"
        try session.save(manifest)
        return session
    }

    static func archive(_ session: RecordingSession, manifest: URL, ffmpeg: URL,
                        cancel: WorkCancellation) throws -> RecordingSession.Artifact {
        let directory = manifest.deletingLastPathComponent()
        let work = directory.appendingPathComponent(".archive-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: work) }
        let list = work.appendingPathComponent("parts.ffconcat")
        var lines = ["ffconcat version 1.0"]
        var pcmHash = SHA256()
        for part in session.parts {
            let url = try RecordingSession.safeURL(part.path, beside: manifest)
            guard try RecordingSession.hash(url, check: cancel.check) == part.sha256 else { throw SessionError.invalid("Source changed before conversion") }
            let escaped = url.path.replacingOccurrences(of: "'", with: "'\\''")
            lines.append("file '\(escaped)'")
            let input = try FileHandle(forReadingFrom: url)
            defer { try? input.close() }
            try input.seek(toOffset: 44)
            while let data = try input.read(upToCount: 1_024 * 1_024), !data.isEmpty { try cancel.check(); pcmHash.update(data: data) }
        }
        try lines.joined(separator: "\n").appending("\n").write(to: list, atomically: true, encoding: .utf8)
        let format = session.options.archiveFormat
        let temporary = work.appendingPathComponent("archive.\(format.rawValue)")
        var args = ["-nostdin", "-hide_banner", "-loglevel", "error", "-xerror", "-n", "-protocol_whitelist", "file", "-f", "concat", "-safe", "0", "-i", list.path, "-map", "0:a:0"]
        switch format {
        case .wav: throw SessionError.invalid("WAV originals are retained unchanged")
        case .flac: args += ["-c:a", "flac", "-compression_level", "\(session.options.flacCompression)"]
        case .opus: args += ["-c:a", "libopus", "-b:a", "\(session.options.bitrateKbps)k"]
        case .m4a: args += ["-c:a", "aac", "-b:a", "\(session.options.bitrateKbps)k", "-movflags", "+faststart"]
        }
        _ = try run(ffmpeg, args + [temporary.path], in: work, cancel: cancel)
        let probe = ffmpeg.deletingLastPathComponent().appendingPathComponent("ffprobe")
        let metadata = try run(probe, ["-v", "error", "-show_entries", "stream=channels,sample_rate,duration:format=duration", "-of", "json", temporary.path], in: work, cancel: cancel)
        guard let info = try JSONSerialization.jsonObject(with: Data(metadata.utf8)) as? [String: Any],
              let streams = info["streams"] as? [[String: Any]], let stream = streams.first,
              stream["channels"] as? Int == session.channels,
              let formatInfo = info["format"] as? [String: Any], let value = formatInfo["duration"] as? String,
              let duration = Double(value), abs(duration - session.duration) <= 0.15 else {
            throw SessionError.invalid("Archive duration or channel verification failed")
        }
        let decoded = try run(ffmpeg, ["-nostdin", "-hide_banner", "-loglevel", "error", "-xerror", "-i", temporary.path,
                                      "-map", "0:a:0", "-ar", "\(session.sampleRate)", "-c:a", "pcm_s16le", "-f", "hash", "-hash", "sha256", "-"], in: work, cancel: cancel)
        let expectedPCM = pcmHash.finalize().map { String(format: "%02x", $0) }.joined()
        if format == .flac && !decoded.lowercased().contains(expectedPCM) { throw SessionError.invalid("Lossless archive PCM checksum mismatch") }
        for part in session.parts {
            guard try RecordingSession.hash(RecordingSession.safeURL(part.path, beside: manifest), check: cancel.check) == part.sha256 else {
                throw SessionError.invalid("Source changed during conversion")
            }
        }
        let stem = manifest.lastPathComponent.replacingOccurrences(of: ".recscribe.json", with: "")
        let hash = try RecordingSession.hash(temporary, check: cancel.check)
        let bytes = try temporary.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        for suffix in 0..<10_000 {
            let name = "\(stem)\(suffix == 0 ? "" : "-Archive\(suffix + 1)").\(format.rawValue)"
            let destination = directory.appendingPathComponent(name)
            // Same-volume hard link publishes without replacing any existing file.
            if Darwin.link(temporary.path, destination.path) == 0 {
                return .init(path: name, format: format, sha256: hash, sizeBytes: Int64(bytes),
                             verification: format == .flac ? "decoded_pcm_sha256_matches_originals" : "full_decode_and_duration_channels_checked; lossy")
            }
            if errno != EEXIST { throw SessionError.invalid("Cannot publish verified archive") }
        }
        throw SessionError.invalid("Cannot reserve archive name")
    }
}
