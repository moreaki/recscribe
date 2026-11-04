import AVFoundation
import CoreAudio
import os

@MainActor protocol InputCaptureSession: AnyObject {
    var uid: String { get }
    func start() throws
    @discardableResult func stop() -> String?
    func checkHardwareStatus()
}

@MainActor struct InputCaptureRequest {
    let uid: String
    let track: CaptureTrack
    let callback: @Sendable (CapturedAudioSample) -> Void
    let failure: @MainActor @Sendable (String) -> Void
}

/// The engine boundary is injectable so startup ordering and late configuration
/// notifications can be exercised without opening a real device or asking for TCC.
@MainActor protocol DeviceInputEngine: AnyObject {
    var snapshot: DeviceInputEngineSnapshot { get }
    func bind() throws
    func observe(_ changed: @escaping @MainActor @Sendable () -> Void)
    func installAndStart(format: AVAudioFormat, block: @escaping @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void) throws
    func stop()
}

struct DeviceInputEngineSnapshot: Equatable {
    let connected: Bool
    let selected: Bool
    let format: AVAudioFormat
    let aggregateMembers: [String]
    let running: Bool
    var hardwareFormatMatches = true
    var usable: Bool {
        connected && selected && hardwareFormatMatches && (1...32).contains(Int(format.channelCount)) &&
            format.sampleRate.isFinite && (1...384_000).contains(format.sampleRate) &&
            format.commonFormat == .pcmFormatFloat32
    }
    func sameConfiguration(as other: Self) -> Bool {
        connected == other.connected && selected == other.selected && format == other.format && hardwareFormatMatches == other.hardwareFormatMatches && aggregateMembers == other.aggregateMembers
    }
}

@MainActor private final class NativeDeviceInputEngine: DeviceInputEngine {
    private let uid: String
    private let device: AudioDeviceID
    private let engine = AVAudioEngine()
    private var observer: NSObjectProtocol?
    private var installed = false
    init(uid: String) throws {
        self.uid = uid
        guard let device = AudioDeviceControls.device(uid: uid) else { throw AudioSourceError.micNotAvailable(uid) }
        self.device = device
    }
    func observe(_ changed: @escaping @MainActor @Sendable () -> Void) {
        observer = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { _ in
            Task { @MainActor in changed() }
        }
    }
    func bind() throws {
        guard let unit = engine.inputNode.audioUnit else { throw SessionError.invalid("Input audio unit is unavailable") }
        var selected = device
        guard AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &selected, UInt32(MemoryLayout<AudioDeviceID>.size)) == noErr else {
            throw SessionError.invalid("The selected input cannot be opened independently")
        }
    }
    var snapshot: DeviceInputEngineSnapshot {
        var actual: AudioDeviceID = 0, size = UInt32(MemoryLayout<AudioDeviceID>.size)
        if let unit = engine.inputNode.audioUnit {
            _ = AudioUnitGetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &actual, &size)
        }
        var address = AudioDeviceControls.address(kAudioDevicePropertyDeviceIsAlive)
        var alive: UInt32 = 0, bytes = UInt32(MemoryLayout<UInt32>.size)
        let connected = AudioDeviceControls.device(uid: uid) == device &&
            AudioObjectGetPropertyData(device, &address, 0, nil, &bytes, &alive) == noErr && alive != 0
        let format = engine.inputNode.outputFormat(forBus: 0)
        return .init(connected: connected, selected: actual == device, format: format,
            aggregateMembers: AudioDeviceControls.aggregateSubDeviceUIDs(device: device), running: engine.isRunning,
            hardwareFormatMatches: matchesHardware(format))
    }
    private func matchesHardware(_ format: AVAudioFormat) -> Bool {
        var property = AudioDeviceControls.address(kAudioDevicePropertyNominalSampleRate)
        var rate: Double = 0, bytes = UInt32(MemoryLayout<Double>.size)
        guard AudioObjectGetPropertyData(device, &property, 0, nil, &bytes, &rate) == noErr,
              abs(rate - format.sampleRate) < 0.01 else { return false }
        property = AudioDeviceControls.address(kAudioDevicePropertyStreamConfiguration, input: true)
        bytes = 0
        guard AudioObjectGetPropertyDataSize(device, &property, 0, nil, &bytes) == noErr,
              bytes >= MemoryLayout<AudioBufferList>.size, bytes <= 65_536 else { return false }
        let memory = UnsafeMutableRawPointer.allocate(byteCount: Int(bytes), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { memory.deallocate() }
        guard AudioObjectGetPropertyData(device, &property, 0, nil, &bytes, memory) == noErr else { return false }
        let channels = UnsafeMutableAudioBufferListPointer(memory.assumingMemoryBound(to: AudioBufferList.self)).reduce(0) { $0 + Int($1.mNumberChannels) }
        return channels == Int(format.channelCount)
    }
    func installAndStart(format: AVAudioFormat, block: @escaping @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void) throws {
        engine.inputNode.installTap(onBus: 0, bufferSize: 1024, format: format, block: block)
        installed = true
        engine.prepare()
        try engine.start()
    }
    func stop() {
        if let observer { NotificationCenter.default.removeObserver(observer); self.observer = nil }
        engine.stop()
        if installed { engine.inputNode.removeTap(onBus: 0); installed = false }
    }
}

