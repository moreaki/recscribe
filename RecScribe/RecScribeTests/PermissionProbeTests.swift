import AppKit
import Foundation
import Testing
@testable import RecScribe

@MainActor private final class ProbeResponse {
    var status = PermissionStatus.denied
    var calls = 0
    var waiting: CheckedContinuation<PermissionStatus, Never>?
}

@MainActor private final class AdvancingPollClock: PollClock {
    private var pending: [AsyncStream<Void>.Continuation] = []
    private(set) var sleeps = 0
    func sleep(for interval: TimeInterval) async throws {
        let (events, signal) = AsyncStream<Void>.makeStream()
        pending.append(signal)
        sleeps += 1
        for await _ in events { break }
        try Task.checkCancellation()
    }
    func advance() {
        let sleepers = pending
        pending.removeAll()
        for sleeper in sleepers { sleeper.yield(()); sleeper.finish() }
    }
    deinit { for sleeper in pending { sleeper.finish() } }
}

@MainActor struct PermissionProbeTests {
    @Test func systemRequestResultIsCachedUntilTheNextDeliberateRequest() async {
        let state = ProbeResponse()
        let manager = PermissionManager(screenCaptureProbe: { state.calls += 1; return state.status })
        for _ in 0..<100 { #expect(await manager.checkPermission() == .denied) }
        state.status = .granted
        #expect(await manager.checkPermission() == .denied && state.calls == 1)
        #expect(await manager.requestPermission())
        for _ in 0..<100 { #expect(await manager.checkPermission() == .granted) }
        #expect(state.calls == 2)
    }
    @Test func simultaneousPassiveAndDeliberateCallersShareThePendingSystemProbe() async throws {
        let state = ProbeResponse()
        let manager = PermissionManager(screenCaptureProbe: {
            state.calls += 1
            return await withCheckedContinuation { state.waiting = $0 }
        })
        let a = Task { await manager.checkPermission() }
        await waitUntil("one real permission probe") { state.waiting != nil }
        let b = Task { await manager.checkPermission() }
        let c = Task { await manager.requestPermission() }
        await settle()
        #expect(state.calls == 1)
        let response = try #require(state.waiting)
        state.waiting = nil
        response.resume(returning: .denied)
        let first = await a.value
        let second = await b.value
        let requested = await c.value
        #expect(first == .denied && second == .denied && requested == false)
        #expect(await manager.checkPermission() == .denied && state.calls == 1)
    }
    @Test(arguments: [false, true])
    func launchAndUnsolicitedActivationNeverIssuePromptingRequests(granted: Bool) async {
        let h = RecorderContractHarness(permission: granted ? .granted : .denied)
        defer { h.cleanup() }
        #expect(h.permissions.preflightCount == 1 && h.permissions.checkCount == 0)
        h.notifications.post(name: NSApplication.didBecomeActiveNotification, object: nil)
        await settle()
        #expect(h.permissions.checkCount == 0)
        #expect(h.model.permissionStatus == (granted ? .granted : .denied))
        #expect(!h.model.grantWatcherIsPolling)
        if granted {
            h.model.permissionCoordinator.markPermissionSought()
            h.notifications.post(name: NSApplication.didBecomeActiveNotification, object: nil)
            await settle()
            #expect(h.permissions.checkCount == 0)
        }
    }
    @Test func activationCanObserveAGrantAfterTheUserHasRequestedAccess() async {
        let h = RecorderContractHarness(permission: .denied)
        defer { h.cleanup() }
        h.model.permissionCoordinator.markPermissionSought()
        h.permissions.status = .granted
        h.notifications.post(name: NSApplication.didBecomeActiveNotification, object: nil)
        await waitUntil("activation grant observation") { h.model.permissionStatus == .granted }
        #expect(h.permissions.checkCount >= 1 && h.permissions.preflightCount == 1)
        #expect(h.permissions.requestedPermissionKinds.isEmpty)
    }
    @Test func settingsWaitsForRegistrationButHasABoundedDeadline() async {
        for bounded in [false, true] {
            let h = RecorderContractHarness(permission: .denied,
                pollClock: bounded ? ImmediatePollClock() : NeverPollClock(), timeout: bounded ? 0 : 60)
            defer { h.cleanup() }
            h.permissions.holdsChecks = true
            h.model.openSystemSettings()
            await waitUntil("registration request") { h.permissions.checkCount > 0 }
            if bounded {
                await waitUntil("registration deadline") { h.permissions.openSettingsCount == 1 }
            } else {
                await settle()
                #expect(h.permissions.openSettingsCount == 0 && h.model.isOpeningSystemSettings)
            }
            h.permissions.holdsChecks = false
            h.permissions.resumePendingChecks()
            await waitUntil("Settings after registration") { h.permissions.openSettingsCount == 1 }
            #expect(!h.model.isOpeningSystemSettings)
        }
    }
    @Test func anAlreadyGrantedRequestNeverOpensSettings() async {
        let h = RecorderContractHarness(pollClock: ImmediatePollClock(), timeout: 0)
        defer { h.cleanup() }
        h.model.openSystemSettings()
        await waitUntil("already-granted request completion") { !h.model.isOpeningSystemSettings }
        #expect(h.permissions.openSettingsCount == 0 && h.model.permissionStatus == .granted)
    }
    @Test func backgroundGrantIsObservedWithoutAnActivationNotification() async {
        let time = AdvancingPollClock()
        let h = RecorderContractHarness(permission: .denied, pollClock: time, timeout: 0)
        defer { h.cleanup() }
        h.model.openSystemSettings()
        await waitUntil("watcher sleep") { time.sleeps > 0 && h.permissions.checkCount > 0 }
        h.permissions.status = .granted
        time.advance()
        await waitUntil("grant without activation") { h.model.permissionStatus == .granted }
        // The independent registration probe can publish the grant before the watcher finishes.
        await waitUntil("grant watcher completion") { !h.model.grantWatcherIsPolling }
        #expect(!h.model.grantWatcherIsPolling)
    }
    @Test func aFreshObservedGrantSurvivesAnOlderHeldDenial() async {
        let h = RecorderContractHarness(permission: .denied, pollClock: ImmediatePollClock(), timeout: 0)
        defer { h.cleanup() }
        h.permissions.holdsChecks = true
        h.permissions.answersWithStatusAtIssue = true
        let old = Task { await h.model.checkPermission() }
        await waitUntil("held old denial") { h.permissions.checkCount == 1 }
        h.permissions.status = .granted
        h.permissions.holdsChecks = false
        h.model.openSystemSettings()
        await waitUntil("watcher observed the newer grant") { h.model.permissionStatus == .granted }
        h.permissions.resumePendingChecks()
        await old.value
        #expect(h.model.permissionStatus == .granted)
        #expect(h.permissions.openSettingsCount == 0)
    }
    @Test func overlappingCoordinatorChecksDoNotDuplicateTheProviderRequest() async {
        let h = RecorderContractHarness(permission: .denied)
        defer { h.cleanup() }
        h.permissions.holdsChecks = true
        let first = Task { await h.model.checkPermission() }
        await waitUntil("coordinator probe") { h.permissions.checkCount == 1 }
        let second = Task { await h.model.checkPermission() }
        await settle()
        #expect(h.permissions.checkCount == 1)
        h.permissions.status = .granted
        h.permissions.holdsChecks = false
        h.permissions.resumePendingChecks()
        await first.value
        await second.value
        #expect(h.model.permissionStatus == .granted)
    }
}
