import SwiftUI

/// Markdown is rendered natively, without web views, scripts or remote assets.
/// Transcript text is escaped before interpretation; words cannot inject links.
struct MarkdownReadingText: View {
    let text: String
    var font: Font = .body
    static func literal(_ source: String) -> AttributedString {
        let escaped = source.reduce(into: "") { result, character in
            if "\\`*_{}[]()#+.!|>~-".contains(character) { result.append("\\") }
            result.append(character)
        }
        guard var value = try? AttributedString(markdown: escaped, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)),
              String(value.characters) == source else { return AttributedString(source) }
        value.link = nil
        return value
    }
    var body: some View {
        Text(Self.literal(text)).font(font).lineSpacing(WorkspaceStyle.lineSpacing)
            .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct LiveTranscriptView: View {
    @Bindable var live: LiveTranscription
    var compact = false
    var playback: SessionPlayback?
    var recording = false
    var sourceAvailable = false
    var onSeek: ((Double) -> Void)?
    var focusLayout = false
    @State private var followsLatest = true
    var body: some View {
        VStack(alignment: .leading, spacing: StudioSpacing.l) {
            HStack {
                if !focusLayout { Label("Live draft", systemImage: "text.bubble.fill").font(.headline).foregroundStyle(WorkspaceStyle.blue) }
                else { Text("Provisional · \(live.status)").font(.caption).foregroundStyle(.secondary) }
                Spacer()
                Button(followsLatest ? "Following live" : "Follow live", systemImage: "arrow.down.to.line") { followsLatest.toggle() }
                    .buttonStyle(.borderless).font(.caption).tint(WorkspaceStyle.blue)
                    .accessibilityLabel("Follow latest transcript text")
                    .accessibilityValue(followsLatest ? "On" : "Off")
            }
            if !focusLayout { Text("Unverified · \(live.status)").font(.caption).foregroundStyle(.secondary) }
            if live.captureNeedsReview {
                Label("Recording has review notes. Check the saved audio, source coverage and this partial draft.",
                      systemImage: "exclamationmark.triangle")
                    .font(.callout).foregroundStyle(.orange)
            }
            if live.segments.isEmpty {
                if focusLayout {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("Waiting for the first words", systemImage: "waveform.and.mic").font(.callout)
                        Text("Words appear after an audio window is processed. Audio capture runs independently of this draft.")
                            .font(.caption).foregroundStyle(.secondary)
                    }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                } else {
                ContentUnavailableView("Let the conversation unfold", systemImage: "waveform.and.mic",
                    description: Text("Enable live transcription before or during recording. Words appear after an audio window is processed. Cloud audio requires separate approval."))
                    .frame(maxWidth: .infinity)
                }
            } else {
                ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: StudioSpacing.xl) {
                        ForEach(live.segments) { segment in
                            VStack(alignment: .leading, spacing: StudioSpacing.sm) {
                                MarkdownReadingText(text: segment.text)
                                let timing = "\(live.isCloudDraft ? "≈ " : "")\(Duration.seconds(segment.startSeconds).formatted(.time(pattern: .hourMinuteSecond))) · \(segment.channelLabel) · \(segment.language ?? "undetected")"
                                if let onSeek {
                                    Button(timing) {
                                        if let seconds = segment.seekTarget(recording: recording, sourceAvailable: sourceAvailable) { onSeek(seconds) }
                                    }
                                    .disabled(segment.seekTarget(recording: recording, sourceAvailable: sourceAvailable) == nil)
                                    .buttonStyle(.borderless).font(.caption2.monospacedDigit())
                                    .accessibilityLabel("Seek audio to \(timing)")
                                } else { Text(timing).font(.caption2.monospacedDigit()).foregroundStyle(.secondary) }
                                if let issue = segment.timingIssue {
                                    Label(issue.label, systemImage: "exclamationmark.triangle")
                                        .font(.caption).foregroundStyle(.orange)
                                }
                            }
                            .padding(StudioSpacing.xs)
                            .background((playback?.isPlaying == true && segment.containsPlayback(playback?.position ?? -1)) ? WorkspaceStyle.blue.opacity(0.12) : .clear,
                                        in: RoundedRectangle(cornerRadius: StudioRadius.control))
                            .id(segment.id)
                        }
                    }.frame(maxWidth: WorkspaceStyle.readingWidth, alignment: .leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .onChange(of: live.segments.last) { _, value in if followsLatest, let value { proxy.scrollTo(value.id, anchor: .bottom) } }
                .onChange(of: followsLatest) { _, follow in if follow, let id = live.segments.last?.id { proxy.scrollTo(id, anchor: .bottom) } }
                .onAppear { if let id = live.segments.last?.id, followsLatest { proxy.scrollTo(id, anchor: .bottom) } }
                }
            }
            if let error = live.errorMessage { Text(error).font(.caption).foregroundStyle(.orange).textSelection(.enabled) }
            if !compact {
                HStack {
                    Label(live.lastChunk?.label ?? "No chunk processed yet", systemImage: "timer")
                    Spacer()
                    if let directory = live.directory {
                        Button("Draft artifacts", systemImage: "folder") { NSWorkspace.shared.activateFileViewerSelecting([directory]) }
                    }
                }.font(.caption).foregroundStyle(.secondary)
                Text(live.isCloudDraft
                     ? "Cloud audio requires this activation’s approval. Raw events remain on this Mac. Times describe uploaded windows, not aligned words; speakers and languages are unverified. Transcript becomes available after recording stops."
                     : "Live text uses one mix; original recording tracks stay separate. Complete raw chunk results stay on this Mac. Word boundaries, silence and language switches need review; this is not the final transcript.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
    }
}

struct LiveTranscriptionControl: View {
    @Bindable var live: LiveTranscription
    @State private var preview = false
    var showsPreview = true
    @Environment(\.openWindow) private var openWindow
    @Environment(\.studioNavigation) private var navigation
    var body: some View {
        HStack {
            Toggle("Live transcription", isOn: Binding(get: { live.enabled }, set: { live.setEnabled($0) }))
                .toggleStyle(.switch).controlSize(.small).tint(WorkspaceStyle.blue)
            Spacer()
            if showsPreview {
            Button { preview.toggle() } label: { Image(systemName: "text.bubble") }
                .buttonStyle(.plain).accessibilityLabel("Preview live transcript").help("Preview the live draft")
                .popover(isPresented: $preview, arrowEdge: .bottom) {
                    LiveTranscriptView(live: live, compact: true).padding(WorkspaceStyle.contentPadding)
                        .frame(width: WorkspaceStyle.previewWidth, height: WorkspaceStyle.previewHeight)
                        .background(WorkspaceStyle.background)
                }
            }
            Button {
                AppWindow.open(.settings, using: openWindow, navigation: navigation)
            } label: { Image(systemName: "externaldrive") }
                .help("Manage preserved live drafts in Settings → Recording")
                .accessibilityLabel("Live draft storage settings")
        }
        .confirmationDialog("Send new audio to OpenAI?", isPresented: Binding(
            get: { live.pendingCloudRequest != nil }, set: { if !$0 { live.dismissCloudAudio() } }), titleVisibility: .visible) {
                Button("Approve new audio") { live.confirmCloudAudio() }.disabled(live.busy)
                Button("Keep audio local", role: .cancel) { live.dismissCloudAudio() }
            } message: {
                if let request = live.pendingCloudRequest {
                    Text("\(request.source.lastPathComponent)\nModel: \(request.model)\nOnly audio recorded after this approval is eligible, including each separate channel. Audio leaves this Mac; API costs and OpenAI retention rules apply. Approval ends when transcription stops or settings change. WAV recording continues if the network fails. Text cleanup and summary require a separate action.")
                }
            }
    }
}

struct TranscriptWorkspace: View {
    @Environment(LiveTranscription.self) private var live
    @Environment(SessionLibrary.self) private var library
    @Environment(\.openWindow) private var openWindow
    @Environment(\.studioNavigation) private var navigation
    @State private var playback: SessionPlayback
    @State private var pendingSeekSeconds: Double?
    @State private var pendingPassage: PlaybackPolicy.Passage?
    @State private var section: Section
    @State private var document: TranscriptPreview?
    @State private var error: String?
    @State private var selectedJob: URL?
    @State private var transcriptToDelete: URL?
    @State private var sourceAvailable = false
    @State private var playbackAvailable = false
    @State private var followAudio = true
    @State private var copyNotice: String?
    @State private var copyVersion = 0
    @State private var inspector: InspectorTab = .review
    @State private var showsInspector = false
    @State private var selectedGroupID: String?
    @State private var reviewItemID: String?
    @State private var contentWidth: CGFloat = 1_000
    @State private var review = TranscriptReviewState()
    @State private var documentReload = 0
    @FocusState private var inspectorTrigger: InspectorTab?
    private enum InspectorTab: String, CaseIterable, Hashable { case review = "Review", details = "Details" }
    private var displayedJob: URL? {
        selectedJob ?? library.studioJob
    }
    private var reviewItems: [TranscriptReading.ReviewItem] {
        document?.reviewItems ?? []
    }
    private var uncheckedItems: [TranscriptReading.ReviewItem] {
        reviewItems.filter { !review.checked.contains($0.key) }
    }
    private var waitingForDocument: Bool {
        selectedJob == nil && library.busy && library.studioJob == library.latestJob && library.progress < 1
    }
    private var source: URL? {
        if section == .live { return live.sourceURL }
        return document?.sourceURL ?? library.studioSource
    }
    enum Section: String, WorkspaceTab {
        case live = "Live", transcript = "Transcript", summary = "Summary", review = "Review"
        var symbol: String {
            switch self {
            case .live: "waveform"
            case .transcript: "doc.text"
            case .summary: "sparkles"
            case .review: "checkmark.shield"
            }
        }
    }
    init(section: Section = .transcript, playback: SessionPlayback = SessionPlayback()) {
        _section = State(initialValue: section)
        _playback = State(initialValue: playback)
    }

    private func copyToPasteboard(_ text: String, format: String) {
        copyNotice = TranscriptClipboard.copy(text, format: format, to: .general)
        copyVersion &+= 1
    }

    private var processingMenu: some View {
        Menu("Process") {
            if let source {
                Button(document == nil ? "Create final transcript" : "Transcribe again", systemImage: "text.bubble") {
                    selectedJob = nil; library.transcribe(source)
                }.disabled(!sourceAvailable)
            }
            if document != nil, let job = displayedJob {
                Button(section == .summary ? "Generate summary" : "Improve text", systemImage: "sparkles") {
                    library.requestTextProcessing(job, summary: section == .summary, sourceName: source?.lastPathComponent)
                }
            }
            Divider()
            Button("AI & transcription settings", systemImage: "slider.horizontal.3") {
                AppWindow.open(.settings, using: openWindow, navigation: navigation)
            }
        }.menuStyle(.borderlessButton).fixedSize().font(.callout).foregroundStyle(.secondary)
            .disabled(library.busy || library.recordingActive || library.liveWorkActive)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: StudioSpacing.xl) {
            let headerLayout = contentWidth < 780
                ? AnyLayout(VStackLayout(alignment: .leading, spacing: 12))
                : AnyLayout(HStackLayout(alignment: .top, spacing: 20))
            headerLayout {
                if let source {
                    TranscriptSourceView(source: source,
                        duration: document?.source.map { Double($0.durationMs) / 1_000 },
                        detail: document?.recognitionLabel ?? "Full recording",
                        recording: library.recordingActive, playback: playback,
                        pendingSeekSeconds: $pendingSeekSeconds,
                        pendingPassage: $pendingPassage,
                        sourceAvailabilityChanged: { sourceAvailable = $0 },
                        playbackAvailabilityChanged: { playbackAvailable = $0 },
                        focusLayout: true)
                } else { Text("Studio").font(.title2.weight(.semibold)) }
                if contentWidth >= 780 { Spacer(minLength: 0) }
                HStack(spacing: 16) {
                if let document {
                    Button("Review · \(uncheckedItems.count)", systemImage: "checkmark.shield") {
                        if inspector == .review && showsInspector { showsInspector = false }
                        else {
                            let items = document.reviewItems
                            if let selectedGroupID, let groupID = TranscriptReading.reviewGroupID(for: selectedGroupID, in: document),
                               items.contains(where: { $0.groupID == groupID }) {
                                reviewItemID = "passage-\(groupID)"
                            } else { reviewItemID = uncheckedItems.first?.id ?? items.first?.id }
                            inspector = .review; showsInspector = true
                        }
                    }
                    .focused($inspectorTrigger, equals: .review)
                    Menu("Export", systemImage: "square.and.arrow.up") {
                        let markdown = document.exportText(for: section, markdown: true)
                        let plain = document.exportText(for: section, markdown: false)
                        Button("Copy Markdown", systemImage: "doc.on.doc") { copyToPasteboard(markdown, format: "Markdown") }.disabled(markdown.isEmpty)
                        Button("Copy plain text", systemImage: "doc.plaintext") { copyToPasteboard(plain, format: "plain text") }.disabled(plain.isEmpty)
                        Menu("Review notes") {
                            Button("Copy Markdown") { copyToPasteboard(document.reviewMarkdownText, format: "review Markdown") }
                            Button("Copy plain text") { copyToPasteboard(document.reviewPlainText, format: "review notes") }
                        }.disabled(document.reviewPlainText.isEmpty)
                        if !markdown.isEmpty { ShareLink(item: markdown) { Label("Share…", systemImage: "square.and.arrow.up") } }
                    }
                    Button("Details", systemImage: "info.circle") { inspector = .details; showsInspector = true }
                        .labelStyle(.iconOnly).help("Recording and transcript details")
                        .focused($inspectorTrigger, equals: .details)
                }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .onGeometryChange(for: CGFloat.self, of: { $0.size.width }) { contentWidth = $0 }
            if let copyNotice {
                Label(copyNotice, systemImage: "checkmark.circle").font(.caption).foregroundStyle(WorkspaceStyle.mint)
                    .accessibilityIdentifier("transcript-copy-status")
            }
            WorkspaceTabs(title: "Document", selection: $section,
                sections: [.transcript, .summary], showsIcons: false)
                .overlay(alignment: .bottom) { Divider() }
            if section == .summary || document == nil {
                HStack { Spacer(); processingMenu }
            }
            if section == .live {
                LiveTranscriptView(live: live, playback: playback, recording: library.recordingActive,
                    sourceAvailable: sourceAvailable, onSeek: { pendingSeekSeconds = $0 })
            }
            else if let document {
                let content = section == .summary ? document.summaryText : section == .review ? document.reviewPlainText : ""
                if section == .transcript && !document.segments.isEmpty {
                    TranscriptReadingView(
                        document: document,
                        playback: playback,
                        onSeek: { seconds in pendingSeekSeconds = seconds },
                        selectedGroupID: $selectedGroupID,
                        onReview: { id in
                            followAudio = false
                            selectedGroupID = id
                            reviewItemID = TranscriptReading.reviewGroupID(for: id, in: document).map { "passage-\($0)" }
                            inspector = .review; showsInspector = true
                        },
                        followPlayback: $followAudio,
                        checkedReviewGroupIDs: Set(reviewItems.filter { review.checked.contains($0.key) }.compactMap(\.groupID))
                    ).overlay(alignment: .topTrailing) { processingMenu }

                } else if section == .summary, let notes = document.summary?.notes, !notes.isEmpty {
                    TranscriptSummaryView(document: document) { id in
                        followAudio = false
                        section = .transcript
                        selectedGroupID = id
                    }
                } else if content.isEmpty {
                    ContentUnavailableView(section == .summary ? "No summary yet" : "No review notes", systemImage: section == .summary ? "sparkles" : "checkmark.shield",
                        description: Text(section == .summary ? "Choose Ollama or OpenAI in Settings → Intelligence, then Generate summary above. Cloud text transfer always asks for confirmation." : "Inspect the transcript before relying on it."))
                } else {
                    ScrollView { MarkdownReadingText(text: content).frame(maxWidth: WorkspaceStyle.readingWidth).padding(.vertical, StudioSpacing.s) }
                }
                Spacer(minLength: 0)
                Label("\(document.processing.mode.rawValue) · \(document.includesCloudAudio ? "Includes cloud audio transcription" : document.includesCloudText ? "Includes cloud text" : "Processed locally")", systemImage: "checkmark.shield").font(.caption).foregroundStyle(.secondary)
            } else {
                ContentUnavailableView(library.busy ? "Processing your recording" : "Create a final transcript", systemImage: "doc.text",
                    description: Text(source == nil ? "Choose a recording or import a WAV. Live drafts and final transcripts are separate." : "Create a final transcript from this recording, then improve its text or generate a summary. Live drafts have their own workspace."))
                if source == nil { Button("Choose recording / import…") { AppWindow.open(.recordings, using: openWindow, navigation: navigation) } }
                Spacer(minLength: 0)
            }
            if let message = error ?? library.errorMessage {
                Text(message).font(.caption).foregroundStyle(.orange).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if library.busy {
                HStack { ProgressView(value: library.progress); Button("Cancel") { library.cancel() } }
            }
            if let previous = library.previousJob, library.errorMessage != nil {
                Button("Open previous transcript") { library.cancelRestoration(); selectedJob = previous }
            }
            HStack {
                Text(library.busy ? library.activity : source == nil ? "Saved recordings and Live sessions stay separate" : sourceAvailable ? "Original audio preserved" : "Original audio unavailable")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Menu("More", systemImage: "ellipsis") {
                    Button("Change recording…") { AppWindow.open(.recordings, using: openWindow, navigation: navigation) }
                    Button("Open transcript…", systemImage: "doc.text.magnifyingglass") {
                        let panel = NSOpenPanel()
                        panel.canChooseDirectories = true; panel.canChooseFiles = false
                        panel.directoryURL = AppSettings.supportDirectory.appendingPathComponent("Jobs")
                        panel.message = "Choose a job folder containing transcript.json"
                        if panel.runModal() == .OK, let url = panel.url { library.cancelRestoration(); selectedJob = url }
                    }
                    if let source {
                        Button("Reveal recording", systemImage: "folder") { NSWorkspace.shared.activateFileViewerSelecting([source]) }
                            .disabled(!sourceAvailable)
                    }
                    if let job = displayedJob {
                        Button("Reveal artifacts", systemImage: "folder") { NSWorkspace.shared.activateFileViewerSelecting([job]) }
                        Divider()
                        Button("Delete transcript…", systemImage: "trash", role: .destructive) { transcriptToDelete = job }
                            .disabled(!library.canDeleteTranscript(job))
                            .help("Move this transcript and its job artifacts to Trash. Keep the recording.")
                    }
                }.menuStyle(.borderlessButton).fixedSize().font(.caption)
            }

        }
        .padding(.horizontal, 36).padding(.top, 24).padding(.bottom, 12)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if source != nil {
                VStack(spacing: 0) {
                    Divider()
                    HStack(spacing: 16) {
                        if playback.hasPresentation {
                            SessionPlaybackView(playback: playback, showsSourceIdentity: false)
                        } else {
                            Button("Play", systemImage: "play.fill") { pendingSeekSeconds = 0 }
                                .disabled(!playbackAvailable)
                            Text("00:00").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                            Slider(value: .constant(0), in: 0...1).disabled(true)
                                .accessibilityLabel("Playback position").help("Play the recording to enable seeking")
                            if let duration = document?.source?.durationMs {
                                Text(Duration.seconds(Double(duration) / 1_000).formatted(.time(pattern: .minuteSecond)))
                                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                            }
                        }
                        Button(followAudio ? "Following audio" : "Follow audio") { followAudio.toggle() }
                            .buttonStyle(.borderless).font(.caption).fixedSize()
                    }.padding(.horizontal, 36).padding(.vertical, 14)
                }.background(WorkspaceStyle.panel)
            }
        }
        .inspector(isPresented: $showsInspector) {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    HStack {
                        Picker("Inspector", selection: $inspector) {
                            ForEach(InspectorTab.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                        }.pickerStyle(.segmented).labelsHidden()
                        Button("Close inspector", systemImage: "xmark") { closeInspector() }.labelStyle(.iconOnly).buttonStyle(.borderless)
                            .keyboardShortcut(.cancelAction)
                            .disabled(navigation != nil && navigation?.mode != .studio)
                    }
                    if let document {
                        if inspector == .review {
                            let items = document.reviewItems
                            Text("Listen. Compare. Verify.").font(.headline)
                            Text("Review notes stay attached to their original sources. Opening a note does not mark it as checked.")
                                .font(.caption).foregroundStyle(.secondary)
                            if review.loading {
                                HStack { ProgressView().controlSize(.small); Text("Loading review status…").font(.caption) }
                            } else if review.context != nil {
                                Label(uncheckedItems.isEmpty && !items.isEmpty ? "All review items checked" : "\(uncheckedItems.count) to check · \(review.checked.count) checked",
                                    systemImage: uncheckedItems.isEmpty && !items.isEmpty ? "checkmark.circle" : "checkmark.shield")
                                    .font(.callout).foregroundStyle(.secondary)
                            }
                            if let message = review.error {
                                VStack(alignment: .leading, spacing: 8) {
                                    Label(message, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
                                    Button("Reload transcript & review status", systemImage: "arrow.clockwise") { documentReload += 1 }
                                }
                            }
                            if items.isEmpty {
                                ContentUnavailableView("No flagged passages", systemImage: "checkmark.shield",
                                    description: Text("Inspect the transcript before relying on it."))
                            }
                            if !items.isEmpty {
                                let index = items.firstIndex(where: { $0.id == reviewItemID }) ?? 0
                                let item = items[index]
                                HStack(spacing: 12) {
                                    Button("Previous review item", systemImage: "chevron.left") {
                                        selectReviewItem(items[index - 1])
                                    }.labelStyle(.iconOnly).disabled(index == 0)
                                    Text("\(index + 1) of \(items.count)").font(.callout.monospacedDigit())
                                        .accessibilityLabel("Review item \(index + 1) of \(items.count)")
                                    Button("Next review item", systemImage: "chevron.right") {
                                        selectReviewItem(items[index + 1])
                                    }.labelStyle(.iconOnly).disabled(index == items.count - 1)
                                    Spacer()
                                    Menu("All items") {
                                        ForEach(items) { candidate in
                                            Button(candidate.title, systemImage: review.checked.contains(candidate.key) ? "checkmark.circle" : "circle") {
                                                selectReviewItem(candidate)
                                            }
                                        }
                                    }.menuStyle(.borderlessButton).fixedSize()
                                }
                                VStack(alignment: .leading, spacing: 10) {
                                    if let id = item.groupID {
                                        Button(item.title, systemImage: "text.magnifyingglass") {
                                            followAudio = false; section = .transcript; selectedGroupID = id
                                        }.buttonStyle(.borderless).multilineTextAlignment(.leading)
                                    } else { Label(item.title, systemImage: "doc.text").font(.subheadline.weight(.medium)) }
                                    ForEach(item.reasons, id: \.self) { Text(TranscriptReading.reviewLabel($0)).font(.callout) }
                                    if let group = document.readingGroups.first(where: { $0.id == item.groupID }) {
                                        sourceEvidence(group, in: document)
                                        if !playbackAvailable {
                                            Label("Audio is unavailable for playback. Original recognition remains readable.", systemImage: "speaker.slash")
                                                .font(.caption).foregroundStyle(.secondary)
                                        }
                                    } else {
                                        Text("This note applies to the whole recording.").font(.caption).foregroundStyle(.secondary)
                                    }
                                    DisclosureGroup("Technical details") {
                                        Text(item.reasons.joined(separator: "\n")).font(.caption.monospaced()).textSelection(.enabled)
                                    }.font(.caption).foregroundStyle(.secondary)
                                    Divider().padding(.vertical, 6)
                                    HStack(spacing: 12) {
                                        Button(review.checked.contains(item.key) ? "Reopen item" : "Mark checked",
                                            systemImage: review.checked.contains(item.key) ? "arrow.uturn.backward" : "checkmark") {
                                            review.setChecked(item, checked: !review.checked.contains(item.key))
                                        }.buttonStyle(.borderedProminent)
                                            .keyboardShortcut("k", modifiers: [.command, .option])
                                            .help("Mark checked or reopen item (⌥⌘K)")
                                            .disabled(review.context == nil || review.loading || review.saving)
                                        if review.saving { ProgressView().controlSize(.small).accessibilityLabel("Saving review status") }
                                    }
                                    let nextItems = Array(items.dropFirst(index + 1)) + items.prefix(index)
                                    if let next = nextItems.first(where: { !review.checked.contains($0.key) }) {
                                        Button("Next unchecked item", systemImage: "arrow.right") { selectReviewItem(next) }
                                            .buttonStyle(.borderless).font(.caption)
                                            .keyboardShortcut("n", modifiers: [.command, .option])
                                            .help("Next unchecked item (⌥⌘N)")
                                    }
                                    Text("Checked records your review of this version. It does not certify accuracy or change original flags, text or exports. A changed transcript requires a new review.")
                                        .font(.caption).foregroundStyle(.secondary)
                                }.frame(maxWidth: .infinity, alignment: .leading).id(item.id)
                            }
                        } else {
                            Label("Recording details", systemImage: "info.circle").font(.headline)
                            if let source { Text(source.lastPathComponent).textSelection(.enabled) }
                            LabeledContent("Mode", value: document.processing.mode.rawValue)
                            LabeledContent("Language", value: document.processing.sourceLanguage ?? "Not supplied")
                            LabeledContent("Recognition", value: document.recognitionLabel.isEmpty ? "Not supplied" : document.recognitionLabel)
                            if let metadata = document.source {
                                LabeledContent("Duration", value: Duration.seconds(Double(metadata.durationMs) / 1_000).formatted(.time(pattern: .hourMinuteSecond)))
                                LabeledContent("Channels", value: String(metadata.channels))
                                LabeledContent("Sample rate", value: "\(metadata.sampleRate) Hz")
                            }
                            LabeledContent("Segments", value: String(document.segments.count))
                            Text("Channel numbers identify audio sources, not speakers. Original audio and raw recognition results are preserved.")
                                .font(.caption).foregroundStyle(.secondary)
                            if let job = displayedJob { Button("Reveal artifacts", systemImage: "folder") { NSWorkspace.shared.activateFileViewerSelecting([job]) } }
                        }
                    }
                }.padding(20)
            }
            .inspectorColumnWidth(min: 280, ideal: 340, max: 440).background(WorkspaceStyle.background)
        }
        .confirmationDialog("Send transcript text to OpenAI?", isPresented: Binding(
            get: { library.pendingTextRequest != nil }, set: { if !$0 { library.pendingTextRequest = nil } })) {
                Button("Send text and process") { library.confirmTextProcessing() }
                Button("Cancel", role: .cancel) { library.pendingTextRequest = nil }
            } message: {
                Text("Source: \(library.pendingTextRequest?.sourceName ?? "")\nModel: \(library.pendingTextRequest?.model ?? "")\nOnly transcript text, segment IDs and uncertainty flags are sent to api.openai.com. No audio or local file paths. API charges and OpenAI retention policies apply. Originals remain on this Mac.")
            }
        .confirmationDialog("Move transcript to Trash?", isPresented: Binding(
            get: { transcriptToDelete != nil }, set: { if !$0 { transcriptToDelete = nil } })) {
                if let job = transcriptToDelete {
                    Button("Move transcript to Trash", role: .destructive) {
                        transcriptToDelete = nil
                        Task {
                            if await library.deleteTranscript(job) {
                                playback.stop()
                                pendingSeekSeconds = nil
                                selectedJob = nil
                                document = nil
                                error = nil
                                section = .transcript
                            }
                        }
                    }
                }
                Button("Cancel", role: .cancel) { transcriptToDelete = nil }
            } message: {
                Text("The transcript, summary and all artifacts in this job folder move to Trash. The original recording is kept. You can restore the folder from Trash.")
            }
        .task(id: copyVersion) {
            guard copyNotice != nil else { return }
            do { try await Task.sleep(for: .seconds(2)) } catch { return }
            copyNotice = nil
        }
        .onChange(of: section) { _, _ in copyNotice = nil }
        .onChange(of: library.studioJob) { _, job in
            selectedJob = nil
            if job == nil {
                document = nil; error = nil; pendingSeekSeconds = nil
                playback.stop(); section = .transcript
            }
        }
        .onDisappear { review.reset() }
        .task(id: "\(displayedJob?.path ?? ""):\(waitingForDocument):\(documentReload)") {
            pendingPassage = nil
            document = nil
            error = nil
            review.reset()
            reviewItemID = nil; selectedGroupID = nil
            guard !waitingForDocument, let job = displayedJob else { return }
            do {
                let result = try await TranscriptPreview.read(job)
                try Task.checkCancellation()
                document = result
                if selectedJob != nil { library.rememberOpenedTranscript(job, source: result.sourceURL) }
                if section == .live { section = .transcript }
                await review.load(job: job, document: result)
                try Task.checkCancellation()
                if reviewItemID == nil { reviewItemID = uncheckedItems.first?.id ?? reviewItems.first?.id }
            } catch is CancellationError { }
            catch { if !Task.isCancelled { self.error = error.localizedDescription } }
        }
    }

    private func closeInspector() {
        showsInspector = false
        inspectorTrigger = inspector
    }

    private func selectReviewItem(_ item: TranscriptReading.ReviewItem) {
        reviewItemID = item.id
        followAudio = false
        section = .transcript
        selectedGroupID = item.groupID
    }

    private func sourceEvidence(_ group: TranscriptReading.Group, in document: TranscriptPreview) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            ForEach(group.segments) { segment in
                VStack(alignment: .leading, spacing: 8) {
                    let source = TranscriptReading.Group(segments: [segment])
                    Divider()
                    Text(source.channels).font(.subheadline.weight(.semibold))
                    Text(source.timing).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    Text(segment.confidenceLabel).font(.callout)
                    Text("Model confidence is not a measured probability that these words are correct. Music can produce confident errors.")
                        .font(.caption).foregroundStyle(.secondary)
                    Text("Original recognition").font(.caption).foregroundStyle(.secondary)
                    MarkdownReadingText(text: segment.sourceText)
                    if document.displayedText(segment) != segment.sourceText {
                        Text("Displayed text").font(.caption).foregroundStyle(.secondary)
                        MarkdownReadingText(text: document.displayedText(segment))
                    }
                    if let start = segment.startMs, let end = segment.endMs,
                       let passage = PlaybackPolicy.Passage(start: Double(start) / 1_000, end: Double(end) / 1_000) {
                        Button("Listen to passage", systemImage: "play") { pendingPassage = passage }
                            .disabled(!playbackAvailable)
                            .help("Play this time range and stop at its end")
                    }
                    Text(segment.id).font(.caption.monospaced()).foregroundStyle(.tertiary).textSelection(.enabled)
                }
            }
        }
    }
}

private struct TranscriptSummaryView: View {
    let document: TranscriptPreview
    var onSource: (String) -> Void

    var body: some View {
        let notes = document.summary?.notes ?? []
        let sources = TranscriptReading.summarySources(in: document)
        ScrollView {
            VStack(alignment: .leading, spacing: 32) {
                Text("Draft summary").font(.caption).foregroundStyle(.secondary)
                ForEach(notes.indices, id: \.self) { index in
                    VStack(alignment: .leading, spacing: 12) {
                        MarkdownReadingText(text: notes[index].text, font: .title3)
                        ForEach(sources[index]) { source in
                            if let groupID = source.groupID {
                                Button("Source · \(source.timing ?? source.id) · \(source.channels ?? "")", systemImage: "text.magnifyingglass") {
                                    onSource(groupID)
                                }.buttonStyle(.borderless).font(.caption)
                                    .multilineTextAlignment(.leading)
                                    .help("Show original passage \(source.id). Opening a source does not start audio.")
                            } else {
                                Label("Source unavailable · \(source.id)", systemImage: "exclamationmark.circle")
                                    .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                            }
                        }
                        if sources[index].isEmpty {
                            Text("No source references supplied").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                Text("A summary is a derived draft. Check its source passages before sharing.")
                    .font(.callout).foregroundStyle(.secondary)
            }.frame(maxWidth: WorkspaceStyle.readingWidth, alignment: .leading)
                .frame(maxWidth: .infinity).padding(.vertical, 20)
        }
    }
}

@MainActor
enum TranscriptClipboard {
    static func copy(_ text: String, format: String, to board: NSPasteboard) -> String? {
        guard !text.isEmpty else { return nil }
        board.clearContents()
        return board.setString(text, forType: .string) ? "Copied \(format)" : "Copy failed · try again"
    }
}
