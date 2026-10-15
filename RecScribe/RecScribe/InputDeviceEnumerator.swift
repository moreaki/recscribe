//
//  InputDeviceEnumerator.swift
//  RecScribe
//
//  Lists microphones and other audio input devices for the capture-source
//  picker (BL-130).
//
//  Discovery is prompt-free. Core Audio adds channel/rate capabilities and
//  eligible virtual/aggregate inputs; UID identity is retained for SCK.
//

import AVFoundation
import CoreAudio

/// One input device the picker can offer.
nonisolated struct InputDeviceInfo: Identifiable, Sendable, Equatable {
    /// `AVCaptureDevice.uniqueID`, passed straight to `microphoneCaptureDeviceID`.
    var id: String { uid }
    let uid: String
    let name: String
    var inputChannels: Int? = nil
    var sampleRate: Double? = nil
    var transport: UInt32 = 0
    var channelLabels: [String] = []
    var aggregateMembers: [String] = []
    var isAggregate: Bool { transport == kAudioDeviceTransportTypeAggregate }
    var isVirtual: Bool { transport == kAudioDeviceTransportTypeVirtual }
    var mayLoopBack: Bool {
        isVirtual || ["loopback", "blackhole", "soundflower", "vb-cable"].contains { name.localizedCaseInsensitiveContains($0) }
    }
    var kindLabel: String { isAggregate ? "Aggregate" : (isVirtual ? "Virtual / possible loopback" : "Hardware input") }
}

@MainActor
protocol InputDeviceEnumerating: AnyObject {
    /// Currently connected input devices, in the order macOS reports them.
    func availableInputDevices() -> [InputDeviceInfo]
}

@MainActor
final class InputDeviceEnumerator: InputDeviceEnumerating {

    func availableInputDevices() -> [InputDeviceInfo] {
        // `.microphone` covers built-in and USB/Thunderbolt interfaces;
        // `.external` picks up devices macOS classifies separately.
        let session = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone, .external],
            mediaType: .audio,
            position: .unspecified
        )
        var seen = Set<String>()
        let discovered = session.devices
            // A device can be reported by more than one type.
            .filter { seen.insert($0.uniqueID).inserted }
            // Names come from macOS verbatim — the user recognises "Scarlett 2i2
            // 4th Gen" and would not recognise anything we invented.
            .map { InputDeviceInfo(uid: $0.uniqueID, name: $0.localizedName) }
        let hardware = Self.coreAudioInputs()
        let capabilities = Dictionary(hardware.map { ($0.uid, $0) }, uniquingKeysWith: { first, _ in first })
        let merged = discovered.map { capabilities[$0.uid] ?? $0 }
        return merged + hardware.filter { !seen.contains($0.uid) }
    }

    private static func coreAudioInputs() -> [InputDeviceInfo] {
        var devicesAddress = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &devicesAddress, 0, nil, &size) == noErr else { return [] }
        var devices = Array(repeating: AudioDeviceID(0), count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &devicesAddress, 0, nil, &size, &devices) == noErr else { return [] }
        return devices.compactMap { device in
            var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamConfiguration,
                mScope: kAudioDevicePropertyScopeInput, mElement: kAudioObjectPropertyElementMain)
            var bytes: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(device, &address, 0, nil, &bytes) == noErr,
                  bytes >= MemoryLayout<AudioBufferList>.size else { return nil }
            let memory = UnsafeMutableRawPointer.allocate(byteCount: Int(bytes), alignment: MemoryLayout<AudioBufferList>.alignment)
            defer { memory.deallocate() }
            guard AudioObjectGetPropertyData(device, &address, 0, nil, &bytes, memory) == noErr else { return nil }
            let list = UnsafeMutableAudioBufferListPointer(memory.assumingMemoryBound(to: AudioBufferList.self))
            let channels = list.reduce(0) { $0 + Int($1.mNumberChannels) }
            guard channels > 0 else { return nil }
            func string(_ selector: AudioObjectPropertySelector) -> String? {
                var property = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                    mElement: kAudioObjectPropertyElementMain)
                var value: CFString = "" as CFString
                var count = UInt32(MemoryLayout<CFString>.size)
                let status = withUnsafeMutablePointer(to: &value) {
                    AudioObjectGetPropertyData(device, &property, 0, nil, &count, $0)
                }
                guard status == noErr else { return nil }
                return value as String
            }
            guard let uid = string(kAudioDevicePropertyDeviceUID), let name = string(kAudioObjectPropertyName) else { return nil }
            var rate = Float64(0)
            var count = UInt32(MemoryLayout<Float64>.size)
            address.mSelector = kAudioDevicePropertyNominalSampleRate; address.mScope = kAudioObjectPropertyScopeGlobal
            let status = AudioObjectGetPropertyData(device, &address, 0, nil, &count, &rate)
            var transport: UInt32 = 0
            var property = AudioDeviceControls.address(kAudioDevicePropertyTransportType)
            bytes = UInt32(MemoryLayout<UInt32>.size)
            _ = AudioObjectGetPropertyData(device, &property, 0, nil, &bytes, &transport)
            var labels: [String] = []
            for channel in 1...min(channels, 32) {
                var nameProperty = AudioDeviceControls.address(kAudioObjectPropertyElementName, input: true, element: UInt32(channel))
                var label: CFString = "" as CFString
                bytes = UInt32(MemoryLayout<CFString>.size)
                let result = withUnsafeMutablePointer(to: &label) { AudioObjectGetPropertyData(device, &nameProperty, 0, nil, &bytes, $0) }
                labels.append(result == noErr && !(label as String).isEmpty ? label as String : "Channel \(channel)")
            }
            var members: [String] = []
            if transport == kAudioDeviceTransportTypeAggregate {
                property = AudioDeviceControls.address(kAudioAggregateDevicePropertyActiveSubDeviceList)
                bytes = 0
                if AudioObjectGetPropertyDataSize(device, &property, 0, nil, &bytes) == noErr {
                    var ids = [AudioDeviceID](repeating: 0, count: Int(bytes) / MemoryLayout<AudioDeviceID>.size)
                    if AudioObjectGetPropertyData(device, &property, 0, nil, &bytes, &ids) == noErr {
                        members = ids.compactMap { AudioDeviceControls.string($0, kAudioDevicePropertyDeviceUID) }
                    }
                }
            }
            return InputDeviceInfo(uid: uid, name: name, inputChannels: channels,
                sampleRate: status == noErr && rate.isFinite && rate > 0 ? rate : nil,
                transport: transport, channelLabels: labels, aggregateMembers: members)
        }
    }
}
