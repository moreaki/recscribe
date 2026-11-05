import SwiftUI

struct TranscriptReadingView: View {

    let document: TranscriptPreview
    private let hasPlayback: Bool
    private let playbackPosition: Double?
    @Bindable private var playback: SessionPlayback
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
        playbackPosition: Double? = nil,
        onSeek: ((Double) -> Void)? = nil
    ) {
        self.document = document
        self.hasPlayback = playback != nil
        self.playbackPosition = playbackPosition
        self._playback = Bindable(wrappedValue: playback ?? SessionPlayback())
        self.onSeek = onSeek
        _mode = State(initialValue: mode)
        _expandedGroups = State(initialValue: expandedGroups)
    }

    var effectivePositionSeconds: Double? {
        if let playbackPosition {
            return playbackPosition
        }
        guard hasPlayback, (playback.player != nil || playback.isPlaying || playback.position > 0) else {
            return nil
        }
        return playback.position
    }

    var displayedGroups: [TranscriptReading.Group] {
        document.groups(for: mode)
    }

    var activeGroupID: String? {
        TranscriptReading.activeGroupID(in: displayedGroups, positionSeconds: effectivePositionSeconds)
    }

    var body: some View {
        let groups = displayedGroups
        let currentActiveGroupID = TranscriptReading.activeGroupID(
            in: groups,
            positionSeconds: effectivePositionSeconds
        )
        let showFollowControl = playbackPosition != nil || (hasPlayback && (playback.player != nil || playback.isPlaying || playback.position > 0))
        VStack(alignment: .leading, spacing: StudioSpacing.md) {
            HStack {
                WorkspaceTabs(title: "Transcript presentation", selection: $mode)
                if showFollowControl {
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
                    LazyVStack(alignment: .leading, spacing: StudioSpacing.xl) {
                        ForEach(groups) { group in
                            let isActive = currentActiveGroupID == group.id
                            VStack(alignment: .leading, spacing: StudioSpacing.sm) {
                                HStack {
                                    if let startSeconds = group.startSeconds, (onSeek != nil || hasPlayback) {
                                        Button {
                                            if hasPlayback {
                                                playback.seek(to: startSeconds)
                                            }
                                            onSeek?(startSeconds)
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
                            .padding(isActive ? StudioSpacing.s : 0)
                            .background(
                                isActive
                                    ? RoundedRectangle(cornerRadius: 8).fill(WorkspaceStyle.mint.opacity(0.1))
                                    : nil
                            )
                            .id(group.id)
                        }
                    }.frame(maxWidth: WorkspaceStyle.readingWidth, alignment: .leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, StudioSpacing.s)
                }
                .onChange(of: currentActiveGroupID) { _, nextID in
                    if followPlayback, let nextID {
                        proxy.scrollTo(nextID, anchor: .center)
                    }
                }
                .onChange(of: followPlayback) { _, follow in
                    if follow, let currentActiveGroupID {
                        proxy.scrollTo(currentActiveGroupID, anchor: .center)
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
        VStack(alignment: .leading, spacing: StudioSpacing.md) {
            ForEach(group.segments) { segment in
                VStack(alignment: .leading, spacing: StudioSpacing.xs) {
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
        }.padding(.top, StudioSpacing.s)
    }
}
