import SwiftUI

/// An editor for the existing graph. Disclosure changes never write audio settings.
struct AudioRoutingView: View {
    @EnvironmentObject private var recorder: RecorderViewModel
    @Environment(\.dismissWindow) private var dismissWindow
    @ObservedObject private var levels = AudioLevels.shared
    @ObservedObject private var monitor = CapturedAudioMonitor.shared
    @ObservedObject private var monitorLevels = CapturedAudioMonitor.shared.levels
    @ObservedObject private var playbackLevels = PlaybackLevels.shared
    @ObservedObject private var hardwareObserver = AudioHardwareObserver.shared
    @State private var devices: [InputDeviceInfo] = []
    @State private var outputs: [AudioOutputDevice] = []
    @State private var systemOutputUID: String?
    @State private var apps: [RunningAppInfo] = []
    @State private var showApps = false
    @State private var loadingApps = false
    @State private var appError: String?
    @State private var expandedPanel: AudioRoutingPanel?
    @FocusState private var focusedPanel: AudioRoutingPanel?
    private let embeddedInStudio: Bool
    private let onClose: (() -> Void)?

    init(levels: AudioLevels = .shared, monitor: CapturedAudioMonitor = .shared,
         playbackLevels: PlaybackLevels = .shared, hardwareObserver: AudioHardwareObserver = .shared,
         expandedPanel: AudioRoutingPanel? = nil,
         embeddedInStudio: Bool = false,
         onClose: (() -> Void)? = nil) {
        _levels = ObservedObject(wrappedValue: levels)
        _monitor = ObservedObject(wrappedValue: monitor)
        _monitorLevels = ObservedObject(wrappedValue: monitor.levels)
        _playbackLevels = ObservedObject(wrappedValue: playbackLevels)
        _hardwareObserver = ObservedObject(wrappedValue: hardwareObserver)
        _expandedPanel = State(initialValue: expandedPanel)
        self.embeddedInStudio = embeddedInStudio
        self.onClose = onClose
    }

