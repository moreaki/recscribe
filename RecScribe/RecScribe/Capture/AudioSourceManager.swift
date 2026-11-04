import Observation
//
//  AudioSourceManager.swift
//  RecScribe
//
//  Owns capture-source selection for BL-100: persists the user's choice,
//  enumerates currently running apps for the picker, and validates a source
//  is still capturable before a recording starts.
//

import AppKit
import Foundation
import ScreenCaptureKit

/// A running app the capture-source picker can offer, as seen by ScreenCaptureKit.
struct RunningAppInfo: Identifiable, Sendable, Equatable {
    var id: String { bundleID }
    let bundleID: String
    let applicationName: String
    /// Whether the app or one of its helper processes currently holds an active Core Audio object (#16).
    var isAudioActive: Bool = false

    init(bundleID: String, applicationName: String, isAudioActive: Bool = false) {
        self.bundleID = bundleID
        self.applicationName = applicationName
        self.isAudioActive = isAudioActive
    }
}

enum AudioSourceError: Error, LocalizedError, Equatable {
    case appNotRunning(String)
    /// The selected input device is no longer connected (BL-130).
    case micNotAvailable(String)

    var errorDescription: String? {
        switch self {
        case .appNotRunning(let bundleID):
            return "The selected app (\(bundleID)) is not currently running."
        case .micNotAvailable:
            return "The selected microphone isn't connected."
        }
    }

    var recoverySuggestion: String? {
        switch self {
        case .appNotRunning:
            return "Open the app, or choose a different capture source."
        case .micNotAvailable:
            return "Reconnect it, or choose a different capture source."
        }
    }
}

@MainActor
protocol AudioSourceProviding: AnyObject {
    /// The persisted capture source. Defaults to `.systemAll` on first run.
    var selectedSource: AudioSource { get }
    func setSelectedSource(_ source: AudioSource)
    /// Throws `AudioSourceError` if `source` cannot be captured right now
    /// (e.g. the selected app isn't running). Call before starting capture.
    func validate(_ source: AudioSource) async throws
    /// Currently running apps the picker can offer, excluding RecScribe itself.
    ///
    /// ⚠️ **This calls `SCShareableContent` directly, bypassing `PermissionProviding`.**
    /// That means it can raise the system permission dialog and registers the app
    /// with TCC — so it must never run on a zero-click path (BL-085). It is safe
    /// today only because nothing reaches it without a Record click.
    ///
    /// **Precondition for BL-100's source picker:** SwiftUI evaluates `Menu`
    /// content eagerly in several situations, so a naïvely wired picker would call
    /// this on *popover appearance* — a zero-click prompt. Enumerate only on an
    /// explicit submenu open, and only when `permissionStatus == .granted`.
    func availableApps() async throws -> [RunningAppInfo]
    /// Currently connected input devices (BL-130). Synchronous and prompt-free.
    func availableInputDevices() -> [InputDeviceInfo]
    /// Last-known display name for a bundle ID, or nil if never seen.
    ///
    /// `AudioSource.app` persists only a bundle ID, so without this the UI has
    /// nothing to show but the raw identifier. Reading it must never enumerate —
    /// that would cost a permission prompt on whatever path asked.
    func knownAppName(forBundleID bundleID: String) -> String?
}

@MainActor
@Observable final class AudioSourceManager: AudioSourceProviding {
    private let defaults: UserDefaults
    private let deviceEnumerator: InputDeviceEnumerating
    private let audioProcesses: AudioCapableProcessListing
    private let key = "selectedAudioSource"
    private let namesKey = "knownAppNames"

    /// Apps that pass every other filter but that nobody would ever choose to
    /// record.
    ///
    /// Finder is user-facing (`activationPolicy == .regular`) and always running,
    /// so the policy filter cannot remove it — it would otherwise appear as a
    /// capture target on every Mac, forever, at the top of an alphabetical list.
    ///
    /// Keep this list short. It is a patch over specific known-wrong entries,
    /// **not** a substitute for a rule; if it starts growing, the filter above it
    /// is what needs fixing.
    static let alwaysExcludedBundleIDs: Set<String> = [
        "com.apple.finder"
    ]

