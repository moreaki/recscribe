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
    @Published private(set) var position = 0.0
    @Published private(set) var duration = 0.0
    @Published private(set) var isPlaying = false
    func togglePlayback() {
        guard let player else { return }
        if player.rate > 0 { player.pause() }
        else {
            if duration > 0, position >= duration { player.seek(to: .zero) }
            player.play()
        }
        isPlaying = player.rate > 0
    }
    func seek(to seconds: Double) {
        guard seconds.isFinite, duration > 0 else { return }
        let target = min(duration, max(0, seconds))
        player?.seek(to: CMTime(seconds: target, preferredTimescale: 48_000), toleranceBefore: .zero, toleranceAfter: .zero)
        position = target
    }
    @Published private(set) var player: AVPlayer?
    @Published private(set) var playing: UUID?
    @Published private(set) var loading = false
    @Published private(set) var errorMessage: String?
    private var task: Task<Void, Never>?
    private var generation = UUID()
    private let build: (SessionEntry) async throws -> AVPlayerItem
    private let activate: (AVPlayer) -> Void
    private var recordingActive = false
    let levels: PlaybackLevels
    private var levelObservation: AnyCancellable?
    private var routeTask: Task<Void, Never>?
    @Published private(set) var outputDevices: [AudioOutputDevice] = []
    @Published private(set) var effectiveOutput = "System output"
    func refreshOutput() {
        outputDevices = AudioDeviceControls.outputs()
        let selected = levels.value.outputUID
        let actual = outputDevices.first { $0.uid == (selected ?? AudioDeviceControls.defaultOutputUID()) }
        effectiveOutput = actual?.name ?? "System output"
        if let selected, !outputDevices.contains(where: { $0.uid == selected }) {
            effectiveOutput = "Selected output unavailable · using system output"
        }
        if let player { levels.apply(to: player, devices: outputDevices) }
    }

    init(build: @escaping (SessionEntry) async throws -> AVPlayerItem = SessionPlaybackBuilder.item,
         activate: @escaping (AVPlayer) -> Void = { $0.play() }, levels: PlaybackLevels? = nil) {
        self.build = build
        self.activate = activate
        self.levels = levels ?? .shared
        levelObservation = self.levels.$value.dropFirst().sink { [weak self] _ in
            Task { @MainActor [weak self] in self?.refreshOutput() }
        }
    }
    func play(_ entry: SessionEntry) {
        load(id: entry.session.id) { [build] in try await build(entry) }
    }
    func playFile(_ url: URL) {
        load(id: UUID()) {
            guard url.isFileURL else { throw SessionError.invalid("Playback requires a local audio file") }
            let asset = AVURLAsset(url: url)
            guard try await asset.load(.isPlayable), !(try await asset.loadTracks(withMediaType: .audio)).isEmpty else {
                throw SessionError.invalid("This file has no playable audio")
            }
            return AVPlayerItem(asset: asset)
        }
    }
    private func load(id selection: UUID, operation: @escaping @MainActor () async throws -> AVPlayerItem) {
        stop()
        guard !recordingActive else { return }
        let id = generation
        loading = true
        errorMessage = nil
        task = Task { [weak self] in
            do {
                let item = try await operation()
                guard !Task.isCancelled, let self, generation == id else { return }
                let player = AVPlayer(playerItem: item)
                self.levels.apply(to: player)
                self.player = player
                self.refreshOutput()
                self.routeTask = Task { [weak self] in
                    var ticks = 0
                    while !Task.isCancelled {
                        try? await Task.sleep(for: .milliseconds(200))
                        guard !Task.isCancelled, let self else { return }
                        let seconds = self.player?.currentTime().seconds ?? 0
                        let length = self.player?.currentItem?.duration.seconds ?? 0
                        position = seconds.isFinite ? max(0, seconds) : 0
                        duration = length.isFinite ? max(0, length) : 0
                        isPlaying = (self.player?.rate ?? 0) > 0
                        ticks += 1
                        if ticks % 10 == 0 { refreshOutput() }
                    }
                }
                playing = selection
                activate(player)
            } catch is CancellationError { }
            catch { if self?.generation == id { self?.errorMessage = error.localizedDescription } }
            if self?.generation == id { self?.loading = false; self?.task = nil }
        }
    }
    func playSource(_ source: RecordingSession.SourceTrack, parent: SessionEntry) {
        stop()
        guard !recordingActive else { return }
        let id = generation
        loading = true
        task = Task { [weak self] in
            do {
                let entry = try await Task.detached(priority: .utility) {
                    try LinkedSourceSessions.read(source, parent: parent.session, at: parent.id)
                }.value
                guard !Task.isCancelled, let self, generation == id else { return }
                play(entry)
            } catch { if self?.generation == id { self?.loading = false; self?.errorMessage = error.localizedDescription } }
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
        routeTask?.cancel(); routeTask = nil
        player?.pause()
        player = nil
        playing = nil
        loading = false
        position = 0; duration = 0; isPlaying = false
    }
    deinit { task?.cancel(); routeTask?.cancel() }
}
