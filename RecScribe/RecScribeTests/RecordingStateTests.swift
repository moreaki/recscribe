import Testing
@testable import RecScribe

struct RecordingStateTests {
    @Test func fullTransitionContractAndSourceLock() {
        let phases: [RecordingState] = [.idle, .starting, .recording, .stopping, .error(.diskFull), .recovering]
        // Each row is an independent specification, indexed by the destination.
        let allowed = ["010000", "101010", "000111", "100010", "110000", "001110"]
        for row in phases.indices {
            for column in phases.indices {
                let truth = Array(allowed[row])[column] == "1"
                #expect(phases[row].canTransition(to: phases[column]) == truth)
            }
            #expect(phases[row].allowsCaptureSourceChange == (row == 0 || row == 4))
        }
    }
    @Test func technicalFailuresStayOutOfMessagesAndRecoveryIsSpecific() {
        let failures: [RecorderError] = [.startFailed("PRIVATE_DEBUG_DETAIL"), .stopFailed("PRIVATE_DEBUG_DETAIL"),
                                        .streamFailed("PRIVATE_DEBUG_DETAIL"), .captureStopFailed("PRIVATE_DEBUG_DETAIL")]
        for failure in failures {
            #expect(failure.detail == "PRIVATE_DEBUG_DETAIL")
            #expect(!failure.message.contains("PRIVATE_DEBUG_DETAIL"))
            #expect(!failure.message.isEmpty)
        }
        #expect(failures[0].recovery == .tryAgain)
        #expect(failures.dropFirst().allSatisfy { $0.recovery == nil })
        #expect(RecorderError.microphoneDenied.recovery == .openMicrophoneSettings)
        #expect(RecorderError.saveLocationUnavailable.recovery == .chooseFolder)
        #expect(RecorderError.diskFull.recovery == nil)
        #expect(RecoverySuggestion.openSettings.label == "Open settings")
        #expect(RecoverySuggestion.tryAgain.label == "Try again")
    }
}
