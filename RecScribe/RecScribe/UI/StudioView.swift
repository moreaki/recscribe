import Observation
import SwiftUI

enum StudioWorkspaceMode: String, WorkspaceTab, CaseIterable {
    case studio = "Studio"
    case live = "Live"
    case recordings = "Recordings"
    case routing = "Audio Routing"
    case settings = "Settings"

    var symbol: String {
        switch self {
        case .studio: "waveform.circle"
        case .live: "waveform"
        case .routing: "slider.horizontal.below.rectangle"
        case .recordings: "rectangle.stack"
        case .settings: "slider.horizontal.3"
        }
    }

    var window: AppWindow {
        switch self {
        case .studio: .studio
        case .live: .live
        case .recordings: .recordings
        case .routing: .routing
        case .settings: .settings
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
        case .live: mode = .live
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
    @AppStorage(FocusAppearance.defaultsKey) private var appearance = FocusAppearance.system

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
        NavigationSplitView {
            List(selection: Binding<StudioWorkspaceMode?>(get: { workspaceMode }, set: { if let value = $0 { workspaceMode = value } })) {
                Section("Workspace") {
                    ForEach(StudioWorkspaceMode.allCases, id: \.self) { mode in
                        HStack {
                            Label(mode.rawValue, systemImage: mode.symbol)
                            Spacer(minLength: 8)
                            Text("⌘\(String(mode.window.commandKey))")
                                .font(.caption.monospaced()).foregroundStyle(.secondary)
                                .accessibilityHidden(true)
                        }.tag(mode).padding(.vertical, 5)
                            .help("\(mode.rawValue) (⌘\(String(mode.window.commandKey)))")
                    }
                }
            }
            .listStyle(.sidebar)
            .navigationTitle("RecScribe")
            .navigationSplitViewColumnWidth(min: 165, ideal: 185, max: 240)
        } detail: {
            VStack(spacing: 0) {
                if recorder.isRecording && workspaceMode != .live {
                    HStack {
                        Label("Live session", systemImage: "record.circle.fill")
                            .foregroundStyle(WorkspaceStyle.recording)
                        RecorderElapsedDisplay(telemetry: recorder.telemetry, fontSize: 13).frame(width: 72)
                        Text(recorder.captureSourceName ?? "System audio").foregroundStyle(.secondary).lineLimit(1)
                        Spacer()
                        Button("Stop") { Task { await recorder.stopRecording() } }
                        Button("Show Live", systemImage: "arrow.up.right") { workspaceMode = .live }
                    }.font(.callout).padding(12).background(WorkspaceStyle.panel)
                    Divider()
                }
                ZStack {
                    // Keep document and capture state alive when changing destinations.
                    TranscriptWorkspace(section: .transcript, playback: recorder.audio.makePlayback())
                        .opacity(workspaceMode == .studio ? 1 : 0)
                        .allowsHitTesting(workspaceMode == .studio).accessibilityHidden(workspaceMode != .studio)
                    FocusLiveWorkspace()
                        .opacity(workspaceMode == .live ? 1 : 0)
                        .allowsHitTesting(workspaceMode == .live).accessibilityHidden(workspaceMode != .live)
                    RecordingLibraryView(makePlayback: { recorder.audio.makePlayback() },
                        embeddedInStudio: true, isVisible: workspaceMode == .recordings,
                        onOpenStudio: { workspaceMode = .studio })
                        .opacity(workspaceMode == .recordings ? 1 : 0)
                        .allowsHitTesting(workspaceMode == .recordings).accessibilityHidden(workspaceMode != .recordings)
                    switch workspaceMode {
                    case .studio, .live, .recordings: EmptyView()
                    case .routing:
                        AudioRoutingView(levels: recorder.audio.levels, monitor: recorder.audio.monitor,
                            playbackLevels: recorder.audio.playbackLevels, hardwareObserver: recorder.audio.hardware,
                            embeddedInStudio: true)
                    case .settings:
                        ConfigurationView(liveDrafts: live.drafts, embeddedInStudio: true)
                    }
                }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            .navigationTitle(workspaceMode.rawValue)
            .background(WorkspaceStyle.background)
        }
        .navigationSplitViewStyle(.balanced)
        .frame(minWidth: AppWindow.studio.minimumSize.width, minHeight: AppWindow.studio.minimumSize.height)
        .background(WorkspaceStyle.background).tint(WorkspaceStyle.blue).studioThemeAdaptingToContrast()
        .onChange(of: appearance, initial: true) { _, value in value.apply() }
    }
}

private struct FocusLiveWorkspace: View {
    @Environment(RecorderViewModel.self) private var recorder
    @Environment(LiveTranscription.self) private var live
    @Environment(SessionLibrary.self) private var library
    @Environment(\.openWindow) private var openWindow
    @Environment(\.studioNavigation) private var navigation
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                RecorderView()
                if recorder.state == .idle, !recorder.isFinalizingAfterFailure,
                   let source = recorder.lastRecordingURL {
                    HStack {
                        Label("Recording saved", systemImage: "checkmark.circle").foregroundStyle(.secondary)
                        Spacer()
                        Button("Open in Studio", systemImage: "arrow.up.right") {
                            library.openRecordingInStudio(source)
                            AppWindow.open(.studio, using: openWindow, navigation: navigation)
                        }
                    }.font(.callout)
                }
                Divider()
                LiveTranscriptionControl(live: live, showsPreview: false)
                if live.enabled || live.captureNeedsReview || live.errorMessage != nil {
                    LiveTranscriptView(live: live, compact: true, recording: recorder.isRecording, focusLayout: true)
                        .frame(minHeight: 160, idealHeight: 230, maxHeight: 300)
                }
            }.padding(.horizontal, 36).padding(.vertical, 24).frame(maxWidth: 1100).frame(maxWidth: .infinity)
        }
    }
}
