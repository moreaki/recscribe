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
    }
}
