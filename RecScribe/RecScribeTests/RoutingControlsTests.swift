import Foundation
import Testing
@testable import RecScribe

@MainActor struct RoutingControlsTests {
    @Test func mutedSummaryNamesOnlySelectedMutedSourcesAndRetainsDeviceIdentity() throws {
        let suite = "routing59-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let names = RoutingSourceNames(defaults: defaults)
        let levels = AudioLevels(defaults: defaults)
        names.remember([.init(uid: "mic", name: "MacBook Air Microphone", inputChannels: 1, sampleRate: 48000)])
        levels.set("system", .init(decibels: -9, muted: true))
        levels.set("input:mic", .init(muted: true))
        levels.set("input:removed", .init(muted: true))
        levels.set("master", .init(muted: true))
        let source = AudioSource.multiple(appBundleID: nil, inputs: [.init(deviceUID: "mic")])
        #expect(names.mutedSources(source, levels: levels, appName: { _ in nil }) == ["System audio", "MacBook Air Microphone"])
        names.remember([]) // Unplugging must not discard the known device name.
        #expect(RoutingSourceNames(defaults: defaults).input("mic") == "MacBook Air Microphone")
        levels.set("input:mic", .init(muted: false))
        #expect(names.mutedSources(source, levels: levels, appName: { _ in nil }) == ["System audio"])
        let onlyMic = AudioSource.inputsOnly([.init(deviceUID: "mic")])
        #expect(names.mutedSources(onlyMic, levels: levels, appName: { _ in nil }).isEmpty)
        levels.set("app:us.zoom", .init(muted: true))
        #expect(names.mutedSources(.app(bundleID: "us.zoom"), levels: levels, appName: { _ in "Zoom" }) == ["Zoom"])
        #expect(names.input("unknown").contains("unknown"))
        #expect(levels.level("system").decibels == -9)
        names.remember([.init(uid: "mic", name: "Renamed microphone", inputChannels: 1, sampleRate: 48000)])
        #expect(names.input("mic") == "Renamed microphone")
    }

    @Test func automaticAvailabilityKeepsMuteAndChannelChoicesAcrossReconnectAndRelaunch() throws {
        let suite = "routing59-auto-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let levels = AudioLevels(defaults: defaults)
        levels.set("input:mic", .init(decibels: -6, muted: true))
        let device = InputDeviceInfo(uid: "mic", name: "Mic", inputChannels: 2, sampleRate: 48000)
        let other = InputDeviceInfo(uid: "other", name: "Other", inputChannels: 1, sampleRate: 48000)
        let policy = AutomaticRoutingSources(defaults: defaults)
        let added = policy.selection(from: .systemAll, devices: [device, other])
        #expect(Set(added.inputSelections.map(\.deviceUID)) == ["mic", "other"])
        #expect(added.requiresScreenCapture)
        #expect(added.isMixed)
        var configured = added
        configured.inputs[0].routes = [] // Explicit disconnection from mix must also survive.
        let departed = policy.selection(from: configured, devices: [])
        #expect(departed.inputSelections.isEmpty)
        let reconnected = AutomaticRoutingSources(defaults: defaults).selection(from: departed, devices: [device, other])
        #expect(reconnected.inputSelections.first?.routes == [])
        #expect(AudioLevels(defaults: defaults).level("input:mic") == .init(decibels: -6, muted: true))
        let app = policy.selection(from: .app(bundleID: "us.zoom"), devices: [device])
        #expect(app.appBundleID == "us.zoom")
    }

    @Test func automaticSelectionDefersDuringCaptureAndRespectsManualMute() async throws {
        let suite = "routing59-gate-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let provider = MockAudioSourceProviding(selectedSource: .systemAll)
        let recorder = RecorderViewModel(controller: MockRecordingControlling(), permissions: MockPermissionProviding(.granted),
            clock: ManualClock(), audioSource: provider, defaults: defaults)
        let device = InputDeviceInfo(uid: "mic", name: "Mic", inputChannels: 1, sampleRate: 48000)
        recorder.audio.levels.set("input:mic", .init(muted: true))
        recorder.refreshAvailableRoutingSources([device])
        #expect(recorder.selectedSource.inputSelections.count == 1)
        #expect(recorder.audio.levels.level("input:mic").muted)
        await recorder.startRecording()
        recorder.refreshAvailableRoutingSources([])
        #expect(recorder.selectedSource.inputSelections.count == 1)
        await recorder.stopRecording()
    }
}
