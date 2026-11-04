import AppKit
import Observation
import SwiftUI
import Testing
import os

@testable import RecScribe

@MainActor
@Suite(.serialized)
struct ObservationLayoutTests {
    @Test func lockBackedFadersInvalidateUIReadsButNotCaptureSnapshots() {
        let defaults = UserDefaults(suiteName: "observation-levels-\(UUID())")!
        let levels = AudioLevels(defaults: defaults)
        let uiChanges = OSAllocatedUnfairLock(initialState: 0)
        let captureChanges = OSAllocatedUnfairLock(initialState: 0)
        withObservationTracking {
            _ = levels.level("master")
        } onChange: {
            uiChanges.withLock { $0 += 1 }
        }
        withObservationTracking {
            _ = levels.snapshot(for: .systemAll)
        } onChange: {
            captureChanges.withLock { $0 += 1 }
        }
        levels.set("master", .init(decibels: -6))
        #expect(uiChanges.withLock { $0 } == 1)
        #expect(captureChanges.withLock { $0 } == 0)
        #expect(levels.snapshot(for: .systemAll).master.decibels == -6)
    }

    @Test func subcontrollersReleaseNotificationObserversWithRecorder() async throws {
        let center = NotificationCenter()
        let permissions = MockPermissionProviding(.denied)
        weak var permissionOwner: PermissionCoordinator?
        weak var installOwner: InstallLocationMonitor?
        do {
            let recorder = RecorderViewModel(
                controller: MockRecordingControlling(), permissions: permissions,
                installLocation: MockInstallLocationProviding(.applications),
                defaults: UserDefaults(suiteName: "observation-owner-\(UUID())")!,
                notificationCenter: center)
            permissionOwner = recorder.permissionCoordinator
            installOwner = recorder.installLocationMonitor
        }
        #expect(permissionOwner == nil)
        #expect(installOwner == nil)
        center.post(name: NSApplication.didBecomeActiveNotification, object: nil)
        try await Task.sleep(for: .milliseconds(20))
        #expect(permissionOwner == nil)
    }

    @Test func popoverHostingResizesAndKeepsFooterOutsideBoundedScroll() async throws {
        let fixture = PopoverFixture()
        let layout = PopoverLayout(availableHeight: 500)
        let host = NSHostingController(
            rootView: PopoverFrame(layout: layout) {
                Rectangle().frame(height: fixture.height)
            } footer: {
                Text("Quit").frame(height: fixture.footer)
            })
        host.sizingOptions = [.preferredContentSize]
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: WorkspaceStyle.popoverWidth, height: 200),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentViewController = host
        defer { window.contentViewController = nil }
        func settle() async throws -> CGFloat {
            for _ in 0..<6 {
                host.view.layoutSubtreeIfNeeded()
                try await Task.sleep(for: .milliseconds(20))
            }
            return host.view.fittingSize.height
        }
        let collapsed = try await settle()
        fixture.height = 330  // Expanding controls changes the content's ideal size.
        let expanded = try await settle()
        #expect(expanded > collapsed + 100)
        fixture.height = 1200
        let capped = try await settle()
        #expect(abs(capped - 500) < 2)
        fixture.footer = 85  // Accessibility-size footer gets its own room.
        let largeFooter = try await settle()
        #expect(abs(largeFooter - 500) < 2)
        #expect(layout.scrollHeight(content: fixture.height, footer: fixture.footer) == 414)
        layout.availableHeight = 300  // Moving to a shorter screen shrinks the viewport.
        let shortScreen = try await settle()
        #expect(abs(shortScreen - 300) < 2)
        fixture.height = 140
        let collapsedAgain = try await settle()
        #expect(abs(collapsedAgain - 226) < 2)
        #expect(abs(host.preferredContentSize.height - collapsedAgain) < 2)
    }
}

@MainActor
@Observable private final class PopoverFixture {
    var height: CGFloat = 140
    var footer: CGFloat = 50
}
