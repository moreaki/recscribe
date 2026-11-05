import Foundation
import Testing
@testable import RecScribe

@MainActor struct MonitorControllerTests {
    @Test(arguments: MonitoringMode.allCases)
    func monitoringPolicyIsDistinctAndCannotStartCaptureWithoutAnInput(mode: MonitoringMode) throws {
        let identity = "monitor-contract-\(UUID())"
        let storage = try #require(UserDefaults(suiteName: identity))
        defer { storage.removePersistentDomain(forName: identity) }
        let controller = MonitorController(defaults: storage)
        var warnings: [MonitorError] = []
        controller.onWarning = { warnings.append($0) }
        #expect(controller.mode == .off && !controller.isMonitoring)
        controller.setMode(mode)
        let expectedIdle = mode == .always
        #expect(MonitorController.shouldRun(mode: mode, isRecording: false) == expectedIdle)
        #expect(warnings.count == (expectedIdle ? 1 : 0))
        warnings.removeAll()
        controller.recordingStateChanged(isRecording: true)
        #expect(MonitorController.shouldRun(mode: mode, isRecording: true) == (mode != .off))
        #expect(warnings == (mode == .off ? [] : [.deviceUnavailable]))
        #expect(!controller.isMonitoring)
        #expect(MonitorController(defaults: storage).mode == mode)
        warnings.removeAll()
        controller.setMode(.off)
        #expect(!controller.isMonitoring && warnings.isEmpty)
    }
    @Test func unknownStoredModeIsOffAndPolicyCombinationsAreUnique() throws {
        let identity = "monitor-corrupt-\(UUID())"
        let storage = try #require(UserDefaults(suiteName: identity))
        defer { storage.removePersistentDomain(forName: identity) }
        storage.set("unknown", forKey: "monitoringMode")
        #expect(MonitorController(defaults: storage).mode == .off)
        let policies = MonitoringMode.allCases.map { mode in
            [false, true].map { MonitorController.shouldRun(mode: mode, isRecording: $0) }
        }
        #expect(policies.count == 3 && Set(policies).count == 3)
    }
}
