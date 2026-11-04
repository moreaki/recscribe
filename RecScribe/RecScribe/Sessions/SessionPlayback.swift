import AVFoundation
import Combine
import Foundation

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

        // Single-part fast path (#13): load the verified WAV directly via AVURLAsset
        // instead of building an AVMutableComposition.
        if urls.count == 1 {
            let asset = AVURLAsset(url: urls[0])
            guard try await asset.load(.isPlayable),
                  !(try await asset.loadTracks(withMediaType: .audio)).isEmpty else {
                throw SessionError.invalid("Missing audio track")
            }
            try Task.checkCancellation()
            return AVPlayerItem(asset: asset)
        }

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

@MainActor
final class SessionPlaybackCoordinator {
    private weak var activeInstance: SessionPlayback?
    private var requestToken: UInt64 = 0

    func stop() {
        activeInstance?.stop()
        requestToken &+= 1
    }

    func claim(for instance: SessionPlayback) -> UInt64 {
        if let active = activeInstance, active !== instance {
            active.stop()
        }
        requestToken &+= 1
        activeInstance = instance
        return requestToken
    }

    func owns(instance: SessionPlayback, token: UInt64) -> Bool {
        activeInstance === instance && requestToken == token
    }

    func release(instance: SessionPlayback) {
        if activeInstance === instance {
            activeInstance = nil
        }
    }
}

/// Owns selection and the one outstanding load. Late completions cannot start audio.
/// Uses event-driven AVPlayer observers, latest-wins coalesced seeking, and
/// single-active-player preemption (#13, #41).
@MainActor
final class SessionPlayback: ObservableObject {

    private nonisolated final class PlayerObserverCleanup: @unchecked Sendable {
        weak var player: AVPlayer?
        var timeToken: Any?
        var endObserver: NSObjectProtocol?
        private(set) var isTornDown = false

        init(player: AVPlayer, timeToken: Any?, endObserver: NSObjectProtocol?) {
            self.player = player
            self.timeToken = timeToken
            self.endObserver = endObserver
        }

        func tearDown() {
            guard !isTornDown else { return }
            isTornDown = true
            if let token = timeToken, let player {
                player.removeTimeObserver(token)
            }
            timeToken = nil
            player = nil
            if let endObserver {
                NotificationCenter.default.removeObserver(endObserver)
                self.endObserver = nil
            }
        }

        deinit {
            tearDown()
        }
    }

    @Published private(set) var position = 0.0
    @Published private(set) var duration = 0.0
    @Published private(set) var isPlaying = false
    @Published private(set) var player: AVPlayer?
    @Published private(set) var playing: UUID?
    @Published private(set) var loading = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var outputDevices: [AudioOutputDevice] = []
    @Published private(set) var effectiveOutput = "System output"

    let levels: PlaybackLevels
    private let hardwareObserver: AudioHardwareObserver
    private let coordinator: SessionPlaybackCoordinator
    private let build: (SessionEntry) async throws -> AVPlayerItem
    private let activate: (AVPlayer) -> Void
    private let sourceReader: @Sendable (RecordingSession.SourceTrack, RecordingSession, URL) throws -> SessionEntry
    private let asyncSourceReader: ((RecordingSession.SourceTrack, RecordingSession, URL) async throws -> SessionEntry)?
    private var task: Task<Void, Never>?
    private var generation = UUID()
    private var ownedRequestToken: UInt64 = 0
    private var recordingActive = false
    private var levelObservation: AnyCancellable?
    private var hardwareObservation: AnyCancellable?
    private var statusObservation: AnyCancellable?
    private var observerCleanup: PlayerObserverCleanup?
    private var seekInFlight = false
    private var pendingSeekTarget: Double?

    var hasAttachedPlayerObservers: Bool {
        guard let observerCleanup else { return false }
        return !observerCleanup.isTornDown
    }

    var formattedPosition: String { Self.formatTime(position) }
    var formattedDuration: String { Self.formatTime(duration) }

