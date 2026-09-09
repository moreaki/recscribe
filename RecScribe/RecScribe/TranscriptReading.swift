import Foundation
import RecScribeCore

/// A lossless display projection, never a rewrite of canonical evidence.
nonisolated enum TranscriptReading {
    // A high overlap groups simultaneous channel alternatives, not speaker identities.
    static let minimumOverlap = 0.8

    struct Group: Identifiable {
        var segments: [TranscriptPreview.Segment]
        var id: String { segments[0].id }
        var channels: String {
            let values = Set(segments.compactMap(\.channel)).sorted().map { String($0 + 1) }
            return values.isEmpty ? "Channel unknown" : "Channel " + values.joined(separator: " + ")
        }
        var timing: String {
            guard let start = segments.compactMap(\.startMs).min(), let end = segments.compactMap(\.endMs).max() else { return "Time unavailable" }
            return "\(time(start)) – \(time(end))"
        }
        /// Equal cleaned text must not hide conflicting raw ASR or different timing.
        func isShared(in document: TranscriptPreview) -> Bool {
            let first = segments[0]
            return segments.allSatisfy {
                $0.startMs == first.startMs && $0.endMs == first.endMs && $0.sourceText == first.sourceText
                    && document.displayedText($0) == document.displayedText(first)
            }
        }
    }

    static func time(_ milliseconds: Int64) -> String {
        TranscriptRenderer.timestamp(milliseconds)
    }

    static func groups(_ segments: [TranscriptPreview.Segment]) -> [Group] {
        var groups: [Group] = []
        // Keep original order for documents without timing (older preview fixtures).
        for segment in segments {
            if let index = groups.indices.last, matches(segment, groups[index]) {
                groups[index].segments.append(segment)
            } else { groups.append(Group(segments: [segment])) }
        }
        return groups
    }

    private static func matches(_ segment: TranscriptPreview.Segment, _ group: Group) -> Bool {
        guard let channel = segment.channel, let start = segment.startMs, let end = segment.endMs,
              start >= 0, end > start, !group.segments.contains(where: { $0.channel == channel }) else { return false }
        // Require overlap with every member, preventing a chain of unrelated intervals.
        return group.segments.allSatisfy {
            guard $0.channel != nil, let otherStart = $0.startMs, let otherEnd = $0.endMs,
                  otherStart >= 0, otherEnd > otherStart else { return false }
            let overlap = max(0, min(end, otherEnd) - max(start, otherStart))
            return Double(overlap) / Double(max(end - start, otherEnd - otherStart)) >= minimumOverlap
        }
    }
}
