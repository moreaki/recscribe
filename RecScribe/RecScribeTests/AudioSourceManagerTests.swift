//
//  AudioSourceManagerTests.swift
//  RecScribeTests
//
//  BL-100: persistence and validation for capture-source selection.
//  Real-app validation (`.app` against SCShareableContent) needs Screen
//  Recording permission and a real running app, so it's exercised manually
//  (see private/reports/2026-06-25-bl100-spike-plan.md), not here.
//

import Testing
import Foundation
@testable import RecScribe

@MainActor
struct AudioSourceManagerTests {

    private func isolatedDefaults() -> UserDefaults {
        UserDefaults(suiteName: "audiosource-test-\(UUID().uuidString)")!
    }

    @Test("First run defaults to .systemAll")
    func firstRunDefaultsToSystemAll() {
        let manager = AudioSourceManager(defaults: isolatedDefaults())
        #expect(manager.selectedSource == .systemAll)
    }

    @Test("Selection persists within the same defaults suite")
    func selectionPersists() {
        let defaults = isolatedDefaults()
        let manager = AudioSourceManager(defaults: defaults)

        manager.setSelectedSource(.app(bundleID: "com.apple.logic10"))

        #expect(manager.selectedSource == .app(bundleID: "com.apple.logic10"))
    }

    @Test("Selection persists across separate manager instances (relaunch)")
    func selectionPersistsAcrossInstances() {
        let defaults = isolatedDefaults()
        AudioSourceManager(defaults: defaults).setSelectedSource(.app(bundleID: "com.spotify.client"))

        let reloaded = AudioSourceManager(defaults: defaults)
        #expect(reloaded.selectedSource == .app(bundleID: "com.spotify.client"))
    }

    @Test("validate(.systemAll) never throws — always capturable")
    func validateSystemAllAlwaysSucceeds() async throws {
        let manager = AudioSourceManager(defaults: isolatedDefaults())
        try await manager.validate(.systemAll)   // must not throw
    }
}
