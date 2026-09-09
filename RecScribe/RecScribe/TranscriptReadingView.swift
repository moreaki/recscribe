import SwiftUI

struct TranscriptReadingView: View {
    let document: TranscriptPreview
    @State private var mode: Mode
    @State private var expandedGroups: Set<String>
    enum Mode: String, WorkspaceTab {
        case reading = "Reading", channels = "All channels"
        var symbol: String { self == .reading ? "text.alignleft" : "square.stack.3d.up" }
    }
    init(document: TranscriptPreview, mode: Mode = .reading, expandedGroups: Set<String> = []) {
        self.document = document
        _mode = State(initialValue: mode)
        _expandedGroups = State(initialValue: expandedGroups)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: GlassSpacing.md) {
            WorkspaceTabs(title: "Transcript presentation", selection: $mode)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: GlassSpacing.xl) {
                    ForEach(mode == .reading ? TranscriptReading.groups(document.segments) : document.segments.map { .init(segments: [$0]) }) { group in
                        VStack(alignment: .leading, spacing: GlassSpacing.sm) {
                            HStack {
                                Text(group.timing).monospacedDigit()
                                Text(group.channels)
                                if group.segments.contains(where: \.needsReview) {
                                    Label("Review", systemImage: "exclamationmark.circle")
                                }
                            }.font(.caption).foregroundStyle(.secondary)
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
                    }
                }.frame(maxWidth: WorkspaceStyle.readingWidth, alignment: .leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, GlassSpacing.s)
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
