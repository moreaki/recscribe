import AppKit
import CoreMedia
import SwiftUI
import Testing
@testable import RecScribe

/// Offscreen native UI with copied synthetic PCM. Never acquires hardware or
/// enables an output; the optional snapshots show actual production views.
@MainActor
struct AudioTestViewTests {
    @Test func liveAndSampleViewsFitCompactAndNarrowLayouts() async throws {
        let suite = "audio-test-view-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let levels = AudioLevels(defaults: defaults), monitor = CapturedAudioMonitor(defaults: defaults)
        let listening = PlaybackLevels(defaults: defaults), capture = MockAudioCapturing()
        let device = InputDeviceInfo(uid: "test-mic", name: "Studio Display Microphone", inputChannels: 2, sampleRate: 48_000)
        let provider = MockAudioSourceProviding(selectedSource: .multiple(appBundleID: nil, inputs: [.init(device: device)]))
        provider.availableInputDevicesResult = [device]
        let test = AudioTestController(capture: capture, source: provider, permissions: MockPermissionProviding(.granted),
            levels: levels, monitor: monitor, playback: SessionPlayback(activate: { $0.pause() }, levels: listening),
            temporaryRoot: directory, saveDirectory: { directory }, sampleSeconds: 0.05)
        let recorder = RecorderViewModel(controller: MockRecordingControlling(), permissions: MockPermissionProviding(.granted),
            clock: ManualClock(), audioSource: provider, defaults: defaults, audioTest: test)
        recorder.permissionStatus = .granted
        let hosting = NSHostingView(rootView: AudioRoutingView(levels: levels, monitor: monitor, playbackLevels: listening)
            .environmentObject(recorder).preferredColorScheme(.dark))
        hosting.frame = CGRect(x: 0, y: 0, width: 1120, height: 700)
        let window = NSWindow(contentRect: hosting.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.appearance = NSAppearance(named: .darkAqua); window.contentView = hosting
        defer { window.contentView = nil; window.close() }

        func feed() {
            let epoch = CMClockGetTime(CMClockGetHostTimeClock()).seconds
            for index in 0..<8 {
                for track in [CaptureTrack.playback, .input("test-mic")] {
                    let buffer = SampleBufferFixtures.makePCMBuffer(channels: 2, frames: 480, interleaved: false) { _, _ in 0.25 }
                    capture.emit(.init(track: track, presentationTime: epoch + Double(index) / 100, buffer: buffer))
                }
            }
        }
        func render(_ name: String) async throws {
            try await Task.sleep(for: .milliseconds(120))
            hosting.layoutSubtreeIfNeeded()
            #expect(hosting.fittingSize.width <= hosting.frame.width + 1)
            if let path = ProcessInfo.processInfo.environment["AUDIO_TEST_SNAPSHOTS"] {
                let folder = URL(fileURLWithPath: path)
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                let bitmap = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
                hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
                try #require(bitmap.representation(using: .png, properties: [:])).write(to: folder.appendingPathComponent(name + ".png"))
            }
        }
        await test.startPreview(); feed()
        try await render("live-audio-test")
        hosting.frame.size.width = 760
        try await render("live-audio-test-narrow")
        #expect(!recorder.allowsCaptureSourceChange)
        recorder.setCaptureSource(.systemAll)
        #expect(provider.setCount == 0)
        await test.recordSample(); feed(); await test.stop()
        #expect(test.sample != nil && !capture.capturing && !monitor.enabled)
        hosting.frame.size.width = 1120
        try await render("audio-sample-ready")
        hosting.frame.size.width = 760
        try await render("audio-sample-ready-narrow")
        await test.close()
    }
}