    /// Read-through cache. The getter used to hit `UserDefaults` *and* run a
    /// `JSONDecoder` on every access; the menu builder reads it once per row, so
    /// that cost is now per-launch instead of per-read.
    ///
    /// This is also why there must be exactly one `AudioSourceManager` in the app
    /// (resolved in `RecorderViewModel.init`): two caches would diverge, and a
    /// source picked in the menu would be silently ignored by the next recording.
    private var cachedSource: AudioSource?

    init(
        defaults: UserDefaults = .standard,
        deviceEnumerator: InputDeviceEnumerating? = nil,
        audioProcesses: AudioCapableProcessListing? = nil
    ) {
        self.defaults = defaults
        self.deviceEnumerator = deviceEnumerator ?? InputDeviceEnumerator()
        self.audioProcesses = audioProcesses ?? AudioCapableProcesses()
    }

    /// Input devices for the picker.
    ///
    /// Unlike `availableApps()` this needs **no permission gate**: discovery
    /// returns real device names with microphone authorization still
    /// `.notDetermined` and raises no dialog. Only actually *capturing* prompts.
    func availableInputDevices() -> [InputDeviceInfo] {
        deviceEnumerator.availableInputDevices()
    }

    /// Bundle ID → display name, remembered from the last enumeration.
    ///
    /// Persisted because the selection is: after a relaunch the app list has not
    /// been enumerated yet (that needs a deliberate submenu open), so without
    /// this the status line would show a raw bundle ID until the user happened
    /// to open the picker again.
    private var appNameRevision = 0
    @ObservationIgnored private lazy var knownAppNames: [String: String] =
        defaults.dictionary(forKey: namesKey) as? [String: String] ?? [:]

    func knownAppName(forBundleID bundleID: String) -> String? {
        _ = appNameRevision
        return knownAppNames[bundleID]
    }

    private func rememberNames(_ apps: [RunningAppInfo]) {
        var changed = false
        for app in apps where knownAppNames[app.bundleID] != app.applicationName {
            knownAppNames[app.bundleID] = app.applicationName
            changed = true
        }
        // Only touch UserDefaults when something actually moved — this runs on
        // every submenu open.
        if changed { appNameRevision += 1; defaults.set(knownAppNames, forKey: namesKey) }
    }

    var selectedSource: AudioSource {
        if let cachedSource { return cachedSource }
        let decoded = Self.decodeSource(from: defaults, key: key)
        cachedSource = decoded
        return decoded
    }

    /// ⚠️ Decode failures fall back to `.systemAll` rather than throwing, and
    /// that is load-bearing: it is what makes a **downgrade** safe. An older
    /// build reading a newer build's `.mic` selection (BL-130) decodes nothing it
    /// understands and quietly resets to system audio. Turning this into a
    /// throwing decode would convert a silent, correct recovery into an error.
    ///
    /// The corrupt blob is deliberately left in place, not overwritten, so
    /// re-upgrading restores the user's real selection.
    private static func decodeSource(from defaults: UserDefaults, key: String) -> AudioSource {
        guard let data = defaults.data(forKey: key),
              let source = try? JSONDecoder().decode(AudioSource.self, from: data), source.valid else {
            return .systemAll
        }
        return source
    }

    func setSelectedSource(_ source: AudioSource) {
        guard source.valid, let data = try? JSONEncoder().encode(source) else { return }
        // Write through: cache first so a read in the same turn can't observe the
        // stale value, then persist.
        cachedSource = source
        defaults.set(data, forKey: key)
    }

