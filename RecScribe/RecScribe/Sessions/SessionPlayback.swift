import Observation
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
@Observable final class SessionPlayback {

    private nonisolated final class PlayerObserverCleanup: @unchecked Sendable {
        weak var player: AVPlayer?
        var timeToken: Any?
        var notificationObservers: [NSObjectProtocol]
        private(set) var isTornDown = false

        init(player: AVPlayer, timeToken: Any?, notificationObservers: [NSObjectProtocol]) {
            self.player = player
            self.timeToken = timeToken
            self.notificationObservers = notificationObservers
        }

        func tearDown() {
            guard !isTornDown else { return }
            isTornDown = true
            if let token = timeToken, let player {
                player.removeTimeObserver(token)
            }
            // Detach the media as well as pausing. A retained old AVPlayer can
            // acknowledge queued play/pause commands asynchronously, especially
            // during rapid source changes; it must have no source left to play.
            player?.pause()
            player?.replaceCurrentItem(with: nil)
            timeToken = nil
            player = nil
            for observer in notificationObservers { NotificationCenter.default.removeObserver(observer) }
            notificationObservers = []
        }

        deinit {
            tearDown()
        }
    }

    private(set) var phase = PlaybackPhase.idle
    private(set) var sourceName: String?
    private(set) var isScrubbing = false
    private var scrubWantsPlayback = false
    private var resumeAfterSeek: Bool?
    private(set) var position = 0.0
    private(set) var duration = 0.0
    private(set) var isPlaying = false
    private(set) var player: AVPlayer?
    private(set) var playing: UUID?
    private(set) var loading = false
    private(set) var errorMessage: String?
    private(set) var outputDevices: [AudioOutputDevice] = []
    private(set) var effectiveOutput = "System output"

    let levels: PlaybackLevels
    let hardwareObserver: AudioHardwareObserver
    private let coordinator: SessionPlaybackCoordinator
    private let build: (SessionEntry) async throws -> AVPlayerItem
    private let activate: (AVPlayer) -> Void
    private let seekPlayer: (AVPlayer, CMTime, @escaping @Sendable (Bool) -> Void) -> Void
    private let sourceReader: @Sendable (RecordingSession.SourceTrack, RecordingSession, URL) throws -> SessionEntry
    private let asyncSourceReader: ((RecordingSession.SourceTrack, RecordingSession, URL) async throws -> SessionEntry)?
    @ObservationIgnored private var task: Task<Void, Never>?
    private var generation = UUID()
    private var ownedRequestToken: UInt64 = 0
    private var recordingActive = false
    @ObservationIgnored private var levelObservation: ObservationSubscription?
    @ObservationIgnored private var hardwareObservation: ObservationSubscription?
    private var playerObservations: [AnyCancellable] = []
    @ObservationIgnored private var observerCleanup: PlayerObserverCleanup?
    private var seekInFlight = false
    private var pendingSeekTarget: Double?

    var hasAttachedPlayerObservers: Bool {
        guard let observerCleanup else { return false }
        return !observerCleanup.isTornDown
    }

    var canSeek: Bool { player != nil && duration > 0 && phase != .failed }
    var hasPresentation: Bool { loading || player != nil || errorMessage != nil }
    var positionAccessibilityValue: String {
        "\(PlaybackPolicy.spokenTime(position)) of \(PlaybackPolicy.spokenTime(duration))"
    }
    var formattedPosition: String { Self.formatTime(position) }
    var formattedDuration: String { Self.formatTime(duration) }

    nonisolated static func formatTime(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds > 0, seconds < Double(Int.max) else { return "00:00" }
        let total = Int(seconds.rounded(.down))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        if hours > 0 {
            return "\(hours):" + String(format: "%02d:%02d", minutes, secs)
        }
        return String(format: "%02d:%02d", minutes, secs)
    }

