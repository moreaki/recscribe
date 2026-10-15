import SwiftUI

/// An editor for the existing graph. Disclosure changes never write audio settings.
struct AudioRoutingView: View {
    @EnvironmentObject private var recorder: RecorderViewModel
    @Environment(\.dismissWindow) private var dismissWindow
    @ObservedObject private var levels = AudioLevels.shared
    @ObservedObject private var monitor = CapturedAudioMonitor.shared
    @ObservedObject private var monitorLevels = CapturedAudioMonitor.shared.levels
    @ObservedObject private var playbackLevels = PlaybackLevels.shared
    @State private var devices: [InputDeviceInfo] = []
    @State private var outputs: [AudioOutputDevice] = []
    @State private var systemOutputUID: String?
    @State private var apps: [RunningAppInfo] = []
    @State private var showApps = false
    @State private var loadingApps = false
    @State private var appError: String?
    @State private var expandedPanel: AudioRoutingPanel?
    @FocusState private var focusedPanel: AudioRoutingPanel?

    init(levels: AudioLevels = .shared, monitor: CapturedAudioMonitor = .shared,
         playbackLevels: PlaybackLevels = .shared, expandedPanel: AudioRoutingPanel? = nil) {
        _levels = ObservedObject(wrappedValue: levels)
        _monitor = ObservedObject(wrappedValue: monitor)
        _monitorLevels = ObservedObject(wrappedValue: monitor.levels)
        _playbackLevels = ObservedObject(wrappedValue: playbackLevels)
        _expandedPanel = State(initialValue: expandedPanel)
    }