    func validate(_ source: AudioSource) async throws {
        guard source.valid else {
            throw SessionError.invalid("Invalid input selection; choose at most eight distinct devices")
        }
        if case .app(let bundleID) = source.playback {
            let apps = try await availableApps()
            guard apps.contains(where: { $0.bundleID == bundleID }) else {
                throw AudioSourceError.appNotRunning(bundleID)
            }
        }
        guard !source.inputs.isEmpty else { return }
        let devices = availableInputDevices()
        for input in source.inputs {
            guard let device = devices.first(where: { $0.uid == input.deviceUID }) else {
                throw AudioSourceError.micNotAvailable(input.deviceUID)
            }
            if let expectedMembers = input.aggregateMembers,
               !expectedMembers.isEmpty,
               !device.aggregateMembers.isEmpty,
               expectedMembers != device.aggregateMembers {
                throw SessionError.invalid("Aggregate device sub-device membership or order changed. Review the selected channels before recording.")
            }
            if source.kind == .multiple {
                guard let count = device.inputChannels, (1...32).contains(count), input.routes.allSatisfy({ $0.channel < count }) else {
                    throw SessionError.invalid("Input channel availability changed. Review the selected channels before recording.")
                }
            } else if let count = device.inputChannels {
                guard (1...32).contains(count), input.routes.allSatisfy({ $0.channel < count }) else {
                    throw SessionError.invalid("Input channel availability changed. Review the selected channels before recording.")
                }
            }
        }
        if source.kind == .multiple,
           !source.allowDuplicateRoutes,
           !InputRouteSafety.warnings(inputs: source.inputs, devices: devices).isEmpty {
            throw SessionError.invalid("Possible duplicate or loopback routes. Review Capture inputs and remove overlapping devices or explicitly acknowledge their inclusion.")
        }
    }

    func availableApps() async throws -> [RunningAppInfo] {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        let ownBundleID = Bundle.main.bundleIdentifier
        // `SCShareableContent.applications` includes background agents, helpers
        // and daemons — expect 100+ entries, almost none of them things a person
        // would choose to record. Intersect with the apps macOS itself considers
        // user-facing (BL-100 correction C4).
        let userFacing = Set(
            NSWorkspace.shared.runningApplications
                .filter { $0.activationPolicy == .regular }
                .compactMap(\.bundleIdentifier)
        )

        // Keep all open user-facing (`.regular`) apps selectable so users can
        // select an idle browser before joining a WebEx/browser meeting (#16),
        // while using `audioCapableBundleIDs()` to badge and sort currently
        // audible apps first.
        let audioActive = audioProcesses.audioCapableBundleIDs()
        let candidates = content.applications.map {
            (bundleID: $0.bundleIdentifier, applicationName: $0.applicationName)
        }
        let apps = Self.filterAndSortAvailableApps(
            candidates: candidates,
            userFacingBundleIDs: userFacing,
            audioActiveBundleIDs: audioActive,
            ownBundleID: ownBundleID
        )
        // Enumeration is the only place names are available, and it is gated
        // behind permission and a deliberate submenu open. Capture them here so
        // every other surface can name the selection without enumerating.
        rememberNames(apps)
        return apps
    }

    /// Pure filtering, deduplication, badging, and sorting for user-facing apps (#16).
    /// Keeps all open `.regular` apps selectable while sorting `isAudioActive` apps first.
    static func filterAndSortAvailableApps(
        candidates: [(bundleID: String, applicationName: String)],
        userFacingBundleIDs: Set<String>,
        audioActiveBundleIDs: Set<String>?,
        ownBundleID: String?
    ) -> [RunningAppInfo] {
        var seen = Set<String>()
        let activeSet = audioActiveBundleIDs ?? []
        return candidates
            .filter { $0.bundleID != ownBundleID }
            .filter { userFacingBundleIDs.contains($0.bundleID) }
            .filter { !alwaysExcludedBundleIDs.contains($0.bundleID) }
            .filter { seen.insert($0.bundleID).inserted }
            .map {
                RunningAppInfo(
                    bundleID: $0.bundleID,
                    applicationName: $0.applicationName,
                    isAudioActive: activeSet.contains($0.bundleID)
                )
            }
            .sorted { lhs, rhs in
                if lhs.isAudioActive != rhs.isAudioActive {
                    return lhs.isAudioActive && !rhs.isAudioActive
                }
                return lhs.applicationName.localizedStandardCompare(rhs.applicationName) == .orderedAscending
            }
    }
}
