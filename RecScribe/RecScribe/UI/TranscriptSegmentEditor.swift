import SwiftUI

/// The draft stays local to this source. Only confirmed saves change the transcript.
struct TranscriptSegmentEditor: View {
    let segment: TranscriptPreview.Segment
    let document: TranscriptPreview
    @Bindable var review: TranscriptReviewState
    var showsOriginal = true
    @State private var editing = false
    @State private var draft = ""
    @State private var baseline: TranscriptCorrection?
    @State private var submitted = false

    private var correction: TranscriptCorrection? { document.corrections[segment.id] }
    private var candidate: TranscriptCorrection { .init(kind: .text, text: draft) }
    private var unavailable: Bool { review.context == nil || review.loading || review.saving }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let correction {
                Label(correction.kind == .musicOnly ? "Music only · marked by you" : "Manually corrected", systemImage: "pencil.circle")
                    .font(.caption).foregroundStyle(WorkspaceStyle.mint)
            }
            if editing {
                Text("Correct this passage").font(.subheadline.weight(.medium))
                TextEditor(text: $draft).font(.body)
                    .frame(minHeight: 90, maxHeight: 180)
                    .accessibilityLabel("Corrected passage text")
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(.secondary.opacity(0.3)))
                    .disabled(unavailable)
                HStack {
                    Button("Save correction") { submitted = true; review.setCorrection(candidate, for: segment.id) }
                        .buttonStyle(.borderedProminent)
                        .disabled(unavailable || !candidate.valid || candidate == correction || baseline != correction)
                    Button("Cancel") { editing = false }.disabled(review.saving)
                    if review.saving { ProgressView().controlSize(.small) }
                }
                if !candidate.valid {
                    Text("Enter text of at most 64 KB, or choose Music only.").font(.caption).foregroundStyle(.secondary)
                }
                if baseline != correction {
                    Text("The saved passage changed while you were editing. Your draft is kept; cancel and reopen editing to use the latest text.")
                        .font(.caption).foregroundStyle(.orange)
                }
            }
            HStack {
                if !editing {
                    Button("Edit text", systemImage: "pencil") {
                        draft = correction?.kind == .musicOnly ? segment.sourceText : document.displayedText(segment)
                        baseline = correction; submitted = false
                        editing = true
                    }.disabled(unavailable)
                }
                Button("Music only", systemImage: "music.note") { submitted = true; review.setCorrection(.musicOnly, for: segment.id) }
                    .disabled(unavailable || correction?.kind == .musicOnly)
                if correction != nil {
                    Button("Remove correction") { submitted = true; review.setCorrection(nil, for: segment.id) }.disabled(unavailable)
                }
            }.buttonStyle(.borderless).font(.caption)
            if showsOriginal, editing || correction != nil {
                DisclosureGroup("Original recognition") { MarkdownReadingText(text: segment.sourceText) }
                    .font(.caption).foregroundStyle(.secondary)
            }
            if editing || correction != nil {
                Text("Corrections appear in this transcript and copied/shared text. Original recognition is preserved.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .onChange(of: correction) { _, _ in if submitted { editing = false; submitted = false } }
        .onChange(of: review.error) { _, error in if error != nil { submitted = false } }
        .onChange(of: document.revision) { _, _ in editing = false }
    }
}
