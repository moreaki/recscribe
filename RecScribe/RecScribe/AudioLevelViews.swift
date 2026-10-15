import AVKit
import SwiftUI

struct RecordingLevelsView: View {
    @ObservedObject var recorder: RecorderViewModel
    @ObservedObject private var levels = AudioLevels.shared
    @ObservedObject private var monitor = CapturedAudioMonitor.shared
    @State private var expanded = false
    private var source: AudioSource { recorder.audioSource.selectedSource }
    var body: some View {
        DisclosureGroup("Audio levels", isExpanded: $expanded) {
            ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                if source.isMixed || source.microphoneUID == nil {
                    SourceFader(id: source.playbackLevelID, title: "Playback capture gain", levels: levels,
                                channels: source.isMixed ? 2 : (recorder.sourceHealth.first?.health.channels ?? 2), preservesSources: source.isMixed)
                }
                if source.kind == .multiple {
                    ForEach(source.inputSelections) { selection in
                        let device = recorder.audioSource.availableInputDevices().first { $0.uid == selection.deviceUID }
                        SourceFader(id: "input:" + selection.deviceUID, title: device?.name ?? "Unavailable input", levels: levels,
                                    channels: min(32, device?.inputChannels ?? 1), preservesSources: true)
                    }
                } else if source.microphoneUID != nil {
                    SourceFader(id: source.microphoneLevelID, title: "Microphone / input gain", levels: levels,
                                channels: min(2, recorder.audioSource.availableInputDevices().first { $0.uid == source.microphoneUID }?.inputChannels ?? 1), preservesSources: source.isMixed)
                }
                SourceFader(id: "master", title: source.isMixed ? "Master recording mix" : "Master saved recording", levels: levels, channels: 0, preservesSources: source.isMixed)
                Text(source.isMixed ? "Faders and mute affect the derived mix. Separate source tracks are still saved at unity gain. The mix averages source contributions for headroom; peaks above 0 dBFS are hard-clipped in the mix." : "Software gain and mute affect the saved recording. Single-source mode does not save a separate raw track. Peaks above 0 dBFS are hard-clipped.")
                    .font(.caption).foregroundStyle(.secondary)
                if let uid = source.microphoneUID { DeviceVolumeView(uid: uid, input: true) }
                Divider()
                ListeningControls(levels: .shared, title: "Playback output")
                Toggle("Monitor recording through headphones", isOn: Binding(get: { monitor.enabled }, set: { monitor.setEnabled($0, source: source) }))
                Text("Monitor plays the recording mix only while audio is captured. Use headphones to avoid acoustic feedback. Monitoring starts off and turns off after each take.")
                    .font(.caption).foregroundStyle(.secondary)
                if monitor.enabled { ListeningControls(levels: monitor.levels, title: "Live monitor output") }
                if let warning = monitor.warning { Text(warning).font(.caption).foregroundStyle(.orange) }
            }.padding(.top, 8)
            }.frame(height: 340)
        }.font(.callout).fixedSize(horizontal: false, vertical: true)
    }
}

struct SourceFader: View {
    let id: String
    let title: String
    @ObservedObject var levels: AudioLevels
    let channels: Int
    var preservesSources = false
    var context: String? = nil
    private var value: SourceLevel { levels.level(id) }
    private func change(_ body: (inout SourceLevel) -> Void) { var next = value; body(&next); levels.set(id, next) }
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title).fontWeight(.medium)
                Spacer()
                Text(String(format: "%+.1f dB", value.decibels)).monospacedDigit()
                Button("Reset") { levels.set(id, .init()) }.controlSize(.mini).accessibilityLabel("Reset \(context.map { "\($0) \(title)" } ?? title)")
            }
            if value.muted {
                AudioMuteBadge(title: preservesSources
                    ? (id == "master" ? "Recording mix muted" : "Muted in mix · source still saved")
                    : "Saved recording muted")
            }
            GainSlider(value: Binding(get: { value.decibels }, set: { newValue in change { $0.decibels = newValue } }),
                       label: context.map { "\($0) \(title)" } ?? title).frame(height: 30)
                .opacity(value.muted ? 0.5 : 1)
            Toggle(preservesSources ? "Mute in mix" : "Mute saved recording", isOn: Binding(get: { value.muted }, set: { newValue in change { $0.muted = newValue } }))
                .font(.caption).fixedSize(horizontal: false, vertical: true)
                .accessibilityLabel("\(context ?? title): \(preservesSources ? "mute in mix; source still saved" : "mute saved recording")")
                .help(preservesSources ? "Only the derived mix is muted. Original source tracks are still saved at unity gain." : "Muted audio is saved in this single-source recording.")
            if channels > 1 {
                DisclosureGroup("Mix channel trims (dB)") {
                    ForEach(0..<min(32, channels), id: \.self) { ch in
                        HStack {
                            Text("Ch \(ch + 1)")
                            GainSlider(value: Binding(get: { value.channelTrims[ch] ?? 0 }, set: { newValue in change { $0.channelTrims[ch] = newValue } }),
                                       label: "\(context ?? title) channel \(ch + 1) trim").frame(height: 30)
                            Text(String(format: "%+.1f", value.channelTrims[ch] ?? 0)).monospacedDigit().frame(width: 45)
                        }
                    }
                }.font(.caption)
            }
        }
    }
}

