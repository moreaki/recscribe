import AVFoundation
import CoreAudio
import Foundation
import CoreMedia
import os
import Testing
@testable import RecScribe

@MainActor
struct MultipleInputTests {
    private func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true); return url
    }
    private func pcm(_ amplitude: Float, frames: Int = 480, channels: Int = 2, rate: Double = 48_000) -> AVAudioPCMBuffer {
        SampleBufferFixtures.makePCMBuffer(channels: channels, frames: frames, sampleRate: rate, interleaved: false) { _, _ in amplitude }
    }
    private func decoded(_ session: RecordingSession, at manifest: URL) throws -> [[Float]] {
        var output = [[Float]](repeating: [], count: session.channels)
        for part in session.parts {
            let file = try AVAudioFile(forReading: RecordingSession.safeURL(part.path, beside: manifest))
            let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
            try file.read(into: buffer)
            for ch in 0..<session.channels { output[ch] += Array(UnsafeBufferPointer(start: buffer.floatChannelData![ch], count: Int(buffer.frameLength))) }
        }
        return output
    }
    private var descriptors: [RecordingSession.SourceTrack] {
        [.init(role: .playback, name: "Playback"),
         .init(role: .input("a"), name: "Interface", deviceUID: "a", channelRoutes: [.init(channel: 3, placement: .right)]),
         .init(role: .input("b"), name: "Microphone", deviceUID: "b", channelRoutes: [.init(channel: 0, placement: .center)])]
    }
    @Test func selectionMigrationIdentityBoundsAndDuplicateRoutes() throws {
        let source = AudioSource.multiple(appBundleID: nil, inputs: [.init(deviceUID: "a"), .init(deviceUID: "b")])
        let defaults = UserDefaults(suiteName: "multiple-inputs-" + UUID().uuidString)!
        let manager = AudioSourceManager(defaults: defaults)
        manager.setSelectedSource(source)
        #expect(AudioSourceManager(defaults: defaults).selectedSource == source)
        #expect(source.requiresMicrophone && source.microphoneUID == nil)
        #expect(!AudioSource.multiple(appBundleID: nil, inputs: [.init(deviceUID: "a"), .init(deviceUID: "a")]).valid)
        #expect(!AudioSource.multiple(appBundleID: nil, inputs: (0..<9).map { .init(deviceUID: "\($0)") }).valid)
        #expect(!InputSelection(deviceUID: "a", routes: [.init(channel: -1, placement: .left)]).valid)
        #expect(CaptureTrack.input("a/b").valid && !CaptureTrack.input("a/b").rawValue.contains("/"))
        #expect(try JSONDecoder().decode(CaptureTrack.self, from: Data("\"microphone\"".utf8)) == .microphone)
        for legacy in [AudioSource.mic(deviceUID: "a"), .mixed(appBundleID: nil, deviceUID: "a"), .systemAll] {
            manager.setSelectedSource(legacy)
            #expect(AudioSourceManager(defaults: defaults).selectedSource == legacy)
        }
        let hardware = InputDeviceInfo(uid: "a", name: "Hardware", inputChannels: 4)
        let aggregate = InputDeviceInfo(uid: "aggregate", name: "Aggregate", inputChannels: 4, transport: kAudioDeviceTransportTypeAggregate, aggregateMembers: ["a"])
        let virtual = InputDeviceInfo(uid: "virtual", name: "Loopback", inputChannels: 2, transport: kAudioDeviceTransportTypeVirtual)
        #expect(InputRouteSafety.warnings(inputs: [.init(deviceUID: "a")], devices: [hardware]).isEmpty)
        #expect(InputRouteSafety.warnings(inputs: [.init(deviceUID: "a"), .init(deviceUID: "aggregate"), .init(deviceUID: "virtual")], devices: [hardware, aggregate, virtual]).count == 2)
        #expect(InputSelection(device: hardware).routes.map(\.channel) == [0, 1])
    }

    @Test func preflightRejectsMissingDevicesChangedChannelsAndUnacknowledgedLoopback() async throws {
        let devices = SelectedTestDevices([
            .init(uid: "physical", name: "Physical", inputChannels: 2),
            .init(uid: "virtual", name: "Virtual", inputChannels: 2, transport: kAudioDeviceTransportTypeVirtual)
        ])
        let manager = AudioSourceManager(defaults: UserDefaults(suiteName: "input-preflight-" + UUID().uuidString)!, deviceEnumerator: devices)
        await #expect(throws: AudioSourceError.self) { try await manager.validate(.multiple(appBundleID: nil, inputs: [.init(deviceUID: "missing")])) }
        await #expect(throws: SessionError.self) { try await manager.validate(.multiple(appBundleID: nil, inputs: [.init(deviceUID: "physical", routes: [.init(channel: 2, placement: .left)])])) }
        await #expect(throws: SessionError.self) { try await manager.validate(.multiple(appBundleID: nil, inputs: [.init(deviceUID: "virtual")])) }
        try await manager.validate(.multiple(appBundleID: nil, inputs: [.init(deviceUID: "virtual")], allowDuplicateRoutes: true))
        let source = AudioSource.multiple(appBundleID: nil, inputs: [.init(deviceUID: "physical")])
        let actions = OverflowMenu.actions(OverflowContext(selectedSource: source))
        #expect(actions.filter { $0.isSourceRow && $0.isChecked }.map(\.id) == ["sourceMultiple"])
        #expect(!AudioSource.multiple(appBundleID: nil, inputs: []).requiresMicrophone)
    }

    @Test func tapCopiesNativePCMHostTimeAndSealsLateCallbacks() async throws {
        let received = OSAllocatedUnfairLock(initialState: [CapturedAudioSample]())
        let failures = OSAllocatedUnfairLock(initialState: 0)
        let tap = DeviceInputTap(track: .input("native"), callback: { value in received.withLock { $0.append(value) } }, onFailure: { _ in failures.withLock { $0 += 1 } })
        let input = pcm(0.4, frames: 441, channels: 4, rate: 44_100)
        tap.begin(format: input.format)
        let time = AVAudioTime(hostTime: AVAudioTime.hostTime(forSeconds: 123))
        tap.receive(input, time: time)
        input.floatChannelData![3][0] = 0.9
        tap.finish(); tap.receive(input, time: time)
        let saved = received.withLock { $0 }
        try #require(saved.count == 1)
        #expect(saved[0].track == .input("native"))
        #expect(abs(saved[0].presentationTime - 123) < 0.00001)
        #expect(saved[0].buffer.format.channelCount == 4 && saved[0].buffer.floatChannelData![3][0] == 0.4)
        tap.begin(format: input.format)
        tap.receive(input, time: AVAudioTime(sampleTime: 0, atRate: 44_100))
        for _ in 0..<100 where failures.withLock({ $0 }) == 0 { await Task.yield() }
        #expect(failures.withLock { $0 } == 1)
        #expect(received.withLock { $0.count } == 1)
    }

    @Test func actualTapBlockRunsOnBackgroundAudioQueueWithoutActorInheritance() async throws {
        let received = OSAllocatedUnfairLock(initialState: 0)
        let tap = DeviceInputTap(track: .input("background"), callback: { value in received.withLock { $0 += Int(value.buffer.frameLength) } }, onFailure: { _ in Issue.record("Unexpected native tap failure") })
        let packet = CapturedAudioSample(track: .input("background"), presentationTime: 100, buffer: pcm(0.2))
        tap.begin(format: packet.buffer.format)
        let block = tap.block
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                block(packet.buffer, AVAudioTime(hostTime: AVAudioTime.hostTime(forSeconds: 100)))
                continuation.resume()
            }
        }
        tap.finish()
        #expect(received.withLock { $0 } == 480)
    }

    @Test func threeSourceMixRoutesHigherChannelsAndRetainsIndependentTracksWithUIDGain() throws {
        let directory = try folder(); defer { try? FileManager.default.removeItem(at: directory) }
        let mix = SessionWAVWriter(options: .init(maximumPartBytes: 4_844))
        try mix.createFile(at: directory.appendingPathComponent("mix.wav"), sampleRate: 48_000, channels: 2)
        var initial = RecordingLevels(); initial.inputs[.input("a")] = .init(decibels: 6.020599913)
        let levels = initial
        let worker = try SynchronizedCaptureWriter(mix: mix, descriptors: descriptors, epoch: 100, options: .init(maximumPartBytes: 4_844), levels: { levels })
        for i in 0..<10 {
            let time = 100 + Double(i) / 100
            try worker.accept(.init(track: .input("a"), presentationTime: time,
                buffer: SampleBufferFixtures.makePCMBuffer(channels: 4, frames: 480, interleaved: false) { ch, _ in ch == 3 ? 0.6 : Float(ch + 1) * 0.1 }))
            try worker.accept(.init(track: .playback, presentationTime: time, buffer: pcm(0.3)))
            try worker.accept(.init(track: .input("b"), presentationTime: time + 0.02, buffer: pcm(0.9, frames: 441, channels: 1, rate: 44_100)))
        }
        try worker.finish()
        let manifest = try #require(mix.manifestURL), parent = try RecordingSession.read(manifest)
        #expect(parent.schemaVersion == 3 && parent.sourceTracks?.count == 3)
        #expect(parent.gainTracks == descriptors.map(\.role))
        #expect(parent.gainAutomation?.first?.to.count == 97)
        #expect(parent.totalFrames == 5760)
        let audio = try decoded(parent, at: manifest)
        #expect(abs(audio[0][2000] - 0.4) < 0.001)
        #expect(abs(audio[1][2000] - 0.8) < 0.001)
        #expect(abs(audio[0][400] - 0.1) < 0.001)
        for descriptor in try #require(parent.sourceTracks) {
            let child = try LinkedSourceSessions.read(descriptor, parent: parent, at: manifest)
            let saved = try decoded(child.session, at: child.id)
            #expect(child.session.totalFrames == parent.totalFrames)
            if descriptor.deviceUID == "a" {
                #expect(saved.count == 4 && abs(saved[3][1000] - 0.6) < 0.001)
                #expect(descriptor.mixChannels == [3])
            }
            if descriptor.deviceUID == "b" { #expect(saved[0][0..<960].allSatisfy { $0 == 0 }) }
        }
        let verified = try SessionProcessing.process(manifest, ffmpeg: URL(fileURLWithPath: "/unused"), cancel: WorkCancellation())
        #expect(verified.sourceTracks?.count == 3)
    }

    @Test func sourceFailurePreservesAcceptedTailAndOtherSourcesContinue() async throws {
        let directory = try folder(); defer { try? FileManager.default.removeItem(at: directory) }
        let recorder = MultiSourceRecorder(onError: { _ in Issue.record("A failed device must not abort other inputs") })
        var tracks = descriptors
        tracks[1].channelRoutes = [.init(channel: 0, placement: .center)]
        try recorder.start(at: directory.appendingPathComponent("partial.wav"), descriptors: tracks, options: .init(), epoch: 100, continueOnSourceFailure: true)
        for i in 0..<3 {
            for track in tracks.map(\.role) { recorder.accept(.init(track: track, presentationTime: 100 + Double(i) / 100, buffer: pcm(0.3))) }
        }
        recorder.sourceFailed(.input("b"), message: "Test device unplugged; other sources continued")
        for i in 3..<10 {
            for track in [CaptureTrack.playback, .input("a")] { recorder.accept(.init(track: track, presentationTime: 100 + Double(i) / 100, buffer: pcm(0.3))) }
        }
        await #expect(throws: (any Error).self) { try await recorder.stop() }
        let manifest = try #require(recorder.manifestURL), parent = try RecordingSession.read(manifest)
        #expect(parent.totalFrames == 4800 && parent.status == .needsReview)
        let failed = try #require(parent.sourceTracks?.first { $0.role == .input("b") })
        #expect(failed.receivedFrames == 1440)
        #expect(failed.failure?.contains("unplugged") == true)
        let child = try LinkedSourceSessions.read(failed, parent: parent, at: manifest)
        let saved = try decoded(child.session, at: child.id)
        #expect(abs(saved[0][1439] - 0.3) < 0.001) // accepted tail survives stop/failure race
        #expect(saved[0][1440...].allSatisfy { $0 == 0 })
        #expect(recorder.sourceHealth.filter { $0.health.failed }.count == 1)
    }

    @Test func controllerUsesSelectedDeviceSetAndMicrophoneDenialBlocksIt() async throws {
        let source = AudioSource.multiple(appBundleID: nil, inputs: [.init(deviceUID: "a"), .init(deviceUID: "b")])
        let permissions = MockPermissionProviding(.granted); permissions.micStatus = .denied
        let mock = MockRecordingControlling()
        let defaults = UserDefaults(suiteName: "multiple-permission-" + UUID().uuidString)!
        let model = RecorderViewModel(controller: mock, permissions: permissions, audioSource: MockAudioSourceProviding(selectedSource: source), defaults: defaults)
        await model.startRecording()
        #expect(model.state == .error(.microphoneDenied) && mock.startCount == 0)
        let directory = try folder(); defer { try? FileManager.default.removeItem(at: directory) }
        let capture = MockAudioCapturing(), provider = MockAudioSourceProviding(selectedSource: source)
        provider.availableInputDevicesResult = [InputDeviceInfo(uid: "a", name: "Input A", inputChannels: 2, channelLabels: ["A left", "A right"]), InputDeviceInfo(uid: "b", name: "Input B", inputChannels: 2)]
        let controller = RecordingController(captureManager: capture, saveLocation: MockSaveLocationProviding(directory: directory), audioSource: provider,
            levels: AudioLevels(defaults: defaults))
        let audio = try await controller.startRecording(format: .wav)
        let epoch = CMClockGetTime(CMClockGetHostTimeClock()).seconds
        for index in 0..<4 {
            for track in [CaptureTrack.playback, .input("a"), .input("b")] {
                capture.emit(.init(track: track, presentationTime: epoch + Double(index) / 100, buffer: pcm(0.2)))
            }
        }
        try await controller.stopRecording()
        let manifest = RecordingSession.manifestURL(for: audio), session = try RecordingSession.read(manifest)
        #expect(capture.lastSource == source && session.sourceTracks?.count == 3)
        let descriptor = try #require(session.sourceTracks?.first { $0.deviceUID == "a" })
        let child = try LinkedSourceSessions.read(descriptor, parent: session, at: manifest)
        #expect(child.session.sourceIdentity?.deviceUID == "a")
        #expect(child.session.channelMap == ["A left", "A right"])
    }

    @Test func threeIndependentClocksUseHostTimeAndDoNotAccumulateDrift() throws {
        let directory = try folder(); defer { try? FileManager.default.removeItem(at: directory) }
        let mix = SessionWAVWriter()
        try mix.createFile(at: directory.appendingPathComponent("clocks.wav"), sampleRate: 48_000, channels: 2)
        var tracks = descriptors; tracks[1].channelRoutes = [.init(channel: 0, placement: .center)]
        let worker = try SynchronizedCaptureWriter(mix: mix, descriptors: tracks, epoch: 100, options: .init())
        for index in 0..<100 {
            try worker.accept(.init(track: .input("b"), presentationTime: 100 + Double(index) * 0.01001, buffer: pcm(0.3, frames: 441, channels: 1, rate: 44_100)))
            try worker.accept(.init(track: .playback, presentationTime: 100 + Double(index) * 0.01, buffer: pcm(0.2)))
            try worker.accept(.init(track: .input("a"), presentationTime: 100 + Double(index) * 0.00999, buffer: pcm(0.4)))
        }
        try worker.finish()
        let manifest = try #require(mix.manifestURL), parent = try RecordingSession.read(manifest)
        #expect(parent.issues.isEmpty)
        #expect(parent.totalFrames == Int64((0.99 * 1.001 * 48_000).rounded()) + 480)
        for descriptor in try #require(parent.sourceTracks) {
            #expect(try LinkedSourceSessions.read(descriptor, parent: parent, at: manifest).session.totalFrames == parent.totalFrames)
        }
    }

    @Test func formatFailureDuringDrainDoesNotAbortOtherDevicesOrClaimSuccess() async throws {
        let directory = try folder(); defer { try? FileManager.default.removeItem(at: directory) }
        let recorder = MultiSourceRecorder(onError: { _ in Issue.record("Device format failure must remain per-source") })
        var tracks = descriptors; tracks[1].channelRoutes = [.init(channel: 0, placement: .center)]
        try recorder.start(at: directory.appendingPathComponent("format.wav"), descriptors: tracks, options: .init(), epoch: 100, continueOnSourceFailure: true)
        for index in 0..<5 {
            for track in tracks.map(\.role) {
                recorder.accept(.init(track: track, presentationTime: 100 + Double(index) / 100,
                    buffer: pcm(0.2, channels: track == .input("b") && index >= 2 ? 1 : 2)))
            }
        }
        await #expect(throws: (any Error).self) { try await recorder.stop() }
        let manifest = try #require(recorder.manifestURL), session = try RecordingSession.read(manifest)
        #expect(session.totalFrames == 2400 && session.status == .needsReview)
        #expect(session.sourceTracks?.first { $0.role == .input("b") }?.failure != nil)
        #expect(recorder.sourceHealth.first { $0.id == CaptureTrack.playback.rawValue }?.health.writtenFrames == 2400)
    }

    @Test func groupedExportRecoveryAndTrashRetainAllThreeSources() throws {
        let directory = try folder(); defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("recover.wav")
        var root: SessionWAVWriter? = SessionWAVWriter(options: .init(maximumPartBytes: 4_844))
        try root!.createFile(at: url, sampleRate: 48_000, channels: 2)
        var tracks = descriptors; tracks[1].channelRoutes = [.init(channel: 0, placement: .center)]
        var worker: SynchronizedCaptureWriter? = try SynchronizedCaptureWriter(mix: root!, descriptors: tracks, epoch: 100, options: .init(maximumPartBytes: 4_844))
        for index in 0..<4 {
            for track in tracks.map(\.role) { try worker!.accept(.init(track: track, presentationTime: 100 + Double(index) / 100, buffer: pcm(0.2))) }
        }
        let manifest = try #require(root!.manifestURL)
        worker = nil; root = nil // unfinalized headers simulate an interrupted recording
        let recovered = try SessionProcessing.process(manifest, ffmpeg: URL(fileURLWithPath: "/unused"), cancel: WorkCancellation(), recover: true)
        #expect(recovered.status == .needsReview && recovered.sourceTracks?.count == 3)
        for track in try #require(recovered.sourceTracks) {
            let child = try LinkedSourceSessions.read(track, parent: recovered, at: manifest)
            #expect(child.session.parts.allSatisfy { $0.status == .verified })
        }
        let exported = try SessionExporter().export(manifest, to: directory, checkCancellation: {})
        let copyManifest = exported.appendingPathComponent(manifest.lastPathComponent)
        let copy = try RecordingSession.read(copyManifest)
        for track in try #require(copy.sourceTracks) { _ = try LinkedSourceSessions.read(track, parent: copy, at: copyManifest) }
        var grouped: URL?
        try SessionDeletion.moveToTrash(manifest, trash: { grouped = $0 })
        let trashed = try #require(grouped).appendingPathComponent(manifest.lastPathComponent)
        let saved = try RecordingSession.read(trashed)
        for track in try #require(saved.sourceTracks) { _ = try LinkedSourceSessions.read(track, parent: saved, at: trashed) }
    }

    @Test func variableGroupWithoutInputsCapturesPlaybackAndLegacyGroupsRemainVersionTwo() throws {
        let directory = try folder(); defer { try? FileManager.default.removeItem(at: directory) }
        let mix = SessionWAVWriter()
        try mix.createFile(at: directory.appendingPathComponent("playback.wav"), sampleRate: 48_000, channels: 2)
        let worker = try SynchronizedCaptureWriter(mix: mix, descriptors: [.init(role: .playback, name: "Playback")], epoch: 100, options: .init())
        try worker.accept(.init(track: .playback, presentationTime: 100, buffer: pcm(0.4)))
        try worker.finish()
        let manifest = try #require(mix.manifestURL), parent = try RecordingSession.read(manifest)
        #expect(parent.schemaVersion == 3 && parent.gainAutomation?.first?.to.count == 33)
        #expect(abs(try decoded(parent, at: manifest)[0][100] - 0.4) < 0.001)
    }
}

@MainActor
private final class SelectedTestDevices: InputDeviceEnumerating {
    let values: [InputDeviceInfo]
    init(_ values: [InputDeviceInfo]) { self.values = values }
    func availableInputDevices() -> [InputDeviceInfo] { values }
}
