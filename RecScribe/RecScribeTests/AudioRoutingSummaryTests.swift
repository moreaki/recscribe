import Testing
@testable import RecScribe

struct AudioRoutingSummaryTests {
    @Test func routingSummaryDescribesContributionsRatherThanNativeChannelCount() {
        var input = InputSelection(deviceUID: "interface", routes: [
            .init(channel: 0, placement: .left), .init(channel: 7, placement: .right)
        ])
        #expect(AudioRoutingSummary.routes(input, channelCount: 8) == "2 channels → L + R")
        // After a format change, a formerly selected native channel may be gone.
        #expect(AudioRoutingSummary.routes(input, channelCount: 2) == "1 channel → Left only")
        input.routes = [.init(channel: 0, placement: .center)]
        #expect(AudioRoutingSummary.routes(input, channelCount: 1) == "1 channel → L + R")
        input.routes = [.init(channel: 0, placement: .right)]
        #expect(AudioRoutingSummary.routes(input, channelCount: 1) == "1 channel → Right only")
        input.routes = []
        #expect(AudioRoutingSummary.routes(input, channelCount: 8) == "Not connected to mix · original track retained")
    }

    @Test func lostOutputShowsActualFallbackWithoutDiscardingExplicitSelection() {
        let outputs = [AudioOutputDevice(uid: "speakers", name: "Display speakers"),
                       AudioOutputDevice(uid: "headphones", name: "USB headphones")]
        var level = ListeningLevel(outputUID: "headphones")
        #expect(AudioRoutingSummary.output(level, devices: outputs, systemUID: "speakers") == "USB headphones")
        #expect(AudioRoutingSummary.output(level, devices: [outputs[0]], systemUID: "speakers") == "Output unavailable · using Display speakers")
        #expect(level.outputUID == "headphones")
        level.outputUID = nil
        #expect(AudioRoutingSummary.output(level, devices: outputs, systemUID: "speakers") == "System · Display speakers")
    }
}
