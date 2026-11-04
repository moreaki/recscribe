import SwiftUI

struct TranscriptReadingView: View {
    let document: TranscriptPreview
    var playback: SessionPlayback? = nil
    var onSeek: ((Double) -> Void)? = nil
    @State private var mode: Mode
    @State private var expandedGroups: Set<String>
    @State private var followPlayback = true
    enum Mode: String, WorkspaceTab {
        case reading = "Reading", channels = "All channels"
        var symbol: String { self == .reading ? "text.alignleft" : "square.stack.3d.up" }
    }
    init(
        document: TranscriptPreview,
        mode: Mode = .reading,
        expandedGroups: Set<String> = [],
        playback: SessionPlayback? = nil,
        onSeek: ((Double) -> Void)? = nil
    ) {
        self.document = document
        self.playback = playback
        self.onSeek = onSeek
        _mode = State(initialValue: mode)
        _expandedGroups = State(initialValue: expandedGroups)
    }

    private var displayedGroups: [TranscriptReading.Group] {
        mode == .reading ? TranscriptReading.groups(document.segments) : document.segments.map { .init(segments: [$0]) }
    }

    private var activeGroupID: String? {
        guard let playback, playback.player != nil else { return nil }
        return displayedGroups.first(where: { $0.contains(positionSeconds: playback.position) })?.id
    }

    var body: some View {
        VStack(alignment: .leading, spacing: GlassSpacing.md) {
            HStack {
                WorkspaceTabs(title: "Transcript presentation", selection: $mode)
                if playback?.player != nil {
                    Spacer()
                    Button(followPlayback ? "Following audio" : "Follow audio", systemImage: "arrow.down.to.line") {
                        followPlayback.toggle()
                    }
                    .buttonStyle(.borderless)
                    .font(.caption)
                    .tint(WorkspaceStyle.blue)
                }
            }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: GlassSpacing.xl) {
                        ForEach(displayedGroups) { group in
                            let isActive = activeGroupID == group.id
                            VStack(alignment: .leading, spacing: GlassSpacing.sm) {
                                HStack {
                                    if let startSeconds = group.startSeconds, let onSeek {
                                        Button {
                                            onSeek(startSeconds)
                                        } label: {
                                            Text(group.timing).monospacedDigit().underline()
                                        }
                                        .buttonStyle(.plain)
                                        .foregroundStyle(isActive ? WorkspaceStyle.mint : .secondary)
                                        .help("Seek audio to \(group.timing)")
                                    } else {
                                        Text(group.timing).monospacedDigit()
                                    }
                                    Text(group.channels)
                                    if group.segments.contains(where: \.needsReview) {
                                        Label("Review", systemImage: "exclamationmark.circle")
                                    }
                                }.font(.caption).foregroundStyle(isActive ? WorkspaceStyle.mint : .secondary)
                                if group.isShared(in: document) {
                                    MarkdownReadingText(text: document.displayedText(group.segments[0]))
                                    DisclosureGroup("Sources & review", isExpanded: expansion(group.id)) { sources(group) }
                                        .font(.caption).foregroundStyle(.secondary)
                                } else {
                                    DisclosureGroup("Overlapping channel texts · compare \(group.segments.count) variants", isExpanded: expansion(group.id)) {
                                        sources(group)
                                    }.font(.callout).tint(WorkspaceStyle.blue)
                                }
                            }
                            .padding(isActive ? GlassSpacing.s : 0)
                            .background(
                                isActive
                                    ? RoundedRectangle(cornerRadius: 8).fill(WorkspaceStyle.mint.opacity(0.1))
                                    : nil
                            )
                            .id(group.id)
                        }
                    }.frame(maxWidth: WorkspaceStyle.readingWidth, alignment: .leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, GlassSpacing.s)
                }
                .onChange(of: activeGroupID) { _, nextID in
                    if followPlayback, let nextID {
                        proxy.scrollTo(nextID, anchor: .center)
                    }
                }
            }
        }
    }

    private func expansion(_ id: String) -> Binding<Bool> {
        Binding(get: { expandedGroups.contains(id) }, set: { expanded in
            if expanded { expandedGroups.insert(id) } else { expandedGroups.remove(id) }
        })
    }

    private func sources(_ group: TranscriptReading.Group) -> some View {
        VStack(alignment: .leading, spacing: GlassSpacing.md) {
            ForEach(group.segments) { segment in
                VStack(alignment: .leading, spacing: GlassSpacing.xs) {
                    let single = TranscriptReading.Group(segments: [segment])
                    Text("\(single.channels) · \(single.timing) · \(segment.id)").font(.caption).foregroundStyle(.secondary)
                    MarkdownReadingText(text: document.displayedText(segment))
                    if document.displayedText(segment) != segment.sourceText {
                        Text("Original ASR").font(.caption).foregroundStyle(.secondary)
                        MarkdownReadingText(text: segment.sourceText)
                    }
                    ForEach(segment.reviewReasons ?? [], id: \.self) { reason in
                        Text(reason).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                }
            }
        }.padding(.top, GlassSpacing.s)
    }
}
