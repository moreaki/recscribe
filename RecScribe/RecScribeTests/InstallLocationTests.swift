import AppKit
import Foundation
import Testing
@testable import RecScribe

@MainActor struct InstallLocationTests {
    @Test func pathClassificationHasExplicitPriorityAndDoesNotBlockStableFolders() {
        let samples: [(String, InstallLocation)] = [
            ("/Applications/RecScribe.app", .applications), ("/Applications/Tools/RecScribe.app", .applications),
            ("/tmp/DerivedData/P/Products/RecScribe.app", .developerBuild),
            ("/tmp/Build/Products/Release/RecScribe.app", .developerBuild),
            ("/private/AppTranslocation/token/RecScribe.app", .translocated),
            ("/tmp/AppTranslocation/token/DerivedData/RecScribe.app", .translocated)]
        for (path, expected) in samples { #expect(InstallLocation.classify(URL(fileURLWithPath: path)) == expected) }
        for path in ["/Users/example/Applications/RecScribe.app", "/Volumes/Install/RecScribe.app", "/tmp/download/RecScribe.app"] {
            let url = URL(fileURLWithPath: path)
            #expect(InstallLocation.classify(url) == .elsewhere(url))
        }
        let all: [InstallLocation] = [.applications, .developerBuild, .translocated, .elsewhere(URL(fileURLWithPath: "/tmp/app"))]
        for location in all {
            #expect(location.blocksRecording == (location == .translocated))
            #expect(location.noticeIsDismissible == !location.blocksRecording)
        }
        #expect(InstallLocation.applications.explanation == nil && InstallLocation.developerBuild.explanation == nil)
        for word in ["disk image", "Quit", "Applications folder"] { #expect(InstallLocation.translocated.explanation?.contains(word) == true) }
    }
    @Test func translocationPreventsRequestsAndSurvivesDismissal() async {
        var presentations = 0
        let h = RecorderContractHarness(permission: .denied, installation: .translocated, presenter: { presentations += 1 })
        defer { h.cleanup() }
        #expect(h.model.installNotice == InstallLocation.translocated.explanation)
        h.model.openSystemSettings()
        await settle()
        #expect(h.permissions.openSettingsCount == 0 && h.permissions.checkCount == 0)
        #expect(!h.model.grantWatcherIsPolling && presentations == 1)
        h.notifications.post(name: NSApplication.didBecomeActiveNotification, object: nil)
        await settle()
        #expect(h.permissions.checkCount == 0)
        h.model.dismissInstallLocationNotice()
        await h.model.startRecording()
        #expect(h.controller.startCount == 0 && h.model.state == .idle)
        #expect(h.model.installNotice != nil && h.model.showsInstallLocationNotice)
    }
    @Test(arguments: [InstallLocation.applications, .developerBuild, .elsewhere(URL(fileURLWithPath: "/tmp/app"))])
    func stableInstallationRecordsAndSoftNoticeCanBeDismissed(installation: InstallLocation) async {
        let h = RecorderContractHarness(installation: installation)
        defer { h.cleanup() }
        #expect(!h.model.installLocationBlocksRecording)
        await h.model.startRecording()
        #expect(h.model.isRecording && h.controller.startCount == 1)
        await h.model.stopRecording()
        if installation.noticeIsDismissible {
            h.model.dismissInstallLocationNotice()
            #expect(h.model.installNotice == nil)
        }
    }
    @Test func panelIsOnlyAFallbackWhenTheLastWindowDisappears() {
        var shown = 0
        let h = RecorderContractHarness(installation: .translocated, presenter: { shown += 1 })
        defer { h.cleanup() }
        h.model.mainWindowDidAppear()
        h.model.showInstallLocationNotice()
        #expect(shown == 0 && h.model.visibleWindowCount == 1)
        h.model.mainWindowDidAppear()
        h.model.mainWindowDidDisappear()
        #expect(shown == 0 && h.model.visibleWindowCount == 1)
        h.model.mainWindowDidDisappear()
        #expect(shown == 1 && h.model.visibleWindowCount == 0)
        h.model.showInstallLocationNotice()
        #expect(shown == 2)
        let stable = RecorderContractHarness(presenter: { shown += 1 })
        defer { stable.cleanup() }
        stable.model.mainWindowDidAppear()
        stable.model.mainWindowDidDisappear()
        #expect(shown == 2)
    }
}
