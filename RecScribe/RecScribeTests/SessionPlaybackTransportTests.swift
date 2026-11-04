import AppKit
import AVFoundation
import SwiftUI
import Testing
@testable import RecScribe

@MainActor
@Suite(.serialized)
struct SessionPlaybackTransportTests {
    private final class SeekGate {
        struct Request {
            let seconds: Double
            let completion: @Sendable (Bool) -> Void
        }
        var requests: [Request] = []
        func seek(_ player: AVPlayer, to time: CMTime, completion: @escaping @Sendable (Bool) -> Void) {
            requests.append(.init(seconds: time.seconds, completion: completion))
        }
    }

    private func entry() -> SessionEntry {
        var session = RecordingSession(sampleRate: 48_000, channels: 2, channelMap: ["left", "right"], options: .init())
        session.parts = [.init(path: "synthetic.wav", startSample: 0, frames: 120 * 48_000, startedAt: Date())]
        return .init(id: URL(fileURLWithPath: "/synthetic/transport.recscribe.json"), session: session)
    }

    private func playback(_ gate: SeekGate) async -> SessionPlayback {
        let playback = SessionPlayback(build: { _ in AVPlayerItem(asset: AVMutableComposition()) },
            activate: { $0.pause() }, seekPlayer: gate.seek)
        playback.play(entry())
        await waitUntil("synthetic transport loaded") { playback.player != nil }
        return playback
    }

    @Test func queuedSeeksKeepOnlyLatestTargetClampAndPreservePause() async throws {
        let gate = SeekGate(), playback = await playback(gate)
        defer { playback.stop() }
        let player = try #require(playback.player)
        playback.seek(to: 30)
        playback.seek(to: 75)
        playback.seek(to: 90)
        #expect(gate.requests.count == 1 && playback.position == 90)
        try #require(gate.requests.first).completion(false)
        await waitUntil("latest queued seek after cancelled first seek") { gate.requests.count == 2 }
        #expect(gate.requests.map(\.seconds) == [30, 90])
        playback.seek(to: 35)
        gate.requests[1].completion(true)
        await waitUntil("newest target while second seek was in flight") { gate.requests.count == 3 }
        #expect(gate.requests.map(\.seconds) == [30, 90, 35])
        #expect(player.rate == 0) // Scrubbing must not resume paused playback.
        playback.seek(to: -.infinity)
        playback.seek(to: .nan)
        #expect(gate.requests.count == 3 && playback.position == 35)
        playback.seek(to: -100)
        #expect(playback.position == 0)
        playback.seek(to: 10_000)
        #expect(playback.position == 120 && gate.requests.count == 3)
        gate.requests[2].completion(true)
        await waitUntil("clamped latest target") { gate.requests.count == 4 }
        #expect(gate.requests.last?.seconds == 120 && player.rate == 0)
        gate.requests[3].completion(true)
    }

    @Test func endOfFileRestartsAtZeroAndOldCallbacksCannotOverrideNewPlayback() async throws {
        let gate = SeekGate(), playback = await playback(gate)
        defer { playback.stop() }
        let player = try #require(playback.player), item = try #require(player.currentItem)
        player.pause()
        NotificationCenter.default.post(name: .AVPlayerItemDidPlayToEndTime, object: item)
        #expect(playback.position == 120 && !playback.isPlaying)
        playback.togglePlayback()
        #expect(playback.position == 0 && gate.requests.first?.seconds == 0)
        // A queued EOF from the old play-through must not undo the new seek.
        NotificationCenter.default.post(name: .AVPlayerItemDidPlayToEndTime, object: item)
        #expect(playback.position == 0)

        playback.play(entry())
        await waitUntil("replacement transport") { playback.player != nil && playback.player !== player }
        playback.seek(to: 55)
        playback.seek(to: 80)
        #expect(gate.requests.count == 2 && playback.position == 80)
        gate.requests[0].completion(true) // Old generation, while a new seek is pending.
        await settle()
        #expect(gate.requests.count == 2 && playback.position == 80)
        gate.requests[1].completion(true)
        await waitUntil("replacement queued seek") { gate.requests.count == 3 }
        #expect(gate.requests[2].seconds == 80)
        NotificationCenter.default.post(name: .AVPlayerItemDidPlayToEndTime, object: item)
        #expect(playback.position == 80)
        gate.requests[2].completion(true)
    }

    @Test func hostedTransportShortcutsSkipAndToggleWithoutClaimingPlainTyping() async throws {
        let gate = SeekGate(), playback = await playback(gate)
        defer { playback.stop() }
        let host = NSHostingController(rootView: SessionPlaybackView(playback: playback, showListeningControls: false))
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 900, height: 160),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentViewController = host
        defer { window.contentViewController = nil }
        for _ in 0..<6 { host.view.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(20)) }
        func key(_ characters: String, code: UInt16, modifiers: NSEvent.ModifierFlags = [.command, .option]) throws -> Bool {
            let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers,
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
                characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code))
            return window.performKeyEquivalent(with: event)
        }
        #expect(try !key("p", code: 35, modifiers: []))
        #expect(gate.requests.isEmpty)
        #expect(try key(String(UnicodeScalar(NSRightArrowFunctionKey)!), code: 124))
        #expect(playback.position == 15 && gate.requests.first?.seconds == 15)
        #expect(try key(String(UnicodeScalar(NSLeftArrowFunctionKey)!), code: 123))
        #expect(playback.position == 0 && gate.requests.count == 1)
        #expect(try key("p", code: 35))
        #expect(playback.isPlaying)
        #expect(try key("p", code: 35))
        #expect(!playback.isPlaying)
        playback.setRecording(true)
        #expect(playback.player == nil)
        for _ in 0..<6 { host.view.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(20)) }
        _ = try key("p", code: 35)
        #expect(playback.player == nil && !playback.isPlaying)
        gate.requests.first?.completion(true)
    }
}