    nonisolated static func formatTime(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds > 0 else { return "00:00" }
        let total = Int(seconds.rounded(.down))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, secs)
        }
        return String(format: "%02d:%02d", minutes, secs)
    }

    init(
        build: ((SessionEntry) async throws -> AVPlayerItem)? = nil,
        activate: ((AVPlayer) -> Void)? = nil,
        levels: PlaybackLevels? = nil,
        hardwareObserver: AudioHardwareObserver = .shared,
        coordinator: SessionPlaybackCoordinator? = nil,
        sourceReader: @escaping @Sendable (RecordingSession.SourceTrack, RecordingSession, URL) throws -> SessionEntry = LinkedSourceSessions.read,
        asyncSourceReader: ((RecordingSession.SourceTrack, RecordingSession, URL) async throws -> SessionEntry)? = nil
    ) {
        self.build = build ?? SessionPlaybackBuilder.item
        self.activate = activate ?? { $0.play() }
        self.levels = levels ?? PlaybackLevels()
        self.hardwareObserver = hardwareObserver
        self.coordinator = coordinator ?? SessionPlaybackCoordinator()
        self.sourceReader = sourceReader
        self.asyncSourceReader = asyncSourceReader
        levelObservation = self.levels.$value.dropFirst().sink { [weak self] _ in
            Task { @MainActor [weak self] in self?.refreshOutput() }
        }
        hardwareObservation = hardwareObserver.$revision.dropFirst().sink { [weak self] _ in
            Task { @MainActor [weak self] in self?.refreshOutput() }
        }
    }

    func togglePlayback() {
        guard let player else { return }
        if player.rate > 0 || player.timeControlStatus == .playing {
            player.pause()
            isPlaying = false
        } else {
            _ = claimGlobalPlayback()
            if duration > 0, position >= duration {
                seek(to: 0)
            }
            player.play()
            isPlaying = player.rate > 0 || player.timeControlStatus == .playing
        }
    }

    /// Latest-wins coalesced seek (#13). Rapid scrub updates immediately move `position`
    /// while at most one `AVPlayer.seek` runs in flight; any newer target queued during
    /// an active seek runs as soon as the current seek completes.
    func seek(to seconds: Double) {
        guard seconds.isFinite else { return }
        let upperBound = duration > 0 ? duration : max(0, seconds)
        let target = min(upperBound, max(0, seconds))
        position = target
        guard player != nil else { return }
        pendingSeekTarget = target
        drainPendingSeekIfNeeded()
    }

    /// Skip backward or forward by `delta` seconds (e.g. `-15` or `+15`) (#13).
    func skip(by delta: Double) {
        guard delta.isFinite else { return }
        seek(to: position + delta)
    }

    private func drainPendingSeekIfNeeded() {
        guard !seekInFlight, let player, let target = pendingSeekTarget else { return }
        pendingSeekTarget = nil
        seekInFlight = true
        let id = generation
        let cmTarget = CMTime(seconds: target, preferredTimescale: 48_000)
        player.seek(to: cmTarget, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.generation == id else { return }
                self.seekInFlight = false
                if self.pendingSeekTarget != nil {
                    self.drainPendingSeekIfNeeded()
                }
            }
        }
    }

    func refreshOutput() {
        outputDevices = hardwareObserver.outputDevices
        let selected = levels.value.outputUID
        let actual = outputDevices.first { $0.uid == (selected ?? hardwareObserver.defaultOutputUID) }
        effectiveOutput = actual?.name ?? "System output"
        if let selected, !outputDevices.contains(where: { $0.uid == selected }) {
            effectiveOutput = "Selected output unavailable · using system output"
        }
        if let player { levels.apply(to: player, devices: outputDevices) }
    }

    func play(_ entry: SessionEntry) {
        let initialDuration = entry.session.duration
        load(id: entry.session.id, initialDuration: initialDuration) { [build] in
            try await build(entry)
        }
    }

    func playFile(_ url: URL) {
        load(id: UUID(), initialDuration: nil) {
            guard url.isFileURL else { throw SessionError.invalid("Playback requires a local audio file") }
            let asset = AVURLAsset(url: url)
            guard try await asset.load(.isPlayable), !(try await asset.loadTracks(withMediaType: .audio)).isEmpty else {
                throw SessionError.invalid("This file has no playable audio")
            }
            return AVPlayerItem(asset: asset)
        }
    }

    @discardableResult
    private func claimGlobalPlayback() -> UInt64 {
        let token = coordinator.claim(for: self)
        ownedRequestToken = token
        return token
    }

    private func ownsPlayback(id: UUID, requestToken: UInt64) -> Bool {
        !recordingActive
            && generation == id
            && ownedRequestToken == requestToken
            && coordinator.owns(instance: self, token: requestToken)
    }

    private func load(
        id selection: UUID,
        initialDuration: Double?,
        operation: @escaping @MainActor () async throws -> AVPlayerItem
    ) {
        stop()
        guard !recordingActive else { return }
        let requestToken = claimGlobalPlayback()
        let id = generation
        loading = true
        errorMessage = nil
        task = Task { [weak self] in
            do {
                let item = try await operation()
                let assetDuration = try? await item.asset.load(.duration).seconds
                guard !Task.isCancelled, let self, self.ownsPlayback(id: id, requestToken: requestToken) else { return }
                self.finishLoadingPlayer(
                    item: item,
                    selection: selection,
                    initialDuration: initialDuration,
                    assetDuration: assetDuration,
                    id: id
                )
            } catch is CancellationError { }
            catch {
                if let self, self.generation == id {
                    self.errorMessage = error.localizedDescription
                }
            }
            if let self, self.generation == id {
                self.loading = false
                self.task = nil
            }
        }
    }

    private func finishLoadingPlayer(
        item: AVPlayerItem,
        selection: UUID,
        initialDuration: Double?,
        assetDuration: Double?,
        id: UUID
    ) {
        let player = AVPlayer(playerItem: item)
        levels.apply(to: player)
        self.player = player
        let resolvedDuration = initialDuration ?? assetDuration ?? item.duration.seconds
        duration = resolvedDuration.isFinite ? max(0, resolvedDuration) : 0
        position = 0
        refreshOutput()
        attachPlayerObservers(player: player, item: item, id: id)
        playing = selection
        activate(player)
        isPlaying = player.rate > 0 || player.timeControlStatus == .playing
    }

    private func attachPlayerObservers(player: AVPlayer, item: AVPlayerItem, id: UUID) {
        detachPlayerObservers()
        let timeToken = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.1, preferredTimescale: 600),
            queue: .main
        ) { [weak self] time in
            MainActor.assumeIsolated {
                guard let self, self.generation == id else { return }
                if !self.seekInFlight && self.pendingSeekTarget == nil {
                    let seconds = time.seconds
                    if seconds.isFinite {
                        self.position = max(0, seconds)
                    }
                }
                if let itemDuration = self.player?.currentItem?.duration.seconds,
                   itemDuration.isFinite, itemDuration > 0 {
                    self.duration = itemDuration
                }
                self.isPlaying = (self.player?.rate ?? 0) > 0 || self.player?.timeControlStatus == .playing
            }
        }

        statusObservation = player.publisher(for: \.timeControlStatus)
            .receive(on: RunLoop.main)
            .sink { [weak self] status in
                guard let self, self.generation == id else { return }
                self.isPlaying = status == .playing || (self.player?.rate ?? 0) > 0
            }

        let endToken = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.generation == id else { return }
                self.isPlaying = false
                if self.duration > 0 {
                    self.position = self.duration
                }
            }
        }

        observerCleanup = PlayerObserverCleanup(
            player: player,
            timeToken: timeToken,
            endObserver: endToken
        )
    }

    private func detachPlayerObservers() {
        observerCleanup?.tearDown()
        observerCleanup = nil
        statusObservation?.cancel()
        statusObservation = nil
        seekInFlight = false
        pendingSeekTarget = nil
    }

    func playSource(_ source: RecordingSession.SourceTrack, parent: SessionEntry) {
        stop()
        guard !recordingActive else { return }
        let requestToken = claimGlobalPlayback()
        let id = generation
        let reader = sourceReader
        let asyncReader = asyncSourceReader
        loading = true
        errorMessage = nil
        task = Task { [weak self] in
            do {
                let entry: SessionEntry
                if let asyncReader {
                    entry = try await asyncReader(source, parent.session, parent.id)
                } else {
                    let readTask = Task.detached(priority: .utility) {
                        try reader(source, parent.session, parent.id)
                    }
                    entry = try await withTaskCancellationHandler {
                        try await readTask.value
                    } onCancel: {
                        readTask.cancel()
                    }
                }
                guard !Task.isCancelled, let self, self.ownsPlayback(id: id, requestToken: requestToken) else { return }
                let item = try await self.build(entry)
                let assetDuration = try? await item.asset.load(.duration).seconds
                guard !Task.isCancelled, self.ownsPlayback(id: id, requestToken: requestToken) else { return }
                self.finishLoadingPlayer(
                    item: item,
                    selection: entry.session.id,
                    initialDuration: entry.session.duration,
                    assetDuration: assetDuration,
                    id: id
                )
            } catch is CancellationError { }
            catch {
                if let self, self.generation == id {
                    self.errorMessage = error.localizedDescription
                }
            }
            if let self, self.generation == id {
                self.loading = false
                self.task = nil
            }
        }
    }

    func setRecording(_ active: Bool) {
        recordingActive = active
        if active { stop() }
    }

    func stop() {
        generation = UUID()
        ownedRequestToken = 0
        task?.cancel()
        task = nil
        detachPlayerObservers()
        player?.pause()
        player = nil
        playing = nil
        loading = false
        position = 0
        duration = 0
        isPlaying = false
        coordinator.release(instance: self)
    }

    deinit {
        task?.cancel()
        observerCleanup?.tearDown()
    }
}

