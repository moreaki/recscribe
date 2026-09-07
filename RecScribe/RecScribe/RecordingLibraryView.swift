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
                VStack(alignment: .leading) {
                    Text("Your recordings").font(.title2.bold())
                    Text("One session. Every part. A continuous timeline.").foregroundStyle(.secondary)
                }
                Spacer()
                Button("Import WAV / session…") {
                    let panel = NSOpenPanel(); panel.canChooseDirectories = false
                    if panel.runModal() == .OK, let url = panel.url { library.transcribe(url) }
                }.disabled(library.recordingActive)
                Button("Settings…") { openWindow(id: AppWindow.settings.rawValue) }
                Button("Refresh") { reload() }.disabled(library.refreshing)
            }
            if playback.loading { ProgressView("Loading session…") }
            if let player = playback.player { VideoPlayer(player: player).frame(height: theme.metrics.controlHeightLarge * 2) }
            List(library.entries) { entry in
                VStack(alignment: .leading, spacing: GlassSpacing.m) {
                    HStack {
                        Image(systemName: "waveform").foregroundStyle(theme.colors.accent)
                        Text(entry.id.lastPathComponent.replacingOccurrences(of: ".recscribe.json", with: "")).font(.headline)
                        Spacer()
                        Text(entry.session.status == .recording && !library.recordingActive ? "Not finalized — verify / recover" : entry.session.status.label).font(.caption).foregroundStyle(.secondary)
                    }
                    Text("\(entry.session.parts.count) parts · \(entry.session.duration.formatted(.number.precision(.fractionLength(1)))) s · \(entry.session.channels) channels · \(entry.session.sampleRate) Hz PCM")
                        .font(.caption).foregroundStyle(.secondary)
                    HStack {
                        Button(playback.playing == entry.session.id ? "Restart" : "Play session") { playback.play(entry) }
                        Button("Transcribe") { library.transcribe(entry.id) }
                        Button("Verify / Recover") { library.enqueue(entry.id, recover: true) }
                        Button("Export…") {
                            let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false
                            if panel.runModal() == .OK, let url = panel.url {
                                Task { do { let result = try await library.export(entry.id, to: url); NSWorkspace.shared.activateFileViewerSelecting([result]) }
                                    catch is CancellationError { /* Cancellation is shown by the library, not an error alert. */ }
                                    catch { library.errorMessage = error.localizedDescription } }
                            }
                        }
                        Button("Reveal") { NSWorkspace.shared.activateFileViewerSelecting([entry.id]) }
                    }.buttonStyle(.borderless).disabled(library.recordingActive)
                    ForEach(entry.session.issues, id: \.self) { Text($0).font(.caption).foregroundStyle(theme.colors.statusWarning) }
                }.padding(.vertical, GlassSpacing.s)
            }.listStyle(.inset).overlay {
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
            .background(GlassWindowGround()).glassThemeAdaptingToContrast().onAppear { reload() }
            .onDisappear { playback.stop(); library.cancelRefresh() }
            .onChange(of: library.recordingActive) { _, active in if active { playback.stop() } }
    }
    private func reload() { library.load(URL(fileURLWithPath: recorder.saveLocationPath)) }
}
