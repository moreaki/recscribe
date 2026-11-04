import os
import Observation
import AppKit
import Combine
import SwiftUI
import Testing
@testable import RecScribe

@MainActor
@Suite(.serialized)
struct WorkspaceRegressionTests {
    @Test func observationEffectsCoalesceLatestValueAndStopAfterCancellation() async throws {
        let model = RecorderTelemetry()
        var values: [TimeInterval] = []
        let subscription = ObservationSubscription(read: { model.duration }) { values.append($0) }
        model.waveformSamples = [0.5]
        model.duration = 1
        model.duration = 2
        for _ in 0..<50 where values.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        #expect(values == [2])
        model.duration = 3 // An already queued callback must also respect cancel.
        subscription.cancel()
        try await Task.sleep(for: .milliseconds(20))
        #expect(values == [2])
    }
    @Test func startupAndShutdownAreInstalledWithoutAnyStudioView() async throws {
        let suite = "recscribe-startup-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        let oldAppearance = NSApp.appearance
        defer {
            defaults.removePersistentDomain(forName: suite)
            NSApp.appearance = oldAppearance
        }
        let services = AppServices(defaults: defaults, supportDirectory: root)
        let delegate = AppDelegate(services: services)
        #expect(services.recorder.audio === services.audio)
        #expect(services.recorder.audioTest?.playback.levels === services.audio.playbackLevels)
        #expect(services.menuBarController == nil)
        #expect(services.recorder.visibleWindowCount == 0)
        let launch = Notification(name: NSApplication.willFinishLaunchingNotification)
        delegate.applicationWillFinishLaunching(launch)
        let firstController = try #require(services.menuBarController)
        delegate.applicationWillFinishLaunching(launch)
        #expect(services.menuBarController === firstController)
        #expect(services.recorder.visibleWindowCount == 0)
        #expect(!delegate.applicationShouldTerminateAfterLastWindowClosed(NSApp))

        var replies = 0
        let response = delegate.requestTermination { approved in
            #expect(approved)
            replies += 1
        }
        #expect(response == .terminateLater)
        for _ in 0..<100 where replies == 0 { try await Task.sleep(for: .milliseconds(10)) }
        #expect(replies == 1)
        #expect(services.menuBarController == nil)
        #expect(!services.library.canDeleteRecording) // Default shutdown reached the service graph.
        #expect(services.recorder.visibleWindowCount == 0)
    }

    @Test func repeatedQuitWaitsForCleanupAndRepliesOnlyOnce() async throws {
        let suite = "recscribe-quit-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer {
            defaults.removePersistentDomain(forName: suite)
        }
        let services = AppServices(defaults: defaults,
            supportDirectory: FileManager.default.temporaryDirectory.appendingPathComponent(suite))
        let (stream, continuation) = AsyncStream<Void>.makeStream()
        defer { continuation.finish() }
        var preparations = 0
        var replies = 0
        let delegate = AppDelegate(services: services, prepareForTermination: {
            preparations += 1
            for await _ in stream { break }
            await services.shutdown()
        })
        #expect(delegate.requestTermination { _ in replies += 1 } == .terminateLater)
        #expect(delegate.requestTermination { _ in Issue.record("Duplicate Quit must not create another reply") } == .terminateLater)
        for _ in 0..<100 where preparations == 0 { try await Task.sleep(for: .milliseconds(10)) }
        #expect(preparations == 1)
        #expect(replies == 0)
        #expect(services.library.canDeleteRecording)
        continuation.yield(())
        continuation.finish()
        for _ in 0..<100 where replies == 0 { try await Task.sleep(for: .milliseconds(10)) }
        #expect(replies == 1)
        #expect(!services.library.canDeleteRecording)
    }

    @Test func nativeWindowCommandsWorkWithoutAStudioOrCapturedEnvironment() {
        let target = WindowCommandTarget()
        let menu = NSMenu()
        let localizedFile = NSMenu()
        localizedFile.autoenablesItems = false
        let parent = NSMenuItem(title: "Localized menu title", action: nil, keyEquivalent: "")
        parent.submenu = localizedFile
        menu.addItem(parent)
        for destination in [AppWindow.studio, .routing, .recordings, .settings] {
            let item = NSMenuItem(title: "Localized command", action: #selector(WindowCommandTarget.open(_:)),
                                  keyEquivalent: String(destination.commandKey))
            item.target = target
            item.representedObject = destination.rawValue
            localizedFile.addItem(item)
        }
        for destination in [AppWindow.routing, .recordings, .settings, .studio, .routing] {
            #expect(AppWindow.performOpenCommand(destination, in: menu))
            #expect(target.opened.last == destination)
            if destination == .settings { #expect(target.navigation.mode == .settings) }
        }
        #expect(target.navigation.mode == .routing)
        let studioCommand = localizedFile.items[0]
        studioCommand.isEnabled = false
        #expect(!AppWindow.performOpenCommand(.studio, in: menu))
        studioCommand.isEnabled = true
        studioCommand.keyEquivalentModifierMask = [.command, .shift]
        #expect(!AppWindow.performOpenCommand(.studio, in: menu))
        studioCommand.keyEquivalentModifierMask = .command
        studioCommand.isHidden = true
        #expect(!AppWindow.performOpenCommand(.studio, in: menu))
        #expect(!AppWindow.performOpenCommand(.studio, in: NSMenu()))
        #expect(target.opened.count == 5)
    }

    @Test func destinationIsSelectedBeforeOpeningAndSurvivesWindowRecreation() {
        let navigation = StudioNavigation()
        for (destination, mode) in [(AppWindow.routing, StudioWorkspaceMode.routing),
                                    (.recordings, .recordings), (.settings, .settings), (.studio, .studio)] {
            // No Studio view/subscriber exists when a command or menu action opens it.
            navigation.open(destination) { sceneID in
                #expect(sceneID == AppWindow.studio.rawValue)
                #expect(navigation.mode == mode)
            }
            // Closing a scene does not discard app-owned selection.
            let root = StudioView().environment(\.studioNavigation, navigation)
            withExtendedLifetime(root) { #expect(navigation.mode == mode) }
        }
    }

    @Test func routingMeterRepaintsOnTelemetryWithoutInvalidatingRecorder() async throws {
        let suite = "recscribe-meter-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let recorder = RecorderViewModel(controller: MockRecordingControlling(),
            permissions: MockPermissionProviding(.granted), clock: ManualClock(),
            audioSource: MockAudioSourceProviding(), defaults: defaults)
        let parentUpdates = OSAllocatedUnfairLock(initialState: 0)
        withObservationTracking {
            _ = recorder.state
            _ = recorder.statusText
            _ = recorder.canRecord
        } onChange: { parentUpdates.withLock { $0 += 1 } }
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
        #expect(parentUpdates.withLock { $0 } == 0)
    }
}

@MainActor
private final class WindowCommandTarget: NSObject {
    let navigation = StudioNavigation()
    var opened: [AppWindow] = []

    @objc func open(_ sender: NSMenuItem) {
        guard let value = sender.representedObject as? String, let destination = AppWindow(rawValue: value) else { return }
        opened.append(destination)
        navigation.open(destination) { _ in }
    }
}
