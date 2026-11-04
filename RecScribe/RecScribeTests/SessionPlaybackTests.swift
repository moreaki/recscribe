import AVFoundation
import Testing
@testable import RecScribe

@MainActor
struct SessionPlaybackTests {
    @MainActor final class Loader {
        var pending: [UUID: CheckedContinuation<AVPlayerItem, any Error>] = [:]
        func load(_ entry: SessionEntry) async throws -> AVPlayerItem {
            try await withCheckedThrowingContinuation { pending[entry.session.id] = $0 }
        }
        func finish(_ entry: SessionEntry, error: (any Error)? = nil) {
            let continuation = pending.removeValue(forKey: entry.session.id)
            if let error { continuation?.resume(throwing: error) }
            else { continuation?.resume(returning: AVPlayerItem(asset: AVMutableComposition())) }
        }
    }
    private func entry() -> SessionEntry {
        .init(id: URL(fileURLWithPath: "/synthetic/session.recscribe.json"),
              session: RecordingSession(sampleRate: 48_000, channels: 2, channelMap: ["left", "right"], options: .init()))
    }

    @Test func newestSelectionWinsEvenWhenCancelledLoaderCompletesLater() async {
        let loader = Loader(), first = entry(), second = entry()
        var activations = 0
        let playback = SessionPlayback(build: { try await loader.load($0) }, activate: { _ in activations += 1 })
        playback.play(first)
        await waitUntil("first load") { loader.pending[first.session.id] != nil }
        playback.play(second)
        await waitUntil("second load") { loader.pending[second.session.id] != nil }
        loader.finish(second)
        await waitUntil("newest player") { playback.playing == second.session.id }
        loader.finish(first, error: SessionError.invalid("stale error"))
        await settle()
        #expect(activations == 1)
        #expect(playback.playing == second.session.id)
        #expect(playback.errorMessage == nil)
        playback.stop()
    }

    @Test func captureStartAndClosePreventLatePlayback() async {
        for capture in [false, true] {
            let loader = Loader(), selected = entry()
            var activations = 0
            let playback = SessionPlayback(build: { try await loader.load($0) }, activate: { _ in activations += 1 })
            playback.play(selected)
            await waitUntil("delayed asset") { loader.pending[selected.session.id] != nil }
            if capture { playback.setRecording(true) } else { playback.stop() }
            loader.finish(selected)
            await settle()
            #expect(activations == 0)
            #expect(playback.player == nil)
            #expect(playback.errorMessage == nil)
            if capture { playback.play(selected); #expect(!playback.loading) }
        }
    }

    @Test func loadErrorsAreActionableButCancellationIsNotAnError() async {
        for error in [SessionError.invalid("Missing audio part; verify the session") as any Error, CancellationError()] {
            let playback = SessionPlayback(build: { _ in throw error })
            playback.play(entry())
            await waitUntil("load result") { !playback.loading }
            #expect(playback.player == nil)
            #expect((playback.errorMessage == nil) == (error is CancellationError))
        }
    }

    @Test func multipartCompositionUsesExactSampleTimeAndRejectsMissingParts() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let writer = SessionWAVWriter(options: .init(maximumPartBytes: 444))
        try writer.createFile(at: directory.appendingPathComponent("tone.wav"), sampleRate: 48_000, channels: 2)
        try writer.writeBuffer(SampleBufferFixtures.makePCMBuffer(channels: 2, frames: 350, interleaved: false) { _, _ in 0 })
        try writer.finalize()
        let manifest = try #require(writer.manifestURL)
        let session = try SessionProcessing.process(manifest, ffmpeg: URL(fileURLWithPath: "/unused"), cancel: WorkCancellation())
        let selected = SessionEntry(id: manifest, session: session)
        let item = try await SessionPlaybackBuilder.item(for: selected)
        #expect(try await item.asset.load(.duration) == CMTime(value: 350, timescale: 48_000))
        let tracks = try await item.asset.loadTracks(withMediaType: .audio)
        let track = try #require(tracks.first as? AVCompositionTrack)
        let segments = try await track.load(.segments)
        #expect(segments.count == session.parts.count)
        for (segment, part) in zip(segments, session.parts) {
            #expect(segment.timeMapping.target.start == CMTime(value: part.startSample, timescale: 48_000))
            #expect(segment.timeMapping.target.duration == CMTime(value: part.frames, timescale: 48_000))
        }
        var unverified = selected
        unverified.session.parts[0].status = .finalized
        await #expect(throws: (any Error).self) { try await SessionPlaybackBuilder.item(for: unverified) }
        try FileManager.default.removeItem(at: directory.appendingPathComponent(session.parts[1].path))
        await #expect(throws: (any Error).self) { try await SessionPlaybackBuilder.item(for: selected) }
    }

