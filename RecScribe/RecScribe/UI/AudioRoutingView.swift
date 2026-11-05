import SwiftUI

/// An editor for the existing graph. Disclosure changes never write audio settings.
struct AudioRoutingView: View {
    @Environment(RecorderViewModel.self) private var recorder
    @Environment(\.dismissWindow) private var dismissWindow
    @Bindable private var levels: AudioLevels
    @Bindable private var monitor: CapturedAudioMonitor
    @Bindable private var monitorLevels: PlaybackLevels
    @Bindable private var playbackLevels: PlaybackLevels
    @Bindable private var hardwareObserver: AudioHardwareObserver
    private let sourceNames = RoutingSourceNames.shared
    @State private var devices: [InputDeviceInfo] = []
    @State private var knownInputDevices: [String: InputDeviceInfo] = [:]
    @State private var outputs: [AudioOutputDevice] = []
    @State private var systemOutputUID: String?
    @State private var apps: [RunningAppInfo] = []
    @State private var showApps = false
    @State private var loadingApps = false
    @State private var appError: String?
    @State private var expandedPanel: AudioRoutingPanel?
    @FocusState private var focusedPanel: AudioRoutingPanel?
    private let embeddedInStudio: Bool

    init(levels: AudioLevels, monitor: CapturedAudioMonitor,
         playbackLevels: PlaybackLevels, hardwareObserver: AudioHardwareObserver = .shared,
         expandedPanel: AudioRoutingPanel? = nil,
         embeddedInStudio: Bool = false) {
        _levels = Bindable(wrappedValue: levels)
        _monitor = Bindable(wrappedValue: monitor)
        _monitorLevels = Bindable(wrappedValue: monitor.levels)
        _playbackLevels = Bindable(wrappedValue: playbackLevels)
        _hardwareObserver = Bindable(wrappedValue: hardwareObserver)
        _expandedPanel = State(initialValue: expandedPanel)
        self.embeddedInStudio = embeddedInStudio
    }

