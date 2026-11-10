import AVFoundation
import Darwin
import Foundation

/// A bounded, immutable selection. No neighbouring audio or other channels are copied.
nonisolated struct SegmentCloudSelection: Equatable, Sendable {
    static let maximumMilliseconds: Int64 = 120_000
    static let maximumAudioBytes = 24_000_000

    struct Identity: Equatable, Sendable {
        let device: Int32
        let inode: UInt64
        let bytes: Int64
        let modifiedSeconds: Int64
        let modifiedNanos: Int64
        let changedSeconds: Int64
        let changedNanos: Int64

        static func read(_ url: URL) throws -> Self {
            let fd = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
            guard fd >= 0 else { throw SessionError.invalid("Selected audio is unavailable or was replaced") }
            defer { Darwin.close(fd) }
            var info = stat()
            guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG else {
                throw SessionError.invalid("Selected audio is not a regular file")
            }
            return .init(device: info.st_dev, inode: info.st_ino, bytes: info.st_size,
                modifiedSeconds: Int64(info.st_mtimespec.tv_sec), modifiedNanos: Int64(info.st_mtimespec.tv_nsec),
                changedSeconds: Int64(info.st_ctimespec.tv_sec), changedNanos: Int64(info.st_ctimespec.tv_nsec))
        }
    }

    struct Part: Equatable, Sendable {
        let url: URL
        let identity: Identity
        let startFrame: Int64
        let frames: Int64
        let sourceFrames: Int64
    }

    let job: URL
    let revision: String
    let segmentID: String
    let source: URL
    let startMs: Int64
    let endMs: Int64
    let channel: Int
    let sampleRate: Int
    let channels: Int
    let firstFrame: Int64
    let endFrame: Int64
    let parts: [Part]
    let manifestIdentity: Identity?
    let baseline: TranscriptCorrection?

    var timing: String { "\(TranscriptReading.time(startMs)) – \(TranscriptReading.time(endMs))" }
    var audioBytes: Int { Int(endFrame - firstFrame) * 2 + PCM16WAV.headerBytes }

    @concurrent static func prepare(job: URL, document: TranscriptPreview, segmentID: String) async throws -> Self {
        try inspect(job: job, document: document, segmentID: segmentID)
    }

    @concurrent func revalidate() async throws { try validate() }

    static func inspect(job: URL, document: TranscriptPreview, segmentID: String) throws -> Self {
        try Task.checkCancellation()
        guard let revision = document.revision, try TranscriptPreview.currentRevision(job) == revision,
              let metadata = document.source, let source = document.sourceURL, source.isFileURL,
              let segment = document.segments.first(where: { $0.id == segmentID }),
              document.segments.filter({ $0.id == segmentID }).count == 1,
              let start = segment.startMs, let end = segment.endMs, start >= 0, end > start,
              end - start <= maximumMilliseconds, end <= metadata.durationMs,
              let channel = segment.channel, channel >= 0, channel < metadata.channels,
              (1...32).contains(metadata.channels), (1...384_000).contains(metadata.sampleRate) else {
            throw SessionError.invalid("Choose a saved passage with a known channel and a valid time range of at most two minutes.")
        }
        let rate = metadata.sampleRate
        func product(_ ms: Int64) throws -> Int64 {
            let (value, overflow) = ms.multipliedReportingOverflow(by: Int64(rate))
            guard !overflow else { throw SessionError.invalid("Passage timestamps exceed the audio limits") }
            return value
        }
        // Round inward: even fractional sample boundaries cannot add neighbouring audio.
        let from = try product(start), to = try product(end)
        let firstFrame = from / 1_000 + (from % 1_000 == 0 ? 0 : 1), endFrame = to / 1_000
        guard endFrame > firstFrame, endFrame - firstFrame <= Int64((maximumAudioBytes - PCM16WAV.headerBytes) / 2) else {
            throw SessionError.invalid("This passage exceeds the 24 MB audio limit")
        }
        var parts: [Part] = []
        var manifestIdentity: Identity?
        if source.lastPathComponent.hasSuffix(".recscribe.json") {
            manifestIdentity = try Identity.read(source)
            let session = try RecordingSession.read(source)
            guard session.status != .recording, session.parts.count <= 10_000,
                  session.sampleRate == rate, session.channels == metadata.channels else {
                throw SessionError.invalid("Finalize the selected recording before processing this passage")
            }
            var cursor: Int64 = 0
            for part in session.parts {
                try Task.checkCancellation()
                let (next, overflow) = cursor.addingReportingOverflow(part.frames)
                guard part.status == .verified, part.frames > 0, part.startSample == cursor, !overflow else {
                    throw SessionError.invalid("Selected recording contains unverified or missing audio")
                }
                if cursor < endFrame && next > firstFrame {
                    let url = try RecordingSession.safeURL(part.path, beside: source)
                    parts.append(Part(url: url, identity: try Identity.read(url), startFrame: cursor,
                        frames: part.frames, sourceFrames: part.frames))
                }
                cursor = next
            }
            guard endFrame <= cursor, try Identity.read(source) == manifestIdentity else {
                throw SessionError.invalid("Selected recording changed or its passage is unavailable")
            }
        } else {
            guard source.pathExtension.lowercased() == "wav" else { throw SessionError.invalid("Select a WAV or verified recording session") }
            let identity = try Identity.read(source)
            let file = try AVAudioFile(forReading: source, commonFormat: .pcmFormatInt16, interleaved: true)
            guard file.length >= endFrame else { throw SessionError.invalid("Selected passage extends past the audio") }
            parts = [.init(url: source, identity: identity, startFrame: 0, frames: file.length, sourceFrames: file.length)]
        }
        guard !parts.isEmpty else { throw SessionError.invalid("Selected passage has no available audio") }
        for part in parts {
            let file = try AVAudioFile(forReading: part.url, commonFormat: .pcmFormatInt16, interleaved: true)
            guard file.processingFormat.sampleRate == Double(rate), file.processingFormat.channelCount == metadata.channels,
                  file.length == part.sourceFrames, try Identity.read(part.url) == part.identity else {
                throw SessionError.invalid("Selected audio format or length changed")
            }
        }
        return .init(job: job.standardizedFileURL, revision: revision, segmentID: segmentID, source: source,
            startMs: start, endMs: end, channel: channel, sampleRate: rate, channels: metadata.channels,
            firstFrame: firstFrame, endFrame: endFrame, parts: parts, manifestIdentity: manifestIdentity,
            baseline: document.corrections[segmentID])
    }

    func validate() throws {
        try Task.checkCancellation()
        guard startMs >= 0, endMs > startMs, endMs - startMs <= Self.maximumMilliseconds,
              (1...384_000).contains(sampleRate), (1...32).contains(channels), (0..<channels).contains(channel),
              firstFrame >= 0, endFrame > firstFrame,
              endFrame - firstFrame <= Int64((Self.maximumAudioBytes - PCM16WAV.headerBytes) / 2),
              !parts.isEmpty, parts.count <= 10_000 else { throw SessionError.invalid("Invalid selected audio bounds") }
        guard try TranscriptPreview.currentRevision(job) == revision else { throw SessionError.invalid("Transcript changed; select the passage again") }
        if let manifestIdentity, try Identity.read(source) != manifestIdentity {
            throw SessionError.invalid("Recording changed; select the passage again")
        }
        for part in parts where try Identity.read(part.url) != part.identity {
            throw SessionError.invalid("Selected audio changed; select the passage again")
        }
    }

    func copy(to destination: URL) throws {
        try validate()
        let header = try PCM16WAV(sampleRate: Double(sampleRate), channels: 1, payloadBytes: UInt64(endFrame - firstFrame) * 2)
        let fd = Darwin.open(destination.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw WAVWriterError.fileCreationFailed }
        let output = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? output.close() }
        try output.write(contentsOf: header.header)
        var written: Int64 = 0
        for part in parts {
            try Task.checkCancellation()
            let file = try AVAudioFile(forReading: part.url, commonFormat: .pcmFormatInt16, interleaved: true)
            guard file.processingFormat.sampleRate == Double(sampleRate), file.processingFormat.channelCount == channels,
                  file.length == part.sourceFrames,
                  let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 4_096) else {
                throw SessionError.invalid("Selected audio changed while extracting the passage")
            }
            let start = max(firstFrame, part.startFrame) - part.startFrame
            var remaining = min(endFrame, part.startFrame + part.frames) - part.startFrame - start
            file.framePosition = start
            while remaining > 0 {
                try Task.checkCancellation()
                let count = AVAudioFrameCount(min(4_096, remaining))
                try file.read(into: buffer, frameCount: count)
                guard buffer.frameLength == count, let samples = buffer.int16ChannelData?[0] else {
                    throw SessionError.invalid("Selected audio ended while extracting the passage")
                }
                var mono = Data(count: Int(count) * 2)
                mono.withUnsafeMutableBytes { target in
                    for frame in 0..<Int(count) {
                        target.storeBytes(of: samples[frame * channels + channel].littleEndian, toByteOffset: frame * 2, as: Int16.self)
                    }
                }
                try output.write(contentsOf: mono)
                remaining -= Int64(count); written += Int64(count)
            }
        }
        guard written == endFrame - firstFrame else { throw SessionError.invalid("Selected audio contains a gap") }
        try validate()
    }
}
