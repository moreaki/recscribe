import SwiftUI

struct TranscriptReadingView: View {

    let document: TranscriptPreview
    private let hasPlayback: Bool
    private let playbackPosition: Double?
    @Bindable private var playback: SessionPlayback
    var onSeek: ((Double) -> Void)? = nil
    var onReview: ((String) -> Void)? = nil
    var checkedReviewGroupIDs: Set<String>
    private var review: TranscriptReviewState?
    private var cloud: SegmentCloudState?
    @Binding private var selectedGroupID: String?
    @State private var mode: Mode
    @State private var expandedGroups: Set<String>
    @State private var followPlayback = true
    private var externalFollow: Binding<Bool>?
    private var followsAudio: Bool {
        get { externalFollow?.wrappedValue ?? followPlayback }
        nonmutating set { if let externalFollow { externalFollow.wrappedValue = newValue } else { followPlayback = newValue } }
    }
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
        onSeek: ((Double) -> Void)? = nil,
        selectedGroupID: Binding<String?> = .constant(nil),
        onReview: ((String) -> Void)? = nil,
        followPlayback: Binding<Bool>? = nil,
        checkedReviewGroupIDs: Set<String> = [],
        review: TranscriptReviewState? = nil,
        cloud: SegmentCloudState? = nil
    ) {
        self.document = document
        self.hasPlayback = playback != nil
        self.playbackPosition = playbackPosition
        self._playback = Bindable(wrappedValue: playback ?? SessionPlayback())
        self.onSeek = onSeek
        self.onReview = onReview
        self.checkedReviewGroupIDs = checkedReviewGroupIDs
        self.review = review
        self.cloud = cloud
        self.externalFollow = followPlayback
        self._selectedGroupID = selectedGroupID
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
                Menu {
                    Picker("Transcript presentation", selection: $mode) {
                        ForEach(Mode.allCases, id: \.self) { Label($0.rawValue, systemImage: $0.symbol).tag($0) }
                    }
                } label: { Text(mode.rawValue) }
                .menuStyle(.borderlessButton).fixedSize().foregroundStyle(.secondary)
                if showFollowControl && externalFollow == nil {
                    Button(followsAudio ? "Following audio" : "Follow audio", systemImage: "arrow.down.to.line") {
                        followsAudio.toggle()
                    }
                    .buttonStyle(.borderless)
                    .font(.caption)
                    .tint(WorkspaceStyle.blue)
                }
                Spacer()
            }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 32) {
                        ForEach(groups) { group in
                            let isActive = currentActiveGroupID == group.id
                            let isSelected = selectedGroupID == group.id
                            let first = group.segments[0]
                            let sameWords = group.segments.allSatisfy {
                                $0.sourceText == first.sourceText && document.displayedText($0) == document.displayedText(first)
                            }
                            HStack(alignment: .top, spacing: 22) {
                                Group {
                                    if let start = group.startSeconds, onSeek != nil || hasPlayback {
                                        Button {
                                            if let onSeek { onSeek(start) }
                                            else if hasPlayback { playback.seek(to: start) }
                                        } label: { Text(Duration.seconds(start).formatted(.time(pattern: .minuteSecond))) }
                                            .buttonStyle(.plain).help("Seek audio to \(group.timing)")
                                    } else { Text(group.timing) }
                                }.font(.caption.monospacedDigit()).foregroundStyle(isActive ? WorkspaceStyle.mint : .secondary)
                                    .frame(width: 54, alignment: .trailing).padding(.top, 4)
                                VStack(alignment: .leading, spacing: 10) {
                                    if sameWords {
                                        MarkdownReadingText(text: document.displayedText(first), font: .title3)
                                    } else {
                                        ForEach(group.segments) { segment in
                                            VStack(alignment: .leading, spacing: 4) {
                                                Text(TranscriptReading.Group(segments: [segment]).channels).font(.caption).foregroundStyle(.secondary)
                                                MarkdownReadingText(text: document.displayedText(segment), font: .title3)
                                            }
                                        }
                                    }
                                    if let review {
                                        if group.segments.count == 1 {
                                            TranscriptSegmentEditor(segment: first, document: document, review: review, cloud: cloud)
                                        } else {
                                            DisclosureGroup("Edit sources") {
                                                ForEach(group.segments) { segment in
                                                    VStack(alignment: .leading, spacing: 8) {
                                                        Text(TranscriptReading.Group(segments: [segment]).channels).font(.caption.weight(.medium))
                                                        TranscriptSegmentEditor(segment: segment, document: document, review: review, cloud: cloud)
                                                    }.padding(.vertical, 4)
                                                }
                                            }.font(.caption).foregroundStyle(.secondary)
                                        }
                                    }
                                    if group.segments.contains(where: { $0.needsReview || !($0.reviewReasons ?? []).isEmpty }) || !group.isShared(in: document, originalRecognition: true) {
                                        if let onReview {
                                            let checked = checkedReviewGroupIDs.contains(TranscriptReading.reviewGroupID(for: group.id, in: document) ?? group.id)
                                            Button("\(checked ? "Sources checked" : "Check sources") · \(group.segments.count) \(group.segments.count == 1 ? "source" : "sources")",
                                                systemImage: checked ? "checkmark.circle" : "info.circle") { onReview(group.id) }
                                                .buttonStyle(.borderless).font(.caption).tint(WorkspaceStyle.blue)
                                        } else { Label("Review", systemImage: "exclamationmark.circle").font(.caption).foregroundStyle(.secondary) }
                                    }
                                    if onReview == nil || !(group.segments.contains(where: { $0.needsReview || !($0.reviewReasons ?? []).isEmpty }) || !group.isShared(in: document, originalRecognition: true)) {
                                        DisclosureGroup("Source details", isExpanded: expansion(group.id)) { sources(group) }
                                            .font(.caption).foregroundStyle(.secondary)
                                    }
                                }.frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .padding(6)
                            .background(isActive || isSelected ? WorkspaceStyle.selected : .clear, in: RoundedRectangle(cornerRadius: 8))
                            .id(group.id)
                        }
                    }.frame(maxWidth: 800, alignment: .leading)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 28)

                }
                .onChange(of: currentActiveGroupID) { _, nextID in
                    if followsAudio, let nextID {
                        proxy.scrollTo(nextID, anchor: .center)
                    }
                }
                .onChange(of: selectedGroupID, initial: true) { _, id in
                    if let id {
                        expandedGroups.insert(id)
                        proxy.scrollTo(id, anchor: .center)
                    }
                }
                .onChange(of: followsAudio) { _, follow in
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
                        Text(TranscriptReading.reviewLabel(reason)).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                    DisclosureGroup("Technical details") {
                        Text((segment.reviewReasons ?? []).joined(separator: "\n")).font(.caption.monospaced()).textSelection(.enabled)
                    }.font(.caption).foregroundStyle(.secondary)
                }
            }
        }.padding(.top, StudioSpacing.s)
    }
}
