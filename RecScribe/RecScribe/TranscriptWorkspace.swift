import SwiftUI

/// Markdown is rendered natively, without web views, scripts or remote assets.
/// Transcript text is escaped before interpretation; words cannot inject links.
struct MarkdownReadingText: View {
    let text: String
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
        Text(Self.literal(text)).font(.body).lineSpacing(WorkspaceStyle.lineSpacing)
            .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct LiveTranscriptView: View {
    @ObservedObject var live: LiveTranscription
    var compact = false
    @State private var followsLatest = true
    var body: some View {
        VStack(alignment: .leading, spacing: GlassSpacing.l) {
            HStack {
                Label("Live draft", systemImage: "text.bubble.fill").font(.headline).foregroundStyle(WorkspaceStyle.blue)
                Spacer()
                Button(followsLatest ? "Following live" : "Follow live", systemImage: "arrow.down.to.line") { followsLatest.toggle() }
                    .buttonStyle(.borderless).font(.caption).tint(WorkspaceStyle.blue)
                    .accessibilityLabel("Follow latest transcript text")
                    .accessibilityValue(followsLatest ? "On" : "Off")
            }
            Text("Unverified · \(live.status)").font(.caption).foregroundStyle(.secondary)
            if live.captureNeedsReview {
                Label("Recording was interrupted or could not be finalized. Review the saved audio and this partial draft.",
                      systemImage: "exclamationmark.triangle")
                    .font(.callout).foregroundStyle(.orange)
            }
            if live.segments.isEmpty {
                ContentUnavailableView("Let the conversation unfold", systemImage: "waveform.and.mic",
                    description: Text("Enable live transcription before or during recording. Words appear after an audio window is processed. Cloud audio requires separate approval."))
                    .frame(maxWidth: .infinity)
            } else {
                ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: GlassSpacing.xl) {
                        ForEach(live.segments) { segment in
                            VStack(alignment: .leading, spacing: GlassSpacing.sm) {
                                MarkdownReadingText(text: segment.text)
                                Text("\(live.isCloudDraft ? "≈ " : "")\(Duration.seconds(segment.startSeconds).formatted(.time(pattern: .hourMinuteSecond))) · channel \(segment.channel + 1) · \(segment.language ?? "undetected")")
                                    .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                            }
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
                     : "Bounded recent preview. Complete raw chunk results stay on this Mac. Word boundaries, silence and language switches need review; this is not the final transcript.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
    }
}

struct LiveTranscriptionControl: View {
    @ObservedObject var live: LiveTranscription
    @State private var preview = false
    var body: some View {
        HStack {
            Toggle("Live transcription", isOn: Binding(get: { live.enabled }, set: { live.setEnabled($0) }))
                .toggleStyle(.switch).controlSize(.small).tint(WorkspaceStyle.blue)
            Spacer()
            Button { preview.toggle() } label: { Image(systemName: "text.bubble") }
                .buttonStyle(.plain).accessibilityLabel("Preview live transcript").help("Preview the live draft")
                .onHover { hovering in if hovering { preview = true } }
                .popover(isPresented: $preview, arrowEdge: .bottom) {
                    LiveTranscriptView(live: live, compact: true).padding(WorkspaceStyle.contentPadding)
                        .frame(width: WorkspaceStyle.previewWidth, height: WorkspaceStyle.previewHeight)
                        .background(WorkspaceStyle.background).preferredColorScheme(.dark)
                }
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
    @EnvironmentObject private var live: LiveTranscription
    @EnvironmentObject private var library: SessionLibrary
    @Environment(\.openWindow) private var openWindow
    @State private var section: Section
    @State private var document: TranscriptPreview?
    @State private var error: String?
    @State private var selectedJob: URL?
    @State private var followLiveSource = false
    private var displayedJob: URL? {
        selectedJob ?? (followLiveSource && library.latestSource != live.sourceURL ? nil : library.latestJob)
    }
    private var source: URL? {
        if section == .live { return live.sourceURL }
        return document?.sourceURL ?? (followLiveSource ? live.sourceURL : library.latestSource ?? live.sourceURL)
    }
    enum Section: String, CaseIterable { case live = "Live", transcript = "Transcript", summary = "Summary", review = "Review" }
    init(section: Section = .live) { _section = State(initialValue: section) }
    var body: some View {
        VStack(alignment: .leading, spacing: GlassSpacing.xl) {
            HStack {
                WorkspaceIcon(symbol: section == .summary ? "sparkles" : "text.alignleft", tint: WorkspaceStyle.violet)
                VStack(alignment: .leading, spacing: GlassSpacing.xs) {
                    Text("Your words, in focus").font(.title3.weight(.semibold))
                    Text("From lossless audio to a readable, traceable draft.").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
            }
            Picker("Text view", selection: $section) {
                ForEach(Section.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }.pickerStyle(.segmented)
            if let source {
                TranscriptSourceView(source: source,
                    duration: section == .live ? live.audioSeconds : document?.source.map { Double($0.durationMs) / 1_000 },
                    detail: section == .live ? live.modelName ?? "Local live draft" : document?.recognitionLabel ?? "Full recording · final recognition",
                    recording: library.recordingActive)
            }
            if section != .live {
                HStack {
                    if let source {
                        Button(document == nil ? "Create final transcript" : "Transcribe again", systemImage: "text.bubble") {
                            selectedJob = nil; library.transcribe(source)
                        }
                    }
                    if document != nil, let job = displayedJob {
                        Button(section == .summary ? "Generate summary" : "Improve text", systemImage: "sparkles") {
                            library.requestTextProcessing(job, summary: section == .summary, sourceName: source?.lastPathComponent)
                        }
                    }
                    Button("AI & transcription settings", systemImage: "slider.horizontal.3") { openWindow(id: AppWindow.settings.rawValue) }
                }.disabled(library.busy || library.recordingActive || library.liveWorkActive)
            }
            if section == .live { LiveTranscriptView(live: live) }
            else if let document {
                let content = section == .summary ? document.summaryText : section == .review ? document.reviewReasons.joined(separator: "\n\n") : document.text
                if content.isEmpty {
                    ContentUnavailableView(section == .summary ? "No summary yet" : "No review notes", systemImage: section == .summary ? "sparkles" : "checkmark.shield",
                        description: Text(section == .summary ? "Choose Ollama or OpenAI in Settings → Intelligence, then Generate summary above. Cloud text transfer always asks for confirmation." : "Inspect the transcript before relying on it."))
                } else {
                    ScrollView { MarkdownReadingText(text: content).frame(maxWidth: WorkspaceStyle.readingWidth).padding(.vertical, GlassSpacing.s) }
                }
                Spacer(minLength: 0)
                Label("\(document.processing.mode.rawValue) · \(document.includesCloudAudio ? "Includes cloud audio transcription" : document.includesCloudText ? "Includes cloud text" : "Processed locally") · review required", systemImage: "checkmark.shield").font(.caption).foregroundStyle(.secondary)
            } else {
                ContentUnavailableView(library.busy ? "Processing your recording" : "Create a final transcript", systemImage: "doc.text",
                    description: Text(source == nil ? "Choose a recording or import a WAV. Live drafts and final transcripts are separate." : "The Live tab is a provisional chunk preview. Create a final transcript from the complete recording, then improve its text or generate a summary."))
                if source == nil { Button("Choose recording / import…") { openWindow(id: AppWindow.recordings.rawValue) } }
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
                Button("Open previous transcript") { selectedJob = previous }
            }
            HStack {
                Text("Pipeline: \(library.activity)").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Open transcript…", systemImage: "doc.text.magnifyingglass") {
                    let panel = NSOpenPanel()
                    panel.canChooseDirectories = true
                    panel.canChooseFiles = false
                    panel.directoryURL = AppSettings.supportDirectory.appendingPathComponent("Jobs")
                    panel.message = "Choose a job folder containing transcript.json"
                    if panel.runModal() == .OK, let url = panel.url { selectedJob = url }
                }
                if let job = displayedJob {
                    Button("Artifacts", systemImage: "folder") { NSWorkspace.shared.activateFileViewerSelecting([job]) }
                }
            }
        }
        .padding(WorkspaceStyle.contentPadding)
        .confirmationDialog("Send transcript text to OpenAI?", isPresented: Binding(
            get: { library.pendingTextRequest != nil }, set: { if !$0 { library.pendingTextRequest = nil } })) {
                Button("Send text and process") { library.confirmTextProcessing() }
                Button("Cancel", role: .cancel) { library.pendingTextRequest = nil }
            } message: {
                Text("Source: \(library.pendingTextRequest?.sourceName ?? "")\nModel: \(library.pendingTextRequest?.model ?? "")\nOnly transcript text, segment IDs and uncertainty flags are sent to api.openai.com. No audio or local file paths. API charges and OpenAI retention policies apply. Originals remain on this Mac.")
            }
        .onChange(of: library.latestJob) { _, _ in selectedJob = nil; followLiveSource = false }
        .onChange(of: live.sourceURL) { _, _ in
            selectedJob = nil; document = nil; followLiveSource = true; section = .live
        }
        .task(id: "\(displayedJob?.path ?? ""):\(library.progress == 1)") {
            document = nil
            error = nil
            guard selectedJob != nil || library.progress == 1, let job = displayedJob else { return }
            do {
                let result = try await TranscriptPreview.read(job)
                try Task.checkCancellation()
                document = result
                if selectedJob != nil { library.rememberOpenedTranscript(job, source: result.sourceURL) }
                if section == .live { section = .transcript }
            } catch is CancellationError { }
            catch { if !Task.isCancelled { self.error = error.localizedDescription } }
        }
    }
}
