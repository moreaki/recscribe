import Observation
import SwiftUI

enum StudioWorkspaceMode: String, WorkspaceTab, CaseIterable {
    case studio = "Studio"
    case routing = "Audio Routing"
    case recordings = "Recordings"
    case settings = "Settings"

    var symbol: String {
        switch self {
        case .studio: "waveform.circle"
        case .routing: "slider.horizontal.below.rectangle"
        case .recordings: "rectangle.stack"
        case .settings: "slider.horizontal.3"
        }
    }
}

/// Scene-independent selection survives closing and recreating the Studio window.
@MainActor @Observable
final class StudioNavigation {
    var mode = StudioWorkspaceMode.studio

    func open(_ window: AppWindow, using open: (String) -> Void) {
        switch window {
        case .studio: mode = .studio
        case .routing: mode = .routing
        case .recordings: mode = .recordings
        case .settings: mode = .settings
        }
        open(AppWindow.studio.rawValue)
    }
}

extension EnvironmentValues {
    @Entry var studioNavigation: StudioNavigation? = nil
}

struct StudioView: View {
    @Environment(RecorderViewModel.self) private var recorder
    @Environment(LiveTranscription.self) private var live
    @Environment(AppSettings.self) private var settings
    @Environment(\.studioNavigation) private var navigation
    @State private var initialMode: StudioWorkspaceMode

    private var workspaceMode: StudioWorkspaceMode {
        get { navigation?.mode ?? initialMode }
        nonmutating set {
            if let navigation { navigation.mode = newValue }
            else { initialMode = newValue }
        }
    }

    init(workspaceMode: StudioWorkspaceMode = .studio) {
        _initialMode = State(initialValue: workspaceMode)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: GlassSpacing.md) {
                GlassBrandLockup(size: .compact)
                WorkspaceTabs(title: "Workspace", selection: Binding(get: { workspaceMode }, set: { workspaceMode = $0 }))
                .frame(maxWidth: 560)
                Spacer()
                Label(live.cloudAudioActive ? "Cloud audio approved" : settings.values.processingLocation == .cloud ? "Cloud audio requires approval" : "Audio stays on your Mac",
                      systemImage: live.cloudAudioActive ? "cloud" : "lock.shield")
                    .font(.caption).foregroundStyle(live.cloudAudioActive ? .orange : WorkspaceStyle.mint)
            }.padding(WorkspaceStyle.contentPadding)
            Divider()
            HStack(alignment: .top, spacing: 0) {
                ScrollView {
                    VStack(spacing: GlassSpacing.xl) {
                        RecorderView()
                        Divider()
                        LiveTranscriptionControl(live: live, showsPreview: false)
                        Text("Recording always comes first. Transcription is optional. \(settings.values.processingLocation.detail)")
                            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                    }.padding(WorkspaceStyle.contentPadding)
                }.frame(width: WorkspaceStyle.railWidth)
                Divider()
                Group {
                    switch workspaceMode {
                    case .studio:
                        TranscriptWorkspace(playback: recorder.audio.makePlayback())
                    case .routing:
                        AudioRoutingView(levels: recorder.audio.levels, monitor: recorder.audio.monitor,
                            playbackLevels: recorder.audio.playbackLevels, hardwareObserver: recorder.audio.hardware,
                            embeddedInStudio: true)
                    case .recordings:
                        RecordingLibraryView(makePlayback: { recorder.audio.makePlayback() },
                            embeddedInStudio: true, onOpenStudio: { workspaceMode = .studio })
                    case .settings:
                        ConfigurationView(liveDrafts: live.drafts, embeddedInStudio: true)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
        .frame(minWidth: AppWindow.studio.minimumSize.width, minHeight: AppWindow.studio.minimumSize.height)
        .background(WorkspaceStyle.background).tint(WorkspaceStyle.blue).glassThemeAdaptingToContrast()
    }
}
