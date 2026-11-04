//
//  AudioSource.swift
//  RecScribe
//
//  What to capture audio from (BL-100 / #40). `AudioSourceManager` owns selection
//  and persistence; `ScreenCaptureAudioManager` and `DeviceInputCapture` resolve
//  the composable `{ playback, inputs, allowDuplicateRoutes }` graph at capture setup time.
//

import Foundation

/// Composable audio capture configuration combining an optional playback source
/// with zero or more input device selections (#40).
///
/// Supports lossless `Codable` decoding of both the composable schema and legacy
/// 5-case enum payloads (`systemAll`, `app`, `mic`, `mixed`, `multiple`).
nonisolated struct AudioSource: Sendable, Equatable, Hashable {

    nonisolated enum Playback: Codable, Sendable, Equatable, Hashable {
        case none
        case systemAll
        case app(bundleID: String)
    }

    var playback: Playback
    var inputs: [InputSelection]
    var allowDuplicateRoutes: Bool
    /// Preserves whether the selection uses the multi-input routing surface (`.multiple`)
    /// so single-input + playback presets (`.mixed`) and multi-input routing groups remain
    /// distinguishable where required by menu and manifest-version semantics.
    var usesMultiInputRouting: Bool

    init(
        playback: Playback = .systemAll,
        inputs: [InputSelection] = [],
        allowDuplicateRoutes: Bool = false,
        usesMultiInputRouting: Bool? = nil
    ) {
        self.playback = playback
        self.inputs = inputs
        self.allowDuplicateRoutes = allowDuplicateRoutes
        let hasCustomInputRoutes = inputs.contains(where: \.hasCustomRoutes)
        self.usesMultiInputRouting = hasCustomInputRoutes
            || (usesMultiInputRouting ?? (inputs.count > 1 || allowDuplicateRoutes || (playback == .none && inputs.count != 1)))
    }

    // MARK: - Canonical Presets & Factories

    /// Everything the Mac plays (excluding RecScribe), with no input device.
    static let systemAll = AudioSource(
        playback: .systemAll,
        inputs: [],
        allowDuplicateRoutes: false,
        usesMultiInputRouting: false
    )

    /// Only the playback emitted by the application with `bundleID`.
    static func app(bundleID: String) -> AudioSource {
        AudioSource(
            playback: .app(bundleID: bundleID),
            inputs: [],
            allowDuplicateRoutes: false,
            usesMultiInputRouting: false
        )
    }

    /// A microphone or other input device alone, by `AVCaptureDevice.uniqueID` / Core Audio UID (BL-130).
    /// Uses `DeviceInputCapture` directly (`playback == .none`), requiring only Microphone permission.
    static func mic(deviceUID: String) -> AudioSource {
        AudioSource(
            playback: .none,
            inputs: [InputSelection(deviceUID: deviceUID)],
            allowDuplicateRoutes: false,
            usesMultiInputRouting: false
        )
    }

    /// System or application playback recorded simultaneously with one explicit input device.
    static func mixed(appBundleID: String?, deviceUID: String) -> AudioSource {
        AudioSource(
            playback: appBundleID.map(Playback.app(bundleID:)) ?? .systemAll,
            inputs: [InputSelection(deviceUID: deviceUID)],
            allowDuplicateRoutes: false,
            usesMultiInputRouting: false
        )
    }

    /// Multi-source routing configuration with optional app/system playback and `0...N` inputs.
    static func multiple(
        appBundleID: String?,
        inputs: [InputSelection],
        allowDuplicateRoutes: Bool = false
    ) -> AudioSource {
        AudioSource(
            playback: appBundleID.map(Playback.app(bundleID:)) ?? .systemAll,
            inputs: inputs,
            allowDuplicateRoutes: allowDuplicateRoutes,
            usesMultiInputRouting: true
        )
    }

    /// Inputs-only configuration with no playback capture (`playback == .none`).
    static func inputsOnly(
        _ inputs: [InputSelection],
        allowDuplicateRoutes: Bool = false
    ) -> AudioSource {
        AudioSource(
            playback: .none,
            inputs: inputs,
            allowDuplicateRoutes: allowDuplicateRoutes,
            usesMultiInputRouting: inputs.count != 1 || allowDuplicateRoutes || inputs.contains(where: \.hasCustomRoutes)
        )
    }
}

/// The *category* a source belongs to, which is what the menu renders as a row.
///
/// One row per kind, always — so the menu's shape never changes in response to
/// what the world does (an app launching, a mic being plugged in). Only the
/// contents behind a row change (BL-111).
nonisolated enum AudioSourceKind: Hashable, Sendable, CaseIterable {
    case mixed
    case multiple
    /// Everything the Mac plays. A singleton: it needs no submenu.
    case systemAll
    /// One running app, chosen from a list enumerated at runtime.
    case app
    /// One input device, chosen from a list enumerated at runtime.
    case microphone
}

