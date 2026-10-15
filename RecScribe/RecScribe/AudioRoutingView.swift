import SwiftUI

/// An editor for the existing recording graph. Opening this window never starts capture.
struct AudioRoutingView: View {
    @EnvironmentObject private var recorder: RecorderViewModel
    @Environment(\.dismissWindow) private var dismissWindow
    @ObservedObject private var levels = AudioLevels.shared
    @ObservedObject private var monitor = CapturedAudioMonitor.shared
    @State private var devices: [InputDeviceInfo] = []
    @State private var apps: [RunningAppInfo] = []
    @State private var showApps = false
    @State private var loadingApps = false
    @State private var appError: String?

    private var source: AudioSource { recorder.audioSource.selectedSource }
    private var inputs: [InputSelection] { source.inputSelections }
    private var editable: Bool { recorder.state.allowsCaptureSourceChange }
    private var eligible: [InputDeviceInfo] { devices.filter { (1...32).contains($0.inputChannels ?? 0) } }
    private var warnings: [String] { InputRouteSafety.warnings(inputs: inputs, devices: devices) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                WorkspaceIcon(symbol: "point.3.connected.trianglepath.dotted", tint: WorkspaceStyle.mint)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Audio routing").font(.title2.bold())
                    Text(recorder.isRecording ? "Recording · gain and monitor controls remain live" : "Configure your next recording · audio starts when you press Record")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Close") { dismissWindow(id: AppWindow.routing.rawValue) }
            }.padding(24)
            AudioMuteSummary(source: source)
                .padding(.horizontal, 24).padding(.bottom, 12)
            Divider()
            if source.kind != .multiple {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Build a mix from apps and inputs").font(.title3.bold())
                    Text("Your current capture source stays selected until you enable this routing workspace. Each selected input keeps its own original recording alongside the stereo mix.")
                    Button("Use multiple inputs + playback") {
                        save(inputs.map { selected in
                            devices.first { $0.uid == selected.deviceUID }.map(InputSelection.init(device:)) ?? selected
                        })
                    }.buttonStyle(.borderedProminent).disabled(!editable)
                }.padding(24)
                Spacer()
            } else {
                ScrollView {
                    HStack(alignment: .top, spacing: 16) {
                        sourcesColumn.frame(minWidth: 320, maxWidth: .infinity)
                        flowArrow
                        mixColumn.frame(width: 210)
                        flowArrow
                        monitorColumn.frame(width: 260)
                    }.padding(24)
                }
                Divider()
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "info.circle")
                    Text("Connections affect the stereo mix. Original input channels are saved at unity gain. Sources and connections lock during recording; faders stay adjustable. Monitoring is off after each take.")
                }.font(.caption).foregroundStyle(.secondary).padding(16)
            }
        }
        .frame(minWidth: AppWindow.routing.minimumSize.width, minHeight: AppWindow.routing.minimumSize.height)
        .background(WorkspaceStyle.background).tint(WorkspaceStyle.blue).glassThemeAdaptingToContrast()
        .task {
            while !Task.isCancelled {
                devices = recorder.audioSource.availableInputDevices()
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    private var sourcesColumn: some View {
        VStack(alignment: .leading, spacing: 16) {
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
                } label: { Label("Add input", systemImage: "plus") }.disabled(!editable)
            }
            routingCard(muted: levels.level(source.playbackLevelID).muted) {
                Label(source.appBundleID.map { recorder.audioSource.knownAppName(forBundleID: $0) ?? $0 } ?? "System audio", systemImage: "app.connected.to.app.below.fill")
                    .font(.headline)
                Text(source.appBundleID == nil ? "All system playback → L / R" : "Application playback → L / R")
                    .font(.caption).foregroundStyle(.secondary)
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
                SourceFader(id: source.playbackLevelID, title: "Playback gain", levels: levels, channels: 2, preservesSources: true)
                sourceMeter(.playback)
            }
            ForEach(inputs) { input in
                inputCard(input, device: devices.first { $0.uid == input.deviceUID })
            }
            if inputs.isEmpty {
                Text("Playback only. Add an input to include your microphone or audio interface.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            if !warnings.isEmpty {
                routingCard {
                    Label("Review possible loopback", systemImage: "exclamationmark.triangle").font(.headline).foregroundStyle(.orange)
                    ForEach(warnings, id: \.self) { Text($0).font(.caption) }
                    Toggle("Include these possible duplicate / loopback routes", isOn: Binding(get: {
                        if case .multiple(_, _, let allowed) = source { return allowed }; return false
                    }, set: { save(inputs, acknowledge: $0) })).font(.caption).disabled(!editable)
                }
            }
        }
    }

    private func inputCard(_ input: InputSelection, device: InputDeviceInfo?) -> some View {
        let summary = device.map { device in
            let channels = device.inputChannels ?? 0
            let rate = device.sampleRate.map { String(format: "%.0f Hz", $0) } ?? "Rate unavailable"
            return "\(device.kindLabel) · \(channels) \(channels == 1 ? "channel" : "channels") · \(rate)"
        } ?? input.deviceUID
        return routingCard(muted: levels.level("input:" + input.deviceUID).muted) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Label(device?.name ?? "Unavailable input", systemImage: "mic.fill").font(.headline)
                    Text(summary)
                        .font(.caption).foregroundStyle(device == nil ? Color.orange : Color.secondary)
                }
                Spacer()
                Button { save(inputs.filter { $0.deviceUID != input.deviceUID }) } label: { Image(systemName: "minus.circle") }
                    .buttonStyle(.borderless).disabled(!editable).accessibilityLabel("Remove \(device?.name ?? "unavailable input")")
            }
            if let device {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Channel connections").font(.subheadline.weight(.medium))
                    VStack(spacing: 6) {
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
                        Text("Connect to L, R, both (center), or neither. Disconnected channels stay in the original source recording.")
                            .font(.caption2).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
                    }.padding(.top, 8)
                }.disabled(!editable)
            }
            SourceFader(id: "input:" + input.deviceUID, title: "Input gain", levels: levels,
                        channels: min(32, device?.inputChannels ?? 1), preservesSources: true, context: device?.name ?? input.deviceUID)
            sourceMeter(.input(input.deviceUID))
            if device != nil { DeviceVolumeView(uid: input.deviceUID, input: true) }
        }
    }

    private var mixColumn: some View {
        VStack(alignment: .leading, spacing: 16) {
            columnTitle("Recording mix", symbol: "slider.horizontal.3")
            routingCard(muted: levels.level("master").muted) {
                Text("Stereo output").font(.headline)
                HStack(spacing: 8) {
                    outputPort("1 · Left")
                    outputPort("2 · Right")
                }
                Text("48 kHz · WAV").font(.caption).foregroundStyle(.secondary)
                Divider()
                SourceFader(id: "master", title: "Master gain", levels: levels, channels: 0, preservesSources: true)
                Text("Selected channels are averaged per side, then across sources for headroom. Gain above 0 dB can clip the mix.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            routingCard {
                Label("Original sources", systemImage: "waveform.path").font(.headline)
                Text("Playback + \(inputs.count) \(inputs.count == 1 ? "input" : "inputs")")
                Text("All native input channels · unity gain · separate files")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var monitorColumn: some View {
        VStack(alignment: .leading, spacing: 16) {
            columnTitle("Monitor", symbol: "headphones")
            routingCard {
                Toggle("Listen to recording mix", isOn: Binding(get: { monitor.enabled }, set: { monitor.setEnabled($0, source: source) }))
                    .font(.headline).toggleStyle(.switch)
                Text(monitor.enabled ? "\(recorder.isRecording ? "Listening while recording" : "Armed · waiting for recording")" : "Off · no live audio output")
                    .font(.caption).foregroundStyle(.secondary)
                ListeningControls(levels: monitor.levels, title: "Live monitor output")
                Text("Use headphones. This volume changes what you hear, independently of the saved mix.")
                    .font(.caption).foregroundStyle(.secondary)
                if let warning = monitor.warning { Text(warning).font(.caption).foregroundStyle(.orange) }
            }
            routingCard {
                Label("Recording playback", systemImage: "play.circle").font(.headline)
                ListeningControls(levels: .shared, title: "Playback output")
            }
        }
    }

    private var flowArrow: some View {
        Image(systemName: "arrow.right").font(.title3).foregroundStyle(WorkspaceStyle.mint)
            .padding(.top, 72).accessibilityHidden(true)
    }
    private func columnTitle(_ title: String, symbol: String) -> some View {
        Label(title, systemImage: symbol).font(.headline)
    }
    private func outputPort(_ title: String) -> some View {
        Text(title).font(.caption.monospaced().bold()).frame(maxWidth: .infinity).padding(.vertical, 12)
            .background(WorkspaceStyle.mint.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
    }
    private func routingCard<Content: View>(muted: Bool = false, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12, content: content)
            .padding(16).frame(maxWidth: .infinity, alignment: .leading)
            .background(WorkspaceStyle.panel, in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(muted ? Color.orange.opacity(0.6) : Color.primary.opacity(0.08)))
    }
    @ViewBuilder private func sourceMeter(_ track: CaptureTrack) -> some View {
        if recorder.isRecording, let item = recorder.sourceHealth.first(where: { $0.id == track.rawValue }) {
            ProgressView(value: Double(min(1, item.health.peak))).accessibilityLabel("\(item.name) input level")
            Text(item.health.status(at: recorder.healthTime).label).font(.caption).foregroundStyle(item.health.failed ? Color.orange : Color.secondary)
            if let failure = item.health.failureMessage { Text(failure).font(.caption).foregroundStyle(.orange) }
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