    init(
        build: ((SessionEntry) async throws -> AVPlayerItem)? = nil,
        activate: ((AVPlayer) -> Void)? = nil,
        levels: PlaybackLevels? = nil,
        hardwareObserver: AudioHardwareObserver = .shared,
        coordinator: SessionPlaybackCoordinator? = nil,
        seekPlayer: ((AVPlayer, CMTime, @escaping @Sendable (Bool) -> Void) -> Void)? = nil,
        sourceReader: @escaping @Sendable (RecordingSession.SourceTrack, RecordingSession, URL) throws -> SessionEntry = LinkedSourceSessions.read,
        asyncSourceReader: ((RecordingSession.SourceTrack, RecordingSession, URL) async throws -> SessionEntry)? = nil
    ) {
        self.build = build ?? SessionPlaybackBuilder.item
        self.activate = activate ?? { $0.play() }
        self.seekPlayer = seekPlayer ?? { player, target, completion in
            player.seek(to: target, toleranceBefore: PlaybackPolicy.seekTolerance, toleranceAfter: PlaybackPolicy.seekTolerance, completionHandler: completion)
        }
        self.levels = levels ?? PlaybackLevels()
        self.hardwareObserver = hardwareObserver
        self.coordinator = coordinator ?? SessionPlaybackCoordinator()
        self.sourceReader = sourceReader
        self.asyncSourceReader = asyncSourceReader
        levelObservation = ObservationSubscription(read: { [levels = self.levels] in levels.value }) { [weak self] _ in self?.refreshOutput() }
        hardwareObservation = ObservationSubscription(read: { hardwareObserver.revision }) { [weak self] _ in self?.refreshOutput() }
    }

    func togglePlayback() {
        guard let player, phase != .failed else { return }
        if isScrubbing {
            scrubWantsPlayback.toggle(); isPlaying = scrubWantsPlayback
        } else if let desired = resumeAfterSeek {
            resumeAfterSeek = !desired; isPlaying = !desired
        } else if player.rate > 0 || player.timeControlStatus == .playing {
            player.pause()
            isPlaying = false; phase = .paused
        } else {
            _ = claimGlobalPlayback()
            if duration > 0, position >= duration { seek(to: 0) }
            player.play()
            refreshTransportState()
        }
    }

    /// Pause actual output during dragging, retaining the user's play/pause intent.
    /// Resume only after the final coalesced seek, never from a stale generation.
    func setScrubbing(_ editing: Bool) {
        guard let player, phase != .failed, editing != isScrubbing else { return }
        if editing {
            scrubWantsPlayback = resumeAfterSeek ?? isPlaying
            resumeAfterSeek = nil
            isScrubbing = true
            player.pause()
            isPlaying = scrubWantsPlayback; phase = .scrubbing
        } else {
            isScrubbing = false
            resumeAfterSeek = scrubWantsPlayback
            restoreScrubIntentIfReady()
        }
    }

    private func restoreScrubIntentIfReady() {
        guard !isScrubbing, !seekInFlight, pendingSeekTarget == nil,
              let desired = resumeAfterSeek, let player, phase != .failed else { return }
        resumeAfterSeek = nil
        if desired, position < duration { player.play() } else { player.pause() }
        refreshTransportState()
    }

    private func refreshTransportState() {
        guard let player, phase != .failed else { return }
        if isScrubbing { phase = .scrubbing; isPlaying = scrubWantsPlayback; return }
        if let desired = resumeAfterSeek { phase = .scrubbing; isPlaying = desired; return }
        isPlaying = player.rate > 0 || player.timeControlStatus == .playing || player.timeControlStatus == .waitingToPlayAtSpecifiedRate
        switch player.timeControlStatus {
        case .playing: phase = .playing
        case .waitingToPlayAtSpecifiedRate: phase = isPlaying ? .buffering : .paused
        case .paused:
            phase = duration > 0 && position >= duration && !seekInFlight ? .ended : .paused
        @unknown default: phase = .paused
        }
    }

    /// Called only by this generation's registered player observers.
    private func failPlayback(_ error: Error?) {
        guard phase != .failed else { return }
        phase = .failed
        errorMessage = error?.localizedDescription ?? "Audio playback could not continue. Reopen or verify the recording."
        isPlaying = false; isScrubbing = false; resumeAfterSeek = nil
        pendingSeekTarget = nil; seekInFlight = false
        player?.pause()
        player?.currentItem?.cancelPendingSeeks()
    }

