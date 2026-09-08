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
}