    private var source: AudioSource { recorder.selectedSource }
    private var inputs: [InputSelection] { source.inputSelections }
    private var editable: Bool { recorder.allowsCaptureSourceChange }
    private var eligible: [InputDeviceInfo] { devices.filter { (1...32).contains($0.inputChannels ?? 0) } }
    private var monitorState: String {
        monitor.enabled ? (recorder.isRecording || recorder.audioTest?.isCapturing == true ? "Listening" : "Armed · waiting for capture") : "Off"
    }
    private var captureHint: String {
        if recorder.audioTest?.locksSources == true { return "Audio test · mute and gain stay live · inputs reconnect automatically" }
        if recorder.isRecording { return "Recording · mute and gain stay live · inputs reconnect automatically" }
        return editable ? "Source controls are always visible · not recording" : "Preparing or finishing capture · sources and connections locked"
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
                        sourcesColumn
                        HStack(alignment: .top, spacing: 18) {
                            mixColumn.frame(maxWidth: .infinity)
                            flowArrow
                            outputsColumn.frame(maxWidth: .infinity)
                        }
                    }.padding(20)
                }
            }
            if (source.requiresScreenCapture && recorder.permissionStatus != .granted) || monitor.warning != nil || recorder.hasInterruptedSource {
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
            rememberInputDevices()
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
        sourceNames.remember(devices)
        rememberInputDevices()
        outputs = hardwareObserver.outputDevices
        systemOutputUID = hardwareObserver.defaultOutputUID
    }

    private func rememberInputDevices() {
        let selected = Set(inputs.map(\.deviceUID))
        knownInputDevices = knownInputDevices.filter { selected.contains($0.key) }
        for device in devices where selected.contains(device.uid) { knownInputDevices[device.uid] = device }
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
            if !embeddedInStudio {
                Button("Close") { dismissWindow(id: AppWindow.routing.rawValue) }
                    .controlSize(.small)
            }
        }.padding(.horizontal, 20).padding(.vertical, 16)
    }

    private var sourcesColumn: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                columnTitle("Sources", symbol: "waveform")
                Spacer()
            }.padding(.bottom, 3)
            Text("Microphones and audio interfaces are added automatically. Virtual inputs are recorded only when enabled below. Mute controls the mix; enabled inputs also save original tracks. Up to eight inputs per take.")
                .font(.caption).foregroundStyle(.secondary)
            if eligible.count > InputSelection.maximumDevices {
                Text("At most \(InputSelection.maximumDevices) input devices can be captured at once.")
                    .font(.caption).foregroundStyle(.orange)
            }
            CompactRoutingSourceCard(id: source.playbackLevelID, title: playbackName,
                subtitle: "Playback · 2 ch", uid: nil, track: .playback, channels: 2,
                channelNames: ["Left", "Right"], routes: nil, editable: editable,
                available: true, captured: source.requiresScreenCapture, preservesSources: source.isMixed,
                levels: levels, hardware: hardwareObserver) {
                    playbackChooser
                } captureAction: { EmptyView() }
            ForEach(inputs) { input in
                inputCard(input, device: devices.first { $0.uid == input.deviceUID })
            }
            let unusedVirtual = eligible.filter { device in
                device.mayLoopBack && !inputs.contains { $0.deviceUID == device.uid }
            }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            if !unusedVirtual.isEmpty {
                Divider().padding(.top, 8)
                Text("Available virtual inputs").font(.caption).foregroundStyle(.secondary)
                ForEach(unusedVirtual) { device in virtualCaptureButton(device) }
            }
            if let appError { Text(appError).font(.caption).foregroundStyle(.orange) }
            CompactRoutingSourceAlerts()
            if inputs.isEmpty {
                Text("Playback only. Connect an input to include your microphone or audio interface.")
                    .font(.caption).foregroundStyle(.secondary).padding(.top, 4)
            }
        }
    }

    private func virtualCaptureButton(_ device: InputDeviceInfo, compact: Bool = false) -> some View {
        let selected = inputs.contains { $0.deviceUID == device.uid }
        return Button(selected ? "Don't record" : "Record \(device.name)") {
            recorder.setVirtualInputCapture(device, enabled: !selected)
        }
        .font(.caption).controlSize(.small).tint(WorkspaceStyle.blue)
        .fixedSize(horizontal: compact, vertical: false)
        .accessibilityLabel("\(selected ? "Don't record" : "Record") \(device.name)")
        .disabled(!editable || (!selected && inputs.count >= InputSelection.maximumDevices))
        .help(selected ? "Exclude this virtual device from capture." : "Include this virtual device in capture and preserve its original source track.")
    }

    private var playbackName: String {
        guard source.requiresScreenCapture else { return "Playback off" }
        return RoutingSourceNames.playback(source, appName: recorder.audioSource.knownAppName)
    }

    private var playbackChooser: some View {
        Menu {
            Button("All system audio") { save(inputs, playbackState: .systemAll) }
            Button("Choose application…") { loadApps() }.disabled(loadingApps)
            Button("Playback off") { save(inputs, playbackState: AudioSource.Playback.none) }.disabled(inputs.isEmpty)
        } label: {
            Text(source.requiresScreenCapture ? (source.appBundleID == nil ? "All system audio" : "Application audio") : "Playback off")
        }
        .font(.caption2).menuStyle(.borderlessButton).fixedSize()
        .disabled(!editable)
        .accessibilityLabel("Playback source")
        .popover(isPresented: $showApps) {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Application playback").font(.headline)
                    if apps.isEmpty { Text("No open applications found.").font(.caption) }
                    ForEach(apps) { app in
                        Button {
                            save(inputs, playbackState: .app(bundleID: app.bundleID)); showApps = false
                        } label: {
                            HStack {
                                Text(app.applicationName)
                                if app.isAudioActive { Text("Playing audio").font(.caption2).foregroundStyle(WorkspaceStyle.mint) }
                            }
                        }
                    }
                }.padding().frame(minWidth: 240, alignment: .leading)
            }.frame(maxHeight: 360)
        }
    }

    private func inputCard(_ input: InputSelection, device: InputDeviceInfo?) -> some View {
        let name = device?.name ?? sourceNames.input(input.deviceUID)
        let details = device ?? knownInputDevices[input.deviceUID]
        let channels = min(32, max(1, details?.inputChannels ?? ((input.routes.map(\.channel).max() ?? 0) + 1)))
        let rate = details?.sampleRate.map { String(format: "%.0f Hz", $0) } ?? "Rate unavailable"
        let routes = Binding<[InputChannelRoute]>(
            get: { inputs.first { $0.deviceUID == input.deviceUID }?.routes ?? input.routes },
            set: { updated in
                save(inputs.map { selection in
                    guard selection.deviceUID == input.deviceUID else { return selection }
                    var next = selection; next.routes = updated; return next
                })
            })
        return CompactRoutingSourceCard(id: "input:" + input.deviceUID, title: name,
            subtitle: "\(details?.kindLabel ?? "Missing device") · \(channels) ch · \(rate)",
            uid: input.deviceUID, track: .input(input.deviceUID), channels: channels,
            channelNames: details?.channelLabels ?? [], routes: routes, editable: editable,
            available: device != nil, captured: true, preservesSources: source.isMixed,
            levels: levels, hardware: hardwareObserver) {
                EmptyView()
            } captureAction: {
                if let device, device.mayLoopBack { virtualCaptureButton(device, compact: true) }
            }
    }

    private var mixColumn: some View {
        VStack(alignment: .leading, spacing: 8) {
            columnTitle("Recording mix", symbol: "slider.horizontal.3").padding(.bottom, 3)
            disclosureCard(.mix, title: "Stereo recording mix", symbol: "slider.horizontal.3",
                           subtitle: "L / R · 48 kHz WAV", value: gain("master"), muted: levels.level("master").muted) {
                HStack(spacing: 8) { outputPort("1 · Left"); outputPort("2 · Right") }
                SourceFader(id: "master", title: "Master gain", levels: levels, channels: 0, preservesSources: source.isMixed, showsMuteToggle: false)
                Text("Selected channels are averaged per side, then across sources for headroom. Gain above 0 dB can clip the mix.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Text("\(inputs.count + (source.requiresScreenCapture ? 1 : 0)) selected source routes")
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
            if let warning = monitor.warning {
                Label(warning, systemImage: "headphones").foregroundStyle(.orange)
            }
        }.font(.caption).fixedSize(horizontal: false, vertical: true)
    }

    private var footer: some View {
        HStack(alignment: .top, spacing: 16) {
            Text(recorder.audioTest?.state == .testing ? "Preview only · no files saved · stop test to edit connections." : source.isMixed ? "Mix controls retain original tracks. Device levels are system-wide." : "Gain and mute affect saved audio. Device levels are system-wide.")
            Spacer(minLength: 0)
            Text("Monitor: \(monitorState)")
        }.font(.caption2).foregroundStyle(.secondary).padding(.horizontal, 20).padding(.vertical, 12)
    }

    private func disclosureCard<Details: View>(_ panel: AudioRoutingPanel, title: String, symbol: String,
                                               subtitle: String, value: String, muted: Bool = false,
                                               warning: String? = nil, track: CaptureTrack? = nil,
                                               @ViewBuilder details: () -> Details) -> some View {
        let expanded = expandedPanel == panel
        return VStack(alignment: .leading, spacing: 0) {
            AudioRoutingCardHeader(title: title, symbol: symbol, subtitle: subtitle, value: value,
                                   expanded: expanded, muted: muted, warning: warning,
                                   muteTitle: panel == .monitor || panel == .recordingPlayback ? "Muted" : source.isMixed ? "Muted in mix" : "Capture muted",
                                   focus: $focusedPanel, panel: panel) {
                expandedPanel = expanded ? nil : panel
                focusedPanel = panel
            } actions: {
                cardActions(panel, title: title, muted: muted)
            }
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

    private func levelID(_ panel: AudioRoutingPanel) -> String? {
        switch panel {
        case .playback: source.requiresScreenCapture ? source.playbackLevelID : nil
        case .input(let uid): "input:" + uid
        case .mix: "master"
        default: nil
        }
    }

    @ViewBuilder private func cardActions(_ panel: AudioRoutingPanel, title: String, muted: Bool) -> some View {
        let listening = panel == .monitor ? monitorLevels : playbackLevels
        if case .input(let uid) = panel,
           let device = devices.first(where: { $0.uid == uid && $0.mayLoopBack }) {
            virtualCaptureButton(device, compact: true)
        }
        if let id = levelID(panel) {
            muteButton(title: title, muted: muted) {
                var next = levels.level(id); next.muted.toggle(); levels.set(id, next)
            }
        } else if panel == .monitor || panel == .recordingPlayback {
            muteButton(title: title, muted: muted) {
                var next = listening.value; next.muted.toggle(); listening.set(next)
            }
        }
        if panel == .monitor {
            Button(monitor.enabled ? "Monitor on" : "Monitor off") {
                monitor.setEnabled(!monitor.enabled, source: source)
            }.font(.caption).controlSize(.small)
                .accessibilityLabel(monitor.enabled ? "Disable headphone monitoring" : "Enable headphone monitoring")
        }
        Menu {
            switch panel {
            case .playback, .input:
                if let id = levelID(panel) {
                    Button("Reset gain & mute") { levels.set(id, .init()) }
                }
            case .mix:
                Text("Required stereo recording mix")
                Button("Reset mix settings") { levels.set("master", .init()) }
                Text("Original source tracks are kept separately.")
            case .monitor, .recordingPlayback:
                if panel == .monitor {
                    Button("Turn monitoring off") { monitor.setEnabled(false, source: source) }.disabled(!monitor.enabled)
                }
                Button("Reset volume & mute") {
                    var next = listening.value
                    next.volume = panel == .monitor ? 0.5 : 1
                    next.muted = false
                    listening.set(next)
                }
                Text("Listening only. Saved audio is unchanged.")
            }
        } label: { Image(systemName: "ellipsis") }
        .menuStyle(.borderlessButton).fixedSize().accessibilityLabel("Actions for \(title)")
    }
    private func muteButton(title: String, muted: Bool, action: @escaping () -> Void) -> some View {
        AudioRoutingMuteButton(title: title, muted: muted, action: action)
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
        if let test = recorder.audioTest, !recorder.isRecording {
            AudioTestSourceMeterView(test: test, track: track,
                muted: levels.level(track == .playback ? source.playbackLevelID : inputs.first(where: { CaptureTrack.input($0.deviceUID) == track }).map { "input:" + $0.deviceUID } ?? "").muted)
        } else if recorder.isRecording {
            CaptureSourceMeter(telemetry: recorder.telemetry, track: track)
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

/// Only this leaf subscribes to incoming level and health updates.
struct CaptureSourceMeter: View {
    @Bindable var telemetry: RecorderTelemetry
    let track: CaptureTrack

    var body: some View {
        if let item = telemetry.sourceHealth.first(where: { $0.id == track.rawValue }) {
            VStack(alignment: .leading, spacing: 4) {
                ProgressView(value: Double(min(1, item.health.peak)))
                    .accessibilityLabel("\(item.name) raw input level")
                let status = item.health.status(at: telemetry.healthTime)
                Text(status.label).foregroundStyle([.noData, .stalled, .writeStalled, .failed].contains(status) ? Color.orange : Color.secondary)
                if let failure = item.health.failureMessage { Text(failure).foregroundStyle(.orange) }
                if item.health.clipped { Text("Clipping detected · reduce recording gain").foregroundStyle(.orange) }
            }.font(.caption2).padding(.bottom, 10)
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

/// Source and mute status shared by capture surfaces and the Settings workspace.
struct MultipleInputsView: View {
    @Bindable var recorder: RecorderViewModel
    private var source: AudioSource { recorder.selectedSource }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if source.kind == .multiple {
                let count = source.inputSelections.count
                Text("\(source.requiresScreenCapture ? "Playback + " : "")\(count) \(count == 1 ? "input" : "inputs") → stereo recording mix")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Text("Connect apps and inputs, adjust channels, and choose a monitor output.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            AudioMuteSummary(source: source, audio: recorder.audio, appName: recorder.audioSource.knownAppName)
            if let test = recorder.audioTest, test.locksSources {
                Label("Audio test active · start recording to end the test and begin a take", systemImage: "waveform.circle")
                    .font(.caption).foregroundStyle(WorkspaceStyle.mint)
            }
        }.font(.callout)
    }
}

struct CaptureHealthView: View {
    @Bindable var recorder: RecorderViewModel
    @Bindable var telemetry: RecorderTelemetry

    init(recorder: RecorderViewModel, telemetry: RecorderTelemetry? = nil) {
        self.recorder = recorder
        self._telemetry = Bindable(wrappedValue: telemetry ?? recorder.telemetry)
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

/// Keep mute feedback in the existing action row so toggling never moves cards.
struct AudioRoutingCardHeader<Actions: View>: View {
    let title: String
    let symbol: String
    let subtitle: String
    let value: String
    let expanded: Bool
    let muted: Bool
    let warning: String?
    let muteTitle: String
    var focus: FocusState<AudioRoutingPanel?>.Binding? = nil
    var panel: AudioRoutingPanel? = nil
    let toggle: () -> Void
    @ViewBuilder var actions: () -> Actions

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let focus {
                disclosureButton.focused(focus, equals: panel)
            } else {
                disclosureButton
            }
            HStack(spacing: 8) {
                // Reserve the same footprint, including wrapped text at narrow widths.
                AudioMuteBadge(title: muteTitle).opacity(muted ? 1 : 0).accessibilityHidden(!muted)
                Spacer(minLength: 0)
                actions()
            }.padding(.horizontal, 12).padding(.bottom, 10)
        }
    }

    private var disclosureButton: some View {
        Button(action: toggle) {
            HStack(spacing: 10) {
                Image(systemName: symbol).foregroundStyle(.secondary).frame(width: 18)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.callout.weight(.medium)).foregroundStyle(.primary)
                    Text(subtitle).font(.caption2).foregroundStyle(.secondary)
                    if let warning { Text(warning).font(.caption2).foregroundStyle(.orange) }
                }.frame(maxWidth: .infinity, alignment: .leading)
                Text(value).font(.caption).monospacedDigit().foregroundStyle(.secondary)
                Image(systemName: expanded ? "chevron.up" : "chevron.down").font(.caption2).foregroundStyle(.secondary)
            }.padding(12).contentShape(Rectangle())
        }.buttonStyle(.plain)
            .accessibilityLabel(title)
            .accessibilityValue("\(expanded ? "Expanded" : "Collapsed"), \(subtitle), \(value)\(muted ? ", muted" : "")\(warning.map { ", \($0)" } ?? "")")
            .accessibilityHint("\(expanded ? "Hide" : "Show") controls. Escape collapses the open controls.")
    }
}

struct AudioRoutingMuteButton: View {
    let title: String
    let muted: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(muted ? "Unmute" : "Mute").frame(minWidth: 44)
        }
        .font(.caption).controlSize(.small).tint(muted ? .orange : WorkspaceStyle.blue)
        .accessibilityLabel("\(muted ? "Unmute" : "Mute") \(title)")
        .accessibilityValue(muted ? "Muted" : "Not muted")
    }
}
