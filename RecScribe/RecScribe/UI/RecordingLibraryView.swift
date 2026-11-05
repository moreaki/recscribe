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
    @State private var inspectedID: URL?
    @State private var searchText = ""
    @State private var links: [URL: RecordingTranscriptLink] = [:]
    @State private var linkError: String?
    var isVisible = true
    private var visibleEntries: [SessionEntry] { RecordingLibraryProjection.filtered(library.entries, query: searchText) }
    private var inspectedEntry: SessionEntry? { library.entries.first { $0.id == inspectedID } }
    private var hiddenSelectionCount: Int { selection.subtracting(visibleEntries.map(\.id)).count }

    @State private var renamingID: URL?
    var embeddedInStudio = false
    var onOpenStudio: (() -> Void)? = nil

    init(makePlayback: @escaping () -> SessionPlayback = { SessionPlayback() },
         embeddedInStudio: Bool = false, isVisible: Bool = true, onOpenStudio: (() -> Void)? = nil) {
        _playback = State(initialValue: makePlayback())
        self.embeddedInStudio = embeddedInStudio
        self.isVisible = isVisible
        self.onOpenStudio = onOpenStudio
    }

    private func navigateToStudio() {
        if let onOpenStudio { onOpenStudio() }
        else { AppWindow.open(.studio, using: openWindow, navigation: navigation) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: StudioSpacing.m) {
            header
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
            HStack(spacing: 12) {
                HStack {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Search recordings", text: $searchText).textFieldStyle(.plain)
                        .accessibilityLabel("Search recordings")
                    if !searchText.isEmpty { Button("Clear search", systemImage: "xmark.circle.fill") { searchText = "" }.labelStyle(.iconOnly).buttonStyle(.plain).foregroundStyle(.secondary) }
                }.padding(10).frame(maxWidth: 360).background(WorkspaceStyle.panel, in: RoundedRectangle(cornerRadius: 8))
                    .overlay { RoundedRectangle(cornerRadius: 8).stroke(WorkspaceStyle.border) }
                Spacer()
                Text(searchText.isEmpty ? "\(library.entries.count) recordings" : "\(visibleEntries.count) of \(library.entries.count) recordings")
                    .font(.callout).foregroundStyle(.secondary)
            }.padding(.vertical, 14)
            selectionToolbar
            if hiddenSelectionCount > 0 {
                HStack {
                    Text("\(hiddenSelectionCount) selected outside these search results").font(.caption).foregroundStyle(.secondary)
                    Button("Show all") { searchText = "" }.buttonStyle(.borderless).font(.caption)
                }
            }
            if let reason = library.deletionBlockedReason {
                Text(reason).font(.caption).foregroundStyle(.secondary)
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(RecordingLibraryProjection.groups(visibleEntries)) { group in
                        Text(group.title).font(.caption.weight(.medium)).foregroundStyle(.secondary)
                            .padding(.top, 22).padding(.bottom, 12).accessibilityAddTraits(.isHeader)
                        ForEach(group.entries) { entry in
                            recordingRow(entry)
                                .padding(.horizontal, 12)
                                .background(selection.contains(entry.id) ? WorkspaceStyle.selected : Color.clear, in: RoundedRectangle(cornerRadius: 8))
                        }
                    }
                }
            }
            .focusable()
            .onCommand(#selector(NSResponder.selectAll(_:))) { selection.formUnion(visibleEntries.map(\.id)) }
            .onExitCommand { selection.removeAll(); selectionAnchor = nil }
            .overlay {
                if library.entries.isEmpty {
                    ContentUnavailableView("No recordings yet", systemImage: "waveform",
                        description: Text("New recordings appear here. Import a WAV file for optional transcription."))
                } else if visibleEntries.isEmpty {
                    ContentUnavailableView.search(text: searchText)
                }
            }
            if let linkError { Text(linkError).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
            ForEach(library.readFailures) { failure in
                Text("\(failure.id.lastPathComponent): \(failure.message)")
                    .font(.caption).foregroundStyle(theme.colors.statusWarning).textSelection(.enabled)
            }
            footer
            if let error = library.errorMessage {
                Text(error).foregroundStyle(theme.colors.statusWarning).font(.caption).textSelection(.enabled)
            }
        }
        .padding(.horizontal, 36).padding(.top, 24).padding(.bottom, 14).frame(
            minWidth: embeddedInStudio ? 0 : AppWindow.recordings.minimumSize.width,
            minHeight: embeddedInStudio ? 0 : AppWindow.recordings.minimumSize.height)
        .background(WorkspaceStyle.background).tint(WorkspaceStyle.blue).studioThemeAdaptingToContrast()
        .onChange(of: isVisible, initial: true) { _, visible in
            if visible { playback.setRecording(library.recordingActive); reload() }
            else { playback.stop() }
        }
        .onDisappear { playback.stop() }
        .task(id: "\(isVisible):\(library.entries.map(\.id)):\(library.latestJob?.path ?? ""):\(library.recordingActive):\(library.liveWorkActive):\(library.busy):\(library.refreshing)") {
            guard isVisible, !library.recordingActive, !library.liveWorkActive, !library.busy, !library.refreshing else { return }
            linkError = nil
            do {
                let result = try await library.transcriptLinks(for: library.entries)
                try Task.checkCancellation()
                links = result
            } catch is CancellationError { }
            catch { if !Task.isCancelled { linkError = "Transcript details could not be refreshed: " + error.localizedDescription } }
        }
        .inspector(isPresented: Binding(get: { isVisible && inspectedID != nil }, set: { if !$0 && isVisible { inspectedID = nil } })) {
            if let entry = inspectedEntry { recordingInspector(entry) }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if playback.hasPresentation {
                SessionPlaybackView(playback: playback).padding(16).background(WorkspaceStyle.panel)
            }
        }
        .onChange(of: library.recordingActive) { _, active in playback.setRecording(active) }
        .onChange(of: library.entries.map(\.id)) { _, ids in
            selection.formIntersection(ids)
            links = links.filter { ids.contains($0.key) }
            if let inspectedID, !ids.contains(inspectedID) { self.inspectedID = nil }
        }
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
            Image(systemName: "rectangle.stack").font(.title2).foregroundStyle(WorkspaceStyle.mint)
            VStack(alignment: .leading) {
                Text("Recordings").font(.title2.weight(.semibold))
                Text("Find a conversation. Pick up where you left off.").font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Import audio…", systemImage: "plus") {
                let panel = NSOpenPanel(); panel.canChooseDirectories = false
                if panel.runModal() == .OK, let url = panel.url { library.transcribe(url); navigateToStudio() }
            }.disabled(!library.canDeleteRecording)
            Button("Refresh", systemImage: "arrow.clockwise") { reload() }.labelStyle(.iconOnly).help("Refresh recordings").disabled(library.refreshing || library.deletingRecordings)
        }
    }

    private var selectionToolbar: some View {
        HStack(spacing: 12) {
            Toggle("Select all \(visibleEntries.count) shown recordings", sources: visibleEntries.map { entry in
                Binding(get: { selection.contains(entry.id) }, set: { selected in
                    if selected { selection.insert(entry.id) } else { selection.remove(entry.id) }
                    selectionAnchor = nil
                })
            }, isOn: \.self)
            .toggleStyle(.checkbox).labelsHidden().frame(width: 20)
            .accessibilityLabel("Select all \(visibleEntries.count) shown recordings").disabled(visibleEntries.isEmpty)
            Text(selection.isEmpty ? "Select recordings" : "\(selection.count) selected").font(.callout)
            Spacer()
            if !selection.isEmpty {
                Button("Clear") { selection.removeAll(); selectionAnchor = nil }.buttonStyle(.borderless)
            }
            if !selection.isEmpty {
            Button("Delete \(selection.count)…", role: .destructive) {
                beginDeletion(library.entries.filter { selection.contains($0.id) })
            }.disabled(!library.canDeleteRecording)
            } else { Text("Newest first").font(.caption).foregroundStyle(.secondary) }
        }.padding(.vertical, 10)
            .overlay(alignment: .top) { Divider() }.overlay(alignment: .bottom) { Divider() }
    }

    private func recordingRow(_ entry: SessionEntry) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Toggle("Select \(entry.displayTitle)", isOn: Binding(get: { selection.contains(entry.id) }, set: { _ in
                selection = RecordingSelection.toggling(entry.id, selected: selection, anchor: selectionAnchor,
                    order: visibleEntries.map(\.id), extend: NSApp.currentEvent?.modifierFlags.contains(.shift) == true || NSEvent.modifierFlags.contains(.shift))
                selectionAnchor = entry.id
            }))
            .toggleStyle(.checkbox).labelsHidden().frame(width: 20)
            .accessibilityLabel("Select \(entry.displayTitle)")
            VStack(alignment: .leading, spacing: 5) {
                Button { openInStudio(entry) } label: {
                    Text(entry.displayTitle).font(.headline).foregroundStyle(.primary).lineLimit(2).multilineTextAlignment(.leading)
                }.buttonStyle(.plain).help("Open in Studio").disabled(library.isDeleting(entry.id))
                timestamp(entry)
                if !entry.session.issues.isEmpty {
                    Button("Recording review notes", systemImage: "exclamationmark.circle") { inspectedID = entry.id }
                        .buttonStyle(.borderless).font(.caption).tint(.secondary)
                }
            }

            Spacer(minLength: 0)
            if selection.isEmpty {
                status(entry).frame(minWidth: 130, alignment: .trailing)
                Button { playback.play(entry) } label: { Image(systemName: playback.playing == entry.session.id ? "arrow.counterclockwise" : "play.fill") }
                    .accessibilityLabel("Play \(entry.displayTitle)")
                    .disabled(!library.canDeleteRecording || entry.session.parts.isEmpty || !entry.session.parts.allSatisfy { $0.status == .verified })
                rowMenu(entry)
            }
        }.buttonStyle(.borderless).padding(.vertical, 16)
            .accessibilityElement(children: .contain)
            .overlay(alignment: .bottom) { Divider() }
    }

    private func timestamp(_ entry: SessionEntry) -> some View {
        Text("\(entry.session.startedAt.formatted(date: .abbreviated, time: .shortened)) · \(Duration.seconds(entry.session.duration).formatted(.time(pattern: .minuteSecond))) · \(entry.session.channels) \(entry.session.channels == 1 ? "channel" : "channels")")
            .font(.caption).foregroundStyle(.secondary)
    }
    @ViewBuilder private func status(_ entry: SessionEntry) -> some View {
        if entry.needsRecovery || entry.session.status == .finalized {
            Label("Preparing recording…", systemImage: "clock").font(.caption).foregroundStyle(.secondary)
        } else if entry.session.status == .needsReview {
            Label("Recording needs review", systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
        } else if let link = links[entry.id] {
            Label(link.needsReview ? "Transcript needs review" : link.hasSummary ? "Transcript + summary" : "Transcript available",
                  systemImage: link.needsReview ? "exclamationmark.circle" : "doc.text").font(.caption).foregroundStyle(.secondary)
        } else {
            Label(entry.session.status.label, systemImage: "waveform").font(.caption).foregroundStyle(.secondary)
        }
    }

    private func openInStudio(_ entry: SessionEntry) {
        if let link = links[entry.id] { library.rememberOpenedTranscript(link.job, source: entry.id) }
        else { library.openRecordingInStudio(entry.id) }
        navigateToStudio()
    }

    private func rowMenu(_ entry: SessionEntry) -> some View {
        Menu {
            Button("Open in Studio", systemImage: "arrow.up.right") { openInStudio(entry) }.disabled(library.isDeleting(entry.id))
            Button("Recording details", systemImage: "info.circle") { inspectedID = entry.id }
            Button("Rename…", systemImage: "pencil") { inspectedID = entry.id; renamingID = entry.id }.disabled(!library.canDeleteRecording)
            if entry.session.title != nil {
                Button("Reset title", systemImage: "arrow.counterclockwise") { Task { await library.rename(entry, title: "") } }.disabled(!library.canDeleteRecording)
            }
            Divider()
            Button("Transcribe", systemImage: "text.bubble") { library.transcribe(entry.id); navigateToStudio() }.disabled(!library.canDeleteRecording)
            Button("Transcribe & summarize", systemImage: "sparkles") { library.transcribe(entry.id, summarize: true); navigateToStudio() }.disabled(!library.canDeleteRecording)
            ForEach(entry.session.sourceTracks ?? [], id: \.role) { source in
                Menu(source.name) {
                    Button("Play source track") { playback.playSource(source, parent: entry) }
                    Button("Transcribe source track") {
                        if let path = source.manifestPath, let url = try? RecordingSession.safeURL(path, beside: entry.id) { library.transcribe(url); navigateToStudio() }
                    }
                }.disabled(source.manifestPath == nil || !library.canDeleteRecording)
            }
            Divider()
            Button("Reveal in Finder", systemImage: "folder") { NSWorkspace.shared.activateFileViewerSelecting([entry.id]) }
            Button("Export…", systemImage: "square.and.arrow.up") { export(entry) }.disabled(!library.canDeleteRecording)
            Divider()
            Button("Delete…", systemImage: "trash", role: .destructive) { beginDeletion([entry]) }.disabled(!library.canDeleteRecording)
        } label: { Image(systemName: "ellipsis") }
        .menuStyle(.borderlessButton).fixedSize().accessibilityLabel("Actions for \(entry.displayTitle)")
    }

    private func recordingInspector(_ entry: SessionEntry) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HStack { Text("Recording details").font(.headline); Spacer(); Button("Close details", systemImage: "xmark") { inspectedID = nil }.labelStyle(.iconOnly).buttonStyle(.borderless) }
                SessionTitleView(entry: entry, library: library, allowsEditing: library.canDeleteRecording,
                    titleFont: .title3.weight(.semibold), titleLineLimit: 3,
                    renameRequested: Binding(get: { renamingID == entry.id }, set: { if !$0 { renamingID = nil } }))
                status(entry)
                LabeledContent("Recorded", value: entry.session.startedAt.formatted(date: .abbreviated, time: .shortened))
                LabeledContent("Duration", value: Duration.seconds(entry.session.duration).formatted(.time(pattern: .hourMinuteSecond)))
                LabeledContent("Channels", value: String(entry.session.channels))
                LabeledContent("Sample rate", value: "\(entry.session.sampleRate) Hz")
                LabeledContent("Parts", value: String(entry.session.parts.count))
                Divider()
                Button("Open in Studio", systemImage: "arrow.up.right") { openInStudio(entry) }.disabled(library.isDeleting(entry.id))
                Button("Transcribe", systemImage: "text.bubble") { library.transcribe(entry.id); navigateToStudio() }.disabled(!library.canDeleteRecording)
                Button("Transcribe & summarize", systemImage: "sparkles") { library.transcribe(entry.id, summarize: true); navigateToStudio() }.disabled(!library.canDeleteRecording)
                if entry.needsRecovery || entry.session.status == .finalized {
                    Button("Verify / recover recording", systemImage: "arrow.clockwise") { library.retryVerification(entry) }.disabled(!library.canDeleteRecording)
                }
                if let link = links[entry.id] {
                    Button("Reveal transcript artifacts", systemImage: "doc.text") { NSWorkspace.shared.activateFileViewerSelecting([link.job]) }
                }
                if !(entry.session.sourceTracks ?? []).isEmpty {
                    Divider()
                    Text("Original source tracks").font(.headline)
                    ForEach(entry.session.sourceTracks ?? [], id: \.role) { source in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(source.name).font(.subheadline.weight(.medium))
                            HStack {
                                Button("Play source") { playback.playSource(source, parent: entry) }
                                Button("Transcribe") {
                                    if let path = source.manifestPath, let url = try? RecordingSession.safeURL(path, beside: entry.id) { library.transcribe(url); navigateToStudio() }
                                }
                            }.disabled(source.manifestPath == nil || !library.canDeleteRecording)
                        }
                    }
                }
                Divider()
                RecordingReviewNotesView(notes: RecordingReviewNotes(session: entry.session))
                DisclosureGroup("File details") { Text(entry.id.path).font(.caption.monospaced()).textSelection(.enabled) }
                Button("Reveal recording", systemImage: "folder") { NSWorkspace.shared.activateFileViewerSelecting([entry.id]) }
                Button("Export…", systemImage: "square.and.arrow.up") { export(entry) }.disabled(!library.canDeleteRecording)
                Button("Delete…", systemImage: "trash", role: .destructive) { beginDeletion([entry]) }.disabled(!library.canDeleteRecording)
            }.controlSize(.small).padding(22)
        }.inspectorColumnWidth(min: 290, ideal: 330, max: 420).background(WorkspaceStyle.panel)
    }

    private var footer: some View {
        HStack {
            if library.workInProgress { ProgressView(value: library.progress).frame(width: theme.metrics.controlHeightMedium * 3) }
            Text(library.workInProgress ? library.activity : "Open a title to work in Studio").font(.caption).foregroundStyle(.secondary)
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
    var titleFont: Font = .headline
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
                Text(entry.displayTitle).font(titleFont).lineLimit(titleLineLimit).truncationMode(.middle).help(entry.displayTitle)
                Button(action: beginEditing) { Image(systemName: "pencil") }
                .buttonStyle(.plain).foregroundStyle(.secondary)
                .help("Rename recording").accessibilityLabel("Rename recording")
                .disabled(!allowsEditing || !library.canDeleteRecording)
            }
        }.controlSize(.small).disabled(saving)
        .onChange(of: renameRequested?.wrappedValue, initial: true) { _, requested in
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

nonisolated enum RecordingLibraryProjection {
    struct Group: Identifiable {
        let title: String
        let entries: [SessionEntry]
        var id: String { title }
    }
    static func filtered(_ entries: [SessionEntry], query: String) -> [SessionEntry] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return entries }
        return entries.filter { $0.displayTitle.localizedStandardContains(query) || $0.filenameStem.localizedStandardContains(query) }
    }
    static func groups(_ entries: [SessionEntry], now: Date = Date(), calendar: Calendar = .current) -> [Group] {
        let today = calendar.startOfDay(for: now)
        let yesterday = calendar.date(byAdding: .day, value: -1, to: today) ?? today
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: today) ?? .distantFuture
        let ordered = entries.sorted {
            $0.session.startedAt == $1.session.startedAt ? $0.id.path < $1.id.path : $0.session.startedAt > $1.session.startedAt
        }
        return [Group(title: "Future dates", entries: ordered.filter { $0.session.startedAt >= tomorrow }),
                Group(title: "Today", entries: ordered.filter { $0.session.startedAt >= today && $0.session.startedAt < tomorrow }),
                Group(title: "Yesterday", entries: ordered.filter { $0.session.startedAt >= yesterday && $0.session.startedAt < today }),
                Group(title: "Earlier", entries: ordered.filter { $0.session.startedAt < yesterday })].filter { !$0.entries.isEmpty }
    }
}
