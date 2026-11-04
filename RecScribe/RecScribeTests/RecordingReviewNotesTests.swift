import Foundation
import Testing
@testable import RecScribe

struct RecordingReviewNotesTests {
    private func session() -> RecordingSession {
        RecordingSession(sampleRate: 48_000, channels: 2, channelMap: ["L", "R"], options: .init())
    }

    @Test func repeatedCoverageWarningsUseRecordedDeviceNameAndRetainEveryOriginal() {
        var session = session()
        let role = CaptureTrack.input("synthetic-mic")
        session.sourceTracks = [.init(role: role, name: "Desk microphone")]
        session.issues = [
            "A selected source stopped delivering data; review source coverage and silence in the mix.",
            "Selected \(role.rawValue) source delivered no data; coverage is incomplete.",
            "Recording saved with incomplete coverage: a selected source delivered no audio data. Review the preserved source tracks.",
            "\(role.rawValue) source: Selected \(role.rawValue) source has no saved audio"
        ]
        let notes = RecordingReviewNotes(session: session)
        #expect(notes.messages.count == 1)
        #expect(notes.messages[0].contains("Desk microphone"))
        #expect(!notes.messages[0].contains(role.rawValue))
        #expect(notes.originalMessages == session.issues)
        #expect(session.issues.count == 4)
    }

    @Test func unknownAndSpecificQualityFailuresStayVisibleWithLegacyNameFallback() {
        var session = session()
        let role = CaptureTrack.input("unidentified-device")
        let failure = "\(role.rawValue) source: Unsupported channel layout"
        session.issues = [failure, "Clipped 120 samples in mix", failure,
            "The recording has clipping, timing gaps or incomplete source coverage. Review the preserved source tracks and mix."]
        let notes = RecordingReviewNotes(session: session)
        #expect(notes.messages.contains("unidentified audio input source: Unsupported channel layout"))
        #expect(notes.messages.contains("Clipped 120 samples in mix"))
        #expect(notes.messages.contains("Check this recording for distortion, timing gaps or missing source audio."))
        #expect(notes.messages.count == 3)
        #expect(notes.originalMessages == session.issues)
    }

    @Test func emptyNotesAndRecordedFallbackNamesDoNotInventADeviceIdentity() {
        var session = session()
        #expect(RecordingReviewNotes(session: session).messages.isEmpty)
        let role = CaptureTrack.input("synthetic-device")
        session.sourceTracks = [.init(role: role, name: "Selected \(role.rawValue)")]
        session.issues = ["Selected \(role.rawValue) source delivered no data; coverage is incomplete."]
        let notes = RecordingReviewNotes(session: session)
        #expect(notes.messages[0].contains("Audio source 1"))
        #expect(!notes.messages[0].contains(role.rawValue))
        #expect(notes.originalMessages == session.issues)
    }
}