    private var source: AudioSource { recorder.audioSource.selectedSource }
    private var inputs: [InputSelection] { source.inputSelections }
    private var editable: Bool { recorder.allowsCaptureSourceChange }
    private var eligible: [InputDeviceInfo] { devices.filter { (1...32).contains($0.inputChannels ?? 0) } }
    private var warnings: [String] { InputRouteSafety.warnings(inputs: inputs, devices: devices) }
    private var monitorState: String {
        monitor.enabled ? (recorder.isRecording || recorder.audioTest?.isCapturing == true ? "Listening" : "Armed · waiting for capture") : "Off"
    }
    private var captureHint: String {
        if recorder.audioTest?.locksSources == true { return "Audio test · sources and connections locked · adjust gain and listening output below" }
        if recorder.isRecording { return "Recording · faders stay live · sources and connections locked" }
        return editable ? "Select a source, mix or output to adjust it · not recording" : "Preparing or finishing capture · sources and connections locked"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            if let test = recorder.audioTest {
                AudioTestControls(test: test, enabled: recorder.state.allowsCaptureSourceChange && !recorder.installLocationBlocksRecording)
                Divider()
            }
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
            if (source.requiresScreenCapture && recorder.permissionStatus != .granted) || !warnings.isEmpty || monitor.warning != nil || recorder.hasInterruptedSource {
                notices.padding(.horizontal, 20).padding(.vertical, 12)
            }
            Divider()
            footer
        }
        .frame(
            minWidth: embeddedInStudio ? 0 : AppWindow.routing.minimumSize.width,
            minHeight: embeddedInStudio ? 0 : AppWindow.routing.minimumSize.height
        )
        .background(WorkspaceStyle.background).tint(WorkspaceStyle.blue).glassThemeAdaptingToContrast()
        .onExitCommand { collapsePanel() }
        .onAppear {
            recorder.audioTest?.opened()
            refreshHardware()
        }
        .onDisappear {
            expandedPanel = nil; focusedPanel = nil
            Task { await recorder.audioTest?.close() }
        }
        .onChange(of: source) { _, next in
            if case .input(let uid) = expandedPanel, !next.inputSelections.contains(where: { $0.deviceUID == uid }) {
                expandedPanel = nil; focusedPanel = .playback
            }
        }
        .onChange(of: hardwareObserver.revision) { _, _ in
            refreshHardware()
        }
    }

    private func refreshHardware() {
        devices = recorder.audioSource.availableInputDevices()
        outputs = hardwareObserver.outputDevices
        systemOutputUID = hardwareObserver.defaultOutputUID
    }

    private var header: some View {
        HStack(spacing: 12) {
            WorkspaceIcon(symbol: "point.3.connected.trianglepath.dotted", tint: WorkspaceStyle.mint)
            VStack(alignment: .leading, spacing: 3) {
                Text("Audio routing").font(.headline)
                Text(captureHint)
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
            Button(embeddedInStudio ? "Back to Studio" : "Close") {
                if let onClose {
                    onClose()
                } else {
                    dismissWindow(id: AppWindow.routing.rawValue)
                }
            }
            .controlSize(.small)
        }.padding(.horizontal, 20).padding(.vertical, 16)
    }

    private var sourcesColumn: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                columnTitle("Sources", symbol: "waveform")
                Spacer()
                Menu {
                    if !source.requiresScreenCapture {
                        Button("Include system playback", systemImage: "speaker.wave.2") {
                            save(inputs, playbackState: .systemAll)
                        }
                        Divider()
                    }
                    ForEach(eligible) { device in
                        Button(device.name, systemImage: inputs.contains { $0.deviceUID == device.uid } ? "checkmark" : "plus") {
                            save(inputs + [.init(device: device)])
                        }.disabled(inputs.contains { $0.deviceUID == device.uid } || inputs.count >= InputSelection.maximumDevices)
                    }
                    Divider()
                    Button("Select all available inputs") { save(eligible.map(InputSelection.init(device:))) }
                        .disabled(eligible.isEmpty || eligible.count > InputSelection.maximumDevices)
                    Button("Remove all inputs") { save([]) }.disabled(inputs.isEmpty || !source.requiresScreenCapture)
                } label: { Label("Add input", systemImage: "plus") }
                    .controlSize(.small).disabled(!editable)
            }.padding(.bottom, 3)
            disclosureCard(.playback, title: playbackName, symbol: "app.connected.to.app.below.fill",
                           subtitle: !source.requiresScreenCapture ? "Playback excluded · inputs only" : (source.appBundleID == nil ? "All system playback → L / R" : "Application playback → L / R"),
                           value: source.requiresScreenCapture ? gain(source.playbackLevelID) : "Off",
                           muted: source.requiresScreenCapture && levels.level(source.playbackLevelID).muted,
                           track: source.requiresScreenCapture ? .playback : nil) {
                playbackChooser
                if source.requiresScreenCapture {
                    SourceFader(id: source.playbackLevelID, title: "Playback gain", levels: levels, channels: 2, preservesSources: true)
                    if let test = recorder.audioTest {
                        DisclosureGroup("Live channel levels") {
                            AudioTestSourceMeterView(test: test, track: .playback, muted: levels.level(source.playbackLevelID).muted, channels: true)
                        }.font(.caption)
                    }
                }
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
        guard source.requiresScreenCapture else { return "Playback off" }
        return source.appBundleID.map { recorder.audioSource.knownAppName(forBundleID: $0) ?? $0 } ?? "System audio"
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
                                if apps.isEmpty { Text("No open applications found.").font(.caption) }
                                ForEach(apps) { app in
                                    Button {
                                        save(inputs, playbackState: .app(bundleID: app.bundleID)); showApps = false
                                    } label: {
                                        HStack {
                                            Text(app.applicationName)
                                            if app.isAudioActive {
                                                Spacer(minLength: 8)
                                                Text("Playing audio")
                                                    .font(.caption2)
                                                    .foregroundStyle(WorkspaceStyle.mint)
                                            }
                                        }
                                    }
                                }
                            }.padding().frame(minWidth: 240, alignment: .leading)
                        }.frame(maxHeight: 360)
                    }
                if source.appBundleID != nil || !source.requiresScreenCapture {
                    Button("All system audio") { save(inputs, playbackState: .systemAll) }.disabled(!editable)
                }
                if source.requiresScreenCapture && !inputs.isEmpty {
                    Button("Exclude playback") { save(inputs, playbackState: AudioSource.Playback.none) }.disabled(!editable)
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
            if let test = recorder.audioTest {
                DisclosureGroup("Live channel levels") {
                    AudioTestSourceMeterView(test: test, track: .input(input.deviceUID), muted: levels.level(id).muted, channels: true)
                }.font(.caption)
            }
            if let device {
                channelConnections(input, device: device).disabled(!editable)
                DeviceVolumeView(uid: input.deviceUID, input: true, hardwareObserver: hardwareObserver)
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
            Text(recorder.audioTest?.state == .testing ? "\(inputs.count + 1) selected source routes" : "\(inputs.count + 1) original source \(inputs.count == 0 ? "track" : "tracks")")
                .font(.caption).foregroundStyle(.secondary).padding(.top, 4)
                .help("Playback and every selected input keep separate files at unity gain, including channels disconnected from the mix. Selected sources can still fail; check capture health while recording.")
            Text(recorder.audioTest?.state == .testing ? "Preview only · no files saved" : "Separate files · unity gain")
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
                ListeningControls(levels: monitor.levels, title: "Live monitor output", hardwareObserver: hardwareObserver)
                Text("Use headphones. Listening volume is independent of the saved recording mix. Monitoring turns off after each take.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            disclosureCard(.recordingPlayback, title: "Recording playback", symbol: "play.circle",
                           subtitle: output(playbackLevels.value), value: volume(playbackLevels.value),
                           muted: playbackLevels.value.muted, warning: outputWarning(playbackLevels.value)) {
                ListeningControls(levels: playbackLevels, title: "Playback output", hardwareObserver: hardwareObserver)
                Text("Changes what you hear when playing saved recordings. The recorded audio stays unchanged.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var notices: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let summary = recorder.interruptedSourceSummary {
                HStack(spacing: 10) {
                    Label(summary, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Spacer(minLength: 8)
                    Button("Stop & start new take") {
                        Task { await recorder.stopAndStartNewTake() }
                    }
                    .controlSize(.small)
                }
            }
            if source.requiresScreenCapture && recorder.permissionStatus != .granted {
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
                    source.allowDuplicateRoutes
                }, set: { save(inputs, acknowledge: $0) })).disabled(!editable)
            }
            if let warning = monitor.warning {
                Label(warning, systemImage: "headphones").foregroundStyle(.orange)
            }
        }.font(.caption).fixedSize(horizontal: false, vertical: true)
    }

    private var footer: some View {
        HStack(alignment: .top, spacing: 16) {
            Text(recorder.audioTest?.state == .testing ? "Preview only · no files saved. Stop the test before changing sources or channel connections." : "Connections and faders affect the mix. Original source tracks stay at unity gain.")
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
            if panel == .mix, let test = recorder.audioTest { AudioTestMixMeterView(test: test).padding(.horizontal, 12) }
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
        if let test = recorder.audioTest, !test.health.isEmpty {
            AudioTestSourceMeterView(test: test, track: track,
                muted: levels.level(track == .playback ? source.playbackLevelID : inputs.first(where: { CaptureTrack.input($0.deviceUID) == track }).map { "input:" + $0.deviceUID } ?? "").muted)
        } else if recorder.isRecording, let item = recorder.sourceHealth.first(where: { $0.id == track.rawValue }) {
            VStack(alignment: .leading, spacing: 4) {
                ProgressView(value: Double(min(1, item.health.peak))).accessibilityLabel("\(item.name) raw input level")
                let status = item.health.status(at: recorder.healthTime)
                Text(status.label).foregroundStyle([.noData, .stalled, .writeStalled, .failed].contains(status) ? Color.orange : Color.secondary)
                if let failure = item.health.failureMessage { Text(failure).foregroundStyle(.orange) }
                if item.health.clipped { Text("Clipping detected · reduce recording gain").foregroundStyle(.orange) }
            }.font(.caption2).padding(.bottom, 10)
        }
    }
    static func makeUpdatedSource(
        from current: AudioSource,
        inputs: [InputSelection],
        acknowledge: Bool? = nil,
        playbackState: AudioSource.Playback? = nil
    ) -> AudioSource {
        let nextPlayback = playbackState ?? current.playback
        let routeGraphChanged = nextPlayback != current.playback || inputs != current.inputs
        let nextAck = acknowledge ?? (routeGraphChanged ? false : current.allowDuplicateRoutes)
        return AudioSource(
            playback: nextPlayback,
            inputs: inputs,
            allowDuplicateRoutes: nextAck,
            usesMultiInputRouting: nextPlayback != .none || inputs.count != 1 || nextAck || inputs.contains(where: \.hasCustomRoutes)
        )
    }
    private func save(_ inputs: [InputSelection], acknowledge: Bool? = nil, playbackState: AudioSource.Playback? = nil) {
        guard editable else { return }
        recorder.setCaptureSource(Self.makeUpdatedSource(
            from: source,
            inputs: inputs,
            acknowledge: acknowledge,
            playbackState: playbackState
        ))
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


/// Disclosure identity is independent of the capture selection and audio settings.
enum AudioRoutingPanel: Hashable {
    case playback, input(String), mix, monitor, recordingPlayback
}

nonisolated enum AudioRoutingSummary {
    static func routes(_ input: InputSelection, channelCount: Int?) -> String {
        let active = channelCount.map { count in input.routes.filter { (0..<count).contains($0.channel) } } ?? input.routes
        let left = active.filter { $0.placement != .right }.count
        let right = active.filter { $0.placement != .left }.count
        if left == 0 && right == 0 { return "Not connected to mix · original track retained" }
        let destination = left > 0 && right > 0 ? "L + R" : left > 0 ? "Left only" : "Right only"
        let count = active.count
        return "\(count) \(count == 1 ? "channel" : "channels") → \(destination)"
    }

    static func output(_ level: ListeningLevel, devices: [AudioOutputDevice], systemUID: String?) -> String {
        let system = devices.first { $0.uid == systemUID }?.name ?? "system output"
        if let uid = level.outputUID {
            return devices.first { $0.uid == uid }?.name ?? "Output unavailable · using \(system)"
        }
        return "System · \(system)"
    }
}

/// Compact entry point shared by the Studio, menu-bar popover and Settings.
struct MultipleInputsView: View {
    @ObservedObject var recorder: RecorderViewModel
    @Environment(\.openWindow) private var openWindow
    private var source: AudioSource { recorder.audioSource.selectedSource }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button("Audio routing…", systemImage: "point.3.connected.trianglepath.dotted") {
                NSApp.activate(ignoringOtherApps: true)
                AppWindow.open(.routing, using: openWindow)
            }
            if source.kind == .multiple {
                let count = source.inputSelections.count
                Text("Playback + \(count) \(count == 1 ? "input" : "inputs") → stereo recording mix")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Text("Connect apps and inputs, adjust channels, and choose a monitor output.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            AudioMuteSummary(source: source)
            if let test = recorder.audioTest, test.locksSources {
                Label("Audio test active · start recording to end the test and begin a take", systemImage: "waveform.circle")
                    .font(.caption).foregroundStyle(WorkspaceStyle.mint)
            }
        }.font(.callout)
    }
}

struct CaptureHealthView: View {
    @ObservedObject var recorder: RecorderViewModel
    @ObservedObject var telemetry: RecorderTelemetry

    init(recorder: RecorderViewModel, telemetry: RecorderTelemetry? = nil) {
        self.recorder = recorder
        self._telemetry = ObservedObject(wrappedValue: telemetry ?? recorder.telemetry)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: GlassSpacing.sm) {
            Text(recorder.captureSourceHint).font(.caption).foregroundStyle(.secondary)
            if recorder.isRecording {
                if let summary = recorder.interruptedSourceSummary {
                    VStack(alignment: .leading, spacing: GlassSpacing.xs) {
                        Label(summary, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.orange)
                        Button("Stop & start new take") {
                            Task { await recorder.stopAndStartNewTake() }
                        }
                        .controlSize(.small)
                    }
                }
                ForEach(telemetry.sourceHealth) { source in
                    let status = source.health.status(at: telemetry.healthTime)
                    VStack(alignment: .leading, spacing: GlassSpacing.xs) {
                        Text("\(source.name): \(status.label)")
                            .foregroundStyle([.noData, .stalled, .writeStalled, .failed].contains(status) ? Color.orange : Color.secondary)
                        if let message = source.health.failureMessage { Text(message).foregroundStyle(.orange) }
                        if let rate = source.health.sampleRate, let channels = source.health.channels {
                            Text("\(channels) input channels · \(rate.formatted(.number.precision(.fractionLength(0)))) Hz · \(source.health.peak >= 1 ? "clipping" : "peak " + String(format: "%.1f dBFS", 20 * log10(max(0.000_001, source.health.peak))))")
                                .foregroundStyle(.secondary)
                            if let post = source.health.postPeak {
                                Text(String(format: "After fader: %.1f dBFS · saved mix: %.1f dBFS", 20 * log10(max(0.000_001, post)), 20 * log10(max(0.000_001, source.health.mixPeak ?? post))))
                                    .foregroundStyle(source.health.clipped ? Color.orange : Color.secondary)
                                if source.health.clipped { Text("Clipping detected · reduce recording gain").foregroundStyle(.orange) }
                            }
                            ProgressView(value: Double(min(1, source.health.peak))).accessibilityLabel("\(source.name) level")
                        }
                        Text("\(source.health.receivedFrames) frames received · \(source.health.writtenFrames) written")
                            .foregroundStyle(.secondary).monospacedDigit()
                    }.font(.caption).help(source.detail ?? source.name).accessibilityElement(children: .combine)
                }
            }
        }.fixedSize(horizontal: false, vertical: true)
    }
}
