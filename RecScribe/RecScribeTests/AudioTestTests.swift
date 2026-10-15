import AVFoundation
import CoreMedia
import Foundation
import os
import Testing
@testable import RecScribe

@MainActor
struct AudioTestTests {
    private func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("audio-test-tests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    private func pcm(_ amplitude: Float, frames: Int = 480) -> AVAudioPCMBuffer {
        SampleBufferFixtures.makePCMBuffer(channels: 2, frames: frames, interleaved: false) { channel, _ in channel == 0 ? amplitude : amplitude / 2 }
    }
    private func defaults() -> UserDefaults { UserDefaults(suiteName: "audio-test-" + UUID().uuidString)! }
    private var descriptors: [RecordingSession.SourceTrack] {
        [.init(role: .playback, name: "Playback"), .init(role: .input("mic"), name: "Microphone", deviceUID: "mic",
            channelRoutes: [.init(channel: 0, placement: .center)])]
    }
    private func decoded(_ manifest: URL) throws -> [[Float]] {
        let session = try RecordingSession.read(manifest)
        var result = [[Float]](repeating: [], count: session.channels)
        for part in session.parts {
            let file = try AVAudioFile(forReading: RecordingSession.safeURL(part.path, beside: manifest))
            let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
            try file.read(into: buffer)
            for channel in result.indices { result[channel] += Array(UnsafeBufferPointer(start: buffer.floatChannelData![channel], count: Int(buffer.frameLength))) }
        }
        return result
    }

    @Test func previewHasRealGainRoutingAndMetersWithoutAnyFiles() throws {
        let directory = try folder(); defer { try? FileManager.default.removeItem(at: directory) }
        let level = OSAllocatedUnfairLock(initialState: RecordingLevels())
        let writer = try SynchronizedCaptureWriter(descriptors: descriptors, epoch: 100, options: .init(), levels: { level.withLock { $0 } })
        let output = OSAllocatedUnfairLock(initialState: [[Float]](repeating: [], count: 2))
        writer.onMix = { buffer in
            let values = (0..<2).map { Array(UnsafeBufferPointer(start: buffer.floatChannelData![$0], count: Int(buffer.frameLength))) }
            output.withLock { channels in
                for channel in 0..<2 { channels[channel] += values[channel] }
            }
        }
        for index in 0..<30 {
            if index == 10 { level.withLock { $0.inputs[.input("mic")] = .init(muted: true) } }
            if index == 20 { level.withLock { $0.master = .init(decibels: 6.020599913) } }
            try writer.accept(.init(track: .playback, presentationTime: 100 + Double(index) / 100, buffer: pcm(0.4)))
            try writer.accept(.init(track: .input("mic"), presentationTime: 100 + Double(index) / 100, buffer: pcm(0.8)))
        }
        try writer.finish()
        let samples = output.withLock { $0 }
        #expect(abs(samples[0][2_000] - 0.6) < 0.001)
        #expect(abs(samples[0][8_000] - 0.2) < 0.001)
        #expect(abs(samples[0][13_000] - 0.4) < 0.001)
        #expect(abs(samples[1][13_000] - 0.2) < 0.001)
        #expect(writer.sourceMeters[.input("mic")]?.raw.hold.first == 0.8)
        #expect(writer.sourceMeters[.input("mic")]?.processed.peaks.first == 0)
        #expect(writer.mixMeter.peaks.count == 2)
        #expect(writer.mix == nil)
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
    }

