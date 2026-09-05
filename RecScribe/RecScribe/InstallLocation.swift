//
//  InstallLocation.swift
//  RecScribe
//
//  Where the app bundle is running from, and what that means for permission
//  (BL-082).
//
//  The case that matters is translocation: double-clicking RecScribe on the
//  mounted disk image instead of dragging it out makes Gatekeeper run it from a
//  randomised read-only path. TCC identity is tied to that throwaway path, so the
//  grant evaporates on the next launch — the one scenario that genuinely looks
//  like "the app doesn't appear in the permission list". No amount of permission
//  guidance can fix it, so this has to be detected *before* any such guidance is
//  offered.
//

import Foundation

/// Where the running bundle lives, in the only terms that change behaviour.
enum InstallLocation: Equatable, Sendable {
    /// Inside the system `/Applications` tree — the intended, TCC-stable home.
    case applications
    /// Gatekeeper path-randomised the bundle. Permission cannot persist. Hard block.
    case translocated
    /// A real, stable path that simply isn't `/Applications` (`~/Applications`, a
    /// custom folder). Legitimate, and TCC handles it fine — never a block.
    case elsewhere(URL)
    /// A build running out of Xcode's build products. Never warn: nagging on every
    /// run is how a warning gets disabled out of irritation within a week.
    case developerBuild

    // MARK: - Classification

    /// Path fragment Gatekeeper's randomised mount point always contains.
    ///
    /// Deliberately a path heuristic and **not** `SecTranslocateIsTranslocatedURL`.
    /// Verified 2026-07-26: that symbol is SPI with no header anywhere in
    /// MacOSX26.4.sdk — its only appearance is the linker stub list in
    /// `Security.tbd`. The header shipped in an Xcode 8 beta and was pulled in the
    /// next one; it was never promoted to public API. Do not "fix" this by linking
    /// the stub. The heuristic is community-observed rather than contractual, but
    /// its failure mode is safe: guess wrong and the warning simply doesn't appear,
    /// which never blocks a working recording.
    private static let translocationMarker = "/AppTranslocation/"

    /// Xcode's build-products roots. `DerivedData` covers the normal Xcode run;
    /// `Build/Products` also catches `xcodebuild` with a custom `SYMROOT`, which is
    /// what CI and scripted builds produce.
    private static let developerMarkers = ["/DerivedData/", "/Build/Products/"]

    /// The system applications folder. `~/Applications` deliberately does **not**
    /// match — it is a legitimate choice that gets the soft treatment, not the
    /// blocked one.
    private static let applicationsPrefix = "/Applications/"

    /// Classify a bundle URL.
    ///
    /// Pure: a function of the URL's path and nothing else — no filesystem access,
    /// no `Bundle.main`. That is what makes every branch table-testable without
    /// mocks, hardware, or a real translocated bundle.
    ///
    /// Precedence is translocated → developerBuild → applications → elsewhere.
    /// The first two are mutually exclusive in practice (a translocated bundle is
    /// under `/private/var/folders`, never under DerivedData), but the order is
    /// fixed explicitly rather than left to chance: translocation is the only
    /// unrecoverable state, so if a path ever managed to look like both, the
    /// blocking answer is the correct one to return.
    static func classify(_ bundleURL: URL) -> InstallLocation {
        let path = bundleURL.path

        if path.contains(translocationMarker) {
            return .translocated
        }
        if developerMarkers.contains(where: { path.contains($0) }) {
            return .developerBuild
        }
        if path.hasPrefix(applicationsPrefix) {
            return .applications
        }
        return .elsewhere(bundleURL)
    }

    // MARK: - Consequences

    /// Whether recording must be refused outright.
    ///
    /// Only translocation. Conflating it with "not in /Applications" would train
    /// users to dismiss the one warning that actually matters.
    var blocksRecording: Bool {
        self == .translocated
    }

    /// Whether the soft note can be dismissed and forgotten. The hard block cannot:
    /// dismissing it would leave the user with an app that silently can't hold a
    /// permission grant.
    var noticeIsDismissible: Bool {
        !blocksRecording
    }

    /// What to tell the user, or `nil` when there is nothing worth saying.
    ///
    /// The translocation copy names the concrete physical action ("quit, drag,
    /// open from there") because there is no in-app remedy — recovering the
    /// original path needs the same SPI rejected above, and moving the bundle is
    /// the LetsMove problem, deliberately out of scope.
    var explanation: String? {
        switch self {
        case .translocated:
            // The one canonical sentence for this state — every surface (main
            // window, floating panel, menu-bar popover) shows it verbatim, so the
            // user reads one fact however they meet the block. "Quit" leads
            // because it is a load-bearing step, not decoration: the running copy
            // is the one that must die for the fix to take.
            return "RecScribe can't record from the disk image. Quit, drag it to "
                 + "your Applications folder, and open it from there."
        case .elsewhere:
            return "RecScribe isn't in your Applications folder. It'll still record — this "
                 + "is just where it lives."
        case .applications, .developerBuild:
            return nil
        }
    }
}

// MARK: - Injection seam

/// The bundle's install location, as a seam.
///
/// Deliberately separate from `PermissionProviding`: this is a property of the
/// bundle, not of a permission, and every existing permission test would
/// otherwise have to carry a location concern it doesn't care about.
@MainActor
protocol InstallLocationProviding: AnyObject {
    var location: InstallLocation { get }
    /// The bundle itself, for "Reveal in Finder" — the user has to find the app
    /// before they can drag it anywhere.
    var bundleURL: URL { get }
}

@MainActor
final class BundleInstallLocation: InstallLocationProviding {

    let bundleURL: URL

    init(bundleURL: URL = Bundle.main.bundleURL) {
        self.bundleURL = bundleURL
    }

    var location: InstallLocation {
        #if DEBUG
        // Belt to `classify`'s DerivedData match: a debug build is by definition
        // not something a user installed, and a nag on every Xcode run is how this
        // whole feature gets commented out. The check lives here, at the call
        // site, rather than inside `classify` — the classifier stays a pure
        // function of the URL so it can be table-tested from a debug test build.
        return .developerBuild
        #else
        return InstallLocation.classify(bundleURL)
        #endif
    }
}
