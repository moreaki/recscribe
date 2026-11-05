import AppKit
import Foundation
import SwiftUI
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
    @Test func summaryCitationsResolveExactOriginalSourcesAndFailClosedForAmbiguousIDs() throws {
        let segments = [ReadingFixtures.segment("s1", "Monday"),
                        ReadingFixtures.segment("s2", "Tuesday", channel: 1, start: 20, end: 2020),
                        ReadingFixtures.segment("ambiguous", "One", start: 5000, end: 6000),
                        ReadingFixtures.segment("ambiguous", "Two", start: 8000, end: 9000)]
        let data = try JSONSerialization.data(withJSONObject: ["schema_version": "1.0",
            "processing": ["mode": "verbatim"], "segments": segments, "review_reasons": [],
            "summary": ["notes": [["text": "A date needs checking.",
                                     "segment_ids": ["s2", "s1", "s2", "missing", "ambiguous"]],
                                    ["text": "No references provided.", "segment_ids": []]]]])
        let decoder = JSONDecoder(); decoder.keyDecodingStrategy = .convertFromSnakeCase
        let document = try decoder.decode(TranscriptPreview.self, from: data)
        let before = document.exportText(for: .summary, markdown: true)
        let sources = TranscriptReading.summarySources(in: document)
        #expect(sources.count == 2)
        #expect(sources[0].map(\.id) == ["s2", "s1", "missing", "ambiguous"])
        #expect(sources[0][0].groupID == "s1")
        #expect(sources[0][0].channels == "Channel 2")
        #expect(sources[0][0].timing == "00:00:00.020 – 00:00:02.020")
        #expect(sources[0][1].timing == "00:00:00.000 – 00:00:02.000")
        #expect(sources[0][2].groupID == nil)
        #expect(sources[0][3].groupID == nil)
        #expect(sources[1].isEmpty)
        #expect(document.exportText(for: .summary, markdown: true) == before)
        #expect(document.summary?.notes[0].segmentIds == ["s2", "s1", "s2", "missing", "ambiguous"])
        #expect(TranscriptReading.reviewLabel("unknown_engine_message") == "Additional processing note. See technical details for the original message.")
    }

    @Test func reviewInspectorIncludesGlobalPassageFlagsAndOverlapWithoutChangingEvidence() throws {
        var first = ReadingFixtures.segment("s1", "Monday")
        first["review_reasons"] = ["confidence_unavailable", "confidence_unavailable"]
        var second = ReadingFixtures.segment("s2", "Tuesday", channel: 1)
        second["needs_review"] = false
        second["review_reasons"] = []
        var flagged = ReadingFixtures.segment("s3", "Check this", start: 3000, end: 5000)
        flagged["review_reasons"] = [] // Legacy flag without reasons must remain visible.
        let data = try JSONSerialization.data(withJSONObject: ["schema_version": "1.0",
            "processing": ["mode": "verbatim"], "segments": [first, second, flagged],
            "review_reasons": ["confidence_unavailable", "confidence_unavailable"]])
        let decoder = JSONDecoder(); decoder.keyDecodingStrategy = .convertFromSnakeCase
        let document = try decoder.decode(TranscriptPreview.self, from: data)
        let before = document.exportText(for: .transcript, markdown: true)
        let items = TranscriptReading.reviewItems(in: document)
        #expect(items.count == 3)
        #expect(items[0].groupID == nil)
        #expect(items[0].reasons == ["confidence_unavailable"])
        #expect(items[1].groupID == "s1")
        #expect(items[1].reasons == ["confidence_unavailable", "overlapping_channel_variants"])
        #expect(items[2].groupID == "s3")
        #expect(items[2].reasons == ["verify_against_audio"])
        #expect(Set(items.map(\.id)).count == items.count)
        #expect(document.segments[0].reviewReasons?.count == 2)
        #expect(document.exportText(for: .transcript, markdown: true) == before)
    }

    @Test func overlapWithoutAnyExplicitReviewFlagStillAppearsInInspector() throws {
        var first = ReadingFixtures.segment("s1", "Monday")
        var second = ReadingFixtures.segment("s2", "Tuesday", channel: 1)
        first["needs_review"] = false; first["review_reasons"] = []
        second["needs_review"] = false; second["review_reasons"] = []
        let document = try ReadingFixtures.document([first, second])
        #expect(TranscriptReading.reviewItems(in: document).first?.reasons == ["overlapping_channel_variants"])
        let primaryGroup = TranscriptReading.reviewGroupID(for: "s1", in: document)
        let alternateGroup = TranscriptReading.reviewGroupID(for: "s2", in: document)
        #expect(primaryGroup == "s1" && alternateGroup == primaryGroup)
        #expect(TranscriptReading.reviewItems(in: document).first?.groupID == alternateGroup)
        #expect(TranscriptReading.reviewGroupID(for: "missing", in: document) == nil)
    }

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

    @Test func interactiveTimestampSeekMappingAndMarkdownPlainTextExport() throws {
        let document = try ReadingFixtures.preview
        let groups = TranscriptReading.groups(document.segments)
        #expect(groups.count == 3)
        #expect(groups[0].startMs == 0)
        #expect(groups[0].endMs == 2000)
        #expect(groups[0].startSeconds == 0.0)
        #expect(groups[0].contains(positionSeconds: 1.25))
        #expect(!groups[0].contains(positionSeconds: 2.5))
        #expect(groups[1].startSeconds == 3.0)
        #expect(groups[1].contains(positionSeconds: 4.0))
        #expect(groups[2].startSeconds == 6.0)

        let markdown = document.exportText(for: .transcript, markdown: true)
        #expect(markdown.contains("# Transcript"))
        #expect(markdown.contains("## 00:00:00.000 – 00:00:02.000 (Channel 1 + 2 · [Review])"))
        #expect(markdown.contains("We will meet on Monday to review the recording."))
        #expect(markdown.contains("- **Channel 1** (00:00:03.000 – 00:00:05.000): The delivery is on Tuesday."))
        #expect(markdown.contains("- **Channel 2** (00:00:03.050 – 00:00:05.050): The delivery is on Thursday."))

        let plain = document.exportText(for: .transcript, markdown: false)
        #expect(plain.contains("[Review] We will meet on Monday to review the recording."))
        #expect(plain.contains("[Review] The delivery is on Tuesday."))
    }

    @Test("Long-transcript navigation, 10 Hz playback follow, seek, and cached projection/export regression (#44)")
    @MainActor
    func longTranscriptNavigationSeekAndCachedExportsRegression() throws {
        var rawSegments: [[String: Any]] = []
        rawSegments.reserveCapacity(1_200)
        for groupIndex in 0..<600 {
            let startMs = groupIndex * 6_000
            let endMs = startMs + 5_000
            let text = "Segment \(groupIndex) discussion on architecture and audio synchronization."
            let id0 = String(format: "s-%04d", groupIndex * 2)
            let id1 = String(format: "s-%04d", groupIndex * 2 + 1)
            rawSegments.append(ReadingFixtures.segment(id0, text, channel: 0, start: startMs, end: endMs))
            rawSegments.append(ReadingFixtures.segment(id1, text, channel: 1, start: startMs, end: endMs))
        }
        let document = try ReadingFixtures.document(rawSegments)
        #expect(document.readingGroups.count == 600)
        #expect(document.channelGroups.count == 1_200)

        let playback = SessionPlayback(coordinator: SessionPlaybackCoordinator())
        var seekedTimestamps: [Double] = []
        let readingView = TranscriptReadingView(
            document: document,
            mode: .reading,
            playback: playback,
            onSeek: { seekedTimestamps.append($0) }
        )

        // Idle playback at 0.0 with no loaded player does not highlight any row
        #expect(readingView.effectivePositionSeconds == nil)
        #expect(readingView.activeGroupID == nil)

        // Explicit playbackPosition override highlights group 0 at 0.25s even before player creation
        let explicitZeroView = TranscriptReadingView(
            document: document,
            mode: .reading,
            playback: playback,
            playbackPosition: 0.25
        )
        #expect(explicitZeroView.activeGroupID == "s-0000")

        // Seeking playback to midpoint (group 300: 1,800.0s ..< 1,805.0s) updates activeGroupID directly
        playback.seek(to: 1_800.5)
        #expect(readingView.effectivePositionSeconds == 1_800.5)
        #expect(readingView.activeGroupID == "s-0600")
        #expect(readingView.displayedGroups[300].startSeconds == 1_800.0)

        // Seeking to final group (group 599: 3,594.0s ..< 3,599.0s)
        playback.seek(to: 3_596.2)
        #expect(readingView.activeGroupID == "s-1198")

        // Seeking into an inter-group gap (1,805.5s is between group 300 and group 301) clears highlight
        playback.seek(to: 1_805.5)
        #expect(readingView.activeGroupID == nil)

        // Channel mode uses cached 1,200 channel groups and resolves the matching channel group ID
        let channelView = TranscriptReadingView(
            document: document,
            mode: .channels,
            playback: playback
        )
        #expect(channelView.displayedGroups.count == 1_200)
        playback.seek(to: 3_594.0)
        #expect(channelView.activeGroupID == "s-1198")

        // Simulate 200 ticks at 10 Hz across groups 0...3 alongside export reads
        let cachedMarkdown = document.exportText(for: .transcript, markdown: true)
        let cachedPlain = document.exportText(for: .transcript, markdown: false)
        var observedTransitions: [String?] = []
        for tick in 0..<200 {
            let seconds = Double(tick) * 0.1
            playback.seek(to: seconds)
            let id = readingView.activeGroupID
            if observedTransitions.last != id {
                observedTransitions.append(id)
            }
            #expect(document.exportText(for: .transcript, markdown: true) == cachedMarkdown)
            #expect(document.exportText(for: .transcript, markdown: false) == cachedPlain)
        }
        #expect(observedTransitions == [nil, "s-0000", nil, "s-0002", nil, "s-0004", nil, "s-0006"])

        // Host in NSHostingView and verify layout across seeks in a long transcript
        let host = NSHostingView(rootView: readingView)
        host.frame = NSRect(x: 0, y: 0, width: 760, height: 600)
        host.layoutSubtreeIfNeeded()
        playback.seek(to: 600.0)
        host.layoutSubtreeIfNeeded()
        #expect(readingView.activeGroupID == "s-0200")
        playback.seek(to: 3_000.0)
        host.layoutSubtreeIfNeeded()
        #expect(readingView.activeGroupID == "s-1000")
    }
}