    @Test func sampleUsesRealWriterCapsTimelineAndKeepsSourcesAtUnity() throws {
        let directory = try folder(); defer { try? FileManager.default.removeItem(at: directory) }
        let sink = SessionWAVWriter()
        try sink.createFile(at: directory.appendingPathComponent("sample.wav"), sampleRate: 48_000, channels: 2)
        var value = RecordingLevels(); value.master.muted = true
        let level = value
        let writer = try SynchronizedCaptureWriter(mix: sink, descriptors: descriptors, epoch: 100, options: .init(),
            maximumFrames: 1_000, levels: { level })
        for index in 0..<6 {
            for track in descriptors.map(\.role) { try writer.accept(.init(track: track, presentationTime: 100 + Double(index) / 100, buffer: pcm(0.4))) }
        }
        try writer.finish()
        let manifest = try #require(sink.manifestURL)
        let result = try SessionProcessing.process(manifest, ffmpeg: URL(fileURLWithPath: "/unused"), cancel: WorkCancellation())
        #expect(result.totalFrames == 1_000)
        #expect(try decoded(manifest).allSatisfy { $0.allSatisfy { $0 == 0 } })
        for track in try #require(result.sourceTracks) {
            let child = try LinkedSourceSessions.read(track, parent: result, at: manifest)
            #expect(child.session.totalFrames == 1_000)
            #expect(abs(try decoded(child.id)[0][999] - 0.4) < 0.001)
        }
    }

    @Test func meterHoldAndDecayDistinguishSilenceFromMissingSource() {
        var meter = CapturePeakMeter()
        meter.update([0.5, 1.2], at: 100)
        meter.update([0, 0], at: 100.1)
        #expect(meter.current(at: 100.2) == [0, 0])
        #expect(meter.hold == [0.5, 1.2])
        meter.update([0.1, 0.2], at: 100.3)
        #expect(meter.current(at: 101) == [0, 0])
        #expect(meter.hold == [0.5, 1.2])
        #expect(CapturePeakMeter().peaks.isEmpty)
    }

    @Test func previewStopSamplePlaybackKeepAndDiscardStaySeparateFromRecording() async throws {
        let directory = try folder(); defer { try? FileManager.default.removeItem(at: directory) }
        let temporary = directory.appendingPathComponent("scratch")
        let capture = MockAudioCapturing(), settings = defaults(), provider = MockAudioSourceProviding(selectedSource: .multiple(appBundleID: nil, inputs: []))
        let playback = SessionPlayback(activate: { $0.pause() }, levels: PlaybackLevels(defaults: settings))
        let test = AudioTestController(capture: capture, source: provider, permissions: MockPermissionProviding(.granted),
            levels: AudioLevels(defaults: settings), monitor: CapturedAudioMonitor(defaults: settings), playback: playback,
            temporaryRoot: temporary, saveDirectory: { directory }, sampleSeconds: 0.05)
        #expect(capture.setupCount == 0 && !FileManager.default.fileExists(atPath: temporary.path))
        await test.startPreview()
        #expect(test.state == .testing && capture.capturing)
        #expect(!FileManager.default.fileExists(atPath: temporary.path))
        await test.stop()
        #expect(test.state == .idle && !capture.capturing)
        await test.recordSample()
        let epoch = CMClockGetTime(CMClockGetHostTimeClock()).seconds
        for index in 0..<8 {
            capture.emit(.init(track: .playback, presentationTime: epoch + Double(index) / 100, buffer: pcm(0.4)))
        }
        await test.stop()
        #expect(test.state == .ready && !capture.capturing)
        let sample = try #require(test.sample)
        #expect(sample.entry.session.totalFrames <= 2_400 && sample.entry.session.totalFrames > 0)
        #expect(try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).allSatisfy { !$0.lastPathComponent.hasSuffix(".recscribe.json") })
        test.playSample()
        await waitUntil("verified sample playback load") { !playback.loading }
        #expect(playback.errorMessage == nil)
        #expect(playback.player != nil && !capture.capturing)
        await test.keepSample()
        #expect(test.sample == nil && !FileManager.default.fileExists(atPath: sample.folder.path))
        let retained = directory.appendingPathComponent(sample.entry.id.lastPathComponent)
        #expect(FileManager.default.fileExists(atPath: retained.path))
        #expect(abs(try decoded(retained)[0].last! - 0.4) < 0.001)
        await test.recordSample()
        let time = CMClockGetTime(CMClockGetHostTimeClock()).seconds
        for index in 0..<3 { capture.emit(.init(track: .playback, presentationTime: time + Double(index) / 100, buffer: pcm(0.2))) }
        await test.stop()
        let discardFolder = try #require(test.sample?.folder)
        test.discard()
        #expect(!FileManager.default.fileExists(atPath: discardFolder.path))
        #expect(FileManager.default.fileExists(atPath: retained.path))
    }

    @Test func deniedPermissionAndCaptureGatePreventCompetingEngines() async throws {
        let directory = try folder(); defer { try? FileManager.default.removeItem(at: directory) }
        let settings = defaults(), capture = MockAudioCapturing(), gate = CaptureSessionGate()
        let permissions = MockPermissionProviding(.denied)
        let provider = MockAudioSourceProviding(selectedSource: .multiple(appBundleID: nil, inputs: []))
        let test = AudioTestController(capture: capture, source: provider, permissions: permissions,
            levels: AudioLevels(defaults: settings), monitor: CapturedAudioMonitor(defaults: settings), gate: gate, temporaryRoot: directory.appendingPathComponent("scratch"), saveDirectory: { directory })
        await test.startPreview()
        #expect(test.state == .idle && test.errorMessage != nil && capture.startCount == 0)
        permissions.status = .granted
        let owner = UUID(); try gate.acquire(owner)
        await test.startPreview()
        #expect(capture.startCount == 0)
        gate.release(owner)
        await test.startPreview()
        #expect(test.state == .testing)
        #expect(throws: (any Error).self) { try gate.acquire(owner) }
        await test.prepareForRecording()
        #expect(!capture.capturing && test.state == .idle)
        try gate.acquire(owner); gate.release(owner)
        await test.startPreview()
        #expect(test.state == .idle) // handoff blocks new tests until the take ends
        test.recordingFinished()
        await test.startPreview()
        await test.close()
        #expect(!capture.capturing)
    }

    @Test func cancellingSuspendedSetupWaitsForCleanupBeforeAnotherCapture() async throws {
        let directory = try folder(); defer { try? FileManager.default.removeItem(at: directory) }
        let settings = defaults(), capture = MockAudioCapturing(), gate = CaptureSessionGate()
        var resume: CheckedContinuation<Void, Never>?
        capture.beforeSetup = { await withCheckedContinuation { resume = $0 } }
        let test = AudioTestController(capture: capture,
            source: MockAudioSourceProviding(selectedSource: .multiple(appBundleID: nil, inputs: [])),
            permissions: MockPermissionProviding(.granted), levels: AudioLevels(defaults: settings), monitor: CapturedAudioMonitor(defaults: settings),
            gate: gate, temporaryRoot: directory, saveDirectory: { directory })
        let start = Task { await test.startPreview() }
        for _ in 0..<200 where resume == nil { try await Task.sleep(for: .milliseconds(5)) }
        #expect(resume != nil)
        let close = Task { await test.close() }
        await Task.yield()
        let other = UUID()
        #expect(throws: (any Error).self) { try gate.acquire(other) }
        resume?.resume()
        await start.value; await close.value
        #expect(capture.startCount == 0 && capture.cleanupCount == 1 && !capture.capturing)
        try gate.acquire(other); gate.release(other)
        capture.beforeSetup = nil
        test.opened()
        await test.startPreview()
        #expect(test.state == .testing && capture.startCount == 1)
        await test.close()
    }

    @Test func automaticSampleStopPreservesGoodPlaybackAndReportsMissingInput() async throws {
        let directory = try folder(); defer { try? FileManager.default.removeItem(at: directory) }
        let settings = defaults(), capture = MockAudioCapturing()
        let device = InputDeviceInfo(uid: "mic", name: "Test microphone", inputChannels: 2, sampleRate: 48_000)
        let provider = MockAudioSourceProviding(selectedSource: .multiple(appBundleID: nil, inputs: [.init(device: device)]))
        provider.availableInputDevicesResult = [device]
        let test = AudioTestController(capture: capture, source: provider, permissions: MockPermissionProviding(.granted),
            levels: AudioLevels(defaults: settings), monitor: CapturedAudioMonitor(defaults: settings), temporaryRoot: directory, saveDirectory: { directory }, sampleSeconds: 0.05)
        await test.recordSample()
        capture.onSourceFailure?(.input("mic"), "Test microphone disconnected")
        let epoch = CMClockGetTime(CMClockGetHostTimeClock()).seconds
        for index in 0..<8 { capture.emit(.init(track: .playback, presentationTime: epoch + Double(index) / 100, buffer: pcm(0.4))) }
        await waitUntil("automatic sample finalization") { test.state == .ready }
        let sample = try #require(test.sample)
        #expect(test.state == .ready && !capture.capturing && capture.stopCount == 1)
        #expect(sample.warnings.contains { $0.contains("Test microphone") && $0.contains("disconnected") })
        #expect(sample.warnings.contains { $0.contains("Test microphone") && $0.contains("no audio received") })
        #expect(try decoded(sample.entry.id)[0].contains { abs($0 - 0.2) < 0.001 })
        await test.close()
        #expect(!FileManager.default.fileExists(atPath: sample.folder.path))
    }

    @Test func failedEmptySampleAndPreviewFailureReleaseAllResources() async throws {
        let directory = try folder(); defer { try? FileManager.default.removeItem(at: directory) }
        let settings = defaults(), capture = MockAudioCapturing(), gate = CaptureSessionGate()
        let scratch = directory.appendingPathComponent("scratch")
        let test = AudioTestController(capture: capture,
            source: MockAudioSourceProviding(selectedSource: .multiple(appBundleID: nil, inputs: [])),
            permissions: MockPermissionProviding(.granted), levels: AudioLevels(defaults: settings), monitor: CapturedAudioMonitor(defaults: settings),
            gate: gate, temporaryRoot: scratch, saveDirectory: { directory })
        await test.recordSample()
        await test.stop()
        #expect(test.state == .idle && test.sample == nil && test.errorMessage != nil)
        #expect(try FileManager.default.contentsOfDirectory(atPath: scratch.path).isEmpty)
        await test.startPreview()
        capture.simulateStreamError("Test capture failed")
        for _ in 0..<200 where test.state != .idle { try await Task.sleep(for: .milliseconds(5)) }
        #expect(!capture.capturing && test.errorMessage == "Test capture failed")
        let owner = UUID(); try gate.acquire(owner); gate.release(owner)
    }

    @Test func repeatedHandoffToRealRecordingControllerHasOneCaptureAndNoTestFiles() async throws {
        let directory = try folder(); defer { try? FileManager.default.removeItem(at: directory) }
        let settings = defaults(), preview = MockAudioCapturing(), recording = MockAudioCapturing(), gate = CaptureSessionGate()
        let provider = MockAudioSourceProviding(selectedSource: .multiple(appBundleID: nil, inputs: []))
        let levels = AudioLevels(defaults: settings)
        let test = AudioTestController(capture: preview, source: provider, permissions: MockPermissionProviding(.granted),
            levels: levels, monitor: CapturedAudioMonitor(defaults: settings), gate: gate,
            temporaryRoot: directory.appendingPathComponent("scratch"), saveDirectory: { directory })
        let controller = RecordingController(captureManager: recording,
            saveLocation: MockSaveLocationProviding(directory: directory), audioSource: provider, levels: levels, captureGate: gate)
        recording.onStart = { #expect(!preview.capturing) }
        for _ in 0..<2 {
            await test.startPreview()
            await #expect(throws: (any Error).self) { try await controller.startRecording(format: .wav) }
            #expect(recording.startCount == recording.stopCount)
            await test.prepareForRecording()
            _ = try await controller.startRecording(format: .wav)
            let epoch = CMClockGetTime(CMClockGetHostTimeClock()).seconds
            for index in 0..<3 { recording.emit(.init(track: .playback, presentationTime: epoch + Double(index) / 100, buffer: pcm(0.4))) }
            await test.startPreview()
            #expect(test.state == .idle && !preview.capturing)
            try await controller.stopRecording()
            test.recordingFinished()
        }
        #expect(recording.startCount == 2 && preview.startCount == 2)
        #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("scratch").path))
    }
}
