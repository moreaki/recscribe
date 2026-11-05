import Foundation
import Testing
@testable import RecScribe

@MainActor private final class WeakPermissionWatcher {
    weak var value: PermissionGrantWatcher?
    init(_ object: PermissionGrantWatcher) { value = object }
}

@MainActor struct PermissionGrantWatcherTests {
    @Test func directObservationUsesProviderStateAndAnnouncesTheFirstGrantOnly() async {
        let permissions = MockPermissionProviding(.denied)
        permissions.preflightStatus = .denied
        let observer = PermissionGrantWatcher(permissions: permissions)
        var announced = 0
        observer.onGranted = { announced += 1 }
        await observer.probeOnce()
        permissions.status = .granted
        await observer.probeOnce()
        await observer.probeOnce()
        #expect(announced == 1 && observer.probeCount == 3)
        #expect(permissions.preflightCount == 0)
        #expect(!observer.isPolling && !observer.holdsActivityAssertion)
    }
    @Test(arguments: [1, 3, 5])
    func boundedPollingHasOneLoopAndReleasesItsActivityBudget(limit: Int) async {
        let provider = MockPermissionProviding(.denied)
        let observer = PermissionGrantWatcher(permissions: provider, clock: ImmediatePollClock(), interval: 0, maxProbes: limit)
        observer.startPolling()
        #expect(observer.isPolling && observer.holdsActivityAssertion)
        observer.startPolling()
        await waitUntil("finite permission budget") { !observer.isPolling }
        #expect(provider.checkCount == limit && observer.probeCount == limit)
        #expect(!observer.holdsActivityAssertion)
        await settle()
        #expect(provider.checkCount == limit)
    }
    @Test func grantAndExplicitStopBothReleaseTheObservationSession() async {
        for allowed in [false, true] {
            let provider = MockPermissionProviding(allowed ? .granted : .denied)
            let observer = PermissionGrantWatcher(permissions: provider, clock: NeverPollClock())
            observer.startPolling()
            await waitUntil("the first observation") { provider.checkCount == 1 }
            if !allowed { observer.stopPolling() }
            await waitUntil("observation stopped") { !observer.isPolling }
            #expect(!observer.holdsActivityAssertion)
            await settle()
            #expect(provider.checkCount == 1)
        }
    }
    @Test func destroyingTheOwnerCancelsItsSleepWithoutAnImmortalLoop() async {
        let provider = MockPermissionProviding(.denied)
        var owner: PermissionGrantWatcher? = PermissionGrantWatcher(permissions: provider, clock: NeverPollClock())
        let weak = WeakPermissionWatcher(owner!)
        owner?.startPolling()
        await waitUntil("one probe before owner release") { provider.checkCount == 1 }
        owner = nil
        await waitUntil("permission observer deallocation") { weak.value == nil }
        await settle()
        #expect(provider.checkCount == 1)
    }
    @Test func cancelledRunCannotAnnounceItsOldGrantIntoTheNextRun() async {
        let provider = MockPermissionProviding(.granted)
        provider.holdsChecks = true
        provider.answersWithStatusAtIssue = true
        let observer = PermissionGrantWatcher(permissions: provider, clock: ImmediatePollClock(), maxProbes: 1)
        var grants = 0
        observer.onGranted = { grants += 1 }
        observer.startPolling()
        await waitUntil("old permission run") { provider.checkCount == 1 }
        observer.stopPolling()
        provider.status = .denied
        observer.startPolling()
        await waitUntil("new permission run") { provider.checkCount == 2 }
        provider.holdsChecks = false
        provider.resumePendingChecks()
        await waitUntil("new run completion") { !observer.isPolling }
        #expect(grants == 0 && !observer.holdsActivityAssertion)
    }
    @Test func settingsMetadataSeparatesScreenAndMicrophoneAccess() {
        let screen = PermissionKind.screenCapture
        #expect(screen.settingsAnchor == "Privacy_ScreenCapture")
        #expect(screen.settingsSectionName == "Screen & System Audio Recording")
        #expect(screen.navigationHint.contains(screen.settingsSectionName))
        #expect(screen.navigationHint.contains("System Audio Recording Only"))
        #expect(PermissionKind.microphone.settingsAnchor == "Privacy_Microphone")
        #expect(PermissionKind.microphone.confusableSectionName == nil)
    }
}
