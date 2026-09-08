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
            if live.segments.isEmpty {
                ContentUnavailableView("Let the conversation unfold", systemImage: "waveform.and.mic",
                    description: Text("Enable live transcription before or during recording. Words appear here after a complete chunk has been processed locally."))
                    .frame(maxWidth: .infinity)
            } else {
                ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: GlassSpacing.xl) {
                        ForEach(live.segments) { segment in
                            VStack(alignment: .leading, spacing: GlassSpacing.sm) {
                                MarkdownReadingText(text: segment.text)
                                Text("\(Duration.seconds(segment.startSeconds).formatted(.time(pattern: .hourMinuteSecond))) · channel \(segment.channel + 1) · \(segment.language ?? "undetected")")
                                    .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                            }
                            .id(segment.id)
                        }
                    }.frame(maxWidth: WorkspaceStyle.readingWidth, alignment: .leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .onChange(of: live.segments.last?.id) { _, id in if followsLatest, let id { proxy.scrollTo(id, anchor: .bottom) } }
                .onChange(of: followsLatest) { _, follow in if follow, let id = live.segments.last?.id { proxy.scrollTo(id, anchor: .bottom) } }
                .onAppear { if let id = live.segments.last?.id, followsLatest { proxy.scrollTo(id, anchor: .bottom) } }
                }
            }
            if let error = live.errorMessage { Text(error).font(.caption).foregroundStyle(.orange).textSelection(.enabled) }
            if !compact {
                HStack {
                    Label("\(live.lastChunkSeconds.formatted(.number.precision(.fractionLength(1)))) s / last chunk", systemImage: "timer")
                    Spacer()
                    if let directory = live.directory {
                        Button("Draft artifacts", systemImage: "folder") { NSWorkspace.shared.activateFileViewerSelecting([directory]) }
                    }
                }.font(.caption).foregroundStyle(.secondary)
                Text("Bounded recent preview. Complete raw chunk results stay on this Mac. Word boundaries, silence and language switches need review; this is not the final transcript.")
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
    }
}

struct TranscriptWorkspace: View {
    @EnvironmentObject private var live: LiveTranscription
    @EnvironmentObject private var library: SessionLibrary
    @State private var section = Section.live
    @State private var document: TranscriptPreview?
    @State private var error: String?
    @State private var selectedJob: URL?
    private var displayedJob: URL? { selectedJob ?? library.latestJob }
    private enum Section: String, CaseIterable { case live = "Live", transcript = "Transcript", summary = "Summary", review = "Review" }
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
            if section == .live { LiveTranscriptView(live: live) }
            else if let document {
                let content = section == .summary ? document.summaryText : section == .review ? document.reviewReasons.joined(separator: "\n\n") : document.text
                if content.isEmpty {
                    ContentUnavailableView(section == .summary ? "No summary yet" : "No review notes", systemImage: section == .summary ? "sparkles" : "checkmark.shield",
                        description: Text(section == .summary ? "Enable local AI in Settings, choose an installed model, then use Transcribe & summarize in Recordings. Originals and raw ASR remain unchanged." : "Inspect the transcript before relying on it."))
                } else {
                    ScrollView { MarkdownReadingText(text: content).frame(maxWidth: WorkspaceStyle.readingWidth).padding(.vertical, GlassSpacing.s) }
                }
                Spacer(minLength: 0)
                Label("\(document.processing.mode.rawValue) · AI-derived text and notes require review", systemImage: "checkmark.shield").font(.caption).foregroundStyle(.secondary)
            } else {
                ContentUnavailableView("A little more than a recording", systemImage: section == .summary ? "sparkles" : "doc.text",
                    description: Text("Open Recordings to transcribe a completed session or import a WAV. Your transcript, source-linked summary and review notes appear here."))
                Spacer(minLength: 0)
            }
            if let message = error ?? library.errorMessage { Text(message).font(.caption).foregroundStyle(.orange).textSelection(.enabled) }
            HStack {
                Text(library.activity).font(.caption).foregroundStyle(.secondary)
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
        .onChange(of: library.latestJob) { _, _ in selectedJob = nil }
        .task(id: "\(displayedJob?.path ?? ""):\(library.progress == 1)") {
            document = nil
            error = nil
            guard selectedJob != nil || library.progress == 1, let job = displayedJob else { return }
            do {
                let result = try await TranscriptPreview.read(job)
                try Task.checkCancellation()
                document = result
                section = .transcript
            } catch is CancellationError { }
            catch { if !Task.isCancelled { self.error = error.localizedDescription } }
        }
    }
}