nonisolated extension AudioSource {
    var kind: AudioSourceKind {
        if usesMultiInputRouting || inputs.count > 1 || inputs.contains(where: \.hasCustomRoutes) || (playback == .none && inputs.isEmpty) {
            return .multiple
        }
        switch (playback, inputs.count) {
        case (.systemAll, 0):
            return .systemAll
        case (.app, 0):
            return .app
        case (.none, 1):
            return .microphone
        case (_, 1):
            return .mixed
        default:
            return .multiple
        }
    }

    /// Whether this configuration captures system or application playback via ScreenCaptureKit.
    /// False when `playback == .none` (input-only capture uses `DeviceInputCapture` without `SCStream`).
    var requiresScreenCapture: Bool {
        playback != .none
    }

    var microphoneUID: String? {
        guard !usesMultiInputRouting, inputs.count == 1, !inputs[0].hasCustomRoutes else { return nil }
        return inputs[0].deviceUID
    }

    var appBundleID: String? {
        if case .app(let bundle) = playback {
            return bundle
        }
        return nil
    }

    var isMixed: Bool {
        kind == .mixed || kind == .multiple
    }

    var inputSelections: [InputSelection] {
        inputs
    }

    var requiresMicrophone: Bool {
        !inputs.isEmpty
    }

    var valid: Bool {
        guard playback != .none || !inputs.isEmpty else { return false }
        if case .app(let bundle) = playback, bundle.isEmpty { return false }
        guard inputs.count <= InputSelection.maximumDevices,
              inputs.allSatisfy(\.valid),
              Set(inputs.map(\.deviceUID)).count == inputs.count else {
            return false
        }
        if case .microphone = kind {
            return inputs.count == 1
        }
        if case .mixed = kind {
            return inputs.count == 1
        }
        return true
    }
}

// MARK: - Backward-Compatible Codable (#40)

nonisolated extension AudioSource: Codable {
    private enum CodingKeys: String, CodingKey {
        // Composable schema keys
        case playback
        case inputs
        case allowDuplicateRoutes
        case usesMultiInputRouting
        // Legacy 5-case enum keys
        case systemAll
        case app
        case mic
        case mixed
        case multiple
    }

    private enum LegacyAppKeys: String, CodingKey {
        case bundleID
    }

    private enum LegacyMicKeys: String, CodingKey {
        case deviceUID
    }

    private enum LegacyMixedKeys: String, CodingKey {
        case appBundleID
        case deviceUID
    }

    private enum LegacyMultipleKeys: String, CodingKey {
        case appBundleID
        case inputs
        case allowDuplicateRoutes
    }

    private enum EmptyKeys: CodingKey {}

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(playback, forKey: .playback)
        try container.encode(inputs, forKey: .inputs)
        try container.encode(allowDuplicateRoutes, forKey: .allowDuplicateRoutes)
        try container.encode(usesMultiInputRouting, forKey: .usesMultiInputRouting)
    }

    init(from decoder: Decoder) throws {
        if let single = try? decoder.singleValueContainer(),
           let raw = try? single.decode(String.self),
           raw == "systemAll" {
            self = .systemAll
            return
        }

        let container = try decoder.container(keyedBy: CodingKeys.self)

        // 1. Composable `{ playback, inputs, allowDuplicateRoutes }` schema
        if container.contains(.playback) || container.contains(.inputs) {
            let playback = try container.decodeIfPresent(Playback.self, forKey: .playback) ?? .systemAll
            let inputs = try container.decodeIfPresent([InputSelection].self, forKey: .inputs) ?? []
            let allowDuplicate = try container.decodeIfPresent(Bool.self, forKey: .allowDuplicateRoutes) ?? false
            let usesMulti = try container.decodeIfPresent(Bool.self, forKey: .usesMultiInputRouting)
            self.init(
                playback: playback,
                inputs: inputs,
                allowDuplicateRoutes: allowDuplicate,
                usesMultiInputRouting: usesMulti
            )
            return
        }

        // 2. Legacy 5-case enum payloads
        if container.contains(.systemAll) {
            _ = try container.nestedContainer(keyedBy: EmptyKeys.self, forKey: .systemAll)
            self = .systemAll
            return
        }

        if container.contains(.app) {
            let nested = try container.nestedContainer(keyedBy: LegacyAppKeys.self, forKey: .app)
            let bundleID = try nested.decode(String.self, forKey: .bundleID)
            self = .app(bundleID: bundleID)
            return
        }

        if container.contains(.mic) {
            let nested = try container.nestedContainer(keyedBy: LegacyMicKeys.self, forKey: .mic)
            let deviceUID = try nested.decode(String.self, forKey: .deviceUID)
            self = .mic(deviceUID: deviceUID)
            return
        }

        if container.contains(.mixed) {
            let nested = try container.nestedContainer(keyedBy: LegacyMixedKeys.self, forKey: .mixed)
            let appBundleID = try nested.decodeIfPresent(String.self, forKey: .appBundleID)
            let deviceUID = try nested.decode(String.self, forKey: .deviceUID)
            self = .mixed(appBundleID: appBundleID, deviceUID: deviceUID)
            return
        }

        if container.contains(.multiple) {
            let nested = try container.nestedContainer(keyedBy: LegacyMultipleKeys.self, forKey: .multiple)
            let appBundleID = try nested.decodeIfPresent(String.self, forKey: .appBundleID)
            let inputs = try nested.decode([InputSelection].self, forKey: .inputs)
            let allowDuplicate = try nested.decodeIfPresent(Bool.self, forKey: .allowDuplicateRoutes) ?? false
            self = .multiple(
                appBundleID: appBundleID,
                inputs: inputs,
                allowDuplicateRoutes: allowDuplicate
            )
            return
        }

        throw DecodingError.dataCorrupted(
            DecodingError.Context(
                codingPath: decoder.codingPath,
                debugDescription: "Unrecognized AudioSource payload"
            )
        )
    }
}

