import AppKit
import SwiftUI

/// Editing a card never changes capture selection implicitly. Only channel routes
/// use the locked capture graph; software levels retain their existing live path.
struct CompactRoutingSourceCard<Accessory: View, CaptureAction: View>: View {
    let id: String
    let title: String
    let subtitle: String
    let uid: String?
    let track: CaptureTrack
    let channels: Int
    let channelNames: [String]
    let routes: Binding<[InputChannelRoute]>?
    let editable: Bool
    let available: Bool
    let captured: Bool
    let preservesSources: Bool
    @Bindable var levels: AudioLevels
    let hardware: AudioHardwareObserver
    @ViewBuilder var accessory: () -> Accessory
    @ViewBuilder var captureAction: () -> CaptureAction
    @State private var meterChannel = -1
    @State private var firstChannel = 0
    @FocusState private var channelFocus: ChannelFocus?

    private var value: SourceLevel { levels.level(id) }
    private enum ChannelFocus: Hashable {
        case left(Int), right(Int), trim(Int)
        var channel: Int { switch self { case .left(let i), .right(let i), .trim(let i): i } }
    }
    private func change(_ edit: (inout SourceLevel) -> Void) {
        var next = levels.level(id); edit(&next); levels.set(id, next)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            header.frame(height: 32)
            GeometryReader { geometry in
                let width = max(0, geometry.size.width - 30)
                HStack(alignment: .top, spacing: 10) {
                    gain.frame(width: width * 0.22)
                    CompactDeviceInputLevel(uid: uid, available: available && captured, observer: hardware)
                        .frame(width: width * 0.22)
                    connections.frame(width: width * 0.34)
                    CompactRoutingSignal(track: track, sourceName: title, channels: channels,
                        selectedChannel: $meterChannel, captured: captured)
                        .frame(width: width * 0.22)
                }
            }.frame(height: 56)
        }
        .padding(8).frame(height: 110)
        .background(WorkspaceStyle.panel, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(
            value.muted || !available ? Color.orange.opacity(0.7) : WorkspaceStyle.border))
        .accessibilityElement(children: .contain).accessibilityLabel(title)
        .onChange(of: channels) { _, count in
            if meterChannel >= count { meterChannel = -1 }
            firstChannel = min(firstChannel, max(0, count - 1))
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: uid == nil ? "app.connected.to.app.below.fill" : "mic.fill")
                .foregroundStyle(.secondary).frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(title).font(.callout.weight(.semibold)).lineLimit(1).help(title)
                    CompactRoutingStatus(track: track, muted: value.muted, available: available,
                        captured: captured, preservesSources: preservesSources)
                }
                HStack(spacing: 6) {
                    Text(subtitle).font(.caption2).foregroundStyle(.secondary).lineLimit(1).help(subtitle)
                    accessory()
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
            captureAction()
            AudioRoutingMuteButton(title: title, muted: value.muted) { change { $0.muted.toggle() } }
                .disabled(!captured)
            Button { levels.set(id, .init()) } label: { Image(systemName: "arrow.counterclockwise") }
                .controlSize(.small).help("Reset gain & mute")
                .accessibilityLabel("Reset gain & mute for \(title)")
                .disabled(!captured)
        }
    }

    private var gain: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 3) {
                Text(preservesSources ? "Mix gain" : "Saved gain")
                    .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                Spacer(minLength: 0)
                TextField("dB", value: Binding(get: { value.decibels }, set: { proposed in
                    if proposed.isFinite { change { $0.decibels = min(24, max(-60, proposed)) } }
                }), format: .number.precision(.fractionLength(1)))
                    .textFieldStyle(.plain).focusEffectDisabled()
                    .padding(.horizontal, 5).padding(.vertical, 2)
                    .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 5))
                    .frame(width: 46)
                    .accessibilityLabel("\(title) mix gain in decibels")
                Text("dB").foregroundStyle(.secondary)
            }.font(.caption).frame(height: 20)
            GainSlider(value: Binding(get: { value.decibels }, set: { proposed in
                change { $0.decibels = proposed }
            }), label: "\(title) mix gain").frame(height: 32)
        }.disabled(!captured)
    }

    private var connections: some View {
        ScrollViewReader { proxy in
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 2) {
                    Text("Channels · L / R · trim dB").lineLimit(1)
                    Spacer(minLength: 0)
                    Text("\(firstChannel + 1)/\(channels)").monospacedDigit()
                    Button { scroll(-2, proxy: proxy) } label: { Image(systemName: "chevron.left") }
                        .disabled(firstChannel == 0).accessibilityLabel("Previous channels for \(title)")
                    Button { scroll(2, proxy: proxy) } label: { Image(systemName: "chevron.right") }
                        .disabled(firstChannel >= channels - 1).accessibilityLabel("Next channels for \(title)")
                }.font(.system(size: 9)).foregroundStyle(.secondary).buttonStyle(.plain).frame(height: 14)
                ScrollView(.horizontal) {
                    HStack(spacing: 5) {
                        ForEach(0..<channels, id: \.self) { channel in
                            channelCell(channel).id(channel)
                        }
                    }
                }.scrollIndicators(.hidden).frame(height: 41)
                    .onChange(of: channelFocus) { _, focused in
                        guard let channel = focused?.channel else { return }
                        firstChannel = channel; proxy.scrollTo(channel, anchor: .leading)
                    }
            }
        }
    }

    private func scroll(_ delta: Int, proxy: ScrollViewProxy) {
        firstChannel = min(channels - 1, max(0, firstChannel + delta))
        proxy.scrollTo(firstChannel, anchor: .leading)
    }
    private func channelCell(_ channel: Int) -> some View {
        let name = channelNames.indices.contains(channel) ? channelNames[channel] : "Channel \(channel + 1)"
        let placement = routes?.wrappedValue.first { $0.channel == channel }?.placement
        let left = routes == nil ? channel == 0 : placement == .left || placement == .center
        let right = routes == nil ? channel == 1 : placement == .right || placement == .center
        return VStack(spacing: 1) {
            HStack(spacing: 2) {
                Button("\(channel + 1)") { meterChannel = channel }
                    .buttonStyle(.plain).frame(width: 13).help(name)
                    .accessibilityLabel("Show levels for \(title) \(name)")
                connection("L", channel: channel, connected: left) { route(channel, left: !left, right: right) }
                    .focused($channelFocus, equals: .left(channel))
                connection("R", channel: channel, connected: right) { route(channel, left: left, right: !right) }
                    .focused($channelFocus, equals: .right(channel))
            }.frame(height: 19)
            TextField("Trim", value: Binding(get: { value.channelTrims[channel] ?? 0 }, set: { proposed in
                if proposed.isFinite { change { $0.channelTrims[channel] = min(24, max(-60, proposed)) } }
            }), format: .number.precision(.fractionLength(1)))
                .textFieldStyle(.plain).focusEffectDisabled()
                .padding(.horizontal, 5).padding(.vertical, 2)
                .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 5))
                .font(.caption2).frame(height: 18)
                .focused($channelFocus, equals: .trim(channel))
                .accessibilityLabel("\(title) \(name) trim in decibels")
                .disabled(!captured)
        }.font(.caption2).frame(width: 66)
    }
    private func connection(_ side: String, channel: Int, connected: Bool, action: @escaping () -> Void) -> some View {
        Button(side, action: action).buttonStyle(.plain).frame(width: 23, height: 19)
            .foregroundStyle(connected ? WorkspaceStyle.mint : Color.secondary)
            .background(connected ? WorkspaceStyle.mint.opacity(0.13) : Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 4))
            .disabled(!editable || !available || !captured || routes == nil)
            .accessibilityLabel("\(title) channel \(channel + 1) to \(side == "L" ? "left" : "right")")
            .accessibilityValue(connected ? "Connected" : "Disconnected")
            .help(routes == nil ? "Playback uses fixed stereo connections" : editable ? "Change this channel's mix connection" : "Stop capture before changing connections")
    }
    private func route(_ channel: Int, left: Bool, right: Bool) {
        guard editable, available, captured, let routes else { return }
        var next = routes.wrappedValue.filter { $0.channel != channel }
        if let placement: InputMixPlacement = left && right ? .center : left ? .left : right ? .right : nil {
            next.append(.init(channel: channel, placement: placement))
        }
        routes.wrappedValue = next
    }
}

