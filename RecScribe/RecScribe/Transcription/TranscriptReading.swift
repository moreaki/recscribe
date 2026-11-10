import CryptoKit
import Foundation
import RecScribeCore

/// A lossless display projection, never a rewrite of canonical evidence.
nonisolated enum TranscriptReading {
    // A high overlap groups simultaneous channel alternatives, not speaker identities.
    static let minimumOverlap = 0.8

    struct SummarySource: Identifiable, Sendable {
        let id: String
        let groupID: String?
        let timing: String?
        let channels: String?
    }

    /// Resolve only exact, unambiguous citations supplied by the summary. Missing
    /// references remain visible; displaying a summary never invents evidence.
    static func summarySources(in document: TranscriptPreview) -> [[SummarySource]] {
        let candidates = document.readingGroups.flatMap { group in
            group.segments.map { (segment: $0, groupID: group.id) }
        }
        let byID = Dictionary(grouping: candidates, by: { $0.segment.id })
        return (document.summary?.notes ?? []).map { note in
            var seen = Set<String>()
            return note.segmentIds.filter { seen.insert($0).inserted }.map { id in
                guard let matches = byID[id], matches.count == 1, let match = matches.first else {
                    return SummarySource(id: id, groupID: nil, timing: nil, channels: nil)
                }
                let single = Group(segments: [match.segment])
                return SummarySource(id: id, groupID: match.groupID, timing: single.timing, channels: single.channels)
            }
        }
    }

    struct ReviewItem: Identifiable, Sendable {
        let id: String
        let groupID: String?
        let title: String
        let reasons: [String]
        let key: String

        init(id: String, groupID: String?, title: String, reasons: [String], segmentIDs: [String] = []) {
            self.id = id; self.groupID = groupID; self.title = title; self.reasons = reasons
            let fields = [groupID == nil ? "document" : "passage", "reasons:\(reasons.count)"]
                + reasons.sorted() + ["segments:\(segmentIDs.count)"] + segmentIDs.sorted()
            let scoped = fields.map { "\($0.utf8.count):\($0)" }.joined()
            key = SHA256.hash(data: Data(scoped.utf8)).map { String(format: "%02x", $0) }.joined()
        }
    }

    /// Reading and All channels share the same passage-scoped review task.
    static func reviewGroupID(for segmentID: String, in document: TranscriptPreview) -> String? {
        document.readingGroups.first { $0.segments.contains { $0.id == segmentID } }?.id
    }

    /// Scoped reading projection: global notes and passage notes remain distinct.
    /// Opening this list never acknowledges a warning or changes canonical data.
    static func reviewItems(in document: TranscriptPreview) -> [ReviewItem] {
        var items = Array(Set(document.reviewReasons)).sorted().enumerated().map { index, reason in
            ReviewItem(id: "document-\(index)", groupID: nil, title: reviewTitle(reason), reasons: [reason])
        }
        for group in document.readingGroups {
            var reasons = Set(group.segments.flatMap { $0.reviewReasons ?? [] })
            if group.segments.contains(where: \.needsReview), reasons.isEmpty { reasons.insert("verify_against_audio") }
            if !group.isShared(in: document, originalRecognition: true) { reasons.insert("overlapping_channel_variants") }
            if !reasons.isEmpty {
                items.append(ReviewItem(id: "passage-\(group.id)", groupID: group.id,
                    title: "\(group.timing) · \(group.channels)", reasons: reasons.sorted(), segmentIDs: group.segments.map(\.id)))
            }
        }
        return items
    }

    private static func reviewTitle(_ reason: String) -> String {
        switch reason {
        case "confidence_unavailable": "Confidence information"
        case "low_confidence": "Uncertain recognition"
        case "translate_processor_not_configured": "Translation not applied"
        case "normalize_processor_not_configured": "Text cleanup not applied"
        case "engine_pass_disagreement": "Recognition disagreement"
        case "source_contains_clipping": "Source clipping"
        case "ai_derived_text_unverified": "AI edited text"
        case "ai_summary_unverified": "Summary verification"
        default: "Additional processing note"
        }
    }

    static func reviewLabel(_ reason: String) -> String {
        switch reason {
        case "confidence_unavailable": "Confidence was not supplied by this speech model. Verify against the audio."
        case "low_confidence": "The speech model is uncertain about these words."
        case "translate_processor_not_configured": "Translation has not been applied. Original speech is shown."
        case "normalize_processor_not_configured": "Text cleanup has not been applied. Original speech is shown."
        case "verify_against_audio": "Listen to this passage and verify the words."
        case "overlapping_channel_variants": "Overlapping sources have different text or timing. Compare the originals."
        case "engine_pass_disagreement": "Recognition passes disagree. Compare with the audio."
        case "source_contains_clipping": "The source contains clipping. Some words may be distorted."
        case "ai_derived_text_unverified": "AI edited text needs checking against the original."
        case "ai_summary_unverified": "Check the summary against its source passages."
        default: "Additional processing note. See technical details for the original message."
        }
    }

    struct Group: Identifiable, Sendable, Equatable {
        let segments: [TranscriptPreview.Segment]
        let id: String
        let channels: String
        let timing: String
        let startMs: Int64?
        let endMs: Int64?
        let startSeconds: Double?

        init(segments: [TranscriptPreview.Segment]) {
            self.segments = segments
            self.id = segments[0].id
            let values = Set(segments.compactMap(\.channel)).sorted().map { String($0 + 1) }
            self.channels = values.isEmpty ? "Channel unknown" : "Channel " + values.joined(separator: " + ")
            let computedStart = segments.compactMap(\.startMs).min()
            let computedEnd = segments.compactMap(\.endMs).max()
            self.startMs = computedStart
            self.endMs = computedEnd
            if let start = computedStart, let end = computedEnd {
                self.timing = "\(TranscriptReading.time(start)) – \(TranscriptReading.time(end))"
            } else {
                self.timing = "Time unavailable"
            }
            self.startSeconds = computedStart.map { Double($0) / 1_000.0 }
        }

        func contains(milliseconds: Int64) -> Bool {
            guard let start = startMs, let end = endMs, end >= start else { return false }
            return milliseconds >= start && milliseconds <= end
        }

        func contains(positionSeconds: Double) -> Bool {
            guard positionSeconds.isFinite, positionSeconds >= 0 else { return false }
            return contains(milliseconds: Int64((positionSeconds * 1_000.0).rounded()))
        }

        /// Equal cleaned text must not hide conflicting raw ASR or different timing.
        func isShared(in document: TranscriptPreview, originalRecognition: Bool = false) -> Bool {
            if segments.count <= 1 { return true }
            let first = segments[0]
            return segments.allSatisfy {
                $0.startMs == first.startMs && $0.endMs == first.endMs && $0.sourceText == first.sourceText
                    && (originalRecognition ? document.originalDisplayedText($0) == document.originalDisplayedText(first)
                        : document.displayedText($0) == document.displayedText(first))
            }
        }
    }

    static func time(_ milliseconds: Int64) -> String {
        TranscriptRenderer.timestamp(milliseconds)
    }

    static func activeGroupID(in groups: [Group], positionSeconds: Double?) -> String? {
        guard let positionSeconds, positionSeconds.isFinite, positionSeconds >= 0 else { return nil }
        let ms = Int64((positionSeconds * 1_000.0).rounded())
        return groups.first(where: { $0.contains(milliseconds: ms) })?.id
    }

    static func groups(_ segments: [TranscriptPreview.Segment]) -> [Group] {
        var bucketed: [[TranscriptPreview.Segment]] = []
        // Keep original order for documents without timing (older preview fixtures).
        for segment in segments {
            if let index = bucketed.indices.last, matches(segment, bucketed[index]) {
                bucketed[index].append(segment)
            } else {
                bucketed.append([segment])
            }
        }
        return bucketed.map(Group.init(segments:))
    }

    private static func matches(_ segment: TranscriptPreview.Segment, _ members: [TranscriptPreview.Segment]) -> Bool {
        guard let channel = segment.channel, let start = segment.startMs, let end = segment.endMs,
              start >= 0, end > start, !members.contains(where: { $0.channel == channel }) else { return false }
        // Require overlap with every member, preventing a chain of unrelated intervals.
        return members.allSatisfy {
            guard $0.channel != nil, let otherStart = $0.startMs, let otherEnd = $0.endMs,
                  otherStart >= 0, otherEnd > otherStart else { return false }
            let overlap = max(0, min(end, otherEnd) - max(start, otherStart))
            return Double(overlap) / Double(max(end - start, otherEnd - otherStart)) >= minimumOverlap
        }
    }
}
