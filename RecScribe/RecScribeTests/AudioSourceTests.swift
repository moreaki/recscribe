//
//  AudioSourceTests.swift
//  RecScribeTests
//
//  BL-100 / #40: AudioSource is the persisted, composable Codable value type
//  threaded through AudioSourceManager and the AudioCapturing seam.
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

    @Test("Legacy 5-case enum JSON payloads migrate losslessly into composable AudioSource (#40)")
    func legacyEnumPayloadsMigrateLosslessly() throws {
        let decoder = JSONDecoder()

        let systemJSON = Data(#"{"systemAll":{}}"#.utf8)
        #expect(try decoder.decode(AudioSource.self, from: systemJSON) == .systemAll)

        let appJSON = Data(#"{"app":{"bundleID":"com.apple.logic10"}}"#.utf8)
        let decodedApp = try decoder.decode(AudioSource.self, from: appJSON)
        #expect(decodedApp == .app(bundleID: "com.apple.logic10"))
        #expect(decodedApp.playback == .app(bundleID: "com.apple.logic10"))
        #expect(decodedApp.inputs.isEmpty)
        #expect(decodedApp.requiresScreenCapture)
        #expect(!decodedApp.requiresMicrophone)

        let micJSON = Data(#"{"mic":{"deviceUID":"BuiltInMic"}}"#.utf8)
        let decodedMic = try decoder.decode(AudioSource.self, from: micJSON)
        #expect(decodedMic == .mic(deviceUID: "BuiltInMic"))
        #expect(decodedMic.playback == .none)
        #expect(decodedMic.microphoneUID == "BuiltInMic")
        #expect(!decodedMic.requiresScreenCapture)
        #expect(decodedMic.requiresMicrophone)

        let mixedJSON = Data(#"{"mixed":{"appBundleID":"com.apple.Safari","deviceUID":"BuiltInMic"}}"#.utf8)
        let decodedMixed = try decoder.decode(AudioSource.self, from: mixedJSON)
        #expect(decodedMixed == .mixed(appBundleID: "com.apple.Safari", deviceUID: "BuiltInMic"))
        #expect(decodedMixed.playback == .app(bundleID: "com.apple.Safari"))
        #expect(decodedMixed.microphoneUID == "BuiltInMic")
        #expect(decodedMixed.requiresScreenCapture)
        #expect(decodedMixed.requiresMicrophone)

        let multipleJSON = Data(#"{"multiple":{"appBundleID":"com.google.Chrome","inputs":[{"deviceUID":"USB:Scarlett","routes":[{"channel":0,"placement":"left"},{"channel":1,"placement":"right"}]}],"allowDuplicateRoutes":true}}"#.utf8)
        let decodedMultiple = try decoder.decode(AudioSource.self, from: multipleJSON)
        let expectedRoute = InputSelection(
            deviceUID: "USB:Scarlett",
            routes: [.init(channel: 0, placement: .left), .init(channel: 1, placement: .right)]
        )
        #expect(decodedMultiple == .multiple(appBundleID: "com.google.Chrome", inputs: [expectedRoute], allowDuplicateRoutes: true))
        #expect(decodedMultiple.allowDuplicateRoutes)
        #expect(decodedMultiple.inputs == [expectedRoute])
    }

    @Test("Composable inputsOnly configuration does not require Screen Recording permission (#40)")
    func inputsOnlyRequiresMicrophoneOnly() throws {
        let source = AudioSource.inputsOnly([
            InputSelection(deviceUID: "mic-a"),
            InputSelection(deviceUID: "mic-b")
        ])
        #expect(source.playback == .none)
        #expect(!source.requiresScreenCapture)
        #expect(source.requiresMicrophone)
        #expect(source.valid)
        let roundTrip = try JSONDecoder().decode(AudioSource.self, from: JSONEncoder().encode(source))
        #expect(roundTrip == source)
    }
}
