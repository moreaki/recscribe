//
//  InfoPlistTests.swift
//  RecScribeTests
//
//  BL-084: guards the bundle's Info.plist against silent drift.
//
//  These run against the *host app's built bundle*, not the repo — which is the
//  whole point. A checked-in Info.plist sat in this project for months looking
//  authoritative while contributing nothing to the product: `INFOPLIST_FILE` was
//  never set and `GENERATE_INFOPLIST_FILE` was on, so Xcode synthesised the real
//  plist and ignored the file. Two keys that appeared present in the repo
//  (`NSMicrophoneUsageDescription`, `NSAppleEventsUsageDescription`) were absent
//  from every shipped build. Asserting against the repo would have reproduced the
//  same blind spot, so every check here reads the product.
//

import Testing
import Foundation
import Security
@testable import RecScribe

@MainActor
struct InfoPlistTests {

    /// The host app's bundle. Unit tests are injected into the app via `TEST_HOST`,
    /// so `Bundle.main` is the app being shipped, not the test bundle.
    private var appBundle: Bundle { Bundle.main }

    private func string(_ key: String) -> String? {
        appBundle.object(forInfoDictionaryKey: key) as? String
    }

    @Test("Bundle identity keys are present in the built product")
    func identityKeysPresent() throws {
        #expect(string("CFBundleIdentifier") == "com.moreaki.recscribe")
        #expect(string("CFBundleDisplayName") == "RecScribe")
        #expect(try #require(string("CFBundleShortVersionString")).isEmpty == false)
        #expect(try #require(string("CFBundleVersion")).isEmpty == false)
    }

    /// `CFBundleVersion` must be derived from `CFBundleShortVersionString`.
    ///
    /// The build number is release bookkeeping and must remain monotonic.
    ///
    /// Deriving one from the other — rather than asserting some floor like
    /// `> 1` — is what makes the two impossible to ship out of step: bumping
    /// `MARKETING_VERSION` without `CURRENT_PROJECT_VERSION` fails right here.
    ///
    /// The encoding is `major * 10000 + minor * 100 + patch`, which stays
    /// monotonic for any component under 100.
    @Test("CFBundleVersion is derived from the marketing version, so they cannot drift")
    func bundleVersionTracksMarketingVersion() throws {
        let marketing = try #require(string("CFBundleShortVersionString"))
        // Two statements, not one: `#require` cannot expand inside `#require`.
        let buildString = try #require(string("CFBundleVersion"))
        let build = try #require(Int(buildString),
                                 "CFBundleVersion must be an integer")

        let parts = marketing.split(separator: ".").compactMap { Int($0) }
        #expect(parts.count == 3, "Expected a three-part marketing version, got \(marketing)")
        for part in parts {
            #expect(part < 100, "Component \(part) breaks the major*10000+minor*100+patch encoding")
        }

