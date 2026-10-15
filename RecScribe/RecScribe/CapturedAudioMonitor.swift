import AVFoundation
import Combine
import CoreAudio
import os

/// Optional output-only graph fed by the committed mix. Never opens a microphone.
/// Its bounded 250-ms queue can fail independently without blocking the writer.
@MainActor
final class CapturedAudioMonitor: ObservableObject {
    static let shared = CapturedAudioMonitor()
    @Published private(set) var enabled = false
    @Published private(set) var warning: String?
    let levels: PlaybackLevels
    nonisolated private let queue = DispatchQueue(label: "com.moreaki.recscribe.monitor", qos: .userInteractive)
    nonisolated private let state = OSAllocatedUnfairLock(initialState: (enabled: false, frames: 0, generation: 0))
    nonisolated(unsafe) private var engine: AVAudioEngine?
    nonisolated(unsafe) private var node: AVAudioPlayerNode?
    private var observation: AnyCancellable?
    private var routeTask: Task<Void, Never>?
    private var appliedRoute: String?
    private var appliedRate: Double?
    init(defaults: UserDefaults = .standard) {
        levels = PlaybackLevels(defaults: defaults, key: "audio.monitorLevels.v1", initialVolume: 0.5)
        observation = levels.$value.dropFirst().sink { [weak self] _ in
            Task { @MainActor [weak self] in self?.configureOutput() }
        }
    }
    func setEnabled(_ enabled: Bool, source: AudioSource) {
        if enabled, let uid = source.microphoneUID, Self.isLoopback(uid) {
            setEnabled(false, source: .systemAll)
            warning = "Monitoring is unavailable for virtual or aggregate inputs to avoid audio feedback. Recording is unaffected."
            return
        }
        self.enabled = enabled; warning = nil
        state.withLock { s in s.enabled = enabled; s.generation += 1 }
        queue.async { [self] in engine?.stop(); engine = nil; node = nil }
        appliedRoute = nil
        routeTask?.cancel(); routeTask = nil
        if enabled {
            configureOutput(force: true)
            routeTask = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(2))
                    guard !Task.isCancelled, let self else { return }
                    configureOutput()
                }
            }
        }
    }
    func recordingStopped() {
        // Release the output device between takes; never leave queued sound playing.
        setEnabled(false, source: .systemAll)
    }
    private func configureOutput(force: Bool = false) {
        guard enabled else { return }
        let settings = levels.value
        let outputs = AudioDeviceControls.outputs()
        let uid = outputs.contains(where: { $0.uid == settings.outputUID }) ? settings.outputUID : AudioDeviceControls.defaultOutputUID()
        if let uid, Self.isLoopback(uid) {
            setEnabled(false, source: .systemAll)
            warning = "Live monitoring requires a physical output device. Select headphones to avoid loopback feedback."
            return
        }
        let rate = outputs.first { $0.uid == uid }?.sampleRate
        let changed = force || uid != appliedRoute || rate != appliedRate
        appliedRoute = uid; appliedRate = rate
        let generation = state.withLock { $0.generation }
        queue.async { [self] in
            guard state.withLock({ $0.enabled && $0.generation == generation }) else { return }
            do {
                if changed || engine == nil {
                    engine?.stop(); engine = nil; node = nil
                    let next = AVAudioEngine(), player = AVAudioPlayerNode()
                    if let uid, var device = AudioDeviceControls.device(uid: uid), let unit = next.outputNode.audioUnit {
                        let result = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &device, UInt32(MemoryLayout<AudioDeviceID>.size))
                        guard result == noErr else { throw MonitorError.deviceUnavailable }
                    }
                    next.attach(player)
                    next.connect(player, to: next.mainMixerNode, format: AudioFormatNormalizer.canonical)
                    next.mainMixerNode.outputVolume = settings.muted ? 0 : settings.volume
                    try next.start(); player.play()
                    engine = next; node = player
                }
                engine?.mainMixerNode.outputVolume = settings.muted ? 0 : settings.volume
                guard engine?.isRunning == true else { throw MonitorError.deviceUnavailable }
            } catch { fail("Live monitoring stopped: \(error.localizedDescription) Recording is unaffected.", generation: generation) }
        }
    }
    nonisolated private func fail(_ message: String, generation: Int) {
        guard state.withLock({ s in
            guard s.generation == generation else { return false }
            s.enabled = false; return true
        }) else { return }
        engine?.stop(); engine = nil; node = nil
        Task { @MainActor [weak self] in
            guard let self, state.withLock({ $0.generation == generation }) else { return }
            enabled = false; warning = message; routeTask?.cancel(); routeTask = nil
        }
    }
    nonisolated func submit(_ input: AVAudioPCMBuffer) {
        let frames = Int(input.frameLength)
        let generation = state.withLock { s -> Int? in
            guard s.enabled else { return nil }
            guard frames <= 12_000, s.frames + frames <= 12_000 else { s.enabled = false; return -(s.generation + 1) }
            s.frames += frames; return s.generation
        }
        guard let generation else { return }
        if generation < 0 {
            let current = -generation - 1
            queue.async { [self] in fail("Live monitoring could not keep up and was disabled. Recording is unaffected.", generation: current) }
            return
        }
        // The writer owns input; take a bounded copy before it can be consumed.
        guard let copy = AVAudioPCMBuffer(pcmFormat: input.format, frameCapacity: input.frameLength),
              let src = input.floatChannelData, let dst = copy.floatChannelData else {
            state.withLock { $0.frames -= frames }; return
        }
        copy.frameLength = input.frameLength
        for channel in 0..<Int(input.format.channelCount) { dst[channel].update(from: src[channel], count: frames) }
        let owned = MonitorPCM(buffer: copy)
        queue.async { [self] in
            guard state.withLock({ $0.enabled && $0.generation == generation }), let node else {
                state.withLock { $0.frames -= frames }; return
            }
            node.scheduleBuffer(owned.buffer, completionCallbackType: .dataPlayedBack) { [state] _ in
                state.withLock { $0.frames -= frames }
            }
        }
    }
    private static func isLoopback(_ uid: String) -> Bool {
        guard let device = AudioDeviceControls.device(uid: uid) else { return true }
        var address = AudioDeviceControls.address(kAudioDevicePropertyTransportType), transport: UInt32 = 0
        var bytes = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &bytes, &transport) == noErr else { return true }
        return [kAudioDeviceTransportTypeVirtual, kAudioDeviceTransportTypeAggregate].contains(transport)
    }
    deinit { routeTask?.cancel() }
}
private nonisolated struct MonitorPCM: @unchecked Sendable { let buffer: AVAudioPCMBuffer }
