//
//  AudioCapableProcesses.swift
//  RecScribe
//
//  Which running apps actually have audio, so the capture-source picker offers
//  a list worth reading.
//
//  ScreenCaptureKit's `SCShareableContent.applications` answers "what could I
//  capture the screen of", which is a much larger question than "what could I
//  record the sound of". Even after filtering to user-facing apps, the result is
//  every open window on the Mac — Notes, Xcode, a text editor — none of which
//  anyone scrolls past on purpose.
//
//  ⚠️ The obvious fix — a list of "apps that aren't audio apps" — is the wrong
//  shape twice over. It is unbounded (there is no end to the apps that aren't
//  Ableton), and it is **factually wrong**: Xcode plays build-success sounds,
//  Terminal rings the bell, Notes plays audio attachments. Measured on this
//  machine, Terminal holds a live Core Audio process object. A blocklist would
//  have hidden apps that genuinely make sound.
//
//  Core Audio answers the real question directly.
//  `kAudioHardwarePropertyProcessObjectList` (macOS 14.4+; the deployment target
//  is 15.0) enumerates processes that have audio objects. Measured: it returns
//  in microseconds and raises **no permission prompt** — unlike
//  `SCShareableContent`, it is safe anywhere. This is only the *read* side of
//  Core Audio; it is not the capture-layer migration in BL-101, and carries none
//  of that item's Bluetooth risk.
//

import CoreAudio
import AppKit

@MainActor
protocol AudioCapableProcessListing: AnyObject {
    /// Bundle IDs of running processes that currently hold Core Audio objects.
    ///
    /// Returns `nil` if Core Audio could not answer. Callers must then skip
    /// filtering entirely rather than showing an empty picker — a list that is
    /// too long is a papercut, a list that is wrongly empty is a broken feature.
    func audioCapableBundleIDs() -> Set<String>?
}

@MainActor
final class AudioCapableProcesses: AudioCapableProcessListing {

    func audioCapableBundleIDs() -> Set<String>? {
        guard let objects = processObjects() else { return nil }

        var bundleIDs = Set<String>()
        for object in objects {
            guard let pid = processID(of: object),
                  let app = NSRunningApplication(processIdentifier: pid) else { continue }
            // A helper process (Safari's GPU process, Chrome/Arc/Edge renderer or
            // audio helper, Firefox plugin-container, Electron helper) is where the
            // audio actually lives, while the user picks the outermost `.app` (#16).
            // Resolve both the direct process bundle ID and any enclosing `.app`
            // bundle's `CFBundleIdentifier` so parent browsers are marked audio-active.
            for id in Self.enclosingAppBundleIDs(
                bundleURL: app.bundleURL,
                executableURL: app.executableURL,
                directBundleID: app.bundleIdentifier
            ) {
                bundleIDs.insert(id)
            }
        }
        return bundleIDs
    }

    /// Resolves both a process's direct bundle identifier and the outermost enclosing
    /// `.app` bundle's `CFBundleIdentifier` for nested helper apps/XPC services (#16).
    nonisolated static func enclosingAppBundleIDs(
        bundleURL: URL?,
        executableURL: URL? = nil,
        directBundleID: String? = nil,
        bundleIdentifierLookup: (URL) -> String? = { Bundle(url: $0)?.bundleIdentifier }
    ) -> Set<String> {
        var resolved = Set<String>()
        if let directBundleID, !directBundleID.isEmpty {
            resolved.insert(directBundleID)
            // System WebKit GPU/Audio XPC helpers reside in `/System/Library/Frameworks/WebKit.framework`
            // when playing audio for Safari.
            if directBundleID.hasPrefix("com.apple.WebKit.") {
                resolved.insert("com.apple.Safari")
            }
        }
        for candidateURL in [bundleURL, executableURL].compactMap({ $0 }) {
            let components = candidateURL.standardizedFileURL.pathComponents
            var currentPath = ""
            for component in components {
                if currentPath.isEmpty && component == "/" {
                    currentPath = "/"
                } else if currentPath == "/" {
                    currentPath += component
                } else {
                    currentPath += "/" + component
                }
                if component.hasSuffix(".app") {
                    let outerAppURL = URL(fileURLWithPath: currentPath, isDirectory: true)
                    if let outerID = bundleIdentifierLookup(outerAppURL), !outerID.isEmpty {
                        resolved.insert(outerID)
                    }
                    break
                }
            }
        }
        return resolved
    }

    private func processObjects() -> [AudioObjectID]? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size
        ) == noErr, size > 0 else { return nil }

        let count = Int(size) / MemoryLayout<AudioObjectID>.size
        var objects = [AudioObjectID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &objects
        ) == noErr else { return nil }
        return objects
    }

    private func processID(of object: AudioObjectID) -> pid_t? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyPID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var pid: pid_t = 0
        var size = UInt32(MemoryLayout<pid_t>.size)
        guard AudioObjectGetPropertyData(
            object, &address, 0, nil, &size, &pid
        ) == noErr else { return nil }
        return pid
    }
}
