import AVFoundation
import CryptoKit
import Darwin
import Foundation

nonisolated enum ArchiveFormat: String, Codable, CaseIterable, Sendable {
    case wav, flac, opus, m4a
}

nonisolated struct RecordingStorageOptions: Codable, Equatable, Sendable {
    static let hardCap: Int64 = 3_758_096_384 // 3.5 GiB including the WAV header
    static let minimumPartBytes = Int64(PCM16WAV.headerBytes + 2 * PCM16WAV.sampleBytes)
    static let bytesPerMiB: Int64 = 1 << 20
    static let bitrateRange = 32...320
    static let flacCompressionRange = 0...12
    static let bitrateChoices = [32, 64, 96, 128, 192, 256, 320]
    var maximumPartBytes: Int64 = hardCap
    var archiveFormat: ArchiveFormat = .wav
    var bitrateKbps = 128
    var flacCompression = 5

    func validated() throws -> Self {
        guard (Self.minimumPartBytes...Self.hardCap).contains(maximumPartBytes),
              Self.bitrateRange.contains(bitrateKbps), Self.flacCompressionRange.contains(flacCompression) else {
            throw SessionError.invalid("Invalid recording storage options")
        }
        return self
    }

    static func partBytes(mebibytes: Double) throws -> Int64 {
        let bytes = mebibytes * Double(bytesPerMiB)
        guard bytes.isFinite, bytes >= Double(minimumPartBytes), bytes <= Double(hardCap) else {
            throw SessionError.invalid("WAV part size must be finite and between \(minimumPartBytes) bytes and \(hardCap / bytesPerMiB) MiB")
        }
        return Int64(bytes.rounded(.down))
    }

    init(maximumPartBytes: Int64 = hardCap, archiveFormat: ArchiveFormat = .wav, bitrateKbps: Int = 128, flacCompression: Int = 5) {
        self.maximumPartBytes = maximumPartBytes
        self.archiveFormat = archiveFormat
        self.bitrateKbps = bitrateKbps
        self.flacCompression = flacCompression
    }

    enum CodingKeys: String, CodingKey { case maximumPartBytes, archiveFormat, bitrateKbps, flacCompression }
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // Missing keys are migrations. Invalid manifest values still fail validated().
        maximumPartBytes = try container.decodeIfPresent(Int64.self, forKey: .maximumPartBytes) ?? Self.hardCap
        archiveFormat = try container.decodeIfPresent(ArchiveFormat.self, forKey: .archiveFormat) ?? .wav
        bitrateKbps = try container.decodeIfPresent(Int.self, forKey: .bitrateKbps) ?? 128
        flacCompression = try container.decodeIfPresent(Int.self, forKey: .flacCompression) ?? 5
    }
}

nonisolated enum SessionError: Error, LocalizedError {
    case invalid(String)
    case diskFull
    case noAudio
    var errorDescription: String? {
        switch self {
        case .invalid(let message): message
        case .noAudio: "No audio data was captured. Check the selected source and permissions, then record again."
        case .diskFull: "Not enough free space; existing recording parts are preserved"
        }
    }
}

