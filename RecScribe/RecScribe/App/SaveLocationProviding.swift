import Foundation

@MainActor protocol SaveLocationProviding: AnyObject {
    var configuredDirectory: URL? { get }
    var resolvedDirectory: URL { get }
    var isConfiguredLocationUnavailable: Bool { get }
    func setSaveDirectory(_ url: URL)
    func reset()
}

/// A configured folder is retained even when a volume is absent. Resolution
/// chooses a writable folder without rewriting the user's saved preference.
@MainActor final class SaveLocationManager: SaveLocationProviding {
    private let storage: UserDefaults
    private static let preference = "saveLocationPath"
    init(defaults: UserDefaults = .standard) { storage = defaults }

    var configuredDirectory: URL? {
        storage.string(forKey: Self.preference).map { URL(fileURLWithPath: $0, isDirectory: true) }
    }
    private var usableSelection: URL? {
        guard let selected = configuredDirectory,
              (try? selected.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true,
              FileManager.default.isWritableFile(atPath: selected.path) else { return nil }
        return selected
    }
    var resolvedDirectory: URL {
        usableSelection ?? FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
    }
    var isConfiguredLocationUnavailable: Bool { configuredDirectory != nil && usableSelection == nil }
    func setSaveDirectory(_ url: URL) { storage.set(url.path, forKey: Self.preference) }
    func reset() { storage.removeObject(forKey: Self.preference) }
}
