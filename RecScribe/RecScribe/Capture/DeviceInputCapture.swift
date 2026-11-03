import AVFoundation
import CoreAudio
import os

/// One input-only engine per explicitly chosen UID. No output path and no global
/// default/aggregate changes. A tap transfers a bounded copy with host-clock time.
@MainActor
final class DeviceInputCapture {
    let uid: String
    let track: CaptureTrack
    private var engine: AVAudioEngine?
    private var observer: NSObjectProtocol?
    private var generation = UUID()
    private var configuration = DeviceInputConfigurationPolicy()
    private var selectedDevice: AudioDeviceID?
    private var expectedFormat: AVAudioFormat?
    private var configurationFailed = false
    private let tap: DeviceInputTap
    private let onFailure: @MainActor @Sendable (String) -> Void
    init(uid: String, callback: @escaping @Sendable (CapturedAudioSample) -> Void,
         onFailure: @escaping @MainActor @Sendable (String) -> Void) {
        self.uid = uid; self.track = .input(uid); self.onFailure = onFailure
        tap = DeviceInputTap(track: .input(uid), callback: callback, onFailure: onFailure)
    }
    func start() throws {
        guard engine == nil else { throw AudioRecorderError.alreadyRecording }
        guard let device = AudioDeviceControls.device(uid: uid) else { throw AudioSourceError.micNotAvailable(uid) }
        let next = AVAudioEngine()
        guard let unit = next.inputNode.audioUnit else { throw SessionError.invalid("Input audio unit is unavailable") }
        var selected = device
        guard AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &selected, UInt32(MemoryLayout<AudioDeviceID>.size)) == noErr else {
            throw SessionError.invalid("The selected input cannot be opened independently")
        }
        let format = next.inputNode.outputFormat(forBus: 0)
        guard (1...32).contains(Int(format.channelCount)), format.sampleRate.isFinite,
              (1...384_000).contains(format.sampleRate), format.commonFormat == .pcmFormatFloat32 else {
            throw SessionError.invalid("Input must provide Float32 audio with 1–32 channels")
        }
        tap.begin(format: format)
        next.inputNode.installTap(onBus: 0, bufferSize: 1024, format: format, block: tap.block)
        engine = next
        selectedDevice = device; expectedFormat = format
        generation = UUID(); let id = generation
        configuration = .init(startedAt: ProcessInfo.processInfo.systemUptime)
        configurationFailed = false
        observer = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: next, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.generation == id else { return }
                self.configurationChanged()
            }
        }
        do { next.prepare(); try next.start() }
        catch { stop(); throw error }
        Log.capture.notice("Input engine started selected_device=\(device) actual_device=\(self.currentDevice(next) ?? 0) channels=\(format.channelCount) rate=\(format.sampleRate) running=\(next.isRunning)")
        if !next.isRunning { configurationChanged() }
    }

    private func currentDevice(_ engine: AVAudioEngine) -> AudioDeviceID? {
        guard let unit = engine.inputNode.audioUnit else { return nil }
        var value = AudioDeviceID(0), size = UInt32(MemoryLayout<AudioDeviceID>.size)
        return AudioUnitGetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global,
            0, &value, &size) == noErr ? value : nil
    }

    private func configurationChanged() {
        guard let engine, let selectedDevice, let expectedFormat, !configurationFailed else { return }
        let actual = currentDevice(engine)
        let current = engine.inputNode.outputFormat(forBus: 0)
        var address = AudioDeviceControls.address(kAudioDevicePropertyDeviceIsAlive)
        var alive: UInt32 = 0, bytes = UInt32(MemoryLayout<UInt32>.size)
        let connected = AudioDeviceControls.device(uid: uid) == selectedDevice &&
            AudioObjectGetPropertyData(selectedDevice, &address, 0, nil, &bytes, &alive) == noErr && alive != 0
        let received = tap.receivedFrames
        let decision = configuration.evaluate(connected: connected, sameDevice: actual == selectedDevice,
            sameFormat: current == expectedFormat, running: engine.isRunning, receivedFrames: received,
            now: ProcessInfo.processInfo.systemUptime)
        Log.capture.notice("Input configuration selected_device=\(selectedDevice) actual_device=\(actual ?? 0) connected=\(connected) channels=\(current.channelCount) rate=\(current.sampleRate) running=\(engine.isRunning) received_frames=\(received) action=\(decision.rawValue, privacy: .public)")
        switch decision {
        case .ignore: return
        case .restart:
            do { try engine.start() }
            catch {
                configurationFailed = true
                Log.recordFailure(error, operation: "input_startup_recovery")
                onFailure("The selected input could not start after a configuration change; other sources continue.")
            }
        case .disconnected, .deviceChanged, .formatChanged, .interrupted:
            configurationFailed = true
            onFailure(decision.message)
        }
    }
    @discardableResult func stop() -> String? {
        generation = UUID()
        if let observer { NotificationCenter.default.removeObserver(observer); self.observer = nil }
        // Finish holds the tap lock until every already-entered callback has
        // submitted its copy, so no late buffer can overtake recorder sealing.
        let failed = tap.finish()
        engine?.stop(); engine?.inputNode.removeTap(onBus: 0); engine = nil
        selectedDevice = nil; expectedFormat = nil
        return failed ? "Input timestamps, format or packet budget changed; its track is incomplete. Other sources continued." : nil
    }
}