nonisolated enum InputMixPlacement: String, Codable, CaseIterable, Sendable, Hashable {
    case left, center, right
}

nonisolated struct InputChannelRoute: Codable, Equatable, Sendable, Hashable {
    var channel: Int
    var placement: InputMixPlacement
}

nonisolated struct InputSelection: Codable, Equatable, Sendable, Hashable, Identifiable {
    static let defaultRoutes: [InputChannelRoute] = [.init(channel: 0, placement: .center)]
    var id: String { deviceUID }
    var deviceUID: String
    /// Mix routing only. All native channels are retained in the source session.
    var routes: [InputChannelRoute]
    /// Ordered sub-device UIDs recorded when selecting a Core Audio aggregate device (#36).
    var aggregateMembers: [String]?
    static let maximumDevices = 8
    init(
        deviceUID: String,
        routes: [InputChannelRoute] = Self.defaultRoutes,
        aggregateMembers: [String]? = nil
    ) {
        self.deviceUID = deviceUID
        self.routes = routes
        self.aggregateMembers = aggregateMembers
    }
    init(device: InputDeviceInfo) {
        deviceUID = device.uid
        routes = (0..<min(2, device.inputChannels ?? 1)).map {
            .init(channel: $0, placement: device.inputChannels == 1 ? .center : ($0 == 0 ? .left : .right))
        }
        aggregateMembers = device.isAggregate && !device.aggregateMembers.isEmpty ? device.aggregateMembers : nil
    }
    /// True when the channel routing differs from the canonical single-input mono-center default,
    /// requiring `MultiSourceRecorder` to preserve custom channel placement and multi-channel source tracks.
    var hasCustomRoutes: Bool {
        routes != Self.defaultRoutes
    }
    var valid: Bool {
        !deviceUID.isEmpty && deviceUID.count <= 1024 && routes.count <= 32 &&
        Set(routes.map(\.channel)).count == routes.count && routes.allSatisfy { (0..<32).contains($0.channel) }
    }
}

nonisolated enum InputRouteSafety {
    static func warnings(inputs: [InputSelection], devices: [InputDeviceInfo]) -> [String] {
        let uids = Set(inputs.map(\.deviceUID))
        var warnings: [String] = []
        for input in inputs {
            guard let device = devices.first(where: { $0.uid == input.deviceUID }) else { continue }
            if device.mayLoopBack { warnings.append("\(device.name) may duplicate system playback through a virtual or loopback route.") }
            if device.isAggregate {
                if device.aggregateMembers.contains(where: { uid in devices.contains { $0.uid == uid && $0.mayLoopBack } }) {
                    warnings.append("\(device.name) contains a virtual or loopback input that may duplicate system playback.")
                }
                if !uids.isDisjoint(with: device.aggregateMembers) { warnings.append("\(device.name) overlaps a selected member device.") }
                if device.aggregateMembers.isEmpty { warnings.append("The members of \(device.name) could not be identified; check for overlapping routes.") }
            }
            if input.routes.contains(where: { route in
                device.channelLabels.indices.contains(route.channel) && device.channelLabels[route.channel].localizedCaseInsensitiveContains("loopback")
            }) { warnings.append("A selected channel on \(device.name) is labelled loopback and may duplicate playback.") }
        }
        let aggregates = devices.filter { uids.contains($0.uid) && $0.isAggregate }
        for (index, device) in aggregates.enumerated() {
            for other in aggregates.dropFirst(index + 1) where !Set(device.aggregateMembers).isDisjoint(with: other.aggregateMembers) {
                warnings.append("\(device.name) and \(other.name) share member devices.")
            }
        }
        return warnings
    }
}