/// Mounted only while the routing card is visible; hardware listeners are released
/// on disappearance or device changes. No device writes occur when refreshing.
struct CompactDeviceInputLevel: View {
    let uid: String?
    let available: Bool
    let observer: AudioHardwareObserver
    @State private var controls: [AudioDeviceControls.Volume] = []
    @State private var selected: UInt32 = 0
    @State private var token: UUID?
    @State private var error: String?
    private var control: AudioDeviceControls.Volume? { controls.first { $0.element == selected } }

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 2) {
                Text("Device · system-wide").lineLimit(1)
                Spacer(minLength: 0)
                Button { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Sound-Settings.extension")!) }
                    label: { Image(systemName: "arrow.up.right") }
                    .buttonStyle(.plain).accessibilityLabel("Open Sound settings")
            }.font(.caption2).foregroundStyle(.secondary).frame(height: 14)
            if let control, available {
                HStack(spacing: 3) {
                    if controls.count > 1 {
                        Picker("Hardware channel", selection: $selected) {
                            ForEach(controls) { item in Text(item.element == 0 ? "Device" : "Ch \(item.element)").tag(item.element) }
                        }.labelsHidden().controlSize(.mini).frame(maxWidth: 70)
                    } else { Text(control.element == 0 ? "Device" : "Ch \(control.element)") }
                    Text(error == nil ? "\(Int(control.value * 100))%" : "Failed")
                        .foregroundStyle(error == nil ? Color.secondary : Color.orange).help(error ?? "System-wide input level")
                }.font(.caption2).frame(height: 20)
                Slider(value: Binding(get: { Double(self.control?.value ?? 0) }, set: { next in
                    guard let active = self.control else { return }
                    if AudioDeviceControls.set(active, value: Float(next)) { error = nil; refresh() }
                    else { error = "Device level could not be changed. Check Sound settings." }
                }), in: 0...1).controlSize(.mini).frame(height: 18)
                    .accessibilityLabel("System-wide hardware input level \(control.element == 0 ? "device" : "channel \(control.element)")")
            } else {
                Text(uid == nil ? "Not applicable" : available ? "No writable control" : "Unavailable")
                    .lineLimit(1).font(.caption2).foregroundStyle(.secondary).frame(height: 20)
                Text(uid == nil ? "Playback source" : "Use device controls").font(.system(size: 9)).foregroundStyle(.secondary)
            }
        }
        .onAppear { watch() }
        .onChange(of: uid) { _, _ in watch() }
        .onChange(of: available) { _, _ in watch() }
        .onDisappear { observer.unwatchDevice(token); token = nil }
    }
    private func refresh() {
        controls = available ? AudioDeviceControls.volumes(uid: uid, input: true) : []
        if !controls.contains(where: { $0.element == selected }) { selected = controls.first?.element ?? 0 }
    }
    private func watch() {
        observer.unwatchDevice(token); token = nil; refresh()
        guard available, let uid else { return }
        token = observer.watchDevice(uid: uid, inputScope: true, includeVolumes: true) { refresh() }
    }
}

