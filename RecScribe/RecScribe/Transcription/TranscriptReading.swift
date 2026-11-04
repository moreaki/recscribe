import Foundation
import RecScribeCore

/// A lossless display projection, never a rewrite of canonical evidence.
nonisolated enum TranscriptReading {
    // A high overlap groups simultaneous channel alternatives, not speaker identities.
    static let minimumOverlap = 0.8

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
        func isShared(in document: TranscriptPreview) -> Bool {
            if segments.count <= 1 { return true }
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