nonisolated struct RecordingSession: Codable, Identifiable, Sendable {
    static let currentSchemaVersion = 3
    static let singleSourceSchemaVersion = 1
    static let maximumManifestBytes = 16 * 1_024 * 1_024
    var schemaVersion = singleSourceSchemaVersion
    var id = UUID()
    var startedAt = Date()
    var endedAt: Date?
    var status = SessionStatus.recording
    var sampleRate: Int
    var channels: Int
    var bitDepth = PCM16WAV.bitDepth
    var channelMap: [String]
    var options: RecordingStorageOptions
    var parts: [Part] = []
    var issues: [String] = []
    var artifacts: [Artifact] = []
    /// v2 roots retain linked, synchronized source sessions alongside the derived mix.
    var sourceTracks: [SourceTrack]?
    var parentSessionID: UUID?
    var captureEpoch: Double?
    var gainAutomation: [GainEvent]?
    var gainScope: String?
    var gainTracks: [CaptureTrack]?
    var sourceIdentity: SourceTrack?
    struct SourceTrack: Codable, Sendable {
        var role: CaptureTrack
        var name: String
        var deviceUID: String?
        var bundleID: String?
        var manifestPath: String?
        var nativeSampleRate: Double?
        var channels: Int?
        var mixChannels: [Int] = []
        var receivedFrames: Int64 = 0
        var gapFrames: Int64 = 0
        var channelRoutes: [InputChannelRoute]?
        var failure: String?
        var channelLabels: [String]?
    }


    struct Part: Codable, Sendable {
        var path: String
        var startSample: Int64
        var frames: Int64 = 0
        var sizeBytes = Int64(PCM16WAV.headerBytes)
        var sha256: String?
        var status = PartStatus.opening
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
        let input = try FileHandle(forReadingFrom: url)
        defer { try? input.close() }
        let bytes = try input.read(upToCount: maximumManifestBytes + 1) ?? Data()
        guard bytes.count <= maximumManifestBytes else { throw SessionError.invalid("Session manifest is too large") }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(Self.self, from: bytes).validated(beside: url)
    }

    func validated(beside url: URL) throws -> Self {
        let session = self
        guard (Self.singleSourceSchemaVersion...Self.currentSchemaVersion).contains(session.schemaVersion), (1...32).contains(session.channels),
              (1...384000).contains(session.sampleRate), session.bitDepth == PCM16WAV.bitDepth,
              session.channelMap.count == session.channels else { throw SessionError.invalid("Unsupported session schema or audio format") }
        guard schemaVersion < 2 || sourceTracks != nil else { throw SessionError.invalid("Version 2 requires a source track group") }
        if let epoch = captureEpoch, !epoch.isFinite || epoch < 0 { throw SessionError.invalid("Invalid capture clock") }
        if let tracks = sourceTracks {
            guard (2...Self.currentSchemaVersion).contains(schemaVersion), captureEpoch != nil,
                  (1...CaptureTrack.maximumSources).contains(tracks.count), schemaVersion != 2 || tracks.count == 2,
                  Set(tracks.map(\.role)).count == tracks.count, tracks.allSatisfy({ $0.role.valid }), parentSessionID == nil else { throw SessionError.invalid("Invalid source track group") }
            var references = Set<String>()
            for track in tracks {
                guard track.receivedFrames >= 0, track.gapFrames >= 0 else { throw SessionError.invalid("Invalid source frame counts") }
                if let channels = track.channels {
                    guard (1...32).contains(channels), track.mixChannels.allSatisfy({ (0..<channels).contains($0) }) else {
                        throw SessionError.invalid("Invalid source channel map")
                    }
                }
                if let rate = track.nativeSampleRate, !rate.isFinite || !(1...384000).contains(rate) { throw SessionError.invalid("Invalid source rate") }
                if let routes = track.channelRoutes {
                    guard routes.count <= 32, Set(routes.map(\.channel)).count == routes.count,
                          routes.allSatisfy({ (0..<(track.channels ?? 32)).contains($0.channel) }) else { throw SessionError.invalid("Invalid source channel routing") }
                }
                if let path = track.manifestPath {
                    let child = try Self.safeURL(path, beside: url)
                    guard child != url, path.hasSuffix(".recscribe.json"), references.insert(path).inserted else { throw SessionError.invalid("Invalid source manifest reference") }
                }
            }
        }
        if let events = gainAutomation {
            guard !events.isEmpty, events.count <= 2048, events.allSatisfy({ $0.valid && $0.to.count == events.first?.to.count }), events.first?.frame == 0,
                  zip(events, events.dropFirst()).allSatisfy({ $0.frame <= $1.frame }),
                  ["derived_mix", "processed_single_source"].contains(gainScope ?? "") else {
                throw SessionError.invalid("Invalid recording gain automation")
            }
        }
        if let identity = sourceIdentity {
            guard parentSessionID != nil, sourceTracks == nil, identity.role.valid,
                  identity.channels == channels, identity.manifestPath == nil else { throw SessionError.invalid("Invalid source identity") }
        }
        if let gainTracks {
            guard (1...CaptureTrack.maximumSources).contains(gainTracks.count), Set(gainTracks).count == gainTracks.count,
                  gainTracks.allSatisfy(\.valid), gainAutomation?.first?.to.count == gainTracks.count * 32 + 1,
                  sourceTracks?.map(\.role) == gainTracks else { throw SessionError.invalid("Invalid gain source mapping") }
        }
        _ = try session.options.validated()
        var end: Int64 = 0
        var paths = Set<String>()
        for part in session.parts {
            _ = try Self.safeURL(part.path, beside: url)
            guard paths.insert(part.path).inserted, part.startSample >= end,
                  part.frames >= 0, part.frames <= Int64.max - part.startSample,
                  part.frames <= (Self.maximumSafePartBytes - Int64(PCM16WAV.headerBytes)) / Int64(session.channels * PCM16WAV.sampleBytes) else {
                throw SessionError.invalid("Invalid or overlapping session parts")
            }
            end = part.startSample + part.frames
        }
        for artifact in session.artifacts { _ = try Self.safeURL(artifact.path, beside: url) }
        return session
    }
    private static let maximumSafePartBytes = Int64(PCM16WAV.maximumPayload) + Int64(PCM16WAV.headerBytes)

    /// No archive may promote an incomplete or review-marked source session.
    func verifiedStatus(archiveComplete: Bool) -> SessionStatus {
        guard issues.isEmpty, !parts.isEmpty, parts.allSatisfy({ $0.status == .verified }) else { return .needsReview }
        return archiveComplete ? .completed : .verified
    }

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
              options.maximumPartBytes >= Int64(PCM16WAV.headerBytes) + Int64(channels * PCM16WAV.sampleBytes) else { throw SessionError.invalid("Invalid format or part cap smaller than one audio frame") }
        try checkSpace(url)
        let base = try RecordingSession.reserve(url)
        audioURL = base
        manifestURL = RecordingSession.manifestURL(for: base)
        lease = try SessionLease(manifestURL!)
        session = RecordingSession(sampleRate: Int(sampleRate), channels: channels,
                                   channelMap: (0..<channels).map { "channel-\($0)" }, options: options)
        do { try openPart() } catch { try? markFailure(error); throw error }
    }

    var sessionID: UUID? { session?.id }
    var startedAt: Date? { session?.startedAt }
    var hasIssues: Bool { session?.issues.isEmpty == false }
    var frameCount: Int64 { session?.totalFrames ?? 0 }
    func setGainAutomation(_ events: [GainEvent], scope: String, tracks: [CaptureTrack]? = nil) throws {
        session?.gainTracks = tracks
        session?.gainAutomation = events
        session?.gainScope = scope
        if let manifestURL { try session?.save(manifestURL) }
    }
    func setSourceTracks(_ tracks: [RecordingSession.SourceTrack], epoch: Double) throws {
        session?.schemaVersion = tracks.count == 2 && tracks.allSatisfy({ CaptureTrack.legacyPair.contains($0.role) }) ? 2 : RecordingSession.currentSchemaVersion
        session?.sourceTracks = tracks
        session?.captureEpoch = epoch
        if let manifestURL { try session?.save(manifestURL) }
    }
    func setParent(_ id: UUID, epoch: Double, startedAt: Date? = nil, source: RecordingSession.SourceTrack? = nil) throws {
        session?.sourceIdentity = source
        if let labels = source?.channelLabels, labels.count == session?.channels { session?.channelMap = labels }
        if let startedAt {
            session?.startedAt = startedAt
            for index in session?.parts.indices ?? 0..<0 {
                let offset = Double(session!.parts[index].startSample) / Double(session!.sampleRate)
                session?.parts[index].startedAt = startedAt.addingTimeInterval(offset)
            }
        }
        session?.parentSessionID = id
        session?.captureEpoch = epoch
        if let manifestURL { try session?.save(manifestURL) }
    }
    func addIssue(_ message: String) throws {
        guard session?.issues.contains(message) == false else { return }
        session?.issues.append(message)
        if let manifestURL { try session?.save(manifestURL) }
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
        self.session?.parts[index].status = .recording
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
                let capacity = (options.maximumPartBytes - Int64(PCM16WAV.headerBytes)) / Int64(channels * PCM16WAV.sampleBytes)
                let remaining = capacity - session!.parts.last!.frames
                if remaining == 0 { try closePart(); try openPart(); continue }
                let count = min(Int(remaining), Int(buffer.frameLength) - offset)
                try writer?.writeFrames(buffer, offset: offset, count: count)
                let index = session!.parts.count - 1
                session!.parts[index].frames += Int64(count)
                session!.parts[index].sizeBytes = Int64(PCM16WAV.headerBytes) + session!.parts[index].frames * Int64(channels * PCM16WAV.sampleBytes)
                offset += count
            }
        } catch { try? markFailure(error); throw error }
    }

    private func closePart() throws {
        guard let writer else { return }
        try writer.finalize()
        self.writer = nil
        let index = session!.parts.count - 1
        session!.parts[index].status = .finalized
        try session!.save(manifestURL!)
    }

    func markFailure(_ error: Error) throws {
        failed = true
        session?.status = .needsReview
        session?.issues.append(error.localizedDescription)
        if let manifestURL { try session?.save(manifestURL) }
    }

    func finalize() throws {
        defer { lease = nil }
        do {
            try closePart()
            if !failed, session?.totalFrames == 0 { throw SessionError.noAudio }
            session?.endedAt = Date()
            let needsReview = failed || session?.issues.isEmpty == false
            session?.status = needsReview ? .needsReview : .finalized
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
