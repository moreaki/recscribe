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
    @State private var showsGuide = false
    @State private var appError: String?
    private let embeddedInStudio: Bool

    init(levels: AudioLevels, monitor: CapturedAudioMonitor,
         playbackLevels: PlaybackLevels, hardwareObserver: AudioHardwareObserver = .shared,
         embeddedInStudio: Bool = false) {
        _levels = Bindable(wrappedValue: levels)
        _monitor = Bindable(wrappedValue: monitor)
        _monitorLevels = Bindable(wrappedValue: monitor.levels)
        _playbackLevels = Bindable(wrappedValue: playbackLevels)
        _hardwareObserver = Bindable(wrappedValue: hardwareObserver)
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
            if let test = recorder.audioTest {
                AudioTestControls(test: test, enabled: recorder.state.allowsCaptureSourceChange && !recorder.installLocationBlocksRecording, showsExplanation: false)
                Divider()
            }
            GeometryReader { geometry in
                ScrollView {
                    VStack(alignment: .leading, spacing: 26) {
                        sourcesColumn
                        Divider()
                        if geometry.size.width >= 760 {
                            HStack(alignment: .top, spacing: 32) {
                                mixColumn.frame(minWidth: 280, maxWidth: .infinity)
                                listeningColumn.frame(minWidth: 310, maxWidth: .infinity)
                            }
                        } else {
                            VStack(alignment: .leading, spacing: 28) { mixColumn; Divider(); listeningColumn }
                        }
                    }.padding(.horizontal, 36).padding(.vertical, 24)
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
        .background(WorkspaceStyle.background).tint(WorkspaceStyle.blue).studioThemeAdaptingToContrast()
        .onAppear {
            recorder.audioTest?.opened()
            refreshHardware()
        }
        .onDisappear {
            Task { await recorder.audioTest?.close() }
        }
        .onChange(of: source) { _, next in
            rememberInputDevices()
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
            Image(systemName: "point.3.connected.trianglepath.dotted").font(.title2).foregroundStyle(WorkspaceStyle.mint)
            VStack(alignment: .leading, spacing: 3) {
                Text("Audio routing").font(.title2.weight(.semibold))
                Text(captureHint)
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
            Button("Routing info", systemImage: "info.circle") { showsGuide.toggle() }
                .buttonStyle(.borderless)
                .popover(isPresented: $showsGuide) {
                    VStack(alignment: .leading, spacing: 14) {
                        Text("Sources · Recording mix · Listening").font(.headline)
                        Text("Microphones and audio interfaces are added automatically. Virtual inputs are recorded only when enabled. Up to eight inputs per take.")
                        Text(source.isMixed ? "Enabled inputs save original source tracks; mute and gain change their contribution to the stereo mix." : "In single-source capture, gain and mute change the saved recording.")
                        Text("Monitoring is optional and separate from the saved recording. Hardware controls affect the device itself.")
                        Text("Test audio uses live sources without saving. A fresh sample records up to 10 seconds; capture and monitoring stop before playback.")
                        Button("Close") { showsGuide = false }
                    }.font(.callout).padding(20).frame(width: 360)
                }
            if !embeddedInStudio {
                Button("Close") { dismissWindow(id: AppWindow.routing.rawValue) }
                    .controlSize(.small)
            }
        }.padding(.horizontal, 36).padding(.top, 24).padding(.bottom, 18)
    }

    private var sourcesColumn: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                columnTitle("Sources", symbol: "waveform")
                Spacer()
            }.padding(.bottom, 3)
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
        VStack(alignment: .leading, spacing: 18) {
            columnTitle("Recording mix", symbol: "slider.horizontal.3")
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(source.isMixed ? "Stereo mix" : "Saved recording").font(.callout.weight(.semibold))
                    Text(source.isMixed ? "L / R · 48 kHz WAV" : "Single-source capture").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                cardActions(.mix, title: "Recording mix", muted: levels.level("master").muted)
            }
            SourceFader(id: "master", title: "Master gain", levels: levels, channels: 0,
                preservesSources: source.isMixed, showsMuteToggle: false)
            if let test = recorder.audioTest { AudioTestMixMeterView(test: test) }
            Text(source.isMixed
                 ? "Mix levels shape the stereo recording. Separate source tracks retain their originals. Gain above 0 dB can clip the mix."
                 : "Gain and mute change the saved recording. No separate unity-gain source track is saved in this mode.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Text("\(inputs.count + (source.requiresScreenCapture ? 1 : 0)) selected source routes")
                .font(.caption).foregroundStyle(.secondary)
            if recorder.audioTest?.state == .testing {
                Text("Preview only · no files saved").font(.caption).foregroundStyle(.secondary)
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private var listeningColumn: some View {
        VStack(alignment: .leading, spacing: 18) {
            columnTitle("Listening", symbol: "headphones")
            HStack {
                Label("Headphone monitor", systemImage: "headphones").font(.callout.weight(.semibold))
                Spacer()
                Text(volume(monitorLevels.value)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                cardActions(.monitor, title: "Headphone monitor", muted: monitorLevels.value.muted)
            }
            Text(monitorState).font(.caption).foregroundStyle(.secondary)
            ListeningControls(levels: monitor.levels, title: "Live monitor output", hardwareObserver: hardwareObserver, showsHeader: false)
            Text("Use headphones. Listening never changes saved audio. Monitoring turns off after each take.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Divider()
            HStack {
                Label("Recording playback", systemImage: "play.circle").font(.callout.weight(.semibold))
                Spacer()
                Text(volume(playbackLevels.value)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                cardActions(.recordingPlayback, title: "Recording playback", muted: playbackLevels.value.muted)
            }
            ListeningControls(levels: playbackLevels, title: "Playback output", hardwareObserver: hardwareObserver, showsHeader: false)
            Text("Playback volume affects what you hear. Recorded audio stays unchanged.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }.frame(maxWidth: .infinity, alignment: .leading)
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
            Toggle("Headphone monitoring", isOn: Binding(get: { monitor.enabled }, set: { monitor.setEnabled($0, source: source) }))
                .toggleStyle(.switch).labelsHidden().controlSize(.small)
                .accessibilityLabel("Headphone monitoring")
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
                Text(source.isMixed ? "Original source tracks are kept separately." : "Gain and mute change the saved recording.")
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

    private func volume(_ level: ListeningLevel) -> String { "\(Int((level.volume * 100).rounded()))%" }
    private func output(_ level: ListeningLevel) -> String { AudioRoutingSummary.output(level, devices: outputs, systemUID: systemOutputUID) }
    private func outputWarning(_ level: ListeningLevel) -> String? {
        if let uid = level.outputUID, !outputs.contains(where: { $0.uid == uid }) { return "Selected output unavailable" }
        return level.volume == 0 && !level.muted ? "Output volume is 0%" : nil
    }
    private func columnTitle(_ title: String, symbol: String) -> some View {
        Label(title, systemImage: symbol).font(.callout.weight(.medium)).foregroundStyle(.secondary)
            .frame(minHeight: 22)
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
    var showsExplanation = true
    var compact = false

    init(recorder: RecorderViewModel, telemetry: RecorderTelemetry? = nil, showsExplanation: Bool = true, compact: Bool = false) {
        self.recorder = recorder
        self._telemetry = Bindable(wrappedValue: telemetry ?? recorder.telemetry)
        self.showsExplanation = showsExplanation
        self.compact = compact
    }

    var body: some View {
        VStack(alignment: .leading, spacing: StudioSpacing.sm) {
            if showsExplanation { Text(recorder.captureSourceHint).font(.caption).foregroundStyle(.secondary) }
            if recorder.isRecording {
                if let summary = recorder.interruptedSourceSummary {
                    VStack(alignment: .leading, spacing: StudioSpacing.xs) {
                        Label(summary, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.orange)
                        Button("Stop & start new take") {
                            Task { await recorder.stopAndStartNewTake() }
                        }
                        .controlSize(.small)
                    }
                }
                ForEach(telemetry.layoutSources) { source in
                    CaptureHealthReadout(telemetry: telemetry, source: source, compact: compact)
                }
            }
        }.fixedSize(horizontal: false, vertical: true)
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
