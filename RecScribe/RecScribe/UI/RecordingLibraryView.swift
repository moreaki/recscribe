import AVKit
import SwiftUI

struct RecordingLibraryView: View {
    @Environment(RecorderViewModel.self) private var recorder
    @Environment(SessionLibrary.self) private var library
    @Environment(\.studioTheme) private var theme
    @Environment(\.openWindow) private var openWindow
    @Environment(\.studioNavigation) private var navigation
    @Environment(\.dismissWindow) private var dismissWindow
    @State private var playback: SessionPlayback
    @State private var selection = Set<URL>()
    @State private var selectionAnchor: URL?
    @State private var deletionRequest: RecordingDeletionRequest?
    @State private var result: RecordingDeletionResult?
    @State private var details = Set<URL>()
    @State private var renamingID: URL?
    var embeddedInStudio = false
    var onOpenStudio: (() -> Void)? = nil

    init(makePlayback: @escaping () -> SessionPlayback = { SessionPlayback() },
         embeddedInStudio: Bool = false, onOpenStudio: (() -> Void)? = nil) {
        _playback = State(initialValue: makePlayback())
        self.embeddedInStudio = embeddedInStudio
        self.onOpenStudio = onOpenStudio
    }

    private func navigateToStudio() {
        if let onOpenStudio { onOpenStudio() }
        else { AppWindow.open(.studio, using: openWindow, navigation: navigation) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: StudioSpacing.m) {
            header
            SessionPlaybackView(playback: playback)
            if let result {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(result.summary).font(.callout.bold())
                        Spacer()
                        Button("Dismiss", systemImage: "xmark") { self.result = nil }.labelStyle(.iconOnly)
                    }
                    if !result.remaining.isEmpty {
                        Text("\(result.remaining.count) recordings kept and selected. \(result.stopped ? "Stopped before the next recording." : "Review the failure before retrying.")")
                    }
                    if let failure = result.failure { Text(failure).textSelection(.enabled) }
                    Text("Restore moved folders from macOS Trash. Transcription data was kept unless explicitly included.")
                }.font(.caption).padding(12).background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
            }
            selectionToolbar
            if let reason = library.deletionBlockedReason {
                Text(reason).font(.caption).foregroundStyle(.secondary)
            }
            List {
                ForEach(library.entries) { entry in
                    recordingRow(entry)
                        .listRowBackground(selection.contains(entry.id) ? WorkspaceStyle.blue.opacity(0.12) : Color.clear)
                }
            }
            .listStyle(.inset).scrollContentBackground(.hidden)
            .onCommand(#selector(NSResponder.selectAll(_:))) { selection = Set(library.entries.map(\.id)) }
            .onExitCommand { selection.removeAll(); selectionAnchor = nil }
            .overlay {
                if library.entries.isEmpty {
                    ContentUnavailableView("No recordings yet", systemImage: "waveform",
                        description: Text("New recordings appear here. Import a WAV file for optional transcription."))
                }
            }
            ForEach(library.readFailures) { failure in
                Text("\(failure.id.lastPathComponent): \(failure.message)")
                    .font(.caption).foregroundStyle(theme.colors.statusWarning).textSelection(.enabled)
            }
            footer
            if let error = library.errorMessage {
                Text(error).foregroundStyle(theme.colors.statusWarning).font(.caption).textSelection(.enabled)
            }
        }
        .padding(StudioSpacing.xxl).frame(
            minWidth: embeddedInStudio ? 0 : AppWindow.recordings.minimumSize.width,
            minHeight: embeddedInStudio ? 0 : AppWindow.recordings.minimumSize.height)
        .background(WorkspaceStyle.background).tint(WorkspaceStyle.blue).studioThemeAdaptingToContrast()
        .onAppear { playback.setRecording(library.recordingActive); reload() }
        .onDisappear { playback.stop(); library.cancelRefresh() }
        .onChange(of: library.recordingActive) { _, active in playback.setRecording(active) }
        .onChange(of: library.entries.map(\.id)) { _, ids in selection.formIntersection(ids) }
        .sheet(item: $deletionRequest, onDismiss: { library.closeDeletionPreview() }) { request in
            RecordingDeletionSheet(entries: request.entries, playback: playback) { outcome in
                result = outcome
                selection = Set(outcome.remaining)
                deletionRequest = nil
                selectionAnchor = nil
            }
        }

    }

    private var header: some View {
        HStack {
            WorkspaceIcon(symbol: "rectangle.stack.fill", tint: WorkspaceStyle.mint)
            VStack(alignment: .leading) {
                Text("Your recordings ").font(.title2.bold())
                Text("Listen, transcribe and make sense of your recordings.").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Import…") {
                let panel = NSOpenPanel(); panel.canChooseDirectories = false
                if panel.runModal() == .OK, let url = panel.url { library.transcribe(url); navigateToStudio() }
            }.disabled(!library.canDeleteRecording)
            Button("Refresh") { reload() }.disabled(library.refreshing || library.deletingRecordings)
        }
    }

    private var selectionToolbar: some View {
        HStack(spacing: 12) {
            Toggle("Select all \(library.entries.count) recordings", sources: library.entries.map { entry in
                Binding(get: { selection.contains(entry.id) }, set: { selected in
                    if selected { selection.insert(entry.id) } else { selection.remove(entry.id) }
                    selectionAnchor = nil
                })
            }, isOn: \.self)
            .toggleStyle(.checkbox).labelsHidden().frame(width: 20)
            .accessibilityLabel("Select all \(library.entries.count) recordings").disabled(library.entries.isEmpty)
            Text("\(library.entries.count) recordings").font(.callout)
            Spacer()
            if !selection.isEmpty {
                Text("\(selection.count) selected").font(.callout.bold()).accessibilityAddTraits(.updatesFrequently)
                Button("Clear") { selection.removeAll(); selectionAnchor = nil }.buttonStyle(.borderless)
            }
            Button(selection.isEmpty ? "Delete selected…" : "Delete \(selection.count)…", role: .destructive) {
                beginDeletion(library.entries.filter { selection.contains($0.id) })
            }.disabled(selection.isEmpty || !library.canDeleteRecording)
        }.padding(.vertical, 10)
            .overlay(alignment: .top) { Divider() }.overlay(alignment: .bottom) { Divider() }
    }

    private func recordingRow(_ entry: SessionEntry) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Toggle("Select \(entry.displayTitle)", isOn: Binding(get: { selection.contains(entry.id) }, set: { _ in
                selection = RecordingSelection.toggling(entry.id, selected: selection, anchor: selectionAnchor,
                    order: library.entries.map(\.id), extend: NSApp.currentEvent?.modifierFlags.contains(.shift) == true || NSEvent.modifierFlags.contains(.shift))
                selectionAnchor = entry.id
            }))
            .toggleStyle(.checkbox).labelsHidden().frame(width: 20)
            .accessibilityLabel("Select \(entry.displayTitle)")
            VStack(alignment: .leading, spacing: 5) {
                SessionTitleView(entry: entry, library: library, titleLineLimit: 2,
                    renameRequested: Binding(get: { renamingID == entry.id }, set: { requested in
                        if requested { renamingID = entry.id }
                        else if renamingID == entry.id { renamingID = nil }
                    }))
                ViewThatFits(in: .horizontal) {
                    HStack { timestamp(entry); status(entry) }
                    VStack(alignment: .leading, spacing: 2) { timestamp(entry); status(entry) }
                }
                RecordingReviewNotesView(notes: RecordingReviewNotes(session: entry.session))
                if details.contains(entry.id) {
                    Text("\(entry.session.parts.count) parts · \(entry.session.channels) channels · \(entry.session.sampleRate) Hz PCM")
                        .font(.caption).foregroundStyle(.secondary)
                    Text(entry.filenameStem).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                }
            }
            Spacer(minLength: 0)
            if selection.isEmpty {
                Button { playback.play(entry) } label: { Image(systemName: playback.playing == entry.session.id ? "arrow.counterclockwise" : "play.fill") }
                    .accessibilityLabel("Play \(entry.displayTitle)")
                    .disabled(!library.canDeleteRecording || entry.session.parts.isEmpty || !entry.session.parts.allSatisfy { $0.status == .verified })
                ViewThatFits(in: .horizontal) {
                    Button("Transcribe") { library.transcribe(entry.id); navigateToStudio() }.disabled(!library.canDeleteRecording)
                    EmptyView()
                }
                rowMenu(entry)
            }
        }.buttonStyle(.borderless).padding(.vertical, 9)
    }

    private func timestamp(_ entry: SessionEntry) -> some View {
        Text("\(entry.session.startedAt.formatted(date: .abbreviated, time: .shortened)) · \(entry.session.duration.formatted(.number.precision(.fractionLength(1)))) s")
            .font(.caption).foregroundStyle(.secondary)
    }
    private func status(_ entry: SessionEntry) -> some View {
        Text((entry.needsRecovery || entry.session.status == .finalized) && !library.recordingActive
            ? "Preparing recording…" : entry.session.status.label).font(.caption).foregroundStyle(.secondary)
    }

    private func rowMenu(_ entry: SessionEntry) -> some View {
        Menu {
            Button("Rename…", systemImage: "pencil") { renamingID = entry.id }
            if entry.session.title != nil {
                Button("Reset title", systemImage: "arrow.counterclockwise") { Task { await library.rename(entry, title: "") } }
            }
            Button(details.contains(entry.id) ? "Hide recording details" : "Recording details", systemImage: "info.circle") {
                if !details.insert(entry.id).inserted { details.remove(entry.id) }
            }
            Divider()
            Button("Transcribe", systemImage: "text.bubble") { library.transcribe(entry.id); navigateToStudio() }
            Button("Transcribe & summarize", systemImage: "sparkles") { library.transcribe(entry.id, summarize: true); navigateToStudio() }
            ForEach(entry.session.sourceTracks ?? [], id: \.role) { source in
                Menu(source.name) {
                    Button("Play source track") { playback.playSource(source, parent: entry) }
                    Button("Transcribe source track") {
                        if let path = source.manifestPath, let url = try? RecordingSession.safeURL(path, beside: entry.id) {
                            library.transcribe(url); navigateToStudio()
                        }
                    }
                }.disabled(source.manifestPath == nil)
            }
            Divider()
            Button("Reveal in Finder", systemImage: "folder") { NSWorkspace.shared.activateFileViewerSelecting([entry.id]) }
            Button("Export…", systemImage: "square.and.arrow.up") { export(entry) }
            Divider()
            Button("Delete…", systemImage: "trash", role: .destructive) { beginDeletion([entry]) }
        } label: { Image(systemName: "ellipsis.circle") }
        .menuStyle(.borderlessButton).fixedSize().accessibilityLabel("Actions for \(entry.displayTitle)")
        .disabled(!library.canDeleteRecording)
    }

    private var footer: some View {
        HStack {
            if library.workInProgress { ProgressView(value: library.progress).frame(width: theme.metrics.controlHeightMedium * 3) }
            Text(library.activity).font(.caption)
            Spacer()
            if let job = library.latestJob { Button("Job artifacts") { NSWorkspace.shared.activateFileViewerSelecting([job]) } }
            if library.canCancelWork { Button("Cancel work") { library.cancel() } }
            if !embeddedInStudio { Button("Close window") { dismissWindow(id: AppWindow.recordings.rawValue) } }
        }
    }
    private func beginDeletion(_ entries: [SessionEntry]) { deletionRequest = .init(entries: entries) }
    private func reload() { library.recoverUnfinalizedSessions(in: URL(fileURLWithPath: recorder.saveLocationPath)) }
    private func export(_ entry: SessionEntry) {
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false
        if panel.runModal() == .OK, let url = panel.url {
            Task { do { let result = try await library.export(entry.id, to: url); NSWorkspace.shared.activateFileViewerSelecting([result]) }
                catch is CancellationError {} catch { library.errorMessage = error.localizedDescription } }
        }
    }
}

