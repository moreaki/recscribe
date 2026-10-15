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
