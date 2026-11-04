import AppKit
import AVFoundation
import SwiftUI
import Testing
@testable import RecScribe

@MainActor
@Suite(.serialized)
struct SessionPlaybackAcceptanceTests {
    private final class SeekGate {
        var targets: [Double] = []
        var completions: [@Sendable (Bool) -> Void] = []
        func seek(_ player: AVPlayer, to time: CMTime, completion: @escaping @Sendable (Bool) -> Void) {
            targets.append(time.seconds); completions.append(completion)
        }
    }

    /// A real, silent, local asset: no device capture, private audio or network.
    private func fixture() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("Long source identity — synthetic silence.wav")
        let writer = WAVWriter()
        try writer.createFile(at: url, sampleRate: 48_000, channels: 1)
        let chunk = SampleBufferFixtures.makePCMBuffer(channels: 1, frames: 4_800, interleaved: false) { _, _ in 0 }
        for _ in 0..<300 { try writer.writeBuffer(chunk) }
        try writer.finalize()
        return url
    }

    private func load(_ url: URL, gate: SeekGate) async throws -> SessionPlayback {
        let playback = SessionPlayback(activate: { $0.pause() }, seekPlayer: gate.seek)
        playback.playFile(url)
        #expect(playback.phase == .preparing && playback.sourceName == url.lastPathComponent)
        await waitUntil("file-backed acceptance player") { !playback.loading }
        let player = try #require(playback.player)
        await waitUntil("silent asset ready") { player.status != .unknown }
        #expect(player.status == .readyToPlay)
        #expect(playback.phase == .paused && playback.canSeek)
        return playback
    }

    @Test func draggingHoldsPositionBetweenCompletedSeeksAndRestoresIntentOnlyAfterFinalSeek() async throws {
        let url = try fixture(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        for initiallyPlaying in [false, true] {
            let gate = SeekGate(), playback = try await load(url, gate: gate)
            defer { playback.stop() }
            let player = try #require(playback.player)
            if initiallyPlaying { playback.togglePlayback(); #expect(playback.isPlaying) }
            playback.setScrubbing(true)
            #expect(playback.isScrubbing && playback.phase == .scrubbing)
            #expect(player.rate == 0 && playback.isPlaying == initiallyPlaying)
            playback.seek(to: 8)
            gate.completions[0](true)
            await settle()
            // A gap between drag events used to allow the periodic observer to
            // overwrite the thumb even though the gesture was still active.
            playback.receiveTimeObservation(CMTime(seconds: 1, preferredTimescale: 600), from: player)
            #expect(playback.position == 8 && playback.phase == .scrubbing)
            playback.seek(to: 15); playback.seek(to: 25)
            #expect(gate.targets == [8, 15])
            playback.setScrubbing(false)
            #expect(player.rate == 0)
            gate.completions[1](false)
            await waitUntil("last dragged target") { gate.targets.count == 3 }
            #expect(gate.targets == [8, 15, 25] && player.rate == 0)
            gate.completions[2](true)
            await waitUntil("scrub intent restored") { playback.phase != .scrubbing }
            #expect(playback.isPlaying == initiallyPlaying)
            #expect((player.rate > 0) == initiallyPlaying)
        }
    }

    @Test func pauseDuringDragAndCaptureOrSourceChangeCannotResumeStaleAudio() async throws {
        let url = try fixture(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let gate = SeekGate(), playback = try await load(url, gate: gate)
        defer { playback.stop() }
        playback.togglePlayback(); playback.setScrubbing(true); playback.seek(to: 9)
        playback.togglePlayback() // The pause command during dragging changes intent.
        playback.setScrubbing(false); gate.completions[0](true)
        await waitUntil("pause intent restored") { playback.phase != .scrubbing }
        #expect(!playback.isPlaying && playback.player?.rate == 0)

        for capture in [false, true] {
            playback.togglePlayback(); playback.setScrubbing(true); playback.seek(to: 20)
            let staleCompletion = try #require(gate.completions.last)
            let oldPlayer = try #require(playback.player)
            if capture { playback.setRecording(true) } else { playback.playFile(url) }
            staleCompletion(true)
            await settle()
            #expect(!playback.isScrubbing && !playback.isPlaying && oldPlayer.rate == 0)
            if capture {
                #expect(playback.player == nil && playback.phase == .idle)
                playback.playFile(url)
                #expect(!playback.loading)
            } else {
                await waitUntil("replacement after drag") { playback.player != nil }
                #expect(playback.player !== oldPlayer && playback.phase == .paused)
            }
        }
    }

    @Test func runtimeFailureIsVisibleStickyAndOldItemNotificationsAreDetached() async throws {
        let url = try fixture(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let gate = SeekGate(), playback = try await load(url, gate: gate)
        defer { playback.stop() }
        let player = try #require(playback.player), item = try #require(player.currentItem)
        playback.togglePlayback()
        NotificationCenter.default.post(name: .AVPlayerItemPlaybackStalled, object: item)
        #expect(playback.phase == .buffering)
        playback.setScrubbing(true); playback.seek(to: 10); playback.setScrubbing(false)
        let error = NSError(domain: "SyntheticPlayback", code: 7,
                            userInfo: [NSLocalizedDescriptionKey: "The audio file became unavailable"])
        NotificationCenter.default.post(name: .AVPlayerItemFailedToPlayToEndTime, object: item,
                                        userInfo: [AVPlayerItemFailedToPlayToEndTimeErrorKey: error])
        #expect(playback.phase == .failed && playback.errorMessage == error.localizedDescription)
        #expect(!playback.isPlaying && !playback.canSeek && player.rate == 0)
        gate.completions[0](true)
        NotificationCenter.default.post(name: .AVPlayerItemDidPlayToEndTime, object: item)
        playback.receiveTimeObservation(.zero, from: player)
        playback.togglePlayback()
        await settle()
        #expect(playback.phase == .failed && player.rate == 0)

        playback.playFile(url)
        await waitUntil("player replacing failed item") { !playback.loading }
        let replacement = try #require(playback.player)
        #expect(replacement !== player && playback.errorMessage == nil)
        for name in [Notification.Name.AVPlayerItemDidPlayToEndTime, .AVPlayerItemFailedToPlayToEndTime, .AVPlayerItemPlaybackStalled] {
            NotificationCenter.default.post(name: name, object: item)
        }
        playback.receiveTimeObservation(CMTime(seconds: 29, preferredTimescale: 600), from: player)
        #expect(playback.phase == .paused && playback.position == 0)
        playback.stop()
        #expect(!playback.hasPresentation && !playback.hasAttachedPlayerObservers)
    }

    @Test func endStateSurvivesPeriodicClockUntilExplicitSeekAndPoliciesApplyToNativeFiles() async throws {
        let url = try fixture(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let gate = SeekGate(), playback = try await load(url, gate: gate)
        defer { playback.stop() }
        let player = try #require(playback.player), item = try #require(player.currentItem)
        #expect(item.preferredForwardBufferDuration == PlaybackPolicy.preferredForwardBufferDuration)
        playback.togglePlayback()
        NotificationCenter.default.post(name: .AVPlayerItemDidPlayToEndTime, object: item)
        playback.receiveTimeObservation(.zero, from: player)
        #expect(playback.phase == .ended && playback.position == playback.duration && !playback.isPlaying)
        playback.skip(by: -PlaybackPolicy.skipSeconds)
        #expect(playback.phase == .paused && abs(playback.position - 15) < 0.01)
        #expect(player.rate == 0)
        gate.completions[0](true)
        #expect(SessionPlayback.formatTime(360_001) == "100:00:01")
        #expect(SessionPlayback.formatTime(Double.greatestFiniteMagnitude) == "00:00")
        #expect(PlaybackPolicy.spokenTime(3661, locale: Locale(identifier: "en_US")) == "1 hour, 1 minute, 1 second")
        #expect(PlaybackPolicy.spokenTime(.nan) == "Unknown duration")
    }

    @Test func failedFinalSeekReportsFailureInsteadOfResumingAtAnOldPosition() async throws {
        let url = try fixture(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let gate = SeekGate(), playback = try await load(url, gate: gate)
        defer { playback.stop() }
        playback.togglePlayback(); playback.setScrubbing(true); playback.seek(to: 12)
        playback.setScrubbing(false)
        gate.completions[0](false)
        await waitUntil("failed final seek") { playback.phase == .failed }
        #expect(!playback.isPlaying && playback.player?.rate == 0)
        #expect(playback.errorMessage?.contains("requested position") == true)
    }

    @Test func narrowTransportHasSpokenPositionAndKeyboardControlsWithoutDuplicateActions() async throws {
        let url = try fixture(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let gate = SeekGate(), playback = try await load(url, gate: gate)
        defer { playback.stop() }
        for width: CGFloat in [280, 360, 900] {
            let host = NSHostingView(rootView: SessionPlaybackView(playback: playback, showListeningControls: false)
                .padding().frame(width: width).environment(\.dynamicTypeSize, .accessibility3).preferredColorScheme(.dark))
            // The fixture supplies a fixed viewport. Do not let NSHostingView's
            // intrinsic min/max sizing recursively resize that same window.
            host.sizingOptions = [.intrinsicContentSize]
            host.frame = CGRect(x: 0, y: 0, width: width, height: 260)
            let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: width, height: 260),
                                  styleMask: .titled, backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.contentView = host
            defer { window.contentView = nil; window.close() }
            for _ in 0..<6 { host.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(20)) }
            #expect(host.fittingSize.width > 0 && host.fittingSize.width <= width + 1)
            let slider = try #require(nativeSubviews(host).compactMap { $0 as? PlaybackSlider }.first)
            #expect(slider.accessibilityIdentifier() == "playback-position")
            #expect(slider.accessibilityLabel() == "Playback position")
            #expect(slider.accessibilityValueDescription() == playback.positionAccessibilityValue)
            #expect(slider.minValue == 0 && slider.maxValue == playback.duration)
            #expect(!playback.positionAccessibilityValue.contains("00:30"))
            let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command, .option],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
                characters: String(UnicodeScalar(NSRightArrowFunctionKey)!),
                charactersIgnoringModifiers: String(UnicodeScalar(NSRightArrowFunctionKey)!), isARepeat: false, keyCode: 124))
            let before = playback.position
            #expect(window.performKeyEquivalent(with: event))
            #expect(playback.position == min(playback.duration, before + PlaybackPolicy.skipSeconds))
            if let completion = gate.completions.last { completion(true); await settle() }
            // Native adjustable actions also use the bounded transport, not a second player.
            #expect(slider.accessibilityPerformDecrement())
            #expect(playback.position == max(0, before))
            #expect(slider.doubleValue == playback.position)
            #expect(slider.accessibilityValueDescription() == playback.positionAccessibilityValue)
            if let completion = gate.completions.last { completion(true); await settle() }
            host.layoutSubtreeIfNeeded()
            #expect(slider.accessibilityValueDescription() == playback.positionAccessibilityValue)
            if width == 280 {
                let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: bitmap)
                try #require(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: "/tmp/recscribe13-compact.png"))
            }
        }
    }

    @Test func longTimelineAndEveryStatusWrapWithinCompactAccessibleLayout() async throws {
        let composition = AVMutableComposition()
        composition.insertEmptyTimeRange(CMTimeRange(start: .zero, duration: CMTime(seconds: 360_001, preferredTimescale: 600)))
        let playback = SessionPlayback(build: { _ in AVPlayerItem(asset: composition) }, activate: { $0.pause() })
        playback.play(.init(id: URL(fileURLWithPath: "/synthetic/long-timeline.recscribe.json"),
            session: longSession()))
        await waitUntil("long timeline presentation") { !playback.loading }
        defer { playback.stop() }
        #expect(playback.formattedDuration == "100:00:01")
        for phase in PlaybackPhase.allCases {
            let host = NSHostingView(rootView: VStack(alignment: .leading) {
                PlaybackStatusView(phase: phase, errorMessage: "A synthetic source became unavailable. Reopen the recording and verify its audio parts.")
                SessionPlaybackView(playback: playback, showListeningControls: false)
            }.padding().frame(width: 280).environment(\.dynamicTypeSize, .accessibility3))
            host.sizingOptions = [.intrinsicContentSize]; host.frame = CGRect(x: 0, y: 0, width: 280, height: 400)
            let window = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.contentView = host
            window.appearance = NSAppearance(named: .darkAqua)
            defer { window.contentView = nil; window.close() }
            host.layoutSubtreeIfNeeded()
            #expect(host.fittingSize.width > 0 && host.fittingSize.width <= 281)
            let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            #expect(bitmap.pixelsWide > 0 && host.fittingSize.height > 0 && host.fittingSize.height <= 400)
            if phase == .failed || phase == .buffering {
                try #require(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: "/tmp/recscribe13-status-\(phase.rawValue).png"))
            }

        }
    }

    private func longSession() -> RecordingSession {
        var session = RecordingSession(sampleRate: 48_000, channels: 1, channelMap: ["mono"], options: .init())
        session.parts = [.init(path: "synthetic.wav", startSample: 0, frames: Int64(360_001) * 48_000, startedAt: Date())]
        return session
    }

    private func nativeSubviews(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap(nativeSubviews)
    }
}
