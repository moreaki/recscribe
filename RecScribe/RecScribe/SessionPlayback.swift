import AVFoundation
import Combine

@MainActor
enum SessionPlaybackBuilder {
    static func item(for entry: SessionEntry) async throws -> AVPlayerItem {
        // Validate on a utility worker before asking AVFoundation to load tracks.
        let validation = Task.detached(priority: .utility) {
            _ = try entry.session.validated(beside: entry.id)
            guard !entry.session.parts.isEmpty else { throw SessionError.invalid("Session contains no parts") }
            var end: Int64 = 0
            return try entry.session.parts.map { part in
                try Task.checkCancellation()
                guard part.status == .verified, part.startSample == end else {
                    throw SessionError.invalid("Verify all parts and resolve timeline gaps before playback")
                }
                let url = try RecordingSession.safeURL(part.path, beside: entry.id)
                let header = try PCM16WAV.read(url)
                let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize
                guard header.sampleRate == entry.session.sampleRate, header.channels == entry.session.channels,
                      header.frames == part.frames, size.map(UInt64.init) == header.fileBytes else {
                    throw SessionError.invalid("Part length or format changed; verify it again")
                }
                end = part.startSample + part.frames
                return url
            }
        }
        let urls = try await withTaskCancellationHandler {
            try await validation.value
        } onCancel: { validation.cancel() }
        try Task.checkCancellation()
        let composition = AVMutableComposition()
        guard let track = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw SessionError.invalid("Could not create playback track")
        }
        let rate = Int32(entry.session.sampleRate)
        for (part, url) in zip(entry.session.parts, urls) {
            try Task.checkCancellation()
            let asset = AVURLAsset(url: url)
            guard let source = try await asset.loadTracks(withMediaType: .audio).first else {
                throw SessionError.invalid("Missing audio track")
            }
            try Task.checkCancellation()
            try track.insertTimeRange(CMTimeRange(start: .zero, duration: CMTime(value: part.frames, timescale: rate)),
                                      of: source, at: CMTime(value: part.startSample, timescale: rate))
        }
        try Task.checkCancellation()
        return AVPlayerItem(asset: composition)
    }
}

/// Owns selection and the one outstanding load. Late completions cannot start audio.
@MainActor
final class SessionPlayback: ObservableObject {
    @Published private(set) var player: AVPlayer?
    @Published private(set) var playing: UUID?
    @Published private(set) var loading = false
    @Published private(set) var errorMessage: String?
    private var task: Task<Void, Never>?
    private var generation = UUID()
    private let build: (SessionEntry) async throws -> AVPlayerItem
    private let activate: (AVPlayer) -> Void
    private var recordingActive = false

    init(build: @escaping (SessionEntry) async throws -> AVPlayerItem = SessionPlaybackBuilder.item,
         activate: @escaping (AVPlayer) -> Void = { $0.play() }) {
        self.build = build
        self.activate = activate
    }
    func play(_ entry: SessionEntry) {
        stop()
        guard !recordingActive else { return }
        let id = generation, build = build
        loading = true
        errorMessage = nil
        task = Task { [weak self] in
            do {
                let item = try await build(entry)
                guard !Task.isCancelled, let self, generation == id else { return }
                let player = AVPlayer(playerItem: item)
                self.player = player
                playing = entry.session.id
                activate(player)
            } catch is CancellationError { }
            catch { if self?.generation == id { self?.errorMessage = error.localizedDescription } }
            if self?.generation == id { self?.loading = false; self?.task = nil }
        }
    }
    func setRecording(_ active: Bool) {
        recordingActive = active
        if active { stop() }
    }
    func stop() {
        generation = UUID()
        task?.cancel()
        task = nil
        player?.pause()
        player = nil
        playing = nil
        loading = false
    }
    deinit { task?.cancel() }
}
