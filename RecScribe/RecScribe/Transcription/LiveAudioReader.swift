import Darwin
import Foundation

/// Reads only complete, already appended frames. Never repairs, locks or writes
/// the capture files. A file-backed cursor is the queue, independent of ASR speed.
nonisolated enum LiveAudioReader {
    struct Slice: Sendable {
        let file: URL
        let startFrame: Int64
        let endFrame: Int64
        let availableFrames: Int64
        let sampleRate: Int
        let channels: Int
        let identicalChannels: Bool
    }
    private struct Part {
        let handle: FileHandle
        let start: Int64
        let frames: Int64
    }

    static func copy(manifest: URL, cursor: Int64, seconds: Int, overlapSeconds: Int,
                     finished: Bool, to destination: URL, cancel: WorkCancellation) throws -> Slice? {
        guard cursor >= 0, LiveTranscriptionPolicy.chunkChoices.contains(seconds),
              overlapSeconds >= 0, overlapSeconds < seconds else {
            throw SessionError.invalid("Invalid live audio window")
        }
        return try snapshot(manifest: manifest, finished: finished, cancel: cancel) { session, parts, available in
            try copy(session: session, parts: parts, available: available, cursor: cursor, seconds: seconds,
                     overlapSeconds: overlapSeconds, finished: finished, to: destination, cancel: cancel)
        }
    }

    /// Sample the consent boundary from bytes on disk, not the lagging manifest frame count.
    static func position(manifest: URL, cancel: WorkCancellation) throws -> Int64 {
        try snapshot(manifest: manifest, finished: false, cancel: cancel) { _, _, available in available }
    }

    private static func snapshot<T>(manifest: URL, finished: Bool, cancel: WorkCancellation,
                                    read: (RecordingSession, [Part], Int64) throws -> T) throws -> T {
        try cancel.check()
        let session = try RecordingSession.read(manifest)
        let frameBytes = session.channels * PCM16WAV.sampleBytes
        var parts: [Part] = []
        defer { for part in parts { try? part.handle.close() } }
        var available: Int64 = 0
        for part in session.parts {
            try cancel.check()
            guard part.startSample == available else { throw SessionError.invalid("Live audio has a gap; review the recording") }
            if part.status == .opening && !finished { break } // Writer is still publishing the next part.
            let url = try RecordingSession.safeURL(part.path, beside: manifest)
            let fd = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW)
            guard fd >= 0 else { throw SessionError.invalid("A live recording part is unavailable") }
            let file = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
            do {
                var stat = Darwin.stat()
                guard fstat(fd, &stat) == 0, (stat.st_mode & S_IFMT) == S_IFREG,
                      let fileID = part.fileID, UInt64(stat.st_ino) == fileID else {
                    throw SessionError.invalid("A live recording part was replaced")
                }
                let header = try PCM16WAV(header: file.read(upToCount: PCM16WAV.headerBytes) ?? Data())
                guard header.sampleRate == session.sampleRate, header.channels == session.channels,
                      stat.st_size >= PCM16WAV.headerBytes else { throw WAVWriterError.formatMismatch }
                let frames = (stat.st_size - Int64(PCM16WAV.headerBytes)) / Int64(frameBytes)
                guard frames <= Int64(PCM16WAV.maximumPayload) / Int64(frameBytes),
                      part.status == .recording || frames == part.frames else {
                    throw SessionError.invalid("Live recording size does not match its manifest")
                }
                parts.append(Part(handle: file, start: available, frames: frames))
                guard frames <= Int64.max - available else { throw WAVWriterError.invalidFormat }
                available += frames
            } catch { try? file.close(); throw error }
        }
        return try read(session, parts, available)
    }

    private static func copy(session: RecordingSession, parts: [Part], available: Int64, cursor: Int64,
                             seconds: Int, overlapSeconds: Int, finished: Bool, to destination: URL,
                             cancel: WorkCancellation) throws -> Slice? {
        let frameBytes = session.channels * PCM16WAV.sampleBytes
        let wanted = Int64(seconds * session.sampleRate)
        guard available > cursor, finished || available - cursor >= wanted else { return nil }
        let end = min(available, cursor + wanted)
        let start = max(0, cursor - Int64(overlapSeconds * session.sampleRate))
        let header = try PCM16WAV(sampleRate: Double(session.sampleRate), channels: session.channels,
                                 payloadBytes: UInt64(end - start) * UInt64(frameBytes))
        let fd = Darwin.open(destination.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw WAVWriterError.fileCreationFailed }
        let output = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? output.close() }
        try output.write(contentsOf: header.header)
        var identical = true
        let blockBytes = PCM16WAV.copyBlockBytes / frameBytes * frameBytes
        for part in parts {
            let from = max(start, part.start), to = min(end, part.start + part.frames)
            guard to > from else { continue }
            try part.handle.seek(toOffset: UInt64(PCM16WAV.headerBytes) + UInt64(from - part.start) * UInt64(frameBytes))
            var remaining = Int(to - from) * frameBytes
            while remaining > 0 {
                try cancel.check()
                let count = min(remaining, blockBytes)
                guard let bytes = try part.handle.read(upToCount: count), bytes.count == count else {
                    throw SessionError.invalid("Live audio changed while preparing a chunk")
                }
                if identical && session.channels > 1 {
                    identical = bytes.withUnsafeBytes { raw in
                        let values = raw.bindMemory(to: Int16.self)
                        for frame in stride(from: 0, to: values.count, by: session.channels) {
                            for channel in 1..<session.channels where values[frame] != values[frame + channel] { return false }
                        }
                        return true
                    }
                }
                try output.write(contentsOf: bytes)
                remaining -= bytes.count
            }
        }
        try output.close()
        try cancel.check()
        return Slice(file: destination, startFrame: start, endFrame: end, availableFrames: available,
                     sampleRate: session.sampleRate, channels: session.channels, identicalChannels: identical)
    }
}
