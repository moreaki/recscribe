import Foundation
import CoreAudio
import Testing
@testable import RecScribe

@MainActor struct RoutingControlsTests {
    @Test func discoveryExcludesGeneratedHelpersFromEitherAPIAndPreservesUserAggregates() {
        let uid = "CADefaultDeviceAggregate-67758-0"
        let helper = InputDeviceInfo(uid: uid, name: "Renamed internal helper", inputChannels: 1,
            transport: kAudioDeviceTransportTypeAggregate, aggregateMembers: ["mic"])
        let mic = InputDeviceInfo(uid: "mic", name: "MacBook Air Microphone", inputChannels: 1)
        // Even an identical display name must not hide a deliberately created aggregate.
        let aggregate = InputDeviceInfo(uid: "~:AMS2_Aggregate:0", name: uid, inputChannels: 4,
            sampleRate: 48_000, transport: kAudioDeviceTransportTypeAggregate, aggregateMembers: ["mic", "usb"])
        let virtual = InputDeviceInfo(uid: "teams", name: "Microsoft Teams Audio", inputChannels: 1,
            transport: kAudioDeviceTransportTypeVirtual)
        for discoveredHelper in [false, true] {
            for hardwareHelper in [false, true] where discoveredHelper || hardwareHelper {
                let discovered = [InputDeviceInfo(uid: mic.uid, name: mic.name),
                                  InputDeviceInfo(uid: aggregate.uid, name: aggregate.name)]
                    + (discoveredHelper ? [.init(uid: uid, name: uid)] : [])
                let hardware = [mic, aggregate, virtual] + (hardwareHelper ? [helper] : [])
                let result = InputDeviceEnumerator.mergedInputs(discovered: discovered, hardware: hardware)
                #expect(result == [mic, aggregate, virtual])
                #expect(result.first(where: { $0.uid == aggregate.uid })?.aggregateMembers == ["mic", "usb"])
            }
        }
        #expect(helper.isCoreAudioDefaultHelper)
        for uid in ["CADefaultDeviceAggregate-studio", "CADefaultDeviceAggregate-1", "CADefaultDeviceAggregate-1-",
                    "CADefaultDeviceAggregate--0", "CADefaultDeviceAggregate-1-0-custom", "my-CADefaultDeviceAggregate-1-0"] {
            #expect(!InputDeviceInfo(uid: uid, name: uid).isCoreAudioDefaultHelper)
        }
        #expect(InputDeviceInfo(uid: "CADefaultDeviceAggregate-79903-12", name: "Helper").isCoreAudioDefaultHelper)
    }

    @Test func oldHelperSelectionIsRemovedAndRealAggregateSettingsSurviveRediscovery() throws {
        let suite = "routing59-helper-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let helper = InputDeviceInfo(uid: "CADefaultDeviceAggregate-67758-0", name: "Internal", inputChannels: 1,
            transport: kAudioDeviceTransportTypeAggregate)
        let aggregate = InputDeviceInfo(uid: "studio-aggregate", name: "Studio aggregate", inputChannels: 4,
            transport: kAudioDeviceTransportTypeAggregate, aggregateMembers: ["usb", "mic"])
        let levels = AudioLevels(defaults: defaults)
        levels.set("input:" + aggregate.uid, .init(decibels: -9, muted: true))
        let configured = InputSelection(deviceUID: aggregate.uid, routes: [.init(channel: 3, placement: .right)])
        let old = AudioSource.multiple(appBundleID: nil, inputs: [InputSelection(device: helper), configured])
        let available = InputDeviceEnumerator.mergedInputs(discovered: [helper], hardware: [helper, aggregate])
        let policy = AutomaticRoutingSources(defaults: defaults)
        let selected = policy.selection(from: old, devices: available, levels: levels)
        #expect(selected.inputSelections == [configured])
        #expect(levels.level("input:" + aggregate.uid) == .init(decibels: -9, muted: true))
        let disconnected = policy.selection(from: selected, devices: [])
        let returned = AutomaticRoutingSources(defaults: defaults).selection(from: disconnected, devices: available, levels: levels)
        #expect(returned.inputSelections == [configured])
        #expect(returned.requiresScreenCapture)
    }

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
    @Test func firstAutomaticVirtualSelectionIsMutedButManualUnmuteIsNeverOverridden() throws {
        let suite = "routing59-virtual-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let levels = AudioLevels(defaults: defaults)
        let devices = [InputDeviceInfo(uid: "mic", name: "MacBook Air Microphone", inputChannels: 1),
                       InputDeviceInfo(uid: "teams", name: "Microsoft Teams Audio", inputChannels: 1, transport: kAudioDeviceTransportTypeVirtual),
                       InputDeviceInfo(uid: "squirrels", name: "Squirrels Audio", inputChannels: 2, transport: kAudioDeviceTransportTypeVirtual)]
        levels.set("system", .init(muted: true))
        let policy = AutomaticRoutingSources(defaults: defaults)
        let selected = policy.selection(from: .systemAll, devices: devices, levels: levels)
        #expect(selected.inputs.count == 3)
        #expect(!levels.level("input:mic").muted)
        #expect(levels.level("input:teams").muted && levels.level("input:squirrels").muted)
        levels.set("input:teams", .init(decibels: -9, muted: false))
        _ = AutomaticRoutingSources(defaults: defaults).selection(from: selected, devices: devices, levels: AudioLevels(defaults: defaults))
        #expect(AudioLevels(defaults: defaults).level("input:teams") == .init(decibels: -9, muted: false))
        #expect(levels.level("system").muted)
    }

    @Test func mutedVirtualInputsAllowMonitoringAndUnmutePausesListeningOnly() async throws {
        let suite = "routing59-monitor-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let levels = AudioLevels(defaults: defaults)
        levels.set("input:virtual", .init(muted: true))
        let monitor = CapturedAudioMonitor(defaults: defaults, captureLevels: levels,
            isLoopbackCheck: { $0 == "virtual" }, startEngineAction: { _, _, _ in })
        let source = AudioSource.multiple(appBundleID: nil, inputs: [.init(deviceUID: "virtual")])
        monitor.setEnabled(true, source: source)
        #expect(monitor.enabled && monitor.warning == nil)
        levels.set("input:virtual", .init(muted: false))
        await waitUntil("feedback-safe monitor pause") { !monitor.enabled }
        #expect(monitor.warning?.contains("recording continues") == true)
        #expect(!levels.level("input:virtual").muted) // Preserve the user's explicit choice.
        await monitor.stopAndWait()
    }

}
