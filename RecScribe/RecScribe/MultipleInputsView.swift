import SwiftUI

/// Compact entry point shared by the Studio, menu-bar popover and Settings.
struct MultipleInputsView: View {
    @ObservedObject var recorder: RecorderViewModel
    @Environment(\.openWindow) private var openWindow
    private var source: AudioSource { recorder.audioSource.selectedSource }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button("Audio routing…", systemImage: "point.3.connected.trianglepath.dotted") {
                NSApp.activate(ignoringOtherApps: true)
                openWindow(id: AppWindow.routing.rawValue)
            }
            if source.kind == .multiple {
                let count = source.inputSelections.count
                Text("Playback + \(count) \(count == 1 ? "input" : "inputs") → stereo recording mix")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Text("Connect apps and inputs, adjust channels, and choose a monitor output.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }.font(.callout)
    }
}