nonisolated enum RecordingSelection {
    static func toggling(_ id: URL, selected: Set<URL>, anchor: URL?, order: [URL], extend: Bool) -> Set<URL> {
        var result = selected
        let remove = selected.contains(id)
        let targets: [URL]
        if extend, let anchor, let a = order.firstIndex(of: anchor), let b = order.firstIndex(of: id) {
            targets = Array(order[min(a,b)...max(a,b)])
        } else { targets = [id] }
        for target in targets { if remove { result.remove(target) } else { result.insert(target) } }
        return result
    }
}

private struct RecordingDeletionRequest: Identifiable {
    let id = UUID()
    let entries: [SessionEntry]
}

private struct RecordingDeletionSheet: View {
    let entries: [SessionEntry]
    let playback: SessionPlayback
    var completed: (RecordingDeletionResult) -> Void
    @Environment(SessionLibrary.self) private var library
    @Environment(\.dismiss) private var dismiss
    @Environment(\.studioTheme) private var theme
    @State private var plan: RecordingDeletionPlan?
    @State private var includeJobs = false
    @State private var checking = true
    @State private var running = false
    @FocusState private var cancelFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(running ? "Moving recordings to Trash…" : "Delete \(entries.count) \(entries.count == 1 ? "recording" : "recordings")?").font(.title2.bold())
            if running {
                ProgressView(value: Double(library.deletionCompleted), total: Double(entries.count))
                Text(library.activity).font(.callout)
                Text("Each recording stays together. Remaining recordings are kept if you stop.").font(.caption).foregroundStyle(.secondary)
                HStack { Spacer(); Button("Stop after current recording") { library.stopDeletionAfterCurrent() } }
            } else {
                Text("Choose what moves to Trash. Nothing is permanently erased.").font(.callout).foregroundStyle(.secondary)
                VStack(spacing: 10) {
                    scopeCard(title: "Recordings only", description: "Move audio, source tracks and recording files.\nKeep all transcription data.", includesJobs: false)
                    scopeCard(title: "Recordings + linked transcription data", description: linkedDataDescription, includesJobs: true)
                }
                .disabled(checking)
                .accessibilityElement(children: .contain)
                .accessibilityLabel("Deletion scope")
                if checking {
                    HStack { ProgressView().controlSize(.small); Text("Checking linked data…") }
                } else if let plan {
                    if !plan.checkedJobs {
                        Text("Linked data has not been checked. Keep transcription data or check it before including it.").font(.caption)
                        Button("Check linked data") { Task { await prepare() } }
                    }
                    if includeJobs, plan.checkedJobs {
                        if !plan.retained.isEmpty {
                            Text("Some transcription data will be kept. \(plan.retained.count) active or unverified jobs in the library could not be safely included; some may be unrelated. This does not remove all transcription data.")
                                .font(.caption).foregroundStyle(.orange)
                            DisclosureGroup("Review retained jobs") {
                                ScrollView {
                                    ForEach(plan.retained) { job in
                                        HStack {
                                            Text(job.problem ?? (job.isTerminal ? "Unverified source identity" : "Job is not finished")).font(.caption)
                                            Spacer()
                                            Button("Reveal") { NSWorkspace.shared.activateFileViewerSelecting([job.url]) }
                                        }.padding(.vertical, 2)
                                    }
                                }.frame(maxHeight: 100)
                            }
                        }
                    }
                    DisclosureGroup("Review \(entries.count) selected recordings") {
                        ScrollView {
                            VStack(alignment: .leading, spacing: 6) {
                                ForEach(plan.items, id: \.entry.id) { item in
                                    Text(item.entry.displayTitle + (includeJobs ? " · \(item.jobs.count) verified jobs" : "")).font(.caption)
                                }
                            }.frame(maxWidth: .infinity, alignment: .leading)
                        }.frame(maxHeight: 120)
                    }
                } else {
                    Text(library.errorMessage ?? "Could not check linked data. Nothing has been deleted.").font(.callout).textSelection(.enabled)
                    HStack {
                        Button("Retry") { Task { await prepare() } }
                        Button("Keep transcripts and check recordings only") { Task { includeJobs = false; await prepare(inspectJobs: false) } }
                    }
                }
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "arrow.uturn.backward").foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Recoverable in macOS Trash.").font(.caption.weight(.medium))
                        Text("Each recording stays together with its selected files. Raw Live drafts and external copies are kept.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 4)
                if let reason = library.deletionBlockedReason, !checking { Text(reason).font(.caption).foregroundStyle(.orange) }
                Divider()
                HStack {
                    Spacer()
                    Button("Cancel", role: .cancel) { library.closeDeletionPreview(); dismiss() }
                        .keyboardShortcut(.cancelAction).focused($cancelFocused)
                    Button(role: .destructive) { execute() } label: {
                        Text("Move \(entries.count) to Trash")
                            .font(.callout.weight(.medium)).foregroundStyle(.white)
                            .padding(.horizontal, 14).padding(.vertical, 7)
                            .background(theme.colors.statusDanger, in: RoundedRectangle(cornerRadius: 7))
                            .contentShape(RoundedRectangle(cornerRadius: 7))
                    }
                    .buttonStyle(.plain)
                    .opacity(canMoveToTrash ? 1 : 0.45)
                    .disabled(!canMoveToTrash)
                }
            }
        }.padding(28).frame(width: 534).fixedSize(horizontal: false, vertical: true)
        .interactiveDismissDisabled(running)
        .task { cancelFocused = true; await prepare() }
        .onDisappear { library.closeDeletionPreview() }
    }
    private var canMoveToTrash: Bool {
        !checking && plan != nil && library.deletionBlockedReason == nil && (!includeJobs || plan?.checkedJobs == true)
    }

    private var linkedDataDescription: String {
        if let plan, plan.checkedJobs {
            "Also move \(plan.jobCount) verified \(plan.jobCount == 1 ? "job" : "jobs"), including transcripts, summaries, edits and generated job files."
        } else {
            "Also move verified finished jobs, including transcripts, summaries, edits and generated job files."
        }
    }

    private func scopeCard(title: String, description: String, includesJobs: Bool) -> some View {
        let selected = includeJobs == includesJobs
        return Button { includeJobs = includesJobs } label: {
            HStack(alignment: .top, spacing: 11) {
                Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                    .font(.system(size: 17)).foregroundStyle(selected ? WorkspaceStyle.blue : Color.secondary)
                    .padding(.top, 2)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.callout.weight(.semibold)).foregroundStyle(.primary)
                    Text(description).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading).padding(14)
            .background(selected ? WorkspaceStyle.blue.opacity(0.13) : Color.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 10))
            .overlay { RoundedRectangle(cornerRadius: 10).strokeBorder(selected ? WorkspaceStyle.blue : Color.primary.opacity(0.17), lineWidth: 1) }
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel(title).accessibilityValue(selected ? "Selected" : "Not selected")
        .accessibilityHint(description)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func prepare(inspectJobs: Bool = true) async {
        checking = true; plan = nil
        plan = await library.prepareDeletion(entries, inspectJobs: inspectJobs)
        checking = false
    }
    private func execute() {
        guard let plan else { return }
        if plan.items.flatMap(\.sessions).contains(where: { $0.id == playback.playing }) { playback.stop() }
        running = true
        Task { let result = await library.deleteRecordings(plan, includeJobs: includeJobs); completed(result) }
    }
}

