import CoreAudio
import CoreMedia
import AVFoundation
import Foundation
import Testing
@testable import RecScribe

@MainActor struct LiveInputContinuityTests {
    final class Backend: AudioHardwareBackend {
        var devices: [InputDeviceInfo] = [.init(uid: "mic", name: "Mic", inputChannels: 1, sampleRate: 48000)]
        var changed: (@Sendable () -> Void)?
        var deviceChanges: [@Sendable () -> Void] = []
        func inputDevices() -> [InputDeviceInfo] { devices }
        func outputDevices() -> [AudioOutputDevice] { [] }
        func defaultInputUID() -> String? { nil }
        func defaultOutputUID() -> String? { nil }
        func deviceID(forUID uid: String) -> AudioDeviceID? { devices.contains { $0.uid == uid } ? 42 : nil }
        func addSystemListener(_ handler: @escaping @Sendable () -> Void) -> AnyObject { changed = handler; return NSObject() }
        func removeSystemListener(_ token: AnyObject) { changed = nil }
        func addDeviceListener(deviceID: AudioDeviceID, inputScope: Bool, includeVolumes: Bool, handler: @escaping @Sendable () -> Void) -> AnyObject { deviceChanges.append(handler); return NSObject() }
        func removeDeviceListener(_ token: AnyObject) {}
    }
    final class Input: InputCaptureSession {
        let request: InputCaptureRequest
        var uid: String { request.uid }
        var startFails = false
        var starts = 0
        var stops = 0
        init(_ request: InputCaptureRequest) { self.request = request }
        func start() throws { starts += 1; if startFails { throw SessionError.invalid("Driver warming up") } }
        func stop() -> String? { stops += 1; return nil }
        func checkHardwareStatus() {}
    }
    @Test func returningInputAndNewVirtualDeviceJoinWithoutRestartingOtherInputs() async throws {
        let backend = Backend()
        let observer = AudioHardwareObserver(backend: backend)
        defer { observer.stopObserving() }
        var inputs: [Input] = []
        let capture = ScreenCaptureAudioManager(hardwareObserver: observer, inputFactory: { request in
            let input = Input(request); inputs.append(input); return input
        }, canOpenInput: { true })
        var prepared: [String] = []
        capture.onInputAvailable = { device, _ in prepared.append(device.uid); return true }
        try await capture.setupMultiCapture(source: .inputsOnly([.init(deviceUID: "mic")])) { _ in }
        try await capture.startCapture()
        #expect(inputs.count == 1)
        backend.devices = []; backend.changed?()
        await waitUntil("disconnected hardware snapshot") { observer.inputDevices.isEmpty }
        inputs[0].request.failure("Disconnected")
        await settle()
        #expect(capture.capturing)
        backend.devices = [.init(uid: "mic", name: "Mic", inputChannels: 1, sampleRate: 24000),
                           .init(uid: "virtual", name: "Teams virtual", inputChannels: 2, sampleRate: 48000,
                                 transport: kAudioDeviceTransportTypeVirtual)]
        backend.changed?()
        await waitUntil("rejoined and new virtual input") { inputs.count == 3 }
        #expect(inputs.count == 3, "Constructed inputs: \(inputs.map(\.uid)), prepared: \(prepared)")
        #expect(Set(prepared) == ["mic", "virtual"])
        #expect(inputs[0].starts == 1 && inputs[0].stops == 1)
        #expect(inputs[1].starts == 1 && inputs[2].starts == 1)
        try await capture.stopCapture()
        #expect(inputs[1].stops == 1 && inputs[2].stops == 1)
    }
    @Test func stopDuringSuspendedWriterPreparationPreventsLateEngineStart() async throws {
        let backend = Backend()
        let observer = AudioHardwareObserver(backend: backend)
        defer { observer.stopObserving() }
        var inputs: [Input] = []
        let capture = ScreenCaptureAudioManager(hardwareObserver: observer, inputFactory: { request in
            let input = Input(request); inputs.append(input); return input
        }, canOpenInput: { true })
        var gate: CheckedContinuation<Bool, Never>?
        capture.onInputAvailable = { _, _ in await withCheckedContinuation { gate = $0 } }
        try await capture.setupMultiCapture(source: .inputsOnly([.init(deviceUID: "mic")])) { _ in }
        try await capture.startCapture()
        backend.devices.append(.init(uid: "new", name: "New", inputChannels: 1, sampleRate: 48000))
        backend.changed?()
        await waitUntil("writer preparation gate") { gate != nil }
        try await capture.stopCapture()
        gate?.resume(returning: true)
        await settle()
        #expect(inputs.count == 1)
        #expect(!capture.capturing)
    }
    @Test func recordingControllerJoinsMutedNewInputsAndPreservesExistingManualSettings() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let suite = "routing59-join-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let levels = AudioLevels(defaults: defaults)
        levels.set("input:known", .init(decibels: -3, muted: false))
        let provider = MockAudioSourceProviding(selectedSource: .multiple(appBundleID: nil,
            inputs: [.init(deviceUID: "mic")], allowDuplicateRoutes: true))
        let capture = MockAudioCapturing()
        let controller = RecordingController(captureManager: capture, saveLocation: MockSaveLocationProviding(directory: root),
            audioSource: provider, levels: levels)
        _ = try await controller.startRecording()
        let join = try #require(capture.onInputAvailable)
        #expect(await join(.init(uid: "new", name: "New input", inputChannels: 1, sampleRate: 48000), .init(deviceUID: "new")))
        #expect(levels.level("input:new").muted)
        #expect(await join(.init(uid: "known", name: "Known", inputChannels: 1, sampleRate: 48000), .init(deviceUID: "known")))
        #expect(levels.level("input:known") == .init(decibels: -3, muted: false))
        #expect(!provider.selectedSource.allowDuplicateRoutes)
        #expect(provider.selectedSource.inputSelections.count == 3)
        let time = CMClockGetTime(CMClockGetHostTimeClock()).seconds
        for index in 0..<3 {
            for track in [CaptureTrack.playback, .input("mic"), .input("new"), .input("known")] {
                capture.emit(.init(track: track, presentationTime: time + Double(index) / 100,
                    buffer: SampleBufferFixtures.makePCMBuffer(channels: 1, frames: 480, interleaved: false) { _, _ in 0.2 }))
            }
        }
        try await controller.stopRecording()
        #expect(!capture.capturing)
    }

    @Test func driverThatIsNotReadyWaitsForDeviceEventWithoutRetrySpin() async throws {
        let backend = Backend()
        let observer = AudioHardwareObserver(backend: backend)
        defer { observer.stopObserving() }
        var inputs: [Input] = []
        var warming = true
        let capture = ScreenCaptureAudioManager(hardwareObserver: observer, inputFactory: { request in
            let input = Input(request)
            input.startFails = request.uid == "warming" && warming
            inputs.append(input)
            return input
        }, canOpenInput: { true })
        capture.onInputAvailable = { _, _ in true }
        try await capture.setupMultiCapture(source: .inputsOnly([.init(deviceUID: "mic")])) { _ in }
        try await capture.startCapture()
        backend.devices.append(.init(uid: "warming", name: "Virtual driver", inputChannels: 2, sampleRate: 48000))
        backend.changed?()
        await waitUntil("first driver open attempt") { inputs.count >= 2 }
        await settle()
        #expect(inputs.count == 2)
        #expect(capture.capturing)
        warming = false
        for changed in backend.deviceChanges { changed() }
        await waitUntil("driver ready event") { inputs.count >= 3 }
        #expect(inputs.count == 3)
        #expect(inputs[0].starts == 1 && inputs[0].stops == 0)
        try await capture.stopCapture()
    }

}
