import SwiftUI

struct StudioView: View {
    @EnvironmentObject private var live: LiveTranscription
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: GlassSpacing.md) {
                GlassBrandLockup(size: .compact)
                Text("STUDIO").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                Spacer()
                Label(live.cloudAudioActive ? "Cloud audio approved" : settings.values.processingLocation == .cloud ? "Cloud audio requires approval" : "Audio stays on your Mac",
                      systemImage: live.cloudAudioActive ? "cloud" : "lock.shield")
                    .font(.caption).foregroundStyle(live.cloudAudioActive ? .orange : WorkspaceStyle.mint)
                Button("Recordings", systemImage: "rectangle.stack") { openWindow(id: AppWindow.recordings.rawValue) }
                SettingsPopover()
            }.padding(WorkspaceStyle.contentPadding)
            Divider()
            HStack(alignment: .top, spacing: 0) {
                ScrollView {
                VStack(spacing: GlassSpacing.xl) {
                    RecorderView()
                    Divider()
                    LiveTranscriptionControl(live: live)
                    Text("Recording always comes first. Transcription is optional. \(settings.values.processingLocation.detail)")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }.padding(WorkspaceStyle.contentPadding)
                }.frame(width: WorkspaceStyle.railWidth)
                Divider()
                TranscriptWorkspace().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: AppWindow.studio.minimumSize.width, minHeight: AppWindow.studio.minimumSize.height)
        .background(WorkspaceStyle.background).tint(WorkspaceStyle.blue).glassThemeAdaptingToContrast()
    }
}
