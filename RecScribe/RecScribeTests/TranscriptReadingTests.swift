import Foundation
import Testing
@testable import RecScribe

enum ReadingFixtures {
    static func segment(_ id: String, _ text: String, channel: Int = 0, start: Int = 0, end: Int = 2000) -> [String: Any] {
        ["id": id, "source_text": text, "needs_review": true, "review_reasons": ["verify_against_audio"],
         "channel": channel, "start_ms": start, "end_ms": end]
    }
    static func document(_ segments: [[String: Any]], mode: String = "verbatim") throws -> TranscriptPreview {
        let data = try JSONSerialization.data(withJSONObject: ["schema_version": "1.0", "processing": ["mode": mode],
                                                               "segments": segments, "review_reasons": []])
        let decoder = JSONDecoder(); decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(TranscriptPreview.self, from: data)
    }
    static var preview: TranscriptPreview {
        get throws {
            try document([
                segment("s1", "We will meet on Monday to review the recording."),
                segment("s2", "We will meet on Monday to review the recording.", channel: 1),
                segment("s3", "The delivery is on Tuesday.", start: 3000, end: 5000),
                segment("s4", "The delivery is on Thursday.", channel: 1, start: 3050, end: 5050),
                segment("s5", "Please verify the date against the original audio.", start: 6000, end: 8000)
            ])
        }
    }
}

struct TranscriptReadingTests {
    @Test func exactCrossChannelDuplicatesShareOneReadingAndKeepEverySource() throws {
        let document = try ReadingFixtures.preview
        let groups = TranscriptReading.groups(document.segments)
        #expect(groups.count == 3)
        #expect(groups[0].isShared(in: document))
        #expect(groups[0].channels == "Channel 1 + 2")
        #expect(TranscriptReading.time(3050) == "00:00:03.050")
        #expect(groups[0].segments.map(\.id) == ["s1", "s2"])
        #expect(!groups[1].isShared(in: document))
        #expect(groups.flatMap(\.segments).map(\.id) == document.segments.map(\.id))
        #expect(groups[0].segments.allSatisfy { $0.reviewReasons == ["verify_against_audio"] })
    }

    @Test func repeatsOnSameChannelAndDifferentTimesAreNeverSuppressed() throws {
        let document = try ReadingFixtures.document([
            ReadingFixtures.segment("s1", "Yes"), ReadingFixtures.segment("s2", "Yes"),
            ReadingFixtures.segment("s3", "Yes", channel: 1, start: 5000, end: 7000)])
        #expect(TranscriptReading.groups(document.segments).count == 3)
    }

    @Test func equalDerivedTextDoesNotHideRawDisagreementOrTimingDifference() throws {
        var a = ReadingFixtures.segment("s1", "Monday"), b = ReadingFixtures.segment("s2", "Tuesday", channel: 1)
        a["normalized_text"] = "A weekday"; b["normalized_text"] = "A weekday"
        let document = try ReadingFixtures.document([a, b], mode: "normalize")
        #expect(!TranscriptReading.groups(document.segments)[0].isShared(in: document))
        b["source_text"] = "Monday"; b["start_ms"] = 100
        let timed = try ReadingFixtures.document([a, b], mode: "normalize")
        #expect(!TranscriptReading.groups(timed.segments)[0].isShared(in: timed))
    }

    @Test func missingMetadataAndWeakOverlapFailClosed() throws {
        var old = ReadingFixtures.segment("s1", "Legacy")
        old.removeValue(forKey: "channel"); old.removeValue(forKey: "start_ms"); old.removeValue(forKey: "end_ms")
        var other = old; other["id"] = "s2"
        #expect(TranscriptReading.groups(try ReadingFixtures.document([old, other]).segments).count == 2)
        let document = try ReadingFixtures.document([
            ReadingFixtures.segment("s1", "One speaker"),
            ReadingFixtures.segment("s2", "Another speaker", channel: 1, start: 1800, end: 4000)])
        #expect(TranscriptReading.groups(document.segments).count == 2)
    }
}
