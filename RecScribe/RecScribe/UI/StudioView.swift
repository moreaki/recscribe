import SwiftUI

enum StudioWorkspaceMode: String, WorkspaceTab, CaseIterable {
    case studio = "Studio"
    case routing = "Audio Routing"
    case recordings = "Recordings"

    var symbol: String {
        switch self {
        case .studio: "waveform.circle"
        case .routing: "slider.horizontal.below.rectangle"
        case .recordings: "rectangle.stack"
        }
    }
}

extension Notification.Name {
    static let recScribeSwitchWorkspaceMode = Notification.Name("recScribe.switchWorkspaceMode")
}

struct StudioView: View {
    @EnvironmentObject private var live: LiveTranscription
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.openWindow) private var openWindow
    @State private var workspaceMode: StudioWorkspaceMode

    init(workspaceMode: StudioWorkspaceMode = .studio) {
        _workspaceMode = State(initialValue: workspaceMode)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: GlassSpacing.md) {
                GlassBrandLockup(size: .compact)
                Text("STUDIO").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                WorkspaceTabs(title: "Workspace", selection: $workspaceMode)
                    .frame(maxWidth: 420)
                Spacer()
                Label(live.cloudAudioActive ? "Cloud audio approved" : settings.values.processingLocation == .cloud ? "Cloud audio requires approval" : "Audio stays on your Mac",
                      systemImage: live.cloudAudioActive ? "cloud" : "lock.shield")
                    .font(.caption).foregroundStyle(live.cloudAudioActive ? .orange : WorkspaceStyle.mint)
                Button("Recordings", systemImage: "rectangle.stack") {
                    workspaceMode = .recordings
                }
                SettingsWindowButton()
            }.padding(WorkspaceStyle.contentPadding)
            Divider()
            switch workspaceMode {
            case .studio:
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
            case .routing:
                AudioRoutingView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .recordings:
                RecordingLibraryView(embeddedInStudio: true, onOpenStudio: { workspaceMode = .studio })
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: AppWindow.studio.minimumSize.width, minHeight: AppWindow.studio.minimumSize.height)
        .background(WorkspaceStyle.background).tint(WorkspaceStyle.blue).glassThemeAdaptingToContrast()
        .onReceive(NotificationCenter.default.publisher(for: .recScribeSwitchWorkspaceMode)) { notification in
            if let mode = notification.object as? StudioWorkspaceMode {
                workspaceMode = mode
            }
        }
    }
}
