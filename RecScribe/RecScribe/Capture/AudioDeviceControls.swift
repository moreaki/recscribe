import CoreAudio
import Foundation

nonisolated struct AudioOutputDevice: Identifiable, Equatable, Sendable {
    var id: String { uid }
    var uid: String
    var name: String
    var sampleRate: Double = 0
}

/// Reads capabilities. Writes only exposed, writable scalar controls, never defaults.
nonisolated enum AudioDeviceControls {
    static let volumeElementRange: ClosedRange<UInt32> = 0...32

    /// Match the generated identity of AVAudioEngine's default-I/O helpers.
    /// Display names and aggregate transport alone never exclude a device.
    static func isInternalDefaultHelper(uid: String) -> Bool {
        let prefix = "CADefaultDeviceAggregate-"
        guard uid.hasPrefix(prefix) else { return false }
        let parts = uid.dropFirst(prefix.count).split(separator: "-", omittingEmptySubsequences: false)
        return parts.count == 2 && parts.allSatisfy {
            !$0.isEmpty && $0.utf8.allSatisfy { (48...57).contains($0) }
        }
    }

    struct Volume: Identifiable, Sendable {
        var id: UInt32 { element }
        var device: AudioDeviceID
        var input: Bool
        var element: UInt32
        var value: Float
    }
    static func address(_ selector: AudioObjectPropertySelector, input: Bool? = nil, element: UInt32 = 0) -> AudioObjectPropertyAddress {
        .init(mSelector: selector, mScope: input.map { $0 ? kAudioDevicePropertyScopeInput : kAudioDevicePropertyScopeOutput } ?? kAudioObjectPropertyScopeGlobal, mElement: element)
    }
    static func devices() -> [AudioDeviceID] {
        var property = address(kAudioHardwarePropertyDevices), size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &property, 0, nil, &size) == noErr else { return [] }
        var result = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &property, 0, nil, &size, &result) == noErr else { return [] }
        return result
    }
    static func string(_ device: AudioDeviceID, _ selector: AudioObjectPropertySelector) -> String? {
        var property = address(selector), value: CFString = "" as CFString
        var size = UInt32(MemoryLayout<CFString>.size)
        let status = withUnsafeMutablePointer(to: &value) { AudioObjectGetPropertyData(device, &property, 0, nil, &size, $0) }
        return status == noErr ? value as String : nil
    }
    static func device(uid: String?) -> AudioDeviceID? {
        guard let uid else { return nil }
        return devices().first { string($0, kAudioDevicePropertyDeviceUID) == uid }
    }
    static func outputs() -> [AudioOutputDevice] {
        devices().compactMap { device in
            var property = address(kAudioDevicePropertyStreams, input: false), size: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(device, &property, 0, nil, &size) == noErr, size > 0,
                  let uid = string(device, kAudioDevicePropertyDeviceUID),
                  !isInternalDefaultHelper(uid: uid) else { return nil }
            var rateProperty = address(kAudioDevicePropertyNominalSampleRate), rate: Double = 0
            var bytes = UInt32(MemoryLayout<Double>.size)
            _ = AudioObjectGetPropertyData(device, &rateProperty, 0, nil, &bytes, &rate)
            var aliveProperty = address(kAudioDevicePropertyDeviceIsAlive), alive: UInt32 = 1
            bytes = UInt32(MemoryLayout<UInt32>.size)
            _ = AudioObjectGetPropertyData(device, &aliveProperty, 0, nil, &bytes, &alive)
            guard alive != 0 else { return nil }
            return .init(uid: uid, name: string(device, kAudioObjectPropertyName) ?? uid, sampleRate: rate)
        }
    }
    static func defaultOutputUID() -> String? {
        var property = address(kAudioHardwarePropertyDefaultOutputDevice), device = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &property, 0, nil, &size, &device) == noErr else { return nil }
        return string(device, kAudioDevicePropertyDeviceUID)
    }
    static func defaultInputUID() -> String? {
        var property = address(kAudioHardwarePropertyDefaultInputDevice), device = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &property, 0, nil, &size, &device) == noErr else { return nil }
        return string(device, kAudioDevicePropertyDeviceUID)
    }
    static func aggregateSubDeviceUIDs(device: AudioDeviceID) -> [String] {
        var transport: UInt32 = 0
        var transportProp = address(kAudioDevicePropertyTransportType)
        var bytes = UInt32(MemoryLayout<UInt32>.size)
        _ = AudioObjectGetPropertyData(device, &transportProp, 0, nil, &bytes, &transport)
        guard transport == kAudioDeviceTransportTypeAggregate else { return [] }
        var property = address(kAudioAggregateDevicePropertyActiveSubDeviceList)
        bytes = 0
        guard AudioObjectGetPropertyDataSize(device, &property, 0, nil, &bytes) == noErr, bytes > 0 else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(bytes) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(device, &property, 0, nil, &bytes, &ids) == noErr else { return [] }
        return ids.compactMap { string($0, kAudioDevicePropertyDeviceUID) }
    }
    static func supportedVolumeElements(
        device: AudioDeviceID,
        input: Bool,
        isSupported: (AudioDeviceID, inout AudioObjectPropertyAddress) -> Bool = { dev, property in
            var writable = DarwinBoolean(false)
            return AudioObjectHasProperty(dev, &property)
                && AudioObjectIsPropertySettable(dev, &property, &writable) == noErr
                && writable.boolValue
        }
    ) -> [UInt32] {
        let elements = volumeElementRange.filter { element in
            var property = address(kAudioDevicePropertyVolumeScalar, input: input, element: element)
            return isSupported(device, &property)
        }
        return elements.first == 0 ? Array(elements.prefix(1)) : elements
    }
    static func volumes(uid: String?, input: Bool) -> [Volume] {
        guard let device = device(uid: uid) else { return [] }
        return supportedVolumeElements(device: device, input: input).compactMap { element -> Volume? in
            var property = address(kAudioDevicePropertyVolumeScalar, input: input, element: element)
            var value: Float = 0
            var size = UInt32(MemoryLayout<Float>.size)
            guard AudioObjectGetPropertyData(device, &property, 0, nil, &size, &value) == noErr, value.isFinite else { return nil }
            return .init(device: device, input: input, element: element, value: value)
        }
    }
    static func set(_ control: Volume, value: Float) -> Bool {
        guard value.isFinite, (0...1).contains(value) else { return false }
        var property = address(kAudioDevicePropertyVolumeScalar, input: control.input, element: control.element)
        var writable = DarwinBoolean(false), newValue = value
        guard AudioObjectIsPropertySettable(control.device, &property, &writable) == noErr, writable.boolValue else { return false }
        return AudioObjectSetPropertyData(control.device, &property, 0, nil, UInt32(MemoryLayout<Float>.size), &newValue) == noErr
    }
}
