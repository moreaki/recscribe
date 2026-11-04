import AVKit
import SwiftUI

struct RecordingLibraryView: View {
    @EnvironmentObject private var recorder: RecorderViewModel
    @EnvironmentObject private var library: SessionLibrary
    @Environment(\.glassTheme) private var theme
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow
    @StateObject private var playback = SessionPlayback()
    @State private var recordingToDelete: SessionEntry?
    @State private var showingDeleteConfirmation = false
    @State private var renamingEntryID: URL?
    @State private var draftTitle = ""
    var embeddedInStudio = false
    var onOpenStudio: (() -> Void)? = nil

    private func navigateToStudio() {
        if let onOpenStudio {
            onOpenStudio()
        } else {
            openWindow(id: AppWindow.studio.rawValue)
        }
    }

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
                    if panel.runModal() == .OK, let url = panel.url {
                        library.transcribe(url)
                        navigateToStudio()
                    }
                }.disabled(library.recordingActive)
                Button("Settings…") { openWindow(id: AppWindow.settings.rawValue) }
                Button("Studio", systemImage: "macwindow") { navigateToStudio() }
                Button("Refresh") { reload() }.disabled(library.refreshing)
            }
            if playback.loading { ProgressView("Loading session…") }
            SessionPlaybackView(playback: playback)
            List(library.entries) { entry in
                VStack(alignment: .leading, spacing: GlassSpacing.m) {
                    HStack(alignment: .top) {
                        WorkspaceIcon(symbol: "waveform", tint: WorkspaceStyle.blue)
                        VStack(alignment: .leading, spacing: 6) {
                            if renamingEntryID == entry.id {
                                HStack(spacing: GlassSpacing.s) {
                                    TextField("Recording title", text: $draftTitle)
                                        .textFieldStyle(.roundedBorder)
                                        .onSubmit {
                                            library.rename(entry, title: draftTitle)
                                            renamingEntryID = nil
                                        }
                                    Button("Save") {
                                        library.rename(entry, title: draftTitle)
                                        renamingEntryID = nil
                                    }.controlSize(.small)
                                    Button("Cancel") {
                                        renamingEntryID = nil
                                    }.controlSize(.small)
                                }
                            } else {
                                Text(entry.displayTitle).font(.headline)
                                if entry.session.title != nil {
                                    Text(entry.filenameStem).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            RecordingTimestampPill(date: entry.session.startedAt, tint: WorkspaceStyle.blue)
                        }
                        Spacer()
                        Text(entry.needsRecovery && !library.recordingActive ? "Not finalized — verify / recover" : entry.session.status.label).font(.caption).foregroundStyle(.secondary)
                    }
                    Text("\(entry.session.parts.count) parts · \(entry.session.duration.formatted(.number.precision(.fractionLength(1)))) s · \(entry.session.channels) channels · \(entry.session.sampleRate) Hz PCM")
                        .font(.caption).foregroundStyle(.secondary)
                    HStack {
                        Button(playback.playing == entry.session.id ? "Restart" : "Play session", systemImage: "play.fill") { playback.play(entry) }
                        Button("Transcribe", systemImage: "text.bubble") { library.transcribe(entry.id); navigateToStudio() }
                        Menu {
                            Button("Rename…", systemImage: "pencil") {
                                draftTitle = entry.session.title ?? entry.filenameStem
                                renamingEntryID = entry.id
                            }
                            if entry.session.title != nil {
                                Button("Reset title", systemImage: "arrow.counterclockwise") {
                                    library.rename(entry, title: "")
                                    if renamingEntryID == entry.id { renamingEntryID = nil }
                                }
                            }
                            Button("Transcribe & summarize", systemImage: "sparkles") {
                                library.transcribe(entry.id, summarize: true)
                                navigateToStudio()
                            }
                            ForEach(entry.session.sourceTracks ?? [], id: \.role) { source in
                                Menu(source.name) {
                                    Button("Play source track") { playback.playSource(source, parent: entry) }
                                    Button("Transcribe source track") {
                                        if let path = source.manifestPath,
                                           let url = try? RecordingSession.safeURL(path, beside: entry.id) {
                                            library.transcribe(url); navigateToStudio()
                                        }
                                    }
                                }.disabled(source.manifestPath == nil)
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
                        Button("Delete…", systemImage: "trash", role: .destructive) {
                            recordingToDelete = entry
                            showingDeleteConfirmation = true
                        }
                            .disabled(!library.canDeleteRecording)
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
                if embeddedInStudio {
                    Button("Back to Studio") { navigateToStudio() }
                } else {
                    Button("Close window") { dismissWindow(id: AppWindow.recordings.rawValue) }
                        .help("Close the Recordings window; background processing continues.")
                }
            }
            if let error = library.errorMessage { Text(error).foregroundStyle(theme.colors.statusWarning).font(.caption).textSelection(.enabled) }
        }.padding(GlassSpacing.xxl).frame(
            minWidth: embeddedInStudio ? 0 : AppWindow.recordings.minimumSize.width,
            minHeight: embeddedInStudio ? 0 : AppWindow.recordings.minimumSize.height
        )
            .background(WorkspaceStyle.background).tint(WorkspaceStyle.blue).glassThemeAdaptingToContrast().onAppear {
                playback.setRecording(library.recordingActive)
                reload()
            }
            .onDisappear { playback.stop(); library.cancelRefresh() }
            .onChange(of: library.recordingActive) { _, active in playback.setRecording(active) }
            .confirmationDialog("Move recording to Trash?", isPresented: $showingDeleteConfirmation, titleVisibility: .visible, presenting: recordingToDelete) { entry in
                Button("Move to Trash", role: .destructive) {
                    playback.stop()
                    library.moveToTrash(entry)
                }
                Button("Cancel", role: .cancel) {}
            } message: { entry in
                Text("\(entry.id.lastPathComponent.replacingOccurrences(of: ".recscribe.json", with: "")) and its audio parts and archives will be moved to Trash together. You can restore the folder from Trash. Existing transcripts and exports are kept.")
            }
    }
    private func reload() { library.load(URL(fileURLWithPath: recorder.saveLocationPath)) }
}
