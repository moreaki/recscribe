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
    @Test func workspaceShortcutsFollowSidebarOrder() {
        let destinations = StudioWorkspaceMode.allCases.map(\.window)
        #expect(destinations == [.studio, .live, .recordings, .routing, .settings])
        #expect(destinations.map(\.commandKey) == ["1", "2", "3", "4", "5"])
    }

    @Test func liveCloudCompletionAndLibraryRefreshKeepStudioContextUntilExplicitHandoff() async {
        let oldJob = URL(fileURLWithPath: "/synthetic/old-job")
        let oldSource = URL(fileURLWithPath: "/synthetic/old.recscribe.json")
        let newJob = URL(fileURLWithPath: "/synthetic/new-live-job")
        let newSource = URL(fileURLWithPath: "/synthetic/new.recscribe.json")
        var remembered: URL?
        let library = SessionLibrary(rememberJob: { job, _ in remembered = job })
        library.rememberOpenedTranscript(oldJob, source: oldSource)
        library.setRecording(true)
        library.acceptCloudTranscript(newJob, source: newSource)
        library.setRecording(false)
        #expect(library.latestJob == newJob)
        #expect(library.studioJob == oldJob && library.studioSource == oldSource)
        #expect(remembered == oldJob)
        library.forgetTranscript(newJob)
        #expect(library.studioJob == oldJob && library.studioSource == oldSource && remembered == oldJob)
        library.acceptCloudTranscript(newJob, source: newSource)
        library.openRecordingInStudio(newSource)
        #expect(library.studioJob == newJob && library.studioSource == newSource)
        #expect(remembered == newJob)
        let unprocessed = URL(fileURLWithPath: "/synthetic/unprocessed.recscribe.json")
        library.openRecordingInStudio(unprocessed)
        #expect(library.studioJob == nil && library.studioSource == unprocessed)
        #expect(remembered == nil) // Never display an older transcript under a new title.
        library.acceptCloudTranscript(newJob, source: newSource)
        #expect(library.studioJob == nil && library.studioSource == unprocessed)
        library.acceptCloudTranscript(newJob, source: unprocessed)
        #expect(library.studioJob == newJob && library.studioSource == unprocessed)
        #expect(remembered == newJob)
        await library.shutdown()
    }

    @Test func recordingSearchAndDateGroupsPreserveIdentityAcrossDayBoundaries() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(secondsFromGMT: 0))
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let today = calendar.startOfDay(for: now)
        func entry(_ name: String, _ offset: TimeInterval, title: String? = nil) -> SessionEntry {
            var session = RecordingSession(sampleRate: 48_000, channels: 1, channelMap: ["mic"], options: .init())
            session.startedAt = today.addingTimeInterval(offset); session.title = title
            return .init(id: URL(fileURLWithPath: "/synthetic/\(name).recscribe.json"), session: session)
        }
        let old = entry("old", -86_401), yesterday = entry("yesterday", -1)
        let first = entry("first", 0, title: "Café planning"), later = entry("later", 60)
        let future = entry("future", 86_400)
        let entries = [old, first, future, later, yesterday]
        let groups = RecordingLibraryProjection.groups(entries, now: now, calendar: calendar)
        #expect(groups.map(\.title) == ["Future dates", "Today", "Yesterday", "Earlier"])
        #expect(groups.flatMap(\.entries).map(\.id) == [future.id, later.id, first.id, yesterday.id, old.id])
        #expect(RecordingLibraryProjection.filtered(entries, query: "  CAFE  ").map(\.id) == [first.id])
        #expect(RecordingLibraryProjection.filtered(entries, query: "yesterday").map(\.id) == [yesterday.id])
        #expect(RecordingLibraryProjection.filtered(entries, query: " \n ").count == entries.count)
        let selection: Set<URL> = [first.id, old.id]
        let visible = Set(RecordingLibraryProjection.filtered(entries, query: "café").map(\.id))
        #expect(selection.subtracting(visible) == [old.id])
        #expect(selection.count == 2)
    }

    @Test(arguments: [false, true])
    func automaticLocalTranscriptionKeepsStudioUntilAnExplicitRequest(explicit: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let oldJob = root.appendingPathComponent("old-job")
        let oldSource = root.appendingPathComponent("old.recscribe.json")
        let newSource = root.appendingPathComponent("new.recscribe.json")
        var values = AppSettings.Values()
        values.autoTranscribe = true; values.aiEnabled = false; values.profile = .fast; values.processingLocation = .local
        values.whisperPath = root.appendingPathComponent("unavailable-whisper").path
        values.modelPath = root.appendingPathComponent("unavailable-model").path
        values.vadModelPath = ""
        let config = values
        var result = RecordingSession(sampleRate: 48_000, channels: 1, channelMap: ["mic"], options: .init())
        result.status = .completed
        let verified = result
        var remembered: URL?
        let library = SessionLibrary(settings: { config }, processSession: { _, _, _, _, _ in verified },
            readSessions: { _ in SessionSnapshot() }, rememberJob: { job, _ in remembered = job },
            jobsDirectory: root.appendingPathComponent("Jobs"))
        library.rememberOpenedTranscript(oldJob, source: oldSource)
        if explicit { library.transcribe(newSource) }
        else { library.enqueue(newSource) }
        await waitUntil("local transcription preflight finishes") { library.latestJob != nil && library.canDeleteRecording }
        // Deliberately missing tools stop before inference or any actual audio access.
        #expect(library.errorMessage != nil)
        #expect(library.latestSource == newSource)
        if explicit {
            #expect(library.studioJob == library.latestJob && library.studioSource == newSource)
        } else {
            #expect(library.studioJob == oldJob && library.studioSource == oldSource)
        }
        #expect(remembered == oldJob) // Failed work cannot replace the restorable document.
        await library.shutdown()
    }

    @Test func hiddenLibraryAndWindowTeardownKeepAppOwnedStartupRecoveryRunning() async throws {
        let suite = "recscribe-library-lifecycle-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let recorder = RecorderViewModel(controller: MockRecordingControlling(),
            permissions: MockPermissionProviding(.granted), clock: ManualClock(),
            audioSource: MockAudioSourceProviding(), defaults: defaults)
        let (snapshots, continuation) = AsyncStream<SessionSnapshot>.makeStream()
        defer { continuation.finish() }
        let calls = OSAllocatedUnfairLock(initialState: [URL]())
        var values = AppSettings.Values(); values.autoTranscribe = false
        let config = values
        let library = SessionLibrary(settings: { config }, processSession: { source, _, _, _, _ in
            calls.withLock { $0.append(source) }
            var session = RecordingSession(sampleRate: 48_000, channels: 1, channelMap: ["mic"], options: .init())
            session.status = .completed
            return session
        }, readSessions: { _ in
            for await snapshot in snapshots { try Task.checkCancellation(); return snapshot }
            return SessionSnapshot()
        })
        let source = URL(fileURLWithPath: "/synthetic/startup.recscribe.json")
        library.recoverUnfinalizedSessions(in: source.deletingLastPathComponent())
        #expect(library.refreshing)
        var appeared = false, disappeared = false
        let host = NSHostingView(rootView: AnyView(RecordingLibraryView(embeddedInStudio: true, isVisible: false)
            .environment(recorder).environment(library)
            .onAppear { appeared = true }.onDisappear { disappeared = true }))
        host.frame = NSRect(x: 0, y: 0, width: 1000, height: 700)
        let window = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host
        defer { window.contentView = nil; window.close() }
        window.orderFront(nil)
        host.layoutSubtreeIfNeeded()
        await waitUntil("hidden library mounted") { appeared }
        #expect(library.refreshing)
        host.rootView = AnyView(EmptyView())
        host.layoutSubtreeIfNeeded()
        await waitUntil("library removed with window content") { disappeared }
        #expect(library.refreshing)
        var unfinished = RecordingSession(sampleRate: 48_000, channels: 1, channelMap: ["mic"], options: .init())
        unfinished.status = .finalized
        continuation.yield(SessionSnapshot(entries: [.init(id: source, session: unfinished)]))
        continuation.finish()
        await waitUntil("startup recovery completes") { calls.withLock { $0 == [source] } && library.canDeleteRecording }
        #expect(calls.withLock { $0 } == [source])
        await library.shutdown()
    }

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
        for destination in [AppWindow.studio, .routing, .recordings, .settings, .live] {
            let item = NSMenuItem(title: "Localized command", action: #selector(WindowCommandTarget.open(_:)),
                                  keyEquivalent: String(destination.commandKey))
            item.target = target
            item.representedObject = destination.rawValue
            localizedFile.addItem(item)
        }
        for destination in [AppWindow.routing, .recordings, .settings, .studio, .live, .routing] {
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
        #expect(target.opened.count == 6)
    }

    @Test func destinationIsSelectedBeforeOpeningAndSurvivesWindowRecreation() {
        let navigation = StudioNavigation()
        for (destination, mode) in [(AppWindow.routing, StudioWorkspaceMode.routing),
                                    (.recordings, .recordings), (.settings, .settings), (.studio, .studio), (.live, .live)] {
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
