import AVFoundation
import CryptoKit
import Darwin
import Foundation

nonisolated enum ArchiveFormat: String, Codable, CaseIterable, Sendable {
    case wav, flac, opus, m4a
}

nonisolated struct RecordingStorageOptions: Codable, Equatable, Sendable {
    static let hardCap: Int64 = 3_758_096_384 // 3.5 GiB including the WAV header
    var maximumPartBytes: Int64 = hardCap
    var archiveFormat: ArchiveFormat = .wav
    var bitrateKbps = 128
    var flacCompression = 5

    func validated() throws -> Self {
        guard (48...Self.hardCap).contains(maximumPartBytes),
              (32...320).contains(bitrateKbps), (0...12).contains(flacCompression) else {
            throw SessionError.invalid("Invalid recording storage options")
        }
        return self
    }
}

nonisolated enum SessionError: Error, LocalizedError {
    case invalid(String)
    case diskFull
    var errorDescription: String? {
        switch self {
        case .invalid(let message): message
        case .diskFull: "Not enough free space; existing recording parts are preserved"
        }
    }
}

nonisolated struct RecordingSession: Codable, Identifiable, Sendable {
    var schemaVersion = 1
    var id = UUID()
    var startedAt = Date()
    var endedAt: Date?
    var status = "recording"
    var sampleRate: Int
    var channels: Int
    var bitDepth = 16
    var channelMap: [String]
    var options: RecordingStorageOptions
    var parts: [Part] = []
    var issues: [String] = []
    var artifacts: [Artifact] = []

    struct Part: Codable, Sendable {
        var path: String
        var startSample: Int64
        var frames: Int64 = 0
        var sizeBytes: Int64 = 44
        var sha256: String?
        var status = "opening"
        var recovered = false
        var fileID: UInt64?
        var startedAt: Date
    }
    struct Artifact: Codable, Sendable {
        var path: String
        var format: ArchiveFormat
        var sha256: String
        var sizeBytes: Int64
        var verifiedAt = Date()
        var verification: String
    }
    var totalFrames: Int64 { parts.last.map { $0.startSample + $0.frames } ?? 0 }
    var duration: Double { Double(totalFrames) / Double(sampleRate) }
    static func manifestURL(for audio: URL) -> URL {
        audio.deletingPathExtension().appendingPathExtension("recscribe.json")
    }
    static func partURL(base: URL, index: Int) -> URL {
        index == 0 ? base : base.deletingLastPathComponent()
            .appendingPathComponent("\(base.deletingPathExtension().lastPathComponent)-Part\(index + 1).wav")
    }

    static func read(_ url: URL) throws -> Self {
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= 16 * 1_024 * 1_024 else { throw SessionError.invalid("Session manifest is too large") }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let session = try decoder.decode(Self.self, from: Data(contentsOf: url))
        guard session.schemaVersion == 1, (1...32).contains(session.channels),
              (1...384000).contains(session.sampleRate), session.bitDepth == 16,
              session.channelMap.count == session.channels else { throw SessionError.invalid("Unsupported session schema or audio format") }
        _ = try session.options.validated()
        var end: Int64 = 0
        var paths = Set<String>()
        for part in session.parts {
            _ = try safeURL(part.path, beside: url)
            guard paths.insert(part.path).inserted, part.startSample >= end,
                  part.frames >= 0, part.frames <= Int64.max - part.startSample,
                  part.frames <= (Self.maximumSafePartBytes - 44) / Int64(session.channels * 2) else {
                throw SessionError.invalid("Invalid or overlapping session parts")
            }
            end = part.startSample + part.frames
        }
        for artifact in session.artifacts { _ = try safeURL(artifact.path, beside: url) }
        return session
    }
    private static let maximumSafePartBytes = Int64(UInt32.max) + 8

    static func safeURL(_ name: String, beside manifest: URL) throws -> URL {
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/"),
              !name.contains("\\"), !name.contains("\n"), !name.contains("\r"), !name.contains("\0") else {
            throw SessionError.invalid("Session paths must be local filenames")
        }
        let directory = manifest.deletingLastPathComponent().resolvingSymlinksInPath()
        let url = directory.appendingPathComponent(name)
        guard url.resolvingSymlinksInPath().deletingLastPathComponent() == directory else {
            throw SessionError.invalid("Session path escapes its directory")
        }
        return url
    }

    func save(_ url: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: url, options: .atomic)
    }

    /// Reserve the entire naming namespace using an exclusive manifest file.
    /// Each actual WAV open is also exclusive, protecting against later races.
    static func reserve(_ requested: URL) throws -> URL {
        let directory = requested.deletingLastPathComponent()
        let stem = requested.deletingPathExtension().lastPathComponent
        for suffix in 0..<10_000 {
            let base = suffix == 0 ? stem : "\(stem) (\(suffix))"
            let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
            guard !names.contains(where: { $0 == "\(base).wav" || $0.hasPrefix("\(base)-Part") }) else { continue }
            let audio = directory.appendingPathComponent("\(base).wav")
            let manifest = manifestURL(for: audio)
            let fd = Darwin.open(manifest.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
            if fd >= 0 { Darwin.close(fd); return audio }
            if errno != EEXIST { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        }
        throw SessionError.invalid("Could not reserve a unique recording name")
    }

    static func hash(_ url: URL, skipping: Int = 0, check: () throws -> Void = {}) throws -> String {
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        try file.seek(toOffset: UInt64(skipping))
        var hash = SHA256()
        while let bytes = try file.read(upToCount: 1_024 * 1_024), !bytes.isEmpty {
            try check()
            hash.update(data: bytes)
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

/// Lives only on AudioRecorder's encoding queue. Rollover finalizes a 44-byte
/// header there; expensive checksum/conversion work is deferred until capture ends.
nonisolated final class SessionWAVWriter: AudioFileEncoder {
    private let options: RecordingStorageOptions
    private let freeBytes: (URL) -> Int64?
    private var writer: WAVWriter?
    private var session: RecordingSession?
    private(set) var audioURL: URL?
    private(set) var manifestURL: URL?
    private var nextDiskCheck: Int64 = 0
    private var failed = false
    private var lease: SessionLease?

    init(options: RecordingStorageOptions = .init(), freeBytes: @escaping (URL) -> Int64? = DiskSpace.availableBytes) {
        self.options = options
        self.freeBytes = freeBytes
    }

    func createFile(at url: URL, sampleRate: Double, channels: Int) throws {
        _ = try options.validated()
        guard (1...32).contains(channels), sampleRate.isFinite, (1...384000).contains(sampleRate), sampleRate.rounded() == sampleRate,
              options.maximumPartBytes >= 44 + Int64(channels * 2) else { throw SessionError.invalid("Invalid format or part cap smaller than one audio frame") }
        try checkSpace(url)
        let base = try RecordingSession.reserve(url)
        audioURL = base
        manifestURL = RecordingSession.manifestURL(for: base)
        lease = try SessionLease(manifestURL!)
        session = RecordingSession(sampleRate: Int(sampleRate), channels: channels,
                                   channelMap: (0..<channels).map { "channel-\($0)" }, options: options)
        do { try openPart() } catch { try? markFailure(error); throw error }
    }

    private func checkSpace(_ url: URL) throws {
        guard let available = freeBytes(url) else { throw SessionError.invalid("Free disk space cannot be determined") }
        guard available >= DiskSpace.minimumBytesToRecord else { throw SessionError.diskFull }
    }

    private func openPart() throws {
        guard var session, let audioURL, let manifestURL else { throw SessionError.invalid("Session is not open") }
        try checkSpace(audioURL)
        let partURL = RecordingSession.partURL(base: audioURL, index: session.parts.count)
        let start = session.totalFrames
        session.parts.append(.init(path: partURL.lastPathComponent, startSample: start,
                                   startedAt: session.startedAt.addingTimeInterval(Double(start) / Double(session.sampleRate))))
        self.session = session
        try session.save(manifestURL) // journal intent before creating the next file
        let next = WAVWriter()
        do { try next.createFile(at: partURL, sampleRate: Double(session.sampleRate), channels: session.channels) }
        catch WAVWriterError.fileCreationFailed {
            // The exclusive open failed: this path is not ours to recover.
            self.session?.parts.removeLast()
            try self.session?.save(manifestURL)
            throw WAVWriterError.fileCreationFailed
        }
        writer = next
        let index = session.parts.count - 1
        self.session?.parts[index].fileID = (try FileManager.default.attributesOfItem(atPath: partURL.path)[.systemFileNumber] as? NSNumber)?.uint64Value
        self.session?.parts[index].status = "recording"
        try self.session?.save(manifestURL)
    }

    func writeBuffer(_ buffer: AVAudioPCMBuffer) throws {
        guard !failed, session != nil else { throw SessionError.invalid("Session has stopped after a write failure") }
        do {
            var offset = 0
            while offset < Int(buffer.frameLength) {
                guard let audioURL, let channels = session?.channels, let rate = session?.sampleRate else { throw SessionError.invalid("No active part") }
                let frames = session!.totalFrames
                if frames >= nextDiskCheck {
                    try checkSpace(audioURL)
                    nextDiskCheck = frames + Int64(rate) // at most one second between checks
                }
                let capacity = (options.maximumPartBytes - 44) / Int64(channels * 2)
                let remaining = capacity - session!.parts.last!.frames
                if remaining == 0 { try closePart(); try openPart(); continue }
                let count = min(Int(remaining), Int(buffer.frameLength) - offset)
                try writer?.writeFrames(buffer, offset: offset, count: count)
                let index = session!.parts.count - 1
                session!.parts[index].frames += Int64(count)
                session!.parts[index].sizeBytes = 44 + session!.parts[index].frames * Int64(channels * 2)
                offset += count
            }
        } catch { try? markFailure(error); throw error }
    }

    private func closePart() throws {
        guard let writer else { return }
        try writer.finalize()
        self.writer = nil
        let index = session!.parts.count - 1
        session!.parts[index].status = "finalized"
        try session!.save(manifestURL!)
    }

    func markFailure(_ error: Error) throws {
        failed = true
        session?.status = "needs_review"
        session?.issues.append(error.localizedDescription)
        if let manifestURL { try session?.save(manifestURL) }
    }

    func finalize() throws {
        defer { lease = nil }
        do {
            try closePart()
            session?.endedAt = Date()
            session?.status = failed ? "needs_review" : "finalized"
            if let manifestURL { try session?.save(manifestURL) }
        } catch { try? markFailure(error); throw error }
    }
}

/// Stable sidecar inode: atomic manifest replacement must not release the lease.
nonisolated final class SessionLease {
    private let fd: Int32
    init(_ manifest: URL) throws {
        let url = manifest.deletingLastPathComponent().appendingPathComponent(".\(manifest.lastPathComponent).lock")
        fd = Darwin.open(url.path, O_RDWR | O_CREAT | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw SessionError.invalid("Cannot open session lease") }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            Darwin.close(fd)
            throw SessionError.invalid("This session is currently being recorded or processed")
        }
    }
    deinit { Darwin.close(fd) }
}