        let expected = parts[0] * 10_000 + parts[1] * 100 + parts[2]
        #expect(
            build == expected,
            "CFBundleVersion (\(build)) does not match \(marketing) (expected \(expected)). Set CURRENT_PROJECT_VERSION to \(expected) in all 6 configs."
        )

        // The historic stuck value, called out separately so the failure is
        // unmistakable if it ever returns.
        #expect(build != 1, "CFBundleVersion is still the never-incremented placeholder 1.")
    }

    /// `LSMinimumSystemVersion` is synthesised from `MACOSX_DEPLOYMENT_TARGET`.
    /// The v1.1 capture work (BL-100/130) relies on macOS 15-only ScreenCaptureKit
    /// API, so a silent downgrade here would produce a bundle that launches on a
    /// system where those calls are unavailable.
    @Test("Deployment floor is macOS 15.0")
    func minimumSystemVersionIsFifteen() {
        #expect(string("LSMinimumSystemVersion") == "15.0")
    }

    /// Regression guard for the defect BL-084 fixed. The repo's `Info.plist` was
    /// not wired in as the bundle's plist, but it *was* picked up as a resource by
    /// the file-system-synchronized group — so every build, including shipped v1.0,
    /// carried a second `Info.plist` under `Contents/Resources/` that macOS never
    /// reads. Restoring any stray plist there would resurrect the same confusion.
    @Test("No stray Info.plist shipped under Contents/Resources")
    func noStrayResourceInfoPlist() {
        let stray = appBundle.url(forResource: "Info", withExtension: "plist")
        #expect(stray == nil, "Found an Info.plist in Resources — macOS ignores it; delete it.")
    }

    /// Usage-description strings must live in the *product*, not merely in the repo.
    /// macOS terminates a process that requests a protected resource without the
    /// matching key, so a key that is present in a file but absent from the bundle
    /// is a crash waiting on the feature that needs it.
    ///
    /// RecScribe requests one protected resource whose string it must declare: the
    /// microphone (BL-130). Screen Recording is gated by TCC without a required
    /// purpose string — and `INFOPLIST_KEY_NSScreenCaptureUsageDescription` is not
    /// on Xcode's allow-list at all, which is what closed BL-080 as impossible.
    @Test("Declared usage descriptions match what the app actually requests")
    func usageDescriptionsMatchCapabilities() {
        // ⚠️ Asserted against the **built product**, never the repo — that is the
        // whole point of this suite. Requesting mic access without this key in
        // the shipped bundle is an immediate TCC *termination*: the app is
        // killed, not denied. And the key looked present for months while living
        // in a file that was not part of the build at all (BL-084).
        let required = ["NSMicrophoneUsageDescription"]
        for key in required {
            #expect(string(key)?.isEmpty == false, "Missing usage description: \(key)")
        }

        // Must explain itself, not merely exist: a vague string is what users
        // read in the system prompt and what App Review rejects.
        #expect(string("NSMicrophoneUsageDescription")?.contains("microphone") == true)

        // The reverse guard: nothing the app cannot justify. NSAppleEventsUsageDescription
        // was carried in the dead file for months with no AppleEvents code anywhere.
        #expect(string("NSAppleEventsUsageDescription") == nil)
    }

    /// Whether the host bundle carries a *real* signature rather than the
    /// linker's ad-hoc one.
    ///
    /// CI builds with `CODE_SIGNING_ALLOWED=NO`, which produces
    /// `flags=0x20002(adhoc,linker-signed)` and no entitlements at all — there
    /// the entitlement check would fail for a reason that says nothing about
    /// the entitlement. Gating on ad-hoc rather than on "are there any
    /// entitlements" is deliberate: the case that actually matters is a
    /// Developer-ID build with the entitlement dropped, and that build is not
    /// ad-hoc, so it still fails loudly instead of quietly skipping.
    nonisolated private static var hostCarriesARealSignature: Bool {
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(Bundle.main.bundleURL as CFURL, [], &staticCode) == errSecSuccess,
              let staticCode else { return false }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(), &info) == errSecSuccess,
              let dict = info as? [String: Any],
              let flags = dict[kSecCodeInfoFlags as String] as? UInt32 else { return false }
        let adhoc: UInt32 = 0x0002
        return (flags & adhoc) == 0
    }

    /// BL-161. The usage string above and this entitlement are a **pair**, and
    /// only asserting one of them is what shipped a microphone feature that
    /// could never work.
    ///
    /// A release build must be signed `--options runtime` for notarization
    /// (see `docs/distribution.md`). Under the hardened runtime, TCC refuses
    /// `kTCCServiceMicrophone` outright when this entitlement is absent — it
    /// will not even show the prompt, so `AVCaptureDevice.requestAccess`
    /// returns false immediately and permanently. v1.1.0 shipped that way: the
    /// usage string was present and asserted, the entitlement was absent and
    /// unasserted, and the app was denied before the user saw anything.
    ///
    /// ⚠️ `ENABLE_APP_SANDBOX = NO` does not exempt this. The sandbox and the
    /// hardened runtime are separate mechanisms; this entitlement is read by
    /// both, and reasoning from the sandbox setting is what made two reviews
    /// dismiss the cause.
    ///
    /// Read from the **running task**, which is the host app, for the same
    /// reason every other check here reads the product: an entitlements file in
    /// the repo proves nothing about what got signed.
    @Test(
        "The microphone entitlement the hardened runtime requires is in the product",
        .enabled(if: hostCarriesARealSignature)
    )
    func microphoneEntitlementIsInTheProduct() {
        guard let task = SecTaskCreateFromSelf(nil) else {
            Issue.record("Could not read the running task's entitlements")
            return
        }
        let value = SecTaskCopyValueForEntitlement(
            task,
            "com.apple.security.device.audio-input" as CFString,
            nil
        )
        #expect(
            (value as? Bool) == true,
            "com.apple.security.device.audio-input is missing from the built product; under the hardened runtime the microphone is denied without a prompt"
        )
    }

}
