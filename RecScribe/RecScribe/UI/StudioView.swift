import Observation
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

/// Scene-independent selection survives closing and recreating the Studio window.
@MainActor @Observable
final class StudioNavigation {
    var mode = StudioWorkspaceMode.studio

    func open(_ window: AppWindow, using open: (String) -> Void) {
        switch window {
        case .studio: mode = .studio
        case .routing: mode = .routing
        case .recordings: mode = .recordings
        case .settings: break
        }
        open((window == .settings ? AppWindow.settings : .studio).rawValue)
    }
}

extension EnvironmentValues {
    @Entry var studioNavigation: StudioNavigation? = nil
}

struct StudioView: View {
    @EnvironmentObject private var live: LiveTranscription
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.openWindow) private var openWindow
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
                Text("STUDIO").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                WorkspaceTabs(title: "Workspace", selection: Binding(get: { workspaceMode }, set: { workspaceMode = $0 }))
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
                Group {
                    switch workspaceMode {
                    case .studio:
                        TranscriptWorkspace()
                    case .routing:
                        AudioRoutingView(embeddedInStudio: true, onClose: { workspaceMode = .studio })
                    case .recordings:
                        RecordingLibraryView(embeddedInStudio: true, onOpenStudio: { workspaceMode = .studio })
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: AppWindow.studio.minimumSize.width, minHeight: AppWindow.studio.minimumSize.height)
        .background(WorkspaceStyle.background).tint(WorkspaceStyle.blue).glassThemeAdaptingToContrast()
    }
}