/// Startup may deliver queued I/O reconfiguration notifications. Never switch
/// devices or accept a changed format, and never silently resume a partial take.
nonisolated struct DeviceInputConfigurationPolicy {
    enum Decision: String {
        case ignore, restart, disconnected, deviceChanged, formatChanged, interrupted
        var message: String {
            switch self {
            case .disconnected: "The selected input disconnected; its track is incomplete. Other sources continue."
            case .deviceChanged: "The input engine changed away from the selected device; its track is incomplete. Other sources continue."
            case .formatChanged: "The selected input changed audio format; its track is incomplete. Other sources continue."
            default: "The selected input engine stopped after a configuration change; its track is incomplete. Other sources continue."
            }
        }
    }
    var startedAt: TimeInterval = 0
    private(set) var restarts = 0
    mutating func evaluate(connected: Bool, sameDevice: Bool, sameFormat: Bool, running: Bool,
                           receivedFrames: Int64, now: TimeInterval) -> Decision {
        guard connected else { return .disconnected }
        guard sameDevice else { return .deviceChanged }
        guard sameFormat else { return .formatChanged }
        if running { return .ignore }
        guard receivedFrames == 0, (0...3).contains(now - startedAt), restarts < 2 else { return .interrupted }
        restarts += 1
        return .restart
    }
}

nonisolated final class DeviceInputTap: Sendable {
    private struct State { var accepting = false; var format: AVAudioFormat?; var failed = false; var receivedFrames: Int64 = 0 }
    private let state = OSAllocatedUnfairLock(initialState: State())
    private let track: CaptureTrack
    private let callback: @Sendable (CapturedAudioSample) -> Void
    private let onFailure: @MainActor @Sendable (String) -> Void
    init(track: CaptureTrack, callback: @escaping @Sendable (CapturedAudioSample) -> Void,
         onFailure: @escaping @MainActor @Sendable (String) -> Void) {
        self.track = track; self.callback = callback; self.onFailure = onFailure
    }
    /// Constructed outside any actor context. The legacy ObjC tap type is
    /// non-Sendable and otherwise inherits the installer's MainActor isolation.
    var block: @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void {
        { [self] buffer, time in receive(buffer, time: time) }
    }
    func begin(format: AVAudioFormat) { state.withLock { $0 = .init(accepting: true, format: format) } }
    @discardableResult func finish() -> Bool { state.withLock { $0.accepting = false; return $0.failed } }
    var receivedFrames: Int64 { state.withLock { $0.receivedFrames } }
    func receive(_ buffer: AVAudioPCMBuffer, time: AVAudioTime) {
        let borrowed = BorrowedTapPCM(buffer: buffer)
        state.withLock { s in
            let buffer = borrowed.buffer
            guard s.accepting, buffer.frameLength > 0 else { return }
            guard time.isHostTimeValid, buffer.format == s.format,
                  buffer.format.commonFormat == .pcmFormatFloat32,
                  Double(buffer.frameLength) <= buffer.format.sampleRate * 0.25,
                  (1...32).contains(Int(buffer.format.channelCount)),
                  Int(buffer.frameLength) * Int(buffer.format.channelCount) * 4 <= 4 * 1024 * 1024,
                  let copy = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameLength),
                  let source = buffer.floatChannelData, let destination = copy.floatChannelData else {
                s.accepting = false
                if !s.failed {
                    s.failed = true
                    Task { @MainActor [onFailure] in onFailure("Input timestamps, format or packet budget changed; its track is incomplete. Other sources continue.") }
                }
                return
            }
            copy.frameLength = buffer.frameLength
            let channels = Int(buffer.format.channelCount), frames = Int(buffer.frameLength)
            if buffer.format.isInterleaved { destination[0].update(from: source[0], count: frames * channels) }
            else { for channel in 0..<channels { destination[channel].update(from: source[channel], count: frames) } }
            callback(.init(track: track, presentationTime: AVAudioTime.seconds(forHostTime: time.hostTime), buffer: copy))
            s.receivedFrames += Int64(buffer.frameLength)
        }
    }
}

/// Only crosses a synchronous lock closure on the tap thread; never queued or
/// retained after receive returns. The producer still owns this borrowed PCM.
private nonisolated struct BorrowedTapPCM: @unchecked Sendable { let buffer: AVAudioPCMBuffer }
