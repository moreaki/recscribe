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
    let source: AudioSource
    @ObservedObject private var levels = AudioLevels.shared
    @ObservedObject private var playback = PlaybackLevels.shared
    @ObservedObject private var monitor = CapturedAudioMonitor.shared
    @ObservedObject private var monitorLevels = CapturedAudioMonitor.shared.levels

    private var mutedInputs: Int {
        source.inputSelections.filter { levels.level("input:" + $0.deviceUID).muted }.count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if levels.level("master").muted {
                AudioMuteBadge(title: source.isMixed ? "Recording mix muted" : "Saved recording muted")
                Text(source.isMixed ? "Original source tracks are still saved." : "The saved recording will be silent.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if (source.isMixed || source.microphoneUID == nil), levels.level(source.playbackLevelID).muted {
                AudioMuteBadge(title: source.isMixed ? "Playback muted in mix" : "Playback capture muted")
            }
            if mutedInputs > 0 {
                AudioMuteBadge(title: source.isMixed
                    ? "\(mutedInputs) \(mutedInputs == 1 ? "input" : "inputs") muted in mix"
                    : "Input recording muted")
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
    }
}
