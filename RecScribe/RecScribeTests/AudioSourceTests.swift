//
//  AudioSourceTests.swift
//  RecScribeTests
//
//  BL-100: AudioSource is the persisted, Codable value type threaded through
//  AudioSourceManager and the AudioCapturing seam.
//

import Testing
import Foundation
@testable import RecScribe

struct AudioSourceTests {

    @Test("systemAll round-trips through JSON")
    func systemAllRoundTrips() throws {
        let data = try JSONEncoder().encode(AudioSource.systemAll)
        let decoded = try JSONDecoder().decode(AudioSource.self, from: data)
        #expect(decoded == .systemAll)
    }

    @Test("app(bundleID:) round-trips through JSON, preserving the bundle ID")
    func appRoundTrips() throws {
        let source = AudioSource.app(bundleID: "com.apple.logic10")
        let data = try JSONEncoder().encode(source)
        let decoded = try JSONDecoder().decode(AudioSource.self, from: data)
        #expect(decoded == source)
    }

    @Test("Different bundle IDs are not equal")
    func appEqualityIsBundleIDSensitive() {
        #expect(AudioSource.app(bundleID: "com.apple.logic10") != .app(bundleID: "com.spotify.client"))
    }

    @Test("systemAll and app are never equal")
    func systemAllNotEqualToApp() {
        #expect(AudioSource.systemAll != .app(bundleID: "com.apple.logic10"))
    }
}