    @MainActor final class SourceReaderGate {
        var pending: CheckedContinuation<SessionEntry, any Error>?
        func read(_ entry: SessionEntry) async throws -> SessionEntry {
            try await withCheckedThrowingContinuation { pending = $0 }
        }
        func finish(_ entry: SessionEntry) {
            let continuation = pending
            pending = nil
            continuation?.resume(returning: entry)
        }
    }

    @Test func playSourceClaimsLatestWinsOwnershipAtStartAndNeverPreemptsNewerInstance() async {
        let loader = Loader()
        let sourceGate1 = SourceReaderGate()
        let sourceGate2 = SourceReaderGate()
        let sharedCoordinator = SessionPlaybackCoordinator()
        let parentEntry = entry()
        let childEntry = entry()
        let otherEntry = entry()
        let track = RecordingSession.SourceTrack(role: .input("mic-1"), name: "Mic 1", deviceUID: "mic-1")

        var activationsA = 0
        var activationsB = 0
        let playbackA = SessionPlayback(
            build: { try await loader.load($0) },
            activate: { _ in activationsA += 1 },
            coordinator: sharedCoordinator,
            asyncSourceReader: { _, _, _ in try await sourceGate1.read(childEntry) }
        )
        let playbackB = SessionPlayback(
            build: { try await loader.load($0) },
            activate: { _ in activationsB += 1 },
            coordinator: sharedCoordinator
        )

        // 1. A.playSource starts, then B.play starts while A's read is in flight.
        playbackA.playSource(track, parent: parentEntry)
        await waitUntil("A source read started") { sourceGate1.pending != nil }
        playbackB.play(otherEntry)
        await waitUntil("B load pending") { loader.pending[otherEntry.session.id] != nil }
        loader.finish(otherEntry)
        await waitUntil("B playing") { playbackB.playing == otherEntry.session.id }

        // Release A's delayed source read; A must NOT steal playback from newer B.
        sourceGate1.finish(childEntry)
        await settle()
        #expect(activationsA == 0)
        #expect(playbackA.playing == nil)
        #expect(playbackB.playing == otherEntry.session.id)
        #expect(activationsB == 1)

        // 2. Starting A.playSource while B is playing immediately preempts B at request start.
        let playbackA2 = SessionPlayback(
            build: { _ in AVPlayerItem(asset: AVMutableComposition()) },
            activate: { _ in activationsA += 1 },
            coordinator: sharedCoordinator,
            asyncSourceReader: { _, _, _ in try await sourceGate2.read(childEntry) }
        )
        playbackA2.playSource(track, parent: parentEntry)
        // B must be stopped immediately at A2.playSource request start, before A2's read finishes.
        #expect(playbackB.playing == nil)
        #expect(playbackB.player == nil)
        await waitUntil("A2 source read started") { sourceGate2.pending != nil }

        // 3. Starting recording while A2.playSource is reading cancels A2 and prevents late playback.
        playbackA2.setRecording(true)
        sourceGate2.finish(childEntry)
        await settle()
        #expect(activationsA == 0)
        #expect(playbackA2.playing == nil)
        #expect(playbackA2.player == nil)
    }

    @Test func singlePartFastPathSeekSkipFormatTimeAndObserverTeardownOnDeinit() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let writer = SessionWAVWriter()
        try writer.createFile(at: directory.appendingPathComponent("single.wav"), sampleRate: 48_000, channels: 2)
        try writer.writeBuffer(SampleBufferFixtures.makePCMBuffer(channels: 2, frames: 48_000, interleaved: false) { _, _ in 0.1 })
        try writer.finalize()
        let manifest = try #require(writer.manifestURL)
        let session = try SessionProcessing.process(manifest, ffmpeg: URL(fileURLWithPath: "/unused"), cancel: WorkCancellation())
        let selected = SessionEntry(id: manifest, session: session)

        // Single-part fast path uses AVURLAsset directly rather than AVMutableComposition.
        let item = try await SessionPlaybackBuilder.item(for: selected)
        #expect(item.asset is AVURLAsset)
        #expect(!(item.asset is AVMutableComposition))

        #expect(SessionPlayback.formatTime(0) == "00:00")
        #expect(SessionPlayback.formatTime(65.9) == "01:05")
        #expect(SessionPlayback.formatTime(3661) == "1:01:01")

        var playback: SessionPlayback? = SessionPlayback(activate: { $0.pause() })
        playback?.play(selected)
        await waitUntil("single part loaded") { playback?.playing == selected.session.id }
        #expect(playback?.hasAttachedPlayerObservers == true)
        #expect(abs((playback?.duration ?? 0) - 1.0) < 0.05)

        playback?.seek(to: 0.4)
        #expect(abs((playback?.position ?? 0) - 0.4) < 0.001)
        playback?.skip(by: 0.3)
        #expect(abs((playback?.position ?? 0) - 0.7) < 0.001)
        playback?.skip(by: -15)
        #expect(playback?.position == 0)

        let playerRef = try #require(playback?.player)
        // Releasing SessionPlayback without calling stop() tears down player observers in deinit.
        playback = nil
        _ = playerRef
    }
}