nonisolated struct ListeningLevel: Codable, Equatable, Sendable {
    var volume: Float = 1
    var muted = false
    var outputUID: String?
    var valid: Bool { volume.isFinite && (0...1).contains(volume) && (outputUID?.count ?? 0) <= 1024 }
}

/// Shared by every app player; output controls never enter the capture pipeline.
@MainActor
final class PlaybackLevels: ObservableObject {
    @Published private(set) var value: ListeningLevel
    private let defaults: UserDefaults
    private let key: String
    init(defaults: UserDefaults = .standard, key: String = "audio.playbackLevels.v1", initialVolume: Float = 1) {
        self.defaults = defaults
        self.key = key
        if let data = defaults.data(forKey: key),
           let saved = try? JSONDecoder().decode(ListeningLevel.self, from: data), saved.valid {
            value = saved
        } else {
            value = .init(volume: initialVolume)
        }
    }
    func set(_ newValue: ListeningLevel) {
        guard newValue.valid else { return }
        value = newValue
        if let data = try? JSONEncoder().encode(value) { defaults.set(data, forKey: key) }
    }
    func apply(to player: AVPlayer, devices: [AudioOutputDevice] = AudioDeviceControls.outputs()) {
        player.volume = value.volume
        player.isMuted = value.muted
        player.audioOutputDeviceUniqueID = devices.contains { $0.uid == value.outputUID } ? value.outputUID : nil
    }
}
