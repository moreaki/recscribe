import Foundation
import Security
import Testing
@testable import RecScribe

@MainActor struct InfoPlistTests {
    @Test func builtBundleHasTheRequiredIdentityVersionAndPermissionMetadata() throws {
        let bundle = Bundle.main
        func value(_ key: String) -> String? { bundle.object(forInfoDictionaryKey: key) as? String }
        let required = ["CFBundleIdentifier": "com.moreaki.recscribe", "CFBundleDisplayName": "RecScribe",
                        "LSMinimumSystemVersion": "15.0"]
        for (key, expected) in required { #expect(value(key) == expected) }
        let marketing = try #require(value("CFBundleShortVersionString"))
        let version = marketing.split(separator: ".").compactMap { Int($0) }
        #expect(version.count == 3)
        guard version.count == 3 else { return }
        #expect(version.allSatisfy { (0..<100).contains($0) })
        let build = try #require(value("CFBundleVersion").flatMap(Int.init))
        #expect(build == version.enumerated().reduce(0) { $0 + $1.element * [10_000, 100, 1][$1.offset] })
        #expect(build != 1)
        let purpose = try #require(value("NSMicrophoneUsageDescription"))
        #expect(purpose.contains("microphone"))
        #expect(value("NSAppleEventsUsageDescription") == nil)
        #expect(bundle.url(forResource: "Info", withExtension: "plist") == nil)
    }
    nonisolated private static var signedHost: Bool {
        var handle: SecStaticCode?
        let opened = SecStaticCodeCreateWithPath(Bundle.main.bundleURL as CFURL, SecCSFlags(), &handle)
        guard opened == errSecSuccess, let handle else { return false }
        var metadata: CFDictionary?
        guard SecCodeCopySigningInformation(handle, SecCSFlags(), &metadata) == errSecSuccess,
              let flags = (metadata as? [String: Any])?[kSecCodeInfoFlags as String] as? NSNumber else { return false }
        return flags.uint32Value & 2 == 0 // Ad-hoc test hosts do not carry the app's entitlements.
    }
    @Test(.enabled(if: signedHost))
    func signedProductAllowsAudioInputUnderTheHardenedRuntime() throws {
        let process = try #require(SecTaskCreateFromSelf(nil))
        let entitlement = SecTaskCopyValueForEntitlement(process, "com.apple.security.device.audio-input" as CFString, nil)
        #expect(entitlement as? Bool == true)
    }
}
