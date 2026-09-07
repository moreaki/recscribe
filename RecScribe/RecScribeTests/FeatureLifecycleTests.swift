import AVFoundation
import Foundation
import Testing
@testable import RecScribe

@MainActor
struct FeatureLifecycleTests {
    @Test func settingsPreserveExplicitPathsAndMigrateMissingFields() throws {
        let data = Data(#"{"pythonPath":"/explicit/python","modelPath":"/explicit/model","mode":"unknown-future-mode","autoTranscribe":true}"#.utf8)
        let values = try JSONDecoder().decode(AppSettings.Values.self, from: data)
        #expect(values.pythonPath == "/explicit/python")
        #expect(values.modelPath == "/explicit/model")
        #expect(values.mode == .verbatim)
        #expect(values.autoTranscribe)
        #expect(AppSettings.Values().pythonPath.isEmpty)
        #expect(AppSettings.Values().modelPath.isEmpty)
        for size in [Double.nan, .infinity, -.infinity, -1, Double.greatestFiniteMagnitude] {
            #expect(throws: (any Error).self) { try RecordingStorageOptions.partBytes(mebibytes: size) }
        }
        #expect(try RecordingStorageOptions.partBytes(mebibytes: 1) == RecordingStorageOptions.bytesPerMiB)
    }

    @Test func stoppedPlaybackIgnoresDelayedAssetCompletion() async {
        var completion: CheckedContinuation<AVPlayerItem, Never>?
        let playback = SessionPlayback { _ in
            await withCheckedContinuation { completion = $0 }
        }
        let entry = SessionEntry(id: URL(fileURLWithPath: "/synthetic/session.recscribe.json"),
            session: RecordingSession(sampleRate: 16_000, channels: 1, channelMap: ["channel-0"], options: .init()))
        playback.play(entry)
        await waitUntil("playback load") { completion != nil }
        playback.stop()
        completion?.resume(returning: AVPlayerItem(asset: AVMutableComposition()))
        await settle()
        #expect(playback.player == nil)
        #expect(playback.playing == nil)
        #expect(!playback.loading)
    }

    @Test func manifestReadFailureIsVisibleAndCancellationIsOwned() async {
        let library = SessionLibrary(readSessions: { _ in throw SessionError.invalid("Unreadable test manifest") })
        library.load(URL(fileURLWithPath: "/synthetic"))
        await waitUntil("manifest failure") { !library.refreshing }
        #expect(library.readFailures.first?.message == "Unreadable test manifest")
        library.cancelRefresh()
        #expect(!library.refreshing)
        await library.shutdown()
    }

    @Test func captureCoordinationIsInjectedAndMenusExposeFeatures() {
        var cancellations = 0
        let library = SessionLibrary(cancelRuntime: { cancellations += 1 })
        library.setRecording(true)
        #expect(cancellations == 1)
        #expect(library.recordingActive)
        library.setRecording(false)
        let ids = Set(OverflowMenu.actions().map(\.id))
        #expect(ids.contains("settings"))
        #expect(ids.contains("recordings"))
    }

    @Test func futureManifestStatesAreRejectedAndWireValuesStayStable() throws {
        #expect(try JSONEncoder().encode(SessionStatus.needsReview) == Data(#""needs_review""#.utf8))
        #expect(throws: (any Error).self) { try JSONDecoder().decode(PartStatus.self, from: Data(#""future-state""#.utf8)) }
        let value = try JSONDecoder().decode(JobSnapshot.self,
            from: Data(#"{"schema_version":"1.0","state":"completed_with_review","progress":1}"#.utf8))
        #expect(value.state.isTerminal)
    }
}
