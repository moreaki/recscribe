import AppKit
import Combine
import SwiftUI
import Testing
@testable import RecScribe

@MainActor
struct WorkspaceRegressionTests {
    @Test func destinationIsSelectedBeforeOpeningAndSurvivesWindowRecreation() {
        let navigation = StudioNavigation()
        for (destination, mode) in [(AppWindow.routing, StudioWorkspaceMode.routing),
                                    (.recordings, .recordings), (.studio, .studio)] {
            // No Studio view/subscriber exists when a command or menu action opens it.
            navigation.open(destination) { sceneID in
                #expect(sceneID == AppWindow.studio.rawValue)
                #expect(navigation.mode == mode)
            }
            // Closing a scene does not discard app-owned selection.
            let root = StudioView().environment(\.studioNavigation, navigation)
            withExtendedLifetime(root) { #expect(navigation.mode == mode) }
        }
        navigation.mode = .recordings
        navigation.open(.settings) { #expect($0 == AppWindow.settings.rawValue) }
        #expect(navigation.mode == .recordings)
    }

    @Test func routingMeterRepaintsOnTelemetryWithoutInvalidatingRecorder() async throws {
        let suite = "recscribe-meter-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let recorder = RecorderViewModel(controller: MockRecordingControlling(),
            permissions: MockPermissionProviding(.granted), clock: ManualClock(),
            audioSource: MockAudioSourceProviding(), defaults: defaults)
        var parentUpdates = 0
        let observation = recorder.objectWillChange.sink { parentUpdates += 1 }
        defer { withExtendedLifetime(observation) {} }
        let host = NSHostingView(rootView: CaptureSourceMeter(telemetry: recorder.telemetry, track: .playback)
            .frame(width: 360, height: 90, alignment: .topLeading))
        host.frame = NSRect(x: 0, y: 0, width: 360, height: 90)
        let window = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.contentView = nil; window.close() }

        func pixels() async throws -> Data {
            try await Task.sleep(for: .milliseconds(80))
            host.layoutSubtreeIfNeeded()
            let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            return try #require(bitmap.representation(using: .png, properties: [:]))
        }
        let empty = try await pixels()
        var health = RecordingHealth(startedAt: 0)
        health.lastReceivedAt = 1
        health.lastWrittenAt = 1
        health.writtenFrames = 48_000
        health.peak = 0.75
        recorder.sourceHealth = [.init(id: CaptureTrack.playback.rawValue, name: "Playback", health: health)]
        recorder.healthTime = 1
        let receiving = try await pixels()
        #expect(receiving != empty)
        recorder.healthTime = 60 // No new packet: the same source must now display stalled status.
        let stalled = try await pixels()
        #expect(stalled != receiving)
        #expect(parentUpdates == 0)
    }
}
