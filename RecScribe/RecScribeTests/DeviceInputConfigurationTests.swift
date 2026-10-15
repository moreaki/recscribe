import Testing
@testable import RecScribe

struct DeviceInputConfigurationTests {
    @Test func runningUnchangedDeviceIgnoresQueuedNotificationsWithoutSpendingRecoveryBudget() {
        var policy = DeviceInputConfigurationPolicy(startedAt: 100)
        for frames: Int64 in [0, 1_024, 96_000] {
            #expect(policy.evaluate(connected: true, sameDevice: true, sameFormat: true,
                running: true, receivedFrames: frames, now: 110) == .ignore)
        }
        #expect(policy.restarts == 0)
    }

    @Test func startupRecoveryIsBoundedAndNeverResumesAfterAudioHasStarted() {
        var policy = DeviceInputConfigurationPolicy(startedAt: 100)
        for now in [100.1, 100.2] {
            #expect(policy.evaluate(connected: true, sameDevice: true, sameFormat: true,
                running: false, receivedFrames: 0, now: now) == .restart)
        }
        #expect(policy.evaluate(connected: true, sameDevice: true, sameFormat: true,
            running: false, receivedFrames: 0, now: 100.3) == .interrupted)
        for (time, frames): (Double, Int64) in [(103.1, 0), (100.1, 1), (99, 0)] {
            var fresh = DeviceInputConfigurationPolicy(startedAt: 100)
            #expect(fresh.evaluate(connected: true, sameDevice: true, sameFormat: true,
                running: false, receivedFrames: frames, now: time) == .interrupted)
            #expect(fresh.restarts == 0)
        }
    }

    @Test func realDisconnectDeviceSubstitutionAndFormatChangeAlwaysFail() {
        for running in [false, true] {
            var policy = DeviceInputConfigurationPolicy(startedAt: 100)
            #expect(policy.evaluate(connected: false, sameDevice: true, sameFormat: true,
                running: running, receivedFrames: 0, now: 100.1) == .disconnected)
            #expect(policy.evaluate(connected: true, sameDevice: false, sameFormat: true,
                running: running, receivedFrames: 0, now: 100.1) == .deviceChanged)
            #expect(policy.evaluate(connected: true, sameDevice: true, sameFormat: false,
                running: running, receivedFrames: 0, now: 100.1) == .formatChanged)
            #expect(policy.restarts == 0)
        }
    }
}
