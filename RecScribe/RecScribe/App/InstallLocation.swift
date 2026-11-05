import Foundation

enum InstallLocation: Equatable, Sendable {
    case applications, translocated, elsewhere(URL), developerBuild

    /// Match path components rather than substrings of app/folder names.
    /// Priority matters when a synthetic path contains more than one marker.
    static func classify(_ bundleURL: URL) -> Self {
        let components = bundleURL.pathComponents
        if components.contains("AppTranslocation") { return .translocated }
        let pairs = zip(components, components.dropFirst())
        let buildProducts = pairs.contains { $0 == "Build" && $1 == "Products" }
        if components.contains("DerivedData") || buildProducts { return .developerBuild }
        if components.starts(with: ["/", "Applications"]) { return .applications }
        return .elsewhere(bundleURL)
    }
    var blocksRecording: Bool {
        if case .translocated = self { return true }
        return false
    }
    var noticeIsDismissible: Bool { self != .translocated }
    var explanation: String? {
        if self == .translocated {
            return "RecScribe cannot retain recording access from this disk image. Quit, move the app to your Applications folder, and reopen it there."
        }
        if case .elsewhere = self {
            return "RecScribe is outside your Applications folder. Recording is available from this location."
        }
        return nil
    }
}

@MainActor protocol InstallLocationProviding: AnyObject {
    var location: InstallLocation { get }
    var bundleURL: URL { get }
}

@MainActor final class BundleInstallLocation: InstallLocationProviding {
    let bundleURL: URL
    init(bundleURL: URL = Bundle.main.bundleURL) { self.bundleURL = bundleURL }
    var location: InstallLocation {
        #if DEBUG
        .developerBuild
        #else
        .classify(bundleURL)
        #endif
    }
}
