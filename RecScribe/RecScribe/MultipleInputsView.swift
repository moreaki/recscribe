import SwiftUI

struct MultipleInputsView: View {
    @ObservedObject var recorder: RecorderViewModel
    @State private var devices: [InputDeviceInfo] = []
    @State private var expanded = false
    private var source: AudioSource { recorder.audioSource.selectedSource }
    private var selections: [InputSelection] { source.inputSelections }
    private var enabled: Bool { source.kind == .multiple }
    private var warnings: [String] { InputRouteSafety.warnings(inputs: selections, devices: devices) }
    private var eligible: [InputDeviceInfo] { devices.filter { (1...32).contains($0.inputChannels ?? 0) } }
    private func save(_ inputs: [InputSelection], acknowledge: Bool = false, bundle: String? = nil, changePlayback: Bool = false) {
        recorder.setCaptureSource(.multiple(appBundleID: changePlayback ? bundle : source.appBundleID, inputs: inputs, allowDuplicateRoutes: acknowledge))
    }
    var body: some View {
        DisclosureGroup("Capture inputs\(enabled ? " · \(selections.count) selected" : "")", isExpanded: $expanded) {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Record system or selected-app playback together with up to eight inputs. Select all snapshots the current devices; newly connected inputs are never added automatically.")
                        .font(.caption).foregroundStyle(.secondary)
                    if !enabled {
                        Button("Use multiple inputs + playback") {
                            save(selections.compactMap { selection in devices.first { $0.uid == selection.deviceUID }.map(InputSelection.init(device:)) })
                        }
                    } else {
                        Text(source.appBundleID.map { "Playback: \(recorder.audioSource.knownAppName(forBundleID: $0) ?? $0)" } ?? "Playback: all system audio")
                        if source.appBundleID != nil { Button("Use all system playback") { save(selections, changePlayback: true) } }
                        HStack {
                            Button("Select all available inputs") { save(eligible.map(InputSelection.init(device:))) }
                                .disabled(eligible.count > InputSelection.maximumDevices)
                                .help("At most eight inputs; overlapping and loopback routes require review.")
                            Button("Deselect all") { save([]) }
                        }.controlSize(.small)
                        if eligible.count > InputSelection.maximumDevices { Text("Choose up to eight inputs individually.").font(.caption).foregroundStyle(.secondary) }
                        ForEach(devices) { device in
                            let selection = selections.first { $0.deviceUID == device.uid }
                            VStack(alignment: .leading, spacing: 4) {
                                Toggle(device.name, isOn: Binding(get: { selection != nil }, set: { selected in
                                    var next = selections.filter { $0.deviceUID != device.uid }
                                    if selected { next.append(.init(device: device)) }
                                    save(next)
                                })).disabled(selection == nil && (selections.count >= InputSelection.maximumDevices || !eligible.contains(device)))
                                Text("\(device.kindLabel) · \(device.inputChannels ?? 0) channels · \(device.sampleRate.map { String(format: "%.0f Hz", $0) } ?? "rate unavailable")")
                                    .font(.caption).foregroundStyle(.secondary)
                                if let selection {
                                    DisclosureGroup("Mix channels (all native channels are saved)") {
                                        ForEach(0..<min(32, device.inputChannels ?? 0), id: \.self) { channel in
                                            HStack {
                                                let route = selection.routes.first { $0.channel == channel }
                                                Toggle(device.channelLabels.indices.contains(channel) ? device.channelLabels[channel] : "Channel \(channel + 1)", isOn: Binding(get: { route != nil }, set: { include in
                                                    var next = selection
                                                    next.routes.removeAll { $0.channel == channel }
                                                    if include { next.routes.append(.init(channel: channel, placement: .center)) }
                                                    replace(next)
                                                }))
                                                if let route {
                                                    Picker("Placement", selection: Binding(get: { route.placement }, set: { placement in
                                                        var next = selection
                                                        if let index = next.routes.firstIndex(where: { $0.channel == channel }) { next.routes[index].placement = placement }
                                                        replace(next)
                                                    })) { ForEach(InputMixPlacement.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) } }
                                                        .labelsHidden().accessibilityLabel("\(device.name) channel \(channel + 1) placement")
                                                }
                                            }
                                        }
                                    }.font(.caption)
                                }
                            }
                        }
                        ForEach(selections.filter { selected in !devices.contains { $0.uid == selected.deviceUID } }) { missing in
                            HStack {
                                Text("Selected input unavailable: \(missing.deviceUID)").font(.caption).foregroundStyle(.orange)
                                Button("Remove") { save(selections.filter { $0.deviceUID != missing.deviceUID }) }.controlSize(.small)
                            }
                        }
                        if selections.isEmpty { Text("No inputs selected: only playback will be captured.").font(.caption).foregroundStyle(.secondary) }
                        ForEach(warnings, id: \.self) { Text($0).font(.caption).foregroundStyle(.orange) }
                        if !warnings.isEmpty {
                            Toggle("Include these possible duplicate / loopback routes", isOn: Binding(get: {
                                if case .multiple(_, _, let allow) = source { return allow }; return false
                            }, set: { save(selections, acknowledge: $0) })).font(.caption)
                        }
                        Text("The mix averages selected channels per side and selected sources for headroom. Source files retain every native channel at unity gain. Use headphones to avoid microphone recapture of speakers.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }.padding(.top, 8).disabled(!recorder.state.allowsCaptureSourceChange)
            }.frame(height: 340)
        }.font(.callout)
        .task {
            while !Task.isCancelled {
                devices = recorder.audioSource.availableInputDevices()
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }
    private func replace(_ selection: InputSelection) {
        save(selections.map { $0.deviceUID == selection.deviceUID ? selection : $0 })
    }
}
