import AVFoundation
import Darwin
import Foundation

/// The saved mix has its own cursor. It reads already-written source PCM instead
/// of committing the monitor's bounded reorder window to the recording file.
/// One 4096-frame stereo block and one source block are resident, regardless of
/// source delivery skew or recording duration. All access is worker-confined.
nonisolated final class SourceMixdown {
    struct Failure: LocalizedError {
        var detail: String
        var errorDescription: String? { "The saved mix could not be completed; source tracks are preserved. " + detail }
    }
    struct Source {
        var track: RecordingSession.SourceTrack
        var session: RecordingSession
        var manifest: URL
    }
    static let blockFrames = 4096
    static let clippingIssue = "The derived mix clipped; unattenuated source tracks are retained."
    private(set) var position: Int64
    private(set) var clippedFrames: Int64 = 0
    private var readers: [CaptureTrack: Reader] = [:]

    init(position: Int64 = 0) { self.position = position }

    func render(sources: [Source], tracks: [RecordingSession.SourceTrack], events: [GainEvent],
                to end: Int64, check: () throws -> Void = {},
                write: (AVAudioPCMBuffer) throws -> Void) throws {
        guard !events.isEmpty, events[0].to.count == tracks.count * 32 + 1,
              end >= position else { throw SessionError.invalid("Invalid source mix timeline") }
        var eventIndex = 0
        let starts = tracks.map { $0.mixStartFrame ?? 0 }
        let fixedTopology = starts.allSatisfy { $0 == 0 }
        while position < end {
            try check()
            try autoreleasepool {
                let count = Int(min(Int64(Self.blockFrames), end - position))
                guard let buffer = AVAudioPCMBuffer(pcmFormat: AudioFormatNormalizer.canonical,
                                                   frameCapacity: AVAudioFrameCount(count)),
                      let output = buffer.floatChannelData else { throw WAVWriterError.invalidFormat }
                buffer.frameLength = AVAudioFrameCount(count)
                var blockClipped: Int64 = 0
                output[0].initialize(repeating: 0, count: count)
                output[1].initialize(repeating: 0, count: count)
                for source in sources {
                    try check()
                    guard let slot = tracks.firstIndex(where: { $0.role == source.track.role }) else {
                        throw SessionError.invalid("Unknown mix source")
                    }
                    let reader = readers[source.track.role] ?? Reader()
                    readers[source.track.role] = reader
                    let pcm = try reader.read(source, at: position, count: count)
                    let channels = source.session.channels
                    let routes = source.track.channelRoutes ?? (channels == 1
                        ? [.init(channel: 0, placement: .center)]
                        : [.init(channel: 0, placement: .left), .init(channel: 1, placement: .right)])
                    guard routes.allSatisfy({ (0..<channels).contains($0.channel) }) else {
                        throw SessionError.invalid("Source mix channel is unavailable")
                    }
                    let leftCount = Float(max(1, routes.filter { $0.placement != .right }.count))
                    let rightCount = Float(max(1, routes.filter { $0.placement != .left }.count))
                    var cursor = eventIndex
                    for offset in 0..<count {
                        let frame = position + Int64(offset)
                        guard frame >= (source.track.mixStartFrame ?? 0) else { continue }
                        while cursor + 1 < events.count && events[cursor + 1].frame <= frame { cursor += 1 }
                        let event = events[cursor]
                        let divisor = Float(fixedTopology ? tracks.count : max(1, starts.reduce(0) { $0 + ($1 <= frame ? 1 : 0) }))
                        for route in routes {
                            let value = pcm[offset * channels + route.channel]
                                * event.value(slot * 32 + route.channel, at: frame) / divisor
                            if route.placement != .right { output[0][offset] += value / leftCount }
                            if route.placement != .left { output[1][offset] += value / rightCount }
                        }
                    }
                }
                for offset in 0..<count {
                    let frame = position + Int64(offset)
                    while eventIndex + 1 < events.count && events[eventIndex + 1].frame <= frame { eventIndex += 1 }
                    let master = events[eventIndex].value(tracks.count * 32, at: frame)
                    let l = output[0][offset] * master, r = output[1][offset] * master
                    if abs(l) > 1 || abs(r) > 1 { blockClipped += 1 }
                    output[0][offset] = max(-1, min(1, l))
                    output[1][offset] = max(-1, min(1, r))
                }
                try write(buffer)
                clippedFrames += blockClipped
                position += Int64(count) // Advance only after a successful append.
            }
        }
    }

    /// Source headers can still be checkpointed behind their payload. The owning
    /// writer's snapshot, inode and exact read length define the readable prefix.
    private final class Reader {
        private var file: FileHandle?
        private var name: String?
        private var partIndex = 0

        func read(_ source: Source, at frame: Int64, count: Int) throws -> [Float] {
            let channels = source.session.channels
            var result = [Float](repeating: 0, count: count * channels)
            while partIndex > 0 && (partIndex >= source.session.parts.count || source.session.parts[partIndex].startSample > frame) {
                partIndex -= 1 // A failed output append can retry this block.
            }
            var offset = 0
            while offset < count {
                let absolute = frame + Int64(offset)
                while partIndex + 1 < source.session.parts.count,
                      source.session.parts[partIndex].startSample + source.session.parts[partIndex].frames <= absolute {
                    partIndex += 1
                }
                guard partIndex < source.session.parts.count else { break } // Source ended; explicit trailing silence.
                let part = source.session.parts[partIndex]
                guard absolute < part.startSample + part.frames else { break }
                if absolute < part.startSample {
                    offset += min(count - offset, Int(part.startSample - absolute))
                    continue
                }
                if name != part.path {
                    let url = try RecordingSession.safeURL(part.path, beside: source.manifest)
                    try file?.close()
                    let fd = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
                    guard fd >= 0 else { throw SessionError.invalid("Cannot read a saved mix source") }
                    let opened = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
                    var info = stat()
                    guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
                          part.fileID == nil || part.fileID == UInt64(info.st_ino) else {
                        try? opened.close()
                        throw SessionError.invalid("Mix source identity changed")
                    }
                    file = opened; name = part.path
                }
                let available = Int(min(Int64(count - offset), part.startSample + part.frames - absolute))
                let bytes = available * channels * PCM16WAV.sampleBytes
                try file?.seek(toOffset: UInt64(PCM16WAV.headerBytes)
                    + UInt64(absolute - part.startSample) * UInt64(channels * PCM16WAV.sampleBytes))
                guard let data = try file?.read(upToCount: bytes), data.count == bytes else {
                    throw SessionError.invalid("Saved mix source is truncated")
                }
                data.withUnsafeBytes { raw in
                    for index in 0..<(available * channels) {
                        let value = Int16(littleEndian: raw.loadUnaligned(fromByteOffset: index * 2, as: Int16.self))
                        result[offset * channels + index] = Float(value) / Float(Int16.max)
                    }
                }
                offset += available
            }
            return result
        }
    }

    /// Called under the existing session lease, after source verification. A
    /// crash may leave a complete source prefix longer than the saved mix. Keep
    /// that mix prefix immutable and publish a verified continuation atomically.
    /// If the old prefix is damaged, retain it as an artifact and rebuild from 0.
    static func recover(_ session: inout RecordingSession, at manifest: URL,
                        cancel: WorkCancellation) throws {
        guard session.sourceBasedMix == true, let tracks = session.sourceTracks,
              let events = session.gainAutomation else { return }
        let sources = try tracks.compactMap { track -> Source? in
            guard track.manifestPath != nil else { return nil }
            let child = try LinkedSourceSessions.read(track, parent: session, at: manifest)
            guard child.session.parts.allSatisfy({ $0.status == .verified }), child.session.totalFrames > 0 else {
                throw Failure(detail: "A source could not be verified; recover it before completing the mix.")
            }
            return .init(track: track, session: child.session, manifest: child.id)
        }
        let end = sources.map { $0.session.totalFrames }.max() ?? 0
        let rebuild = session.parts.contains { $0.status != .verified }
        let start = rebuild ? 0 : session.totalFrames
        guard end > start else { return }
        let sourceLeases = try sources.map { try SessionLease($0.manifest) }
        defer { withExtendedLifetime(sourceLeases) {} }
        func verifySources() throws {
            for source in sources {
                for part in source.session.parts {
                    let url = try RecordingSession.safeURL(part.path, beside: source.manifest)
                    guard let hash = part.sha256, try RecordingSession.hash(url, check: cancel.check) == hash else {
                        throw Failure(detail: "A source changed during mix completion")
                    }
                }
            }
        }
        try verifySources()
        try cancel.check()
        let suffix = SessionWAVWriter(options: session.options)
        let stem = manifest.lastPathComponent.replacingOccurrences(of: ".recscribe.json", with: "")
        let destination = manifest.deletingLastPathComponent()
            .appendingPathComponent(stem + "-MixContinuation-" + UUID().uuidString + ".wav")
        var published = false
        defer {
            // Only this attempt's unpublished derived output is disposable.
            // The primary mix and source files are never removed or overwritten.
            if !published {
                try? suffix.markFailure(CancellationError())
                try? suffix.finalize()
                for part in suffix.snapshot?.parts ?? [] {
                    if let url = try? RecordingSession.safeURL(part.path, beside: destination) {
                        try? FileManager.default.removeItem(at: url)
                    }
                }
            }
            if let childManifest = suffix.manifestURL {
                try? FileManager.default.removeItem(at: childManifest)
                try? FileManager.default.removeItem(at: childManifest.deletingLastPathComponent()
                    .appendingPathComponent("." + childManifest.lastPathComponent + ".lock"))
            }
        }
        try suffix.createFile(at: destination, sampleRate: Double(session.sampleRate), channels: session.channels)
        try suffix.setParent(session.id, epoch: session.captureEpoch ?? 0,
                             startedAt: session.startedAt.addingTimeInterval(Double(start) / Double(session.sampleRate)))
        let renderer = SourceMixdown(position: start)
        try renderer.render(sources: sources, tracks: tracks, events: events, to: end,
                            check: cancel.check, write: suffix.writeBuffer)
        try suffix.finalize()
        guard let result = suffix.snapshot else { throw Failure(detail: "Mix continuation is missing") }
        var replacement = session
        for index in replacement.artifacts.indices { replacement.artifacts[index].superseded = true }
        if rebuild {
            for part in session.parts {
                let url = try RecordingSession.safeURL(part.path, beside: manifest)
                let hash = try RecordingSession.hash(url, check: cancel.check)
                let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                if !replacement.artifacts.contains(where: { $0.path == part.path }) {
                    replacement.artifacts.append(.init(path: part.path, format: .wav, sha256: hash,
                        sizeBytes: Int64(size), verification: "previous_partial_mix_retained; not a complete mix", superseded: true))
                }
            }
            replacement.parts = []
        }
        for var part in result.parts {
            try cancel.check()
            let url = try RecordingSession.safeURL(part.path, beside: manifest)
            let layout = try PCM16WAV.read(url)
            guard layout.frames == part.frames, layout.sampleRate == session.sampleRate,
                  layout.channels == session.channels else { throw Failure(detail: "Mix continuation verification failed") }
            part.sha256 = try RecordingSession.hash(url, check: cancel.check)
            part.status = .verified
            part.startSample += start
            replacement.parts.append(part)
        }
        if renderer.clippedFrames > 0, !replacement.issues.contains(clippingIssue) {
            replacement.issues.append(clippingIssue)
        }
        try verifySources()
        _ = try replacement.validated(beside: manifest)
        try replacement.save(manifest)
        published = true
        session = replacement
    }
}