/// Fast meters subscribe at the leaf, keeping source controls out of 10-Hz updates.
private struct CompactRoutingSignal: View {
    @Environment(RecorderViewModel.self) private var recorder
    let track: CaptureTrack
    let sourceName: String
    let channels: Int
    @Binding var selectedChannel: Int
    let captured: Bool
    var body: some View {
        VStack(spacing: 1) {
            HStack(spacing: 2) {
                Text("dBFS").foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Picker("\(sourceName) level channel", selection: $selectedChannel) {
                    Text("All").tag(-1)
                    ForEach(0..<channels, id: \.self) { Text("Ch \($0 + 1)").tag($0) }
                }.labelsHidden().controlSize(.mini).frame(maxWidth: 65)
            }.font(.caption2).frame(height: 14)
            if captured && recorder.isRecording {
                RecordingCompactPeaks(telemetry: recorder.telemetry, track: track, channel: selectedChannel)
            } else if let test = recorder.audioTest, captured {
                PreviewCompactPeaks(test: test, track: track, channel: selectedChannel)
            } else {
                CompactPeakPair(meters: .init(), now: 0, channel: selectedChannel)
            }
        }
    }
}
private struct PreviewCompactPeaks: View {
    @Bindable var test: AudioTestController
    let track: CaptureTrack
    let channel: Int
    var body: some View { CompactPeakPair(meters: test.meters[track] ?? .init(), now: test.now, channel: channel) }
}
private struct RecordingCompactPeaks: View {
    @Bindable var telemetry: RecorderTelemetry
    let track: CaptureTrack
    let channel: Int
    var body: some View {
        CompactPeakPair(meters: telemetry.sourceMeters[track] ?? .init(), now: telemetry.healthTime, channel: channel,
            fallback: telemetry.sourceHealth.first { $0.id == track.rawValue || $0.id == "capture" }?.health)
    }
}
private struct CompactPeakPair: View {
    let meters: CaptureSourceMeters
    let now: TimeInterval
    let channel: Int
    var fallback: RecordingHealth? = nil
    var body: some View {
        VStack(spacing: 4) {
            bar("Input", meter: meters.raw, fallback: fallback?.peak)
            bar("Mix", meter: meters.processed, fallback: fallback?.postPeak)
        }.frame(height: 40)
    }
    private func bar(_ title: String, meter: CapturePeakMeter, fallback: Float?) -> some View {
        let values = meter.current(at: now)
        let peak = channel < 0 ? values.max() : values.indices.contains(channel) ? values[channel] : nil
        let current = peak ?? ((channel < 0 || self.fallback?.channels == 1) ? fallback : nil)
        let hold = channel < 0 ? meter.hold.max() : meter.hold.indices.contains(channel) ? meter.hold[channel] : nil
        let number = current.map { $0 > 0.000001 ? String(format: "%.0f", 20 * log10($0)) : "−∞" } ?? "—"
        return HStack(spacing: 3) {
            Text(title).frame(width: 25, alignment: .leading).foregroundStyle(.secondary)
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.1))
                    Capsule().fill((current ?? 0) > 1 ? Color.orange : WorkspaceStyle.mint)
                        .frame(width: g.size.width * fraction(current ?? 0))
                    if let hold, hold > 0 {
                        Rectangle().fill(hold >= 1 ? Color.orange : Color.secondary).frame(width: 1)
                            .offset(x: max(0, (g.size.width - 1) * fraction(hold)))
                    }
                }
            }.frame(height: 5)
            Text(number).monospacedDigit().frame(width: 25, alignment: .trailing)
        }.font(.system(size: 10)).frame(height: 16)
            .accessibilityElement(children: .ignore).accessibilityLabel("\(title) level")
            .accessibilityValue(current == nil ? "No channel data" : "\(number) dBFS, held peak \(hold.map { String(format: "%.1f", 20 * log10(max(0.000001, $0))) } ?? "unavailable") dBFS")
    }
    private func fraction(_ v: Float) -> Double { max(0, min(1, (20 * log10(Double(max(0.000001, v))) + 60) / 60)) }
}