/// One input-only engine per selected UID. Startup settles on the main run loop,
/// then waits for PCM, with at most three fresh engines. No timer remains once
/// audio arrives, and a failed startup waits for a new hardware event to rejoin.
@MainActor final class DeviceInputCapture: InputCaptureSession {
    let uid: String
    let track: CaptureTrack
    private var engine: (any DeviceInputEngine)?
    private var generation = UUID()
    private var engineID = UUID()
    private var configurationRevision = 0
    private var expected: DeviceInputEngineSnapshot?
    private var starting = false
    private var failed = false
    private var startupTask: Task<Void, Never>?
    private var tap: DeviceInputTap?
    private let factory: @MainActor () throws -> any DeviceInputEngine
    private let sleep: @MainActor (Duration) async throws -> Void
    private let callback: @Sendable (CapturedAudioSample) -> Void
    private let onFailure: @MainActor @Sendable (String) -> Void

    init(uid: String, track: CaptureTrack? = nil, callback: @escaping @Sendable (CapturedAudioSample) -> Void,
         onFailure: @escaping @MainActor @Sendable (String) -> Void,
         engineFactory: (@MainActor () throws -> any DeviceInputEngine)? = nil,
         sleep: @escaping @MainActor (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) {
        self.uid = uid; self.track = track ?? .input(uid)
        self.callback = callback; self.onFailure = onFailure
        self.factory = engineFactory ?? { try NativeDeviceInputEngine(uid: uid) }
        self.sleep = sleep
    }

    func start() throws {
        guard engine == nil, startupTask == nil else { throw AudioRecorderError.alreadyRecording }
        let first = try factory()
        generation = UUID(); let id = generation
        failed = false; starting = true
        do { try open(first, generation: id) }
        catch { stop(); throw error }
        startupTask = Task { [weak self] in
            guard let self else { return }
            defer { if self.generation == id { self.startupTask = nil; self.starting = false } }
            do {
                for attempt in 0..<3 {
                    try Task.checkCancellation()
                    guard self.generation == id else { return }
                    if attempt > 0 { try self.open(self.factory(), generation: id) }
                    guard let engine = self.engine else { return }
                    // Device binding reconfigures asynchronously. Require a quiet,
                    // stable selected-device snapshot before installing the tap.
                    var previous: DeviceInputEngineSnapshot?
                    var revision = self.configurationRevision
                    var settled: DeviceInputEngineSnapshot?
                    for _ in 0..<10 {
                        try await self.sleep(.milliseconds(100))
                        try Task.checkCancellation()
                        guard self.generation == id else { return }
                        let next = engine.snapshot
                        if next.usable, let previous, next.sameConfiguration(as: previous), revision == self.configurationRevision {
                            settled = next; break
                        }
                        previous = next; revision = self.configurationRevision
                    }
                    if let settled {
                        self.expected = settled
                        // Each engine gets a new sealed tap. Late callbacks from a
                        // removed engine can never enter the replacement's state.
                        let engineID = self.engineID
                        let tap = DeviceInputTap(track: self.track, callback: self.callback, onFailure: { [weak self] message in
                            guard let self, self.generation == id, self.engineID == engineID else { return }
                            self.fail(message)
                        })
                        self.tap = tap; tap.begin(format: settled.format)
                        Log.capture.notice("Input tap startup attempt=\(attempt + 1) channels=\(settled.format.channelCount) rate=\(settled.format.sampleRate)")
                        do { try engine.installAndStart(format: settled.format, block: tap.block) }
                        catch {
                            Log.recordFailure(error, operation: "input_startup")
                            if !tap.sealIfNoFrames() {
                                self.fail("The input engine failed after delivering audio; its track is incomplete. Other sources continue.")
                                return
                            }
                            self.closeEngine()
                            continue
                        }
                        for _ in 0..<3 {
                            try await self.sleep(.milliseconds(500))
                            try Task.checkCancellation()
                            guard self.generation == id, !self.failed else { return }
                            if tap.receivedFrames > 0 {
                                self.starting = false
                                self.checkHardwareStatus()
                                return
                            }
                        }
                        // The final PCM check and sealing share the callback's
                        // lock: never rebuild if a first packet won the deadline race.
                        if !tap.sealIfNoFrames() {
                            self.starting = false
                            self.checkHardwareStatus()
                            return
                        }
                    }
                    self.closeEngine()
                }
                self.fail("The selected input delivered no audio after bounded startup recovery. Check that the device is producing audio; other sources continue.")
            } catch is CancellationError { return }
            catch { self.fail("The selected input could not start; other sources continue. \(error.localizedDescription)") }
        }
    }

    private func open(_ engine: any DeviceInputEngine, generation id: UUID) throws {
        self.engine = engine; expected = nil
        engineID = UUID(); let engineID = self.engineID
        engine.observe { [weak self] in
            guard let self, self.generation == id, self.engineID == engineID else { return }
            self.configurationRevision &+= 1
            self.checkHardwareStatus()
        }
        try engine.bind()
    }

    func checkHardwareStatus() {
        guard !starting, !failed, let engine, let expected else { return }
        let snapshot = engine.snapshot
        let policy = DeviceInputConfigurationPolicy()
        let decision = policy.evaluate(connected: snapshot.connected, sameDevice: snapshot.selected,
            sameFormat: snapshot.hardwareFormatMatches && snapshot.format == expected.format,
            sameAggregateMembers: snapshot.aggregateMembers == expected.aggregateMembers,
            running: snapshot.running, receivedFrames: tap?.receivedFrames ?? 0)
        if decision != .ignore { fail(decision.message) }
    }

    private func fail(_ message: String) {
        guard !failed else { return }
        failed = true
        closeEngine()
        onFailure(message)
    }
    private func closeEngine() {
        engineID = UUID()
        tap?.finish(); engine?.stop(); engine = nil; tap = nil; expected = nil
    }
    @discardableResult func stop() -> String? {
        generation = UUID(); startupTask?.cancel(); startupTask = nil; starting = false
        let invalid = tap?.finish() ?? false
        closeEngine()
        return invalid ? "Input timestamps, format or packet budget changed; its track is incomplete. Other sources continued." : nil
    }
}

/// Startup may deliver queued I/O reconfiguration notifications. Never switch
/// devices or accept a changed format in-place. The manager may explicitly reopen
/// the same UID on the existing writer timeline with gap/review evidence.
nonisolated struct DeviceInputConfigurationPolicy {
    enum Decision: String {
        case ignore, disconnected, deviceChanged, formatChanged, aggregateChanged, interrupted, noAudio
        var message: String {
            switch self {
            case .noAudio: "The selected input delivered no audio during startup; other sources continue."
            case .disconnected: "The selected input disconnected; its track is incomplete. Other sources continue."
            case .deviceChanged: "The input engine changed away from the selected device; its track is incomplete. Other sources continue."
            case .formatChanged: "The selected input changed audio format; its track is incomplete. Other sources continue."
            case .aggregateChanged: "The selected aggregate device's sub-device membership changed; its track is incomplete. Other sources continue."
            default: "The selected input engine stopped after a configuration change; its track is incomplete. Other sources continue."
            }
        }
    }
    func evaluate(connected: Bool, sameDevice: Bool, sameFormat: Bool,
                  sameAggregateMembers: Bool = true, running: Bool,
                  receivedFrames: Int64) -> Decision {
        guard connected else { return .disconnected }
        guard sameDevice else { return .deviceChanged }
        guard sameFormat else { return .formatChanged }
        guard sameAggregateMembers else { return .aggregateChanged }
        guard running else { return .interrupted }
        return receivedFrames > 0 ? .ignore : .noAudio
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
    /// Atomically close an empty startup attempt. A callback already transferring
    /// its first copy wins and leaves the established tap open.
    func sealIfNoFrames() -> Bool {
        state.withLock { s in
            guard s.receivedFrames == 0 else { return false }
            s.accepting = false
            return true
        }
    }
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
