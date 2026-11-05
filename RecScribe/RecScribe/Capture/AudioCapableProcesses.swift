import AppKit
import CoreAudio

@MainActor protocol AudioCapableProcessListing: AnyObject {
    func audioCapableBundleIDs() -> Set<String>?
}

/// Core Audio presence is used for activity badges, never to exclude an idle
/// application from the capture picker. Discovery performs no capture request.
@MainActor final class AudioCapableProcesses: AudioCapableProcessListing {
    func audioCapableBundleIDs() -> Set<String>? {
        guard let processes: [AudioObjectID] = AudioPropertyAccess.integers(
            object: AudioObjectID(kAudioObjectSystemObject), selector: kAudioHardwarePropertyProcessObjectList) else { return nil }
        return processes.reduce(into: Set<String>()) { result, process in
            guard let pid: Int32 = AudioPropertyAccess.integer(object: process, selector: kAudioProcessPropertyPID),
                  let application = NSRunningApplication(processIdentifier: pid) else { return }
            result.formUnion(Self.enclosingAppBundleIDs(bundleURL: application.bundleURL,
                executableURL: application.executableURL, directBundleID: application.bundleIdentifier))
        }
    }

    nonisolated static func enclosingAppBundleIDs(bundleURL: URL?, executableURL: URL? = nil,
        directBundleID: String? = nil,
        bundleIdentifierLookup: (URL) -> String? = { Bundle(url: $0)?.bundleIdentifier }) -> Set<String> {
        var names = Set<String>()
        if let directBundleID, !directBundleID.isEmpty {
            names.insert(directBundleID)
            if directBundleID.hasPrefix("com.apple.WebKit.") { names.insert("com.apple.Safari") }
        }
        for path in [bundleURL, executableURL].compactMap({ $0?.standardizedFileURL }) {
            let pieces = path.pathComponents
            guard let root = pieces.firstIndex(where: { $0.hasSuffix(".app") }) else { continue }
            let bundle = URL(fileURLWithPath: NSString.path(withComponents: Array(pieces[...root])), isDirectory: true)
            if let identifier = bundleIdentifierLookup(bundle), !identifier.isEmpty { names.insert(identifier) }
        }
        return names
    }
}

/// Checked, prompt-free HAL integer reads shared by discovery services. Recheck
/// byte counts because the device/process list can change between the two calls.
nonisolated enum AudioPropertyAccess {
    static func integers<T: FixedWidthInteger>(object: AudioObjectID, selector: AudioObjectPropertySelector) -> [T]? {
        var property = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                                   mElement: kAudioObjectPropertyElementMain)
        var bytes: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(object, &property, 0, nil, &bytes) == noErr,
              Int(bytes).isMultiple(of: MemoryLayout<T>.stride) else { return nil }
        if bytes == 0 { return [] }
        var result = [T](repeating: 0, count: Int(bytes) / MemoryLayout<T>.stride)
        let capacity = bytes
        let status = result.withUnsafeMutableBytes {
            AudioObjectGetPropertyData(object, &property, 0, nil, &bytes, $0.baseAddress!)
        }
        guard status == noErr, bytes <= capacity, Int(bytes).isMultiple(of: MemoryLayout<T>.stride) else { return nil }
        return Array(result.prefix(Int(bytes) / MemoryLayout<T>.stride))
    }

    static func integer<T: FixedWidthInteger>(object: AudioObjectID, selector: AudioObjectPropertySelector) -> T? {
        var property = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                                   mElement: kAudioObjectPropertyElementMain)
        var value: T = 0
        var bytes = UInt32(MemoryLayout<T>.size)
        let status = withUnsafeMutablePointer(to: &value) {
            AudioObjectGetPropertyData(object, &property, 0, nil, &bytes, $0)
        }
        return status == noErr && bytes == MemoryLayout<T>.size ? value : nil
    }
}