struct ListeningControls: View {
    @ObservedObject var levels: PlaybackLevels
    let title: String
    @State private var devices: [AudioOutputDevice] = []
    @State private var systemUID: String?
    private func change(_ body: (inout ListeningLevel) -> Void) { var next = levels.value; body(&next); levels.set(next) }
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(title).fontWeight(.medium)
                Spacer()
                Text("\(Int((levels.value.volume * 100).rounded()))%").monospacedDigit()
                Button("Reset") { levels.set(.init(volume: title == "Live monitor output" ? 0.5 : 1)) }.controlSize(.mini).accessibilityLabel("Reset \(title)")
            }
            if levels.value.muted {
                AudioMuteBadge(title: "Output muted · recording unchanged")
            } else if levels.value.volume == 0 {
                AudioMuteBadge(title: "Output volume 0% · recording unchanged")
            }
            HStack {
                Button { change { $0.muted.toggle() } } label: {
                    Image(systemName: levels.value.muted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                        .foregroundStyle(levels.value.muted ? Color.orange : Color.primary)
                }.accessibilityLabel("\(levels.value.muted ? "Unmute" : "Mute") \(title)")
                    .help(levels.value.muted ? "Output is muted. Saved recording levels are unchanged." : "Mute this listening output without changing the saved recording.")
                Slider(value: Binding(get: { Double(levels.value.volume) }, set: { v in change { $0.volume = Float(v) } }), in: 0...1)
                    .accessibilityLabel("\(title) volume").accessibilityValue("\(Int(levels.value.volume * 100)) percent")
                    .opacity(levels.value.muted ? 0.5 : 1)
            }
            Picker("Output device", selection: Binding(get: { levels.value.outputUID ?? "" }, set: { uid in change { $0.outputUID = uid.isEmpty ? nil : uid } })) {
                Text("Follow system output").tag("")
                ForEach(devices) { device in Text(device.name).tag(device.uid) }
                if let uid = levels.value.outputUID, !devices.contains(where: { $0.uid == uid }) { Text("Unavailable output").tag(uid) }
            }.accessibilityLabel("\(title) device")
            if let uid = levels.value.outputUID, !devices.contains(where: { $0.uid == uid }) {
                Text("Selected output unavailable · following system output").font(.caption).foregroundStyle(.orange)
            } else {
                Text("Listening on \(devices.first { $0.uid == (levels.value.outputUID ?? systemUID) }?.name ?? "system output")").font(.caption).foregroundStyle(.secondary)
            }
            DeviceVolumeView(uid: devices.contains(where: { $0.uid == levels.value.outputUID }) ? levels.value.outputUID : systemUID, input: false)
        }
        .task {
            while !Task.isCancelled {
                devices = AudioDeviceControls.outputs(); systemUID = AudioDeviceControls.defaultOutputUID()
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }
}

struct DeviceVolumeView: View {
    let uid: String?
    let input: Bool
    @State private var controls: [AudioDeviceControls.Volume] = []
    @State private var error: String?
    var body: some View {
        DisclosureGroup(input ? "Hardware input level (system-wide)" : "Hardware output volume (system-wide)") {
            if controls.isEmpty { Text("This device has no writable software volume control. Use its hardware controls or Sound settings.").font(.caption).foregroundStyle(.secondary) }
            ForEach(controls) { control in
                HStack {
                    Text(control.element == 0 ? "Device" : "Ch \(control.element)").font(.caption)
                    Slider(value: Binding(get: { Double(controls.first { $0.id == control.id }?.value ?? control.value) }, set: { value in
                        if AudioDeviceControls.set(control, value: Float(value)) {
                            controls = AudioDeviceControls.volumes(uid: uid, input: input); error = nil
                        } else { error = "Device level could not be changed. Check Sound settings." }
                    }), in: 0...1).accessibilityLabel("System-wide \(input ? "input" : "output") level channel \(control.element)")
                }
            }
            if let error { Text(error).font(.caption).foregroundStyle(.orange) }
            Button("Open Sound settings") { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Sound-Settings.extension")!) }
                .controlSize(.small)
            if input { Text("Software gain cannot repair clipping that already occurred in the input hardware.").font(.caption).foregroundStyle(.secondary) }
        }.font(.caption)
        .task(id: uid) {
            while !Task.isCancelled {
                controls = AudioDeviceControls.volumes(uid: uid, input: input)
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }
}

/// Shared audio transport and app-owned listening controls.
struct SessionPlaybackView: View {
    @ObservedObject var playback: SessionPlayback
    var body: some View {
        if playback.player != nil {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Button { playback.togglePlayback() } label: {
                        Image(systemName: playback.isPlaying ? "pause.fill" : "play.fill")
                    }.accessibilityLabel(playback.isPlaying ? "Pause playback" : "Resume playback")
                    Slider(value: Binding(get: { min(playback.position, max(0.001, playback.duration)) }, set: { playback.seek(to: $0) }), in: 0...max(0.001, playback.duration))
                        .disabled(playback.duration <= 0).accessibilityLabel("Playback position")
                    Text(String(format: "%.0f / %.0f s", playback.position, playback.duration)).font(.caption).monospacedDigit()
                    Button("Stop") { playback.stop() }
                }
                ListeningControls(levels: playback.levels, title: "Playback output")
            }
        }
    }
}
