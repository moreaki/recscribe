//
//  BundledFontTests.swift
//  RecScribeTests
//
//  Verifies that RecScribe standardises on native macOS system typography
//  (San Francisco and SF Mono) with no bundled third-party .ttf/.otf font
//  resources (#39), and preserves Dynamic Type scaling bounds.
//

import Testing
import SwiftUI
import AppKit
@testable import RecScribe

@MainActor
struct BundledFontTests {

    @Test("No custom .ttf or .otf font files are shipped in the app bundle")
    func noBundledFontFilesShipped() {
        let ttf = Bundle.main.urls(forResourcesWithExtension: "ttf", subdirectory: nil) ?? []
        let otf = Bundle.main.urls(forResourcesWithExtension: "otf", subdirectory: nil) ?? []
        #expect(ttf.isEmpty)
        #expect(otf.isEmpty)
    }

    @Test("GlassTypography.standard uses native San Francisco and SF Mono families")
    func designSystemUsesNativeSystemTypography() {
        let typography = GlassTypography.standard
        #expect(!typography.usesCustomUIFamily)
        #expect(typography.uiFamily.name == nil)
        #expect(typography.displayFamily.name == nil)
        #expect(typography.monoFamily.name == nil)
        #expect(typography.monoFamily.design == .monospaced)
    }

    @Test("GlassTypography honors Dynamic Type scaling and role maxScale caps")
    func dynamicTypeScalingHonorsRoleCaps() {
        let typography = GlassTypography.standard
        #expect(typography.size(.body, for: .large) == 13)
        #expect(typography.size(.body, for: .accessibility5) == 26)
        // Hero timer is capped at 1.4x (30 * 1.4 = 42), timecodeChip at 1.0x (10).
        #expect(typography.size(.timer, for: .accessibility5) == 42)
        #expect(typography.size(.timecodeChip, for: .accessibility5) == 10)

        for role in WorkspaceStyle.TextRole.allCases {
            #expect(WorkspaceStyle.size(role, for: .large) == role.baseSize)
            #expect(WorkspaceStyle.size(role, for: .accessibility3) > WorkspaceStyle.size(role, for: .large))
        }
    }

    @Test("OnboardingView, InstallLocationNoticeView, and MenuBarPopoverView scale and wrap at accessibility Dynamic Type sizes and with long app/device names")
    func accessibilityDynamicTypeAndLongSourceWrapping() async {
        let suite = "com.moreaki.RecScribe.typography-tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let longAppID = "com.apple.FinalCutStudio"
        let longAppName = "Final Cut Pro Studio Master Suite"
        let longMicUID = "focusrite-18i20-usb"
        let longMicName = "Focusrite Scarlett 18i20 USB Multi-Channel Interface"

        let source = MockAudioSourceProviding(
            selectedSource: .mixed(appBundleID: longAppID, deviceUID: longMicUID)
        )
        source.knownAppNamesResult = [longAppID: longAppName]
        source.availableInputDevicesResult = [
            InputDeviceInfo(uid: longMicUID, name: longMicName, inputChannels: 8)
        ]

        let viewModel = RecorderViewModel(
            controller: MockRecordingControlling(),
            permissions: MockPermissionProviding(.granted),
            clock: ManualClock(),
            saveLocation: MockSaveLocationProviding(directory: URL(fileURLWithPath: "/Users/me/Desktop")),
            audioSource: source,
            installLocation: MockInstallLocationProviding(.applications),
            defaults: defaults
        )

        #expect(viewModel.statusText == "Ready to record \(longAppName) + \(longMicName)")

        let onboardingLarge = fittingSize(
            OnboardingView().environment(viewModel).dynamicTypeSize(.large)
        )
        let onboardingAccessibility = fittingSize(
            OnboardingView().environment(viewModel).dynamicTypeSize(.accessibility3)
        )
        #expect(onboardingLarge.width == 420)
        #expect(onboardingAccessibility.width == 420)
        #expect(onboardingAccessibility.height > onboardingLarge.height)

        let noticeMessage = InstallLocation.translocated.explanation ?? "Move RecScribe to Applications."
        let noticeLarge = fittingSize(
            InstallLocationNoticeView(message: noticeMessage, onReveal: {}, onDismiss: {})
                .dynamicTypeSize(.large)
        )
        let noticeAccessibility = fittingSize(
            InstallLocationNoticeView(message: noticeMessage, onReveal: {}, onDismiss: {})
                .dynamicTypeSize(.accessibility3)
        )
        #expect(noticeLarge.width == 340)
        #expect(noticeAccessibility.width == 340)
        #expect(noticeAccessibility.height > noticeLarge.height)

        await viewModel.startRecording()
        viewModel.duration = 125
        #expect(viewModel.statusText == "Recording \(longAppName) + \(longMicName)")

        let popoverLarge = fittingSize(
            MenuBarPopoverView().environment(viewModel).dynamicTypeSize(.large)
        )
        let popoverAccessibility = fittingSize(
            MenuBarPopoverView().environment(viewModel).dynamicTypeSize(.accessibility3)
        )
        #expect(popoverLarge.width == WorkspaceStyle.popoverWidth)
        #expect(popoverAccessibility.width == WorkspaceStyle.popoverWidth)
        #expect(popoverAccessibility.height > popoverLarge.height)
    }

    private func fittingSize<V: View>(_ view: V) -> CGSize {
        let hosting = NSHostingView(rootView: view)
        hosting.frame = CGRect(x: 0, y: 0, width: 480, height: 800)
        let window = NSWindow(
            contentRect: hosting.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = hosting
        window.layoutIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        hosting.layoutSubtreeIfNeeded()
        let size = hosting.fittingSize
        window.contentView = nil
        return size
    }
}