    private var source: AudioSource { recorder.audioSource.selectedSource }
    private var inputs: [InputSelection] { source.inputSelections }
    private var editable: Bool { recorder.state.allowsCaptureSourceChange }
    private var eligible: [InputDeviceInfo] { devices.filter { (1...32).contains($0.inputChannels ?? 0) } }
    private var warnings: [String] { InputRouteSafety.warnings(inputs: inputs, devices: devices) }
    private var monitorState: String {
        monitor.enabled ? (recorder.isRecording ? "Listening" : "Armed · waiting for recording") : "Off"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            if source.kind != .multiple {
                legacySource
            } else {
                GeometryReader { geometry in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 18) {
                            if geometry.size.width >= 1040 {
                                HStack(alignment: .top, spacing: 12) {
                                    sourcesColumn.frame(maxWidth: .infinity)
                                    flowArrow
                                    mixColumn.frame(width: 250)
                                    flowArrow
                                    outputsColumn.frame(width: 280)
                                }
                            } else {
                                sourcesColumn
                                HStack(alignment: .top, spacing: 18) {
                                    mixColumn.frame(maxWidth: .infinity)
                                    flowArrow
                                    outputsColumn.frame(maxWidth: .infinity)
                                }
                            }
                        }.padding(20)
                    }
                }
                if recorder.permissionStatus != .granted || !warnings.isEmpty || monitor.warning != nil {
                    notices.padding(.horizontal, 20).padding(.vertical, 12)
                }
                Divider()
                footer
            }
        }
        .frame(minWidth: AppWindow.routing.minimumSize.width, minHeight: AppWindow.routing.minimumSize.height)
        .background(WorkspaceStyle.background).tint(WorkspaceStyle.blue).glassThemeAdaptingToContrast()
        .onExitCommand { collapsePanel() }
        .onDisappear { expandedPanel = nil; focusedPanel = nil }
        .onChange(of: source) { _, next in
            if next.kind != .multiple {
                expandedPanel = nil; focusedPanel = nil
            } else if case .input(let uid) = expandedPanel, !next.inputSelections.contains(where: { $0.deviceUID == uid }) {
                expandedPanel = nil; focusedPanel = .playback
            }
        }
        .task {
            while !Task.isCancelled {
                devices = recorder.audioSource.availableInputDevices()
                outputs = AudioDeviceControls.outputs()
                systemOutputUID = AudioDeviceControls.defaultOutputUID()
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            WorkspaceIcon(symbol: "point.3.connected.trianglepath.dotted", tint: WorkspaceStyle.mint)
            VStack(alignment: .leading, spacing: 3) {
                Text("Audio routing").font(.headline)
                Text(recorder.isRecording ? "Recording · faders stay live · sources and connections locked" : editable
                     ? "Select a source, mix or output to adjust it · not recording"
                     : "Preparing or finishing capture · sources and connections locked")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
            Button("Close") { dismissWindow(id: AppWindow.routing.rawValue) }
                .controlSize(.small)
        }.padding(.horizontal, 20).padding(.vertical, 16)
    }

    private var legacySource: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Build a mix from apps and inputs").font(.title3.bold())
            Text("Your current capture source stays selected until you enable this routing workspace. Each selected input keeps its own original recording alongside the stereo mix.")
            Button("Use multiple inputs + playback") {
                save(inputs.map { selected in
                    devices.first { $0.uid == selected.deviceUID }.map(InputSelection.init(device:)) ?? selected
                })
            }.buttonStyle(.borderedProminent).disabled(!editable)
            AudioMuteSummary(source: source)
            Spacer()
        }.padding(24)
    }

    private var sourcesColumn: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                columnTitle("Sources", symbol: "waveform")
                Spacer()
                Menu {
                    ForEach(eligible) { device in
                        Button(device.name, systemImage: inputs.contains { $0.deviceUID == device.uid } ? "checkmark" : "plus") {
                            save(inputs + [.init(device: device)])
                        }.disabled(inputs.contains { $0.deviceUID == device.uid } || inputs.count >= InputSelection.maximumDevices)
                    }
                    Divider()
                    Button("Select all available inputs") { save(eligible.map(InputSelection.init(device:))) }
                        .disabled(eligible.isEmpty || eligible.count > InputSelection.maximumDevices)
                    Button("Remove all inputs") { save([]) }.disabled(inputs.isEmpty)
                } label: { Label("Add input", systemImage: "plus") }
                    .controlSize(.small).disabled(!editable)
            }.padding(.bottom, 3)
            disclosureCard(.playback, title: playbackName, symbol: "app.connected.to.app.below.fill",
                           subtitle: source.appBundleID == nil ? "All system playback → L / R" : "Application playback → L / R",
                           value: gain(source.playbackLevelID), muted: levels.level(source.playbackLevelID).muted,
                           track: .playback) {
                playbackChooser
                SourceFader(id: source.playbackLevelID, title: "Playback gain", levels: levels, channels: 2, preservesSources: true)
            }
            ForEach(inputs) { input in
                inputCard(input, device: devices.first { $0.uid == input.deviceUID })
            }
            if inputs.isEmpty {
                Text("Playback only. Add an input to include your microphone or audio interface.")
                    .font(.caption).foregroundStyle(.secondary).padding(.top, 4)
            }
        }
    }

    private var playbackName: String {
        source.appBundleID.map { recorder.audioSource.knownAppName(forBundleID: $0) ?? $0 } ?? "System audio"
    }

    private var playbackChooser: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Button(loadingApps ? "Loading…" : "Choose application…") { loadApps() }
                    .disabled(!editable || loadingApps)
                    .popover(isPresented: $showApps) {
                        ScrollView {
                            VStack(alignment: .leading, spacing: 12) {
                                Text("Application playback").font(.headline)
                                if apps.isEmpty { Text("No audio-capable apps found. Play audio, then try again.").font(.caption) }
                                ForEach(apps) { app in
                                    Button(app.applicationName) {
                                        save(inputs, playback: app.bundleID, changePlayback: true); showApps = false
                                    }
                                }
                            }.padding().frame(minWidth: 240, alignment: .leading)
                        }.frame(maxHeight: 360)
                    }
                if source.appBundleID != nil {
                    Button("All system audio") { save(inputs, changePlayback: true) }.disabled(!editable)
                }
            }.controlSize(.small)
            if let appError { Text(appError).font(.caption).foregroundStyle(.orange) }
        }
    }

    private func inputCard(_ input: InputSelection, device: InputDeviceInfo?) -> some View {
        let name = device?.name ?? "Unavailable input"
        let id = "input:" + input.deviceUID
        let routeSummary = AudioRoutingSummary.routes(input, channelCount: device?.inputChannels)
        let warning = device == nil ? "Selected input unavailable"
            : (device?.mayLoopBack == true ? "Review loopback" : nil)
        return disclosureCard(.input(input.deviceUID), title: name, symbol: "mic.fill",
                              subtitle: "\(device?.kindLabel ?? "Missing device") · \(routeSummary)",
                              value: gain(id), muted: levels.level(id).muted, warning: warning,
                              track: .input(input.deviceUID)) {
            HStack(alignment: .top) {
                Text(device.map { "\($0.inputChannels ?? 0) native \($0.inputChannels == 1 ? "channel" : "channels") · \($0.sampleRate.map { String(format: "%.0f Hz", $0) } ?? "Rate unavailable")" } ?? input.deviceUID)
                    .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                Button("Remove", systemImage: "minus.circle") { save(inputs.filter { $0.deviceUID != input.deviceUID }) }
                    .labelStyle(.iconOnly).buttonStyle(.borderless).disabled(!editable)
                    .accessibilityLabel("Remove \(name)")
            }
            SourceFader(id: id, title: "Input gain", levels: levels,
                        channels: min(32, device?.inputChannels ?? 1), preservesSources: true, context: name)
            if let device {
                channelConnections(input, device: device).disabled(!editable)
                DeviceVolumeView(uid: input.deviceUID, input: true)
            }
        }
    }

    private func channelConnections(_ input: InputSelection, device: InputDeviceInfo) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Channel connections").font(.subheadline.weight(.medium))
            HStack {
                Text("Input channel").frame(maxWidth: .infinity, alignment: .leading)
                Text("L").frame(width: 36)
                Text("R").frame(width: 36)
            }.font(.caption).foregroundStyle(.secondary)
            ForEach(0..<min(32, device.inputChannels ?? 0), id: \.self) { channel in
                RoutingChannelRow(name: device.channelLabels.indices.contains(channel) ? device.channelLabels[channel] : "Channel \(channel + 1)",
                                  sourceName: device.name, channel: channel,
                                  placement: input.routes.first { $0.channel == channel }?.placement) { placement in
                    var next = input
                    next.routes.removeAll { $0.channel == channel }
                    if let placement { next.routes.append(.init(channel: channel, placement: placement)) }
                    save(inputs.map { $0.deviceUID == next.deviceUID ? next : $0 })
                }
            }
            Text("Connect to L, R, both (center), or neither. All native channels stay in the original track.")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }

    private var mixColumn: some View {
        VStack(alignment: .leading, spacing: 8) {
            columnTitle("Recording mix", symbol: "slider.horizontal.3").padding(.bottom, 3)
            disclosureCard(.mix, title: "Stereo recording mix", symbol: "slider.horizontal.3",
                           subtitle: "L / R · 48 kHz WAV", value: gain("master"), muted: levels.level("master").muted) {
                HStack(spacing: 8) { outputPort("1 · Left"); outputPort("2 · Right") }
                SourceFader(id: "master", title: "Master gain", levels: levels, channels: 0, preservesSources: true)
                Text("Selected channels are averaged per side, then across sources for headroom. Gain above 0 dB can clip the mix.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Text("\(inputs.count + 1) original source \(inputs.count == 0 ? "track" : "tracks")")
                .font(.caption).foregroundStyle(.secondary).padding(.top, 4)
                .help("Playback and every selected input keep separate files at unity gain, including channels disconnected from the mix. Selected sources can still fail; check capture health while recording.")
            Text("Separate files · unity gain")
                .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var outputsColumn: some View {
        VStack(alignment: .leading, spacing: 8) {
            columnTitle("Outputs", symbol: "headphones").padding(.bottom, 3)
            disclosureCard(.monitor, title: "Headphone monitor", symbol: "headphones",
                           subtitle: "\(monitorState) · \(output(monitorLevels.value))", value: volume(monitorLevels.value),
                           muted: monitorLevels.value.muted, warning: outputWarning(monitorLevels.value)) {
                Toggle("Listen to recording mix", isOn: Binding(get: { monitor.enabled }, set: { monitor.setEnabled($0, source: source) }))
                    .toggleStyle(.switch)
                ListeningControls(levels: monitor.levels, title: "Live monitor output")
                Text("Use headphones. Listening volume is independent of the saved recording mix. Monitoring turns off after each take.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            disclosureCard(.recordingPlayback, title: "Recording playback", symbol: "play.circle",
                           subtitle: output(playbackLevels.value), value: volume(playbackLevels.value),
                           muted: playbackLevels.value.muted, warning: outputWarning(playbackLevels.value)) {
                ListeningControls(levels: playbackLevels, title: "Playback output")
                Text("Changes what you hear when playing saved recordings. The recorded audio stays unchanged.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var notices: some View {
        VStack(alignment: .leading, spacing: 10) {
            if recorder.permissionStatus != .granted {
                Label("Screen & System Audio Recording permission is required for playback capture. Review permissions in the recording panel.", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            }
            if !warnings.isEmpty {
                DisclosureGroup {
                    ForEach(warnings, id: \.self) { Text($0).foregroundStyle(.secondary) }
                } label: {
                    Label("Review possible loopback · \(warnings.count) \(warnings.count == 1 ? "route warning" : "route warnings")", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }
                Toggle("Include these possible duplicate / loopback routes", isOn: Binding(get: {
                    if case .multiple(_, _, let allowed) = source { return allowed }; return false
                }, set: { save(inputs, acknowledge: $0) })).disabled(!editable)
            }
            if let warning = monitor.warning {
                Label(warning, systemImage: "headphones").foregroundStyle(.orange)
            }
        }.font(.caption).fixedSize(horizontal: false, vertical: true)
    }

    private var footer: some View {
        HStack(alignment: .top, spacing: 16) {
            Text("Connections and faders affect the mix. Original source tracks stay at unity gain.")
            Spacer(minLength: 0)
            Text("Monitor: \(monitorState) · Audio stays on your Mac")
        }.font(.caption2).foregroundStyle(.secondary).padding(.horizontal, 20).padding(.vertical, 12)
    }

    private func disclosureCard<Details: View>(_ panel: AudioRoutingPanel, title: String, symbol: String,
                                               subtitle: String, value: String, muted: Bool = false,
                                               warning: String? = nil, track: CaptureTrack? = nil,
                                               @ViewBuilder details: () -> Details) -> some View {
        let expanded = expandedPanel == panel
        return VStack(alignment: .leading, spacing: 0) {
            Button {
                expandedPanel = expanded ? nil : panel
                focusedPanel = panel
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: symbol).foregroundStyle(.secondary).frame(width: 18)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(title).font(.callout.weight(.medium)).foregroundStyle(.primary)
                        Text(subtitle).font(.caption2).foregroundStyle(.secondary)
                        if let warning { Text(warning).font(.caption2).foregroundStyle(.orange) }
                        if muted { AudioMuteBadge(title: panel == .monitor || panel == .recordingPlayback ? "Output muted" : "Muted in mix") }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                    Text(value).font(.caption).monospacedDigit().foregroundStyle(.secondary)
                    Image(systemName: expanded ? "chevron.up" : "chevron.down").font(.caption2).foregroundStyle(.secondary)
                }.padding(12).contentShape(Rectangle())
            }.buttonStyle(.plain).focused($focusedPanel, equals: panel)
                .accessibilityLabel(title)
                .accessibilityValue("\(expanded ? "Expanded" : "Collapsed"), \(subtitle), \(value)\(muted ? ", muted" : "")\(warning.map { ", \($0)" } ?? "")")
                .accessibilityHint("\(expanded ? "Hide" : "Show") controls. Escape collapses the open controls.")
            if let track { sourceMeter(track).padding(.horizontal, 12) }
            if expanded {
                VStack(alignment: .leading, spacing: 12) {
                    Divider()
                    details()
                    Button("Done") { collapsePanel() }.controlSize(.small)
                        .accessibilityLabel("Collapse \(title) controls")
                }.padding(.horizontal, 12).padding(.bottom, 12)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(WorkspaceStyle.panel, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(expanded ? WorkspaceStyle.blue : muted || warning != nil ? Color.orange.opacity(0.6) : WorkspaceStyle.border))
    }

    private func collapsePanel() {
        guard let selected = expandedPanel else { return }
        expandedPanel = nil; focusedPanel = selected
    }
    private func gain(_ id: String) -> String { String(format: "%+.1f dB", levels.level(id).decibels) }
    private func volume(_ level: ListeningLevel) -> String { "\(Int((level.volume * 100).rounded()))%" }
    private func output(_ level: ListeningLevel) -> String { AudioRoutingSummary.output(level, devices: outputs, systemUID: systemOutputUID) }
    private func outputWarning(_ level: ListeningLevel) -> String? {
        if let uid = level.outputUID, !outputs.contains(where: { $0.uid == uid }) { return "Selected output unavailable" }
        return level.volume == 0 && !level.muted ? "Output volume is 0%" : nil
    }
    private var flowArrow: some View {
        Image(systemName: "arrow.right").font(.callout).foregroundStyle(WorkspaceStyle.mint)
            .padding(.top, 48).accessibilityHidden(true)
    }
    private func columnTitle(_ title: String, symbol: String) -> some View {
        Label(title, systemImage: symbol).font(.caption.weight(.medium)).foregroundStyle(.secondary)
            .frame(minHeight: 22)
    }
    private func outputPort(_ title: String) -> some View {
        Text(title).font(.caption.monospaced().bold()).frame(maxWidth: .infinity).padding(.vertical, 10)
            .background(WorkspaceStyle.mint.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
    }
    @ViewBuilder private func sourceMeter(_ track: CaptureTrack) -> some View {
        if recorder.isRecording, let item = recorder.sourceHealth.first(where: { $0.id == track.rawValue }) {
            VStack(alignment: .leading, spacing: 4) {
                ProgressView(value: Double(min(1, item.health.peak))).accessibilityLabel("\(item.name) raw input level")
                let status = item.health.status(at: recorder.healthTime)
                Text(status.label).foregroundStyle([.noData, .stalled, .writeStalled, .failed].contains(status) ? Color.orange : Color.secondary)
                if let failure = item.health.failureMessage { Text(failure).foregroundStyle(.orange) }
                if item.health.clipped { Text("Clipping detected · reduce recording gain").foregroundStyle(.orange) }
            }.font(.caption2).padding(.bottom, 10)
        }
    }
    private func save(_ inputs: [InputSelection], acknowledge: Bool = false, playback: String? = nil, changePlayback: Bool = false) {
        guard editable else { return }
        recorder.setCaptureSource(.multiple(appBundleID: changePlayback ? playback : source.appBundleID, inputs: inputs, allowDuplicateRoutes: acknowledge))
    }
    private func loadApps() {
        guard editable, !loadingApps else { return }
        guard recorder.permissionStatus == .granted else {
            appError = "Allow Screen & System Audio Recording in System Settings before choosing an application."; return
        }
        loadingApps = true; appError = nil
        Task { @MainActor in
            defer { loadingApps = false }
            do { apps = try await recorder.audioSource.availableApps(); showApps = true }
            catch { appError = error.localizedDescription }
        }
    }
}

private struct RoutingChannelRow: View {
    let name: String
    let sourceName: String
    let channel: Int
    let placement: InputMixPlacement?
    let change: (InputMixPlacement?) -> Void

    private var left: Bool { placement == .left || placement == .center }
    private var right: Bool { placement == .right || placement == .center }
    var body: some View {
        HStack(spacing: 8) {
            Text(name).font(.caption).frame(maxWidth: .infinity, alignment: .leading)
            connection("L", connected: left) { update(left: !left, right: right) }
            connection("R", connected: right) { update(left: left, right: !right) }
        }
    }
    private func connection(_ side: String, connected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: connected ? "circle.inset.filled" : "circle")
                .foregroundStyle(connected ? WorkspaceStyle.mint : Color.secondary)
                .frame(width: 36, height: 28)
                .background(connected ? WorkspaceStyle.mint.opacity(0.12) : Color.clear, in: RoundedRectangle(cornerRadius: 6))
        }.buttonStyle(.plain)
            .accessibilityLabel("\(sourceName) channel \(channel + 1) to \(side == "L" ? "left" : "right")")
            .accessibilityValue(connected ? "Connected" : "Disconnected")
            .help("\(connected ? "Disconnect from" : "Connect to") \(side == "L" ? "left" : "right") mix channel")
    }
    private func update(left: Bool, right: Bool) {
        change(left && right ? .center : left ? .left : right ? .right : nil)
    }
}
