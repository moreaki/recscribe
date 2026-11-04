import AppKit
import Testing
@testable import RecScribe

@MainActor
struct TranscriptInteractionTests {
    @Test func clipboardExportHasConfirmationAndNeverClearsOnEmptyContent() {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        #expect(TranscriptClipboard.copy("# Transcript\n\nWords", format: "Markdown", to: board) == "Copied Markdown")
        #expect(board.string(forType: .string) == "# Transcript\n\nWords")
        #expect(TranscriptClipboard.copy("", format: "plain text", to: board) == nil)
        #expect(board.string(forType: .string) == "# Transcript\n\nWords")
        #expect(TranscriptClipboard.copy("Words", format: "plain text", to: board) == "Copied plain text")
        #expect(board.string(forType: .string) == "Words")
    }
    @Test func completedLiveTimestampsSeekWhileRecordingAndUnknownIntervalsRemainSafe() {
        let segment = LiveSegment(id: UUID(), startSeconds: 12, endSeconds: 14, channel: 0, language: nil, text: "Synthetic")
        #expect(segment.seekTarget(recording: true, sourceAvailable: true) == nil)
        #expect(segment.seekTarget(recording: false, sourceAvailable: false) == nil)
        #expect(segment.seekTarget(recording: false, sourceAvailable: true) == 12)
        #expect(segment.containsPlayback(13) && !segment.containsPlayback(14))
        let point = LiveSegment(id: UUID(), startSeconds: 12, endSeconds: 12, channel: 0, language: nil, text: "Untimed", timingIssue: .missingDuration)
        #expect(point.seekTarget(recording: false, sourceAvailable: true) == 12)
        #expect(!point.containsPlayback(12))
        let invalid = LiveSegment(id: UUID(), startSeconds: .nan, endSeconds: 14, channel: 0, language: nil, text: "Invalid")
        #expect(invalid.seekTarget(recording: false, sourceAvailable: true) == nil)
    }
}
