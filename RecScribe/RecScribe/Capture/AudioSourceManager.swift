import AppKit
import Foundation
import Observation
import ScreenCaptureKit

struct RunningAppInfo: Identifiable, Sendable, Equatable {
    var id: String { bundleID }
    let bundleID: String
    let applicationName: String
    var isAudioActive = false
}

enum AudioSourceError: Error, LocalizedError, Equatable {
    case appNotRunning(String), micNotAvailable(String)
    var errorDescription: String? {
        switch self {
        case .appNotRunning(let identifier): "The selected app (\(identifier)) is not currently running."
        case .micNotAvailable: "The selected microphone isn't connected."
        }
    }
    var recoverySuggestion: String? {
        switch self {
        case .appNotRunning: "Launch the selected application or select another source."
        case .micNotAvailable: "Reconnect the selected device or select another input."
        }
    }
}

@MainActor protocol AudioSourceProviding: AnyObject {
    var selectedSource: AudioSource { get }
    func setSelectedSource(_ source: AudioSource)
    func validate(_ source: AudioSource) async throws
    func availableApps() async throws -> [RunningAppInfo]
    func availableInputDevices() -> [InputDeviceInfo]
    func knownAppName(forBundleID bundleID: String) -> String?
}

/// Persists stable source identities and display names. Name lookups are pure
/// cache reads; only a deliberate discovery call reaches ScreenCaptureKit.
@MainActor @Observable final class AudioSourceManager: AudioSourceProviding {
    static let alwaysExcludedBundleIDs: Set<String> = ["com.apple.finder"]
    private let storage: UserDefaults
    private let deviceEnumerator: InputDeviceEnumerating
    private let audioProcesses: AudioCapableProcessListing
    private var source: AudioSource?
    private var names: [String: String]

    init(defaults: UserDefaults = .standard, deviceEnumerator: InputDeviceEnumerating? = nil,
         audioProcesses: AudioCapableProcessListing? = nil) {
        storage = defaults
        self.deviceEnumerator = deviceEnumerator ?? InputDeviceEnumerator()
        self.audioProcesses = audioProcesses ?? AudioCapableProcesses()
        names = defaults.dictionary(forKey: "knownAppNames") as? [String: String] ?? [:]
    }
    var selectedSource: AudioSource {
        if let source { return source }
        let selected: AudioSource
        if let blob = storage.data(forKey: "selectedAudioSource"),
           let decoded = try? JSONDecoder().decode(AudioSource.self, from: blob), decoded.valid {
            selected = decoded
        } else { selected = .systemAll }
        // A corrupt/newer preference is left on disk, so downgrade fallback is reversible.
        source = selected
        return selected
    }
    func setSelectedSource(_ selection: AudioSource) {
        guard selection.valid, let encoded = try? JSONEncoder().encode(selection) else { return }
        source = selection
        storage.set(encoded, forKey: "selectedAudioSource")
    }
    func knownAppName(forBundleID bundleID: String) -> String? { names[bundleID] }
    func availableInputDevices() -> [InputDeviceInfo] { deviceEnumerator.availableInputDevices() }

    func validate(_ selection: AudioSource) async throws {
        guard selection.valid else { throw SessionError.invalid("Invalid input selection; choose at most eight distinct devices") }
        if let identifier = selection.appBundleID {
            let applications = try await availableApps()
            guard applications.contains(where: { $0.bundleID == identifier }) else { throw AudioSourceError.appNotRunning(identifier) }
        }
        if selection.inputs.isEmpty { return }
        let devices = availableInputDevices()
        for input in selection.inputs {
            guard let current = devices.first(where: { $0.uid == input.deviceUID }) else { throw AudioSourceError.micNotAvailable(input.deviceUID) }
            if let remembered = input.aggregateMembers, !remembered.isEmpty, !current.aggregateMembers.isEmpty,
               remembered != current.aggregateMembers {
                throw SessionError.invalid("Aggregate device sub-device membership or order changed. Review the selected channels before recording.")
            }
            if let channels = current.inputChannels {
                guard (1...32).contains(channels), input.routes.allSatisfy({ $0.channel < channels }) else {
                    throw SessionError.invalid("Input channel availability changed. Review the selected channels before recording.")
                }
            } else if selection.kind == .multiple {
                throw SessionError.invalid("Input channel availability changed. Review the selected channels before recording.")
            }
        }
    }

    func availableApps() async throws -> [RunningAppInfo] {
        let sharing = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        let visible = NSWorkspace.shared.runningApplications.compactMap { app -> String? in
            app.activationPolicy == .regular ? app.bundleIdentifier : nil
        }
        let result = Self.filterAndSortAvailableApps(
            candidates: sharing.applications.map { ($0.bundleIdentifier, $0.applicationName) },
            userFacingBundleIDs: Set(visible), audioActiveBundleIDs: audioProcesses.audioCapableBundleIDs(),
            ownBundleID: Bundle.main.bundleIdentifier)
        var updated = names
        for app in result { updated[app.bundleID] = app.applicationName }
        if names != updated { names = updated; storage.set(updated, forKey: "knownAppNames") }
        return result
    }

    static func filterAndSortAvailableApps(candidates: [(bundleID: String, applicationName: String)],
        userFacingBundleIDs: Set<String>, audioActiveBundleIDs: Set<String>?, ownBundleID: String?) -> [RunningAppInfo] {
        var unique: [String: RunningAppInfo] = [:]
        for candidate in candidates {
            let key = candidate.bundleID
            guard key != ownBundleID, userFacingBundleIDs.contains(key), !alwaysExcludedBundleIDs.contains(key),
                  unique[key] == nil else { continue }
            unique[key] = .init(bundleID: key, applicationName: candidate.applicationName,
                                isAudioActive: audioActiveBundleIDs?.contains(key) == true)
        }
        return unique.values.sorted { a, b in
            if a.isAudioActive != b.isAudioActive { return a.isAudioActive }
            let order = a.applicationName.localizedStandardCompare(b.applicationName)
            return order == .orderedSame ? a.bundleID < b.bundleID : order == .orderedAscending
        }
    }
}