private struct CompactRoutingStatus: View {
    @Environment(RecorderViewModel.self) private var recorder
    let track: CaptureTrack
    let muted: Bool
    let available: Bool
    let captured: Bool
    let preservesSources: Bool
    var body: some View {
        if !captured { label("Not captured") }
        else if !available { label("Unavailable · reconnecting") }
        else if recorder.isRecording {
            RecordingCompactStatus(telemetry: recorder.telemetry, track: track, muted: muted, preservesSources: preservesSources)
        } else if let test = recorder.audioTest {
            PreviewCompactStatus(test: test, track: track, muted: muted, preservesSources: preservesSources)
        } else { label(muted ? (preservesSources ? "Muted in mix" : "Capture muted") : "Ready") }
    }
    private func label(_ text: String) -> some View { Text(text).font(.caption2).foregroundStyle(.secondary).lineLimit(1).help(text) }
}
private struct PreviewCompactStatus: View {
    @Bindable var test: AudioTestController
    let track: CaptureTrack
    let muted: Bool
    let preservesSources: Bool
    var body: some View {
        CompactSourceStatusText(health: test.health.first { $0.id == track.rawValue }?.health,
            meters: test.meters[track], now: test.now, active: test.isCapturing, preview: true,
            muted: muted, preservesSources: preservesSources)
    }
}
private struct RecordingCompactStatus: View {
    @Bindable var telemetry: RecorderTelemetry
    let track: CaptureTrack
    let muted: Bool
    let preservesSources: Bool
    var body: some View {
        CompactSourceStatusText(health: telemetry.sourceHealth.first { $0.id == track.rawValue || $0.id == "capture" }?.health,
            meters: telemetry.sourceMeters[track], now: telemetry.healthTime, active: true, preview: false,
            muted: muted, preservesSources: preservesSources)
    }
}
private struct CompactSourceStatusText: View {
    let health: RecordingHealth?
    let meters: CaptureSourceMeters?
    let now: TimeInterval
    let active: Bool
    let preview: Bool
    let muted: Bool
    let preservesSources: Bool
    private var message: String {
        if active, let health {
            switch health.status(at: now) {
            case .failed: return "Capture failed"
            case .noData: return "No data"
            case .stalled: return "Source data stopped"
            case .writeStalled: return "Processing stalled"
            case .waiting: return "Waiting for audio"
            default: break
            }
        }
        if meters?.raw.hold.contains(where: { $0 >= 1 }) == true { return "Input clips" }
        if meters?.processed.hold.contains(where: { $0 > 1 }) == true { return "Mix clips" }
        if muted { return preservesSources ? "Muted in mix" : "Capture muted" }
        if !active { return health == nil ? "Ready" : "Test stopped · held peaks" }
        if health?.status(at: now) == .silence { return "Receiving silence" }
        return health == nil ? "Waiting for audio" : preview ? "Preview" : "Recording"
    }
    var body: some View {
        Text(message).font(.caption2).lineLimit(1).foregroundStyle(muted || health?.failed == true || message.contains("clips") || message.contains("stopped") || message.contains("stalled") || message == "No data" ? Color.orange : Color.secondary)
            .help(health?.failureMessage ?? message)
    }
}

/// Long failures belong below the list, so they cannot change one card's height.
struct CompactRoutingSourceAlerts: View {
    @Environment(RecorderViewModel.self) private var recorder
    var body: some View {
        if recorder.isRecording { RecordingSourceAlerts(telemetry: recorder.telemetry) }
        else if let test = recorder.audioTest { PreviewSourceAlerts(test: test) }
    }
}
private struct RecordingSourceAlerts: View {
    @Bindable var telemetry: RecorderTelemetry
    var body: some View { alerts(telemetry.sourceHealth) }
}
private struct PreviewSourceAlerts: View {
    @Bindable var test: AudioTestController
    var body: some View { alerts(test.health) }
}
@ViewBuilder private func alerts(_ health: [SourceRecordingHealth]) -> some View {
    ForEach(health) { item in
        if let message = item.health.failureMessage {
            Label("\(item.name): \(message)", systemImage: "exclamationmark.triangle")
                .font(.caption2).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
        }
    }
}