    /// Latest-wins coalesced seek (#13). Rapid scrub updates immediately move `position`
    /// while at most one `AVPlayer.seek` runs in flight; any newer target queued during
    /// an active seek runs as soon as the current seek completes.
    func seek(to seconds: Double) {
        guard seconds.isFinite, phase != .failed else { return }
        let upperBound = duration > 0 ? duration : max(0, seconds)
        let target = min(upperBound, max(0, seconds))
        position = target
        if phase == .ended { phase = .paused }
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
        let cmTarget = CMTime(seconds: target, preferredTimescale: PlaybackPolicy.seekTimescale)
        seekPlayer(player, cmTarget) { [weak self] finished in
            Task { @MainActor [weak self] in
                guard let self, self.generation == id, self.phase != .failed else { return }
                self.seekInFlight = false
                if self.pendingSeekTarget != nil {
                    self.drainPendingSeekIfNeeded()
                } else if !finished {
                    self.failPlayback(SessionError.invalid("Audio could not seek to the requested position."))
                } else { self.restoreScrubIntentIfReady() }
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
        load(id: entry.session.id, name: entry.displayTitle, initialDuration: initialDuration) { [build] in
            try await build(entry)
        }
    }

    func playFile(_ url: URL) {
        load(id: UUID(), name: url.lastPathComponent, initialDuration: nil) {
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
        name: String,
        initialDuration: Double?,
        operation: @escaping @MainActor () async throws -> AVPlayerItem
    ) {
        stop()
        guard !recordingActive else { return }
        let requestToken = claimGlobalPlayback()
        let id = generation
        loading = true; phase = .preparing; sourceName = name
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
                    self.errorMessage = error.localizedDescription; self.phase = .failed
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
        item.preferredForwardBufferDuration = PlaybackPolicy.preferredForwardBufferDuration
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
        refreshTransportState()
    }

    private func attachPlayerObservers(player: AVPlayer, item: AVPlayerItem, id: UUID) {
        detachPlayerObservers()
        let timeToken = player.addPeriodicTimeObserver(
            forInterval: PlaybackPolicy.observerInterval,
            queue: .main
        ) { [weak self, weak player] time in
            MainActor.assumeIsolated {
                guard let self, self.generation == id, let player else { return }
                self.receiveTimeObservation(time, from: player)
            }
        }

        playerObservations = [
            player.publisher(for: \.timeControlStatus).receive(on: RunLoop.main).sink { [weak self] _ in
                guard let self, self.generation == id else { return }
                self.refreshTransportState()
            },
            item.publisher(for: \.status).receive(on: RunLoop.main).sink { [weak self, weak item] _ in
                guard let self, self.generation == id, let item else { return }
                if item.status == .failed { self.failPlayback(item.error) }
            },
            player.publisher(for: \.status).receive(on: RunLoop.main).sink { [weak self, weak player] _ in
                guard let self, self.generation == id, let player else { return }
                if player.status == .failed { self.failPlayback(player.error) }
            }
        ]

        let endToken = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                // An EOF queued by the previous play-through can arrive after
                // the user has already sought/restarted. Keep the latest intent.
                guard let self, self.generation == id,
                      !self.isScrubbing, !self.seekInFlight, self.pendingSeekTarget == nil, self.phase != .failed else { return }
                self.player?.pause()
                self.isPlaying = false; self.phase = .ended
                if self.duration > 0 {
                    self.position = self.duration
                }
            }
        }

        let failureToken = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemFailedToPlayToEndTime, object: item, queue: .main
        ) { [weak self] notification in
            let error = notification.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error
            MainActor.assumeIsolated {
                guard let self, self.generation == id else { return }
                self.failPlayback(error)
            }
        }
        let stalledToken = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemPlaybackStalled, object: item, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.generation == id, self.isPlaying,
                      !self.isScrubbing, self.phase != .failed else { return }
                self.phase = .buffering
            }
        }

        observerCleanup = PlayerObserverCleanup(
            player: player,
            timeToken: timeToken,
            notificationObservers: [endToken, failureToken, stalledToken]
        )
    }

    /// The observer's event boundary also makes clock/order regressions deterministic.
    func receiveTimeObservation(_ time: CMTime, from observedPlayer: AVPlayer) {
        guard player === observedPlayer, phase != .failed else { return }
        if !isScrubbing, !seekInFlight, pendingSeekTarget == nil, phase != .ended {
            let seconds = time.seconds
            if seconds.isFinite { position = min(max(0, seconds), duration > 0 ? duration : max(0, seconds)) }
        }
        if let seconds = observedPlayer.currentItem?.duration.seconds, seconds.isFinite, seconds > 0 {
            duration = seconds
        }
        refreshTransportState()
    }

    private func detachPlayerObservers() {
        observerCleanup?.tearDown()
        observerCleanup = nil
        playerObservations.forEach { $0.cancel() }
        playerObservations = []
        seekInFlight = false
        pendingSeekTarget = nil
        isScrubbing = false; resumeAfterSeek = nil
    }

    func playSource(_ source: RecordingSession.SourceTrack, parent: SessionEntry) {
        stop()
        guard !recordingActive else { return }
        let requestToken = claimGlobalPlayback()
        let id = generation
        let reader = sourceReader
        let asyncReader = asyncSourceReader
        loading = true; phase = .preparing; sourceName = source.name
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
                    self.errorMessage = error.localizedDescription; self.phase = .failed
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
        player?.replaceCurrentItem(with: nil)
        player = nil
        playing = nil
        loading = false; phase = .idle; sourceName = nil; errorMessage = nil
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
@Observable final class PlaybackLevels {
    private(set) var value: ListeningLevel
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
