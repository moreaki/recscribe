//
//  AudioSource.swift
//  RecScribe
//
//  What to capture audio from (BL-100). `AudioSourceManager` owns selection
//  and persistence; `ScreenCaptureAudioManager` resolves a source into the
//  matching SCContentFilter at capture setup time.
//

import Foundation

nonisolated enum AudioSource: Codable, Sendable, Equatable {
    case multiple(appBundleID: String?, inputs: [InputSelection], allowDuplicateRoutes: Bool = false)
    case mixed(appBundleID: String?, deviceUID: String)
    case systemAll
    case app(bundleID: String)
    /// A microphone or other input device, by `AVCaptureDevice.uniqueID` (BL-130).
    ///
    /// Carries **only** the device UID. Force Mono is deliberately *not* an
    /// associated value here: it is a processing modifier, not part of the
    /// source's identity, and putting it inside the case would silently discard
    /// the setting every time the user switched to system audio and back.
    case mic(deviceUID: String)
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
    /// ⚠️ Exhaustive switch with **no `default`** on purpose: adding a case to
    /// `AudioSource` must fail to compile until someone classifies it. This is
    /// the guarantee BL-111 chose instead of a provider registry, which would
    /// have been an array — and an array is not exhaustiveness.
    var kind: AudioSourceKind {
        switch self {
        case .multiple: return .multiple
        case .mixed: return .mixed
        case .systemAll: return .systemAll
        case .app:       return .app
        case .mic:       return .microphone
        }
    }
}

nonisolated extension AudioSource {
    var microphoneUID: String? {
        switch self {
        case .mic(let uid), .mixed(_, let uid): uid
        case .systemAll, .app, .multiple: nil
        }
    }
    var appBundleID: String? {
        switch self {
        case .app(let bundle), .mixed(let bundle?, _), .multiple(let bundle?, _, _): bundle
        case .systemAll, .mic, .mixed(nil, _), .multiple(nil, _, _): nil
        }
    }
    var isMixed: Bool { kind == .mixed || kind == .multiple }
    var inputSelections: [InputSelection] {
        switch self {
        case .multiple(_, let inputs, _): inputs
        case .mic(let uid), .mixed(_, let uid): [.init(deviceUID: uid)]
        case .systemAll, .app: []
        }
    }
    var requiresMicrophone: Bool { !inputSelections.isEmpty }
    var valid: Bool {
        guard case .multiple(_, let inputs, _) = self else { return true }
        return inputs.count <= InputSelection.maximumDevices && inputs.allSatisfy(\.valid) && Set(inputs.map(\.deviceUID)).count == inputs.count
    }
}


nonisolated enum InputMixPlacement: String, Codable, CaseIterable, Sendable {
    case left, center, right
}

nonisolated struct InputChannelRoute: Codable, Equatable, Sendable {
    var channel: Int
    var placement: InputMixPlacement
}

nonisolated struct InputSelection: Codable, Equatable, Sendable, Identifiable {
    var id: String { deviceUID }
    var deviceUID: String
    /// Mix routing only. All native channels are retained in the source session.
    var routes: [InputChannelRoute]
    static let maximumDevices = 8
    init(deviceUID: String, routes: [InputChannelRoute] = [.init(channel: 0, placement: .center)]) {
        self.deviceUID = deviceUID
        self.routes = routes
    }
    init(device: InputDeviceInfo) {
        deviceUID = device.uid
        routes = (0..<min(2, device.inputChannels ?? 1)).map {
            .init(channel: $0, placement: device.inputChannels == 1 ? .center : ($0 == 0 ? .left : .right))
        }
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
