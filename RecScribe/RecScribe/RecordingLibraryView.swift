import AVKit
import SwiftUI

struct RecordingLibraryView: View {
    @EnvironmentObject private var recorder: RecorderViewModel
    @EnvironmentObject private var library: SessionLibrary
    @Environment(\.glassTheme) private var theme
    @Environment(\.openWindow) private var openWindow
    @StateObject private var playback = SessionPlayback()

    var body: some View {
        VStack(alignment: .leading, spacing: GlassSpacing.xl) {
            HStack {
                WorkspaceIcon(symbol: "rectangle.stack.fill", tint: WorkspaceStyle.mint)
                VStack(alignment: .leading) {
                    Text("Your recordings").font(.title2.bold())
                    Text("Listen, transcribe and make sense of your recordings.").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Import WAV / session…") {
                    let panel = NSOpenPanel(); panel.canChooseDirectories = false
                    if panel.runModal() == .OK, let url = panel.url { library.transcribe(url) }
                }.disabled(library.recordingActive)
                Button("Settings…") { openWindow(id: AppWindow.settings.rawValue) }
                Button("Studio", systemImage: "macwindow") { openWindow(id: AppWindow.studio.rawValue) }
                Button("Refresh") { reload() }.disabled(library.refreshing)
            }
            if playback.loading { ProgressView("Loading session…") }
            if let player = playback.player { VideoPlayer(player: player).frame(height: theme.metrics.controlHeightLarge * 2) }
            List(library.entries) { entry in
                VStack(alignment: .leading, spacing: GlassSpacing.m) {
                    HStack {
                        WorkspaceIcon(symbol: "waveform", tint: WorkspaceStyle.blue)
                        Text(entry.id.lastPathComponent.replacingOccurrences(of: ".recscribe.json", with: "")).font(.headline)
                        Spacer()
                        Text(entry.session.status == .recording && !library.recordingActive ? "Not finalized — verify / recover" : entry.session.status.label).font(.caption).foregroundStyle(.secondary)
                    }
                    Text("\(entry.session.parts.count) parts · \(entry.session.duration.formatted(.number.precision(.fractionLength(1)))) s · \(entry.session.channels) channels · \(entry.session.sampleRate) Hz PCM")
                        .font(.caption).foregroundStyle(.secondary)
                    HStack {
                        Button(playback.playing == entry.session.id ? "Restart" : "Play session", systemImage: "play.fill") { playback.play(entry) }
                        Button("Transcribe", systemImage: "text.bubble") { library.transcribe(entry.id); openWindow(id: AppWindow.studio.rawValue) }
                        Menu {
                            Button("Transcribe & summarize", systemImage: "sparkles") {
                                library.transcribe(entry.id, summarize: true)
                                openWindow(id: AppWindow.studio.rawValue)
                            }
                            Button("Verify / Recover", systemImage: "checkmark.shield") { library.enqueue(entry.id, recover: true) }
                            Button("Reveal", systemImage: "folder") { NSWorkspace.shared.activateFileViewerSelecting([entry.id]) }
                        } label: { Label("More", systemImage: "ellipsis.circle") }
                        Button("Export…") {
                            let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false
                            if panel.runModal() == .OK, let url = panel.url {
                                Task { do { let result = try await library.export(entry.id, to: url); NSWorkspace.shared.activateFileViewerSelecting([result]) }
                                    catch is CancellationError { /* Cancellation is shown by the library, not an error alert. */ }
                                    catch { library.errorMessage = error.localizedDescription } }
                            }
                        }
                    }.buttonStyle(.borderless).disabled(library.recordingActive || library.liveWorkActive)
                    ForEach(entry.session.issues, id: \.self) { Text($0).font(.caption).foregroundStyle(theme.colors.statusWarning) }
                }.padding(.vertical, GlassSpacing.s)
            }.listStyle(.inset).scrollContentBackground(.hidden).overlay {
                if library.entries.isEmpty { ContentUnavailableView("No sessions yet", systemImage: "waveform", description: Text("New recordings appear here. Existing WAV files can be imported for optional transcription.")) }
            }
            ForEach(library.readFailures) { failure in
                Text("\(failure.id.lastPathComponent): \(failure.message)")
                    .font(.caption).foregroundStyle(theme.colors.statusWarning).textSelection(.enabled)
            }
            if let error = playback.errorMessage { Text(error).foregroundStyle(theme.colors.statusWarning) }
            HStack {
                ProgressView(value: library.progress).frame(width: theme.metrics.controlHeightMedium * 3)
                Text(library.activity).font(.caption)
                Spacer()
                if let job = library.latestJob { Button("Job artifacts") { NSWorkspace.shared.activateFileViewerSelecting([job]) } }
                Button("Cancel work") { library.cancel() }
            }
            if let error = library.errorMessage { Text(error).foregroundStyle(theme.colors.statusWarning).font(.caption).textSelection(.enabled) }
        }.padding(GlassSpacing.xxl).frame(minWidth: AppWindow.recordings.minimumSize.width, minHeight: AppWindow.recordings.minimumSize.height)
            .background(WorkspaceStyle.background).tint(WorkspaceStyle.blue).glassThemeAdaptingToContrast().onAppear {
                playback.setRecording(library.recordingActive)
                reload()
            }
            .onDisappear { playback.stop(); library.cancelRefresh() }
            .onChange(of: library.recordingActive) { _, active in playback.setRecording(active) }
    }
    private func reload() { library.load(URL(fileURLWithPath: recorder.saveLocationPath)) }
}