/// Shared inline editor for the library and the transcript's source header.
struct SessionTitleView: View {
    let entry: SessionEntry
    @Bindable var library: SessionLibrary
    var allowsEditing = true
    var onRenamed: (SessionEntry) -> Void = { _ in }
    var titleLineLimit = 1
    var renameRequested: Binding<Bool>? = nil
    @FocusState private var titleFocused: Bool
    @State private var editing = false
    @State private var saving = false
    @State private var title = ""

    var body: some View {
        HStack {
            if editing {
                TextField("Recording title", text: $title).textFieldStyle(.roundedBorder).onSubmit(save)
                    .focused($titleFocused).defaultFocus($titleFocused, true)
                    .task { await Task.yield(); titleFocused = true }
                    .onExitCommand { finishEditing() }
                    .disabled(!allowsEditing)
                Button("Save", action: save).disabled(!allowsEditing || !library.canDeleteRecording)
                Button("Cancel", action: finishEditing)
            } else {
                Text(entry.displayTitle).font(.headline).lineLimit(titleLineLimit).truncationMode(.middle).help(entry.displayTitle)
                Button(action: beginEditing) { Image(systemName: "pencil") }
                .buttonStyle(.plain).foregroundStyle(.secondary)
                .help("Rename recording").accessibilityLabel("Rename recording")
                .disabled(!allowsEditing || !library.canDeleteRecording)
            }
        }.controlSize(.small).disabled(saving)
        .onChange(of: renameRequested?.wrappedValue) { _, requested in
            if requested == true, !editing { beginEditing() }
        }
    }

    private func beginEditing() {
        guard allowsEditing, library.canDeleteRecording, !saving else { return }
        title = entry.displayTitle
        editing = true
        renameRequested?.wrappedValue = true
    }

    private func finishEditing() {
        editing = false
        titleFocused = false
        renameRequested?.wrappedValue = false
    }

    private func save() {
        guard !saving else { return }
        saving = true
        Task {
            defer { saving = false }
            if let updated = await library.rename(entry, title: title) {
                onRenamed(updated)
                finishEditing()
            }
        }
    }
}
