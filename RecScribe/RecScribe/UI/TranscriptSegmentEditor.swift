import SwiftUI
import RecScribeCore

/// The draft stays local to this source. Only confirmed saves change the transcript.
struct TranscriptSegmentEditor: View {
    let segment: TranscriptPreview.Segment
    let document: TranscriptPreview
    @Bindable var review: TranscriptReviewState
    var showsOriginal = true
    var cloud: SegmentCloudState? = nil
    var acoustic: SegmentAcousticState? = nil
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
                Label(correction.kind == .musicOnly ? (correction.automatic != nil ? "Music only · automatically hidden · verify against audio" : correction.acoustic == nil ? "Music only · marked by you" : "Music only · local analysis confirmed by you") : correction.cloud.map { "Cloud recognition · \($0.model) · verify against audio" } ?? "Manually corrected", systemImage: "pencil.circle")
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
                        review.stopAutomatic()
                        draft = correction?.kind == .musicOnly ? segment.sourceText : document.displayedText(segment)
                        baseline = correction; submitted = false
                        editing = true
                    }.disabled(unavailable)
                }
                Button("Music only", systemImage: "music.note") { submitted = true; review.setCorrection(.musicOnly, for: segment.id) }
                    .disabled(unavailable || correction?.kind == .musicOnly)
                if correction != nil {
                    Button(correction?.automatic != nil ? "Restore original recognition" : "Remove correction") { submitted = true; review.setCorrection(nil, for: segment.id) }.disabled(unavailable)
                }
            }.buttonStyle(.borderless).font(.caption)
            if let acoustic {
                Button("Analyze sound locally", systemImage: "waveform") {
                    review.stopAutomatic()
                    if let context = review.context { acoustic.request(job: context.job, document: document, segmentID: segment.id) }
                }.buttonStyle(.borderless).font(.caption)
                    .disabled(unavailable || acoustic.blocked || acoustic.busy || cloud?.busy == true || document.source == nil)
                    .help("Check this channel and time range for instrumental music. No audio leaves this Mac.")
                if let result = acoustic.result, result.selection.segmentID == segment.id {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(result.report.assessment.outcome == .musicNeedsListeningReview
                             ? "Possible music · check for quiet speech"
                             : result.correction == nil ? "Voice detected or music-only result uncertain. Recognition kept." : "Likely instrumental music · listen before confirming")
                            .font(.caption.weight(.medium))
                        if result.report.assessment.outcome == .musicNeedsListeningReview {
                            Text("Longer context suggests music, but quiet speech can have the same scores. Recognition is kept. Listen to this passage before choosing Music only.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Text("Local sound analysis is not a transcription accuracy percentage. Quiet speech can be missed.")
                            .font(.caption).foregroundStyle(.secondary)
                        if result.correction != nil {
                            Button("Confirm music only") { acoustic.confirmMusicOnly(in: review) }
                                .disabled(unavailable || acoustic.busy || acoustic.blocked || editing || correction == result.correction)
                        }
                        Button("Reveal sound analysis", systemImage: "folder") { NSWorkspace.shared.activateFileViewerSelecting([result.evidence]) }
                            .buttonStyle(.borderless).font(.caption)
                    }.padding(.vertical, 8)
                }
            }
            if let cloud {
                Button("Re-recognize with OpenAI…", systemImage: "cloud") {
                    review.stopAutomatic()
                    if let context = review.context { cloud.request(job: context.job, document: document, segmentID: segment.id) }
                }.buttonStyle(.borderless).font(.caption)
                    .disabled(unavailable || cloud.blocked || cloud.busy || cloud.preparing || cloud.pending != nil || document.source == nil)
                    .help("Approve uploading only this channel and time range. Compare the result before applying it.")
                if let result = cloud.result, result.selection.segmentID == segment.id {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Cloud recognition · \(result.reference.model)").font(.caption.weight(.medium))
                        if result.text.isEmpty {
                            Text("The model returned no words. Compare with the audio; original recognition is preserved.").font(.caption)
                        } else {
                            MarkdownReadingText(text: result.text)
                            Button("Use this recognition") { cloud.apply(to: review) }
                                .disabled(unavailable || cloud.busy || cloud.blocked || editing || correction == result.correction)
                        }
                        Button("Reveal cloud response", systemImage: "folder") { NSWorkspace.shared.activateFileViewerSelecting([result.evidence]) }
                            .buttonStyle(.borderless).font(.caption)
                    }.padding(.vertical, 8)
                }
            }
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
