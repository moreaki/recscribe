import Foundation
import Observation

/// Shared presentation names only. Never enumerates devices or requests permission.
@MainActor @Observable
final class RoutingSourceNames {
    static let shared = RoutingSourceNames()
    private let defaults: UserDefaults
    private(set) var inputNames: [String: String]
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        inputNames = defaults.dictionary(forKey: "routing.inputNames.v1") as? [String: String] ?? [:]
    }
    func remember(_ devices: [InputDeviceInfo]) {
        var next = inputNames
        for device in devices where !device.name.isEmpty { next[device.uid] = device.name }
        // Only presentation metadata; cap remembered devices independently of capture.
        if next.count > 256 {
            next = Dictionary(uniqueKeysWithValues: next.sorted { $0.key < $1.key }.prefix(256).map { ($0.key, $0.value) })
        }
        guard next != inputNames else { return }
        inputNames = next
        defaults.set(next, forKey: "routing.inputNames.v1")
    }
    func input(_ uid: String) -> String { inputNames[uid] ?? "Input (\(uid))" }
    static func playback(_ source: AudioSource, appName: (String) -> String?) -> String {
        source.appBundleID.map { appName($0) ?? $0 } ?? "System audio"
    }
    func mutedSources(_ source: AudioSource, levels: AudioLevels, appName: (String) -> String?) -> [String] {
        var result: [String] = []
        if source.requiresScreenCapture, levels.level(source.playbackLevelID).muted {
            result.append(Self.playback(source, appName: appName))
        }
        result += source.inputSelections.filter { levels.level("input:" + $0.deviceUID).muted }.map { input($0.deviceUID) }
        return result
    }
}
