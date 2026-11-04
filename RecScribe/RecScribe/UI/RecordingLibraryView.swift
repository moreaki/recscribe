import AVKit
import SwiftUI

struct RecordingLibraryView: View {
    @Environment(RecorderViewModel.self) private var recorder
    @Environment(SessionLibrary.self) private var library
    @Environment(\.glassTheme) private var theme
    @Environment(\.openWindow) private var openWindow
    @Environment(\.studioNavigation) private var navigation
    @Environment(\.dismissWindow) private var dismissWindow
    @State private var playback: SessionPlayback
    @State private var recordingToDelete: SessionEntry?
    @State private var showingDeleteConfirmation = false
    var embeddedInStudio = false
    var onOpenStudio: (() -> Void)? = nil

    init(makePlayback: @escaping () -> SessionPlayback = { SessionPlayback() },
         embeddedInStudio: Bool = false, onOpenStudio: (() -> Void)? = nil) {
        _playback = State(initialValue: makePlayback())
        self.embeddedInStudio = embeddedInStudio
        self.onOpenStudio = onOpenStudio
    }

    private func navigateToStudio() {
        if let onOpenStudio {
            onOpenStudio()
        } else {
            AppWindow.open(.studio, using: openWindow, navigation: navigation)
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
                Button("Refresh") { reload() }.disabled(library.refreshing)
            }
            if playback.loading { ProgressView("Loading session…") }
            SessionPlaybackView(playback: playback)
            List(library.entries) { entry in
                VStack(alignment: .leading, spacing: GlassSpacing.m) {
                    HStack(alignment: .top) {
                        WorkspaceIcon(symbol: "waveform", tint: WorkspaceStyle.blue)
                        VStack(alignment: .leading, spacing: 6) {
                            SessionTitleView(entry: entry, library: library)
                            if entry.session.title != nil {
                                Text(entry.filenameStem).font(.caption).foregroundStyle(.secondary)
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
                            if entry.session.title != nil {
                                Button("Reset title", systemImage: "arrow.counterclockwise") {
                                    Task { await library.rename(entry, title: "") }
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
                if !embeddedInStudio {
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
                    Task { await library.moveToTrash(entry) }
                }
                Button("Move recording and verified transcript jobs to Trash", role: .destructive) {
                    playback.stop()
                    Task { await library.moveToTrash(entry, includeDerivedJobs: true) }
                }
                Button("Cancel", role: .cancel) {}
            } message: { entry in
                Text("\(entry.displayTitle) and its audio parts and archives move together. By default transcripts are kept. The second option also groups finished jobs with a verified source identity under Transcripts in the same Trash folder. Active or unverifiable jobs and raw Live drafts are kept. You can restore the folder from Trash.")
            }
    }
    private func reload() { library.load(URL(fileURLWithPath: recorder.saveLocationPath)) }
}

/// Shared inline editor for the library and the transcript's source header.
struct SessionTitleView: View {
    let entry: SessionEntry
    @Bindable var library: SessionLibrary
    var allowsEditing = true
    var onRenamed: (SessionEntry) -> Void = { _ in }
    @State private var editing = false
    @State private var saving = false
    @State private var title = ""

    var body: some View {
        HStack {
            if editing {
                TextField("Recording title", text: $title).textFieldStyle(.roundedBorder).onSubmit(save)
                    .disabled(!allowsEditing)
                Button("Save", action: save).disabled(!allowsEditing || !library.canDeleteRecording)
                Button("Cancel") { editing = false }
            } else {
                Text(entry.displayTitle).font(.headline).lineLimit(1).truncationMode(.middle).help(entry.displayTitle)
                Button {
                    title = entry.session.title ?? entry.filenameStem
                    editing = true
                } label: { Image(systemName: "pencil") }
                .buttonStyle(.plain).accessibilityLabel("Rename recording")
                .disabled(!allowsEditing || !library.canDeleteRecording)
            }
        }.controlSize(.small).disabled(saving)
    }

    private func save() {
        guard !saving else { return }
        saving = true
        Task {
            defer { saving = false }
            if let updated = await library.rename(entry, title: title) {
                onRenamed(updated)
                editing = false
            }
        }
    }
}
