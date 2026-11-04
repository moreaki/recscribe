import SwiftUI

/// Text and an icon keep mute visible without relying on a checkbox or colour.
struct AudioMuteBadge: View {
    var title = "Muted"

    var body: some View {
        Label(title, systemImage: "speaker.slash.fill")
            .font(.caption.weight(.medium))
            .foregroundStyle(.orange)
            .padding(.horizontal, 7).padding(.vertical, 3)
            .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 5))
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityElement(children: .combine)
    }
}

/// Always visible beside the routing entry point, even with Audio levels closed.
/// Observe listening preferences directly: the monitor does not republish them.
struct AudioMuteSummary: View {
    private let appName: (String) -> String?
    private let names = RoutingSourceNames.shared
    private let hardware = AudioHardwareObserver.shared
    let source: AudioSource
    @Bindable private var levels: AudioLevels
    @Bindable private var playback: PlaybackLevels
    @Bindable private var monitor: CapturedAudioMonitor
    @Bindable private var monitorLevels: PlaybackLevels

    init(source: AudioSource, audio: AudioServices, appName: @escaping (String) -> String? = { _ in nil }) {
        self.appName = appName
        self.source = source
        levels = audio.levels
        playback = audio.playbackLevels
        monitor = audio.monitor
        monitorLevels = audio.monitor.levels
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if levels.level("master").muted {
                AudioMuteBadge(title: source.isMixed ? "Recording mix muted" : "Saved recording muted")
                Text(source.isMixed ? "Original source tracks are still saved." : "The saved recording will be silent.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            ForEach(Array(names.mutedSources(source, levels: levels, appName: appName).enumerated()), id: \.offset) { _, name in
                AudioMuteBadge(title: "\(name) \(source.isMixed ? "muted in mix" : "capture muted")")
            }
            if monitorLevels.value.muted {
                AudioMuteBadge(title: monitor.enabled ? "Monitor output muted" : "Monitor off · output muted")
            } else if monitor.enabled, monitorLevels.value.volume == 0 {
                AudioMuteBadge(title: "Monitor output at 0%")
            }
            if playback.value.muted {
                AudioMuteBadge(title: "Recording playback muted")
            } else if playback.value.volume == 0 {
                AudioMuteBadge(title: "Recording playback at 0%")
            }
        }
        .onAppear { names.remember(hardware.inputDevices) }
        .onChange(of: hardware.revision) { _, _ in names.remember(hardware.inputDevices) }
    }
}
