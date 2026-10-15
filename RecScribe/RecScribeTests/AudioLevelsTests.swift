import AVFoundation
import Foundation
import os
import Testing
import SwiftUI
@testable import RecScribe

@MainActor
struct AudioLevelsTests {
    private func defaults() -> UserDefaults { UserDefaults(suiteName: "levels-test-" + UUID().uuidString)! }
    private func buffer(_ value: Float = 0.25, frames: Int = 960) -> AVAudioPCMBuffer {
        SampleBufferFixtures.makePCMBuffer(channels: 2, frames: frames, interleaved: false) { _, _ in value }
    }
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true); return url
    }
    private func decoded(_ url: URL) throws -> AVAudioPCMBuffer {
        let file = try AVAudioFile(forReading: url)
        let result = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
        try file.read(into: result); return result
    }

    @Test func sourceIdentityPersistenceValidationAndOutputIndependence() throws {
        let saved = defaults(), levels = AudioLevels(defaults: saved)
        let source = AudioSource.mixed(appBundleID: "browser", deviceUID: "studio")
        levels.set(source.microphoneLevelID, .init(decibels: 6, muted: false, channelTrims: [1: -6]))
        #expect(abs(levels.snapshot(for: source).microphone.amplitude(channel: 0) - 1.9952623) < 0.00001)
        #expect(levels.snapshot(for: source).microphone.amplitude(channel: 1) == 1)
        #expect(AudioLevels(defaults: saved).level(source.microphoneLevelID) == levels.level(source.microphoneLevelID))
        #expect(levels.snapshot(for: .mic(deviceUID: "different")).microphone.decibels == 0)
        let playback = PlaybackLevels(defaults: saved)
        playback.set(.init(volume: 0.2, muted: true, outputUID: "headphones"))
        #expect(levels.level(source.microphoneLevelID).decibels == 6)
        #expect(PlaybackLevels(defaults: saved).value == playback.value)
        levels.set(source.microphoneLevelID, .init(decibels: .nan))
        levels.set(source.microphoneLevelID, .init(decibels: 25))
        #expect(levels.level(source.microphoneLevelID).decibels == 6)
        playback.set(.init(volume: .infinity))
        #expect(playback.value.volume == 0.2)
        saved.set(Data("{\"input:studio\":{\"decibels\":999,\"muted\":false,\"channelTrims\":{}}}".utf8), forKey: "audio.sourceLevels.v1")
        #expect(AudioLevels(defaults: saved).level(source.microphoneLevelID).decibels == 0)
        saved.set(Data("{\"volume\":-2,\"muted\":false}".utf8), forKey: "audio.playbackLevels.v1")
        #expect(PlaybackLevels(defaults: saved).value.volume == 1)
    }

    @Test func monitorStartsOffUsesSeparateLevelsAndRejectsUnresolvedLoopback() {
        let saved = defaults(), monitor = CapturedAudioMonitor(defaults: saved)
        let playback = PlaybackLevels(defaults: saved)
        #expect(!monitor.enabled)
        #expect(monitor.levels.value.volume == 0.5)
        monitor.levels.set(.init(volume: 0.1, muted: true))
        #expect(playback.value.volume == 1 && !playback.value.muted)
        monitor.setEnabled(true, source: .mic(deviceUID: "unresolvable-loopback-test"))
        #expect(!monitor.enabled)
        #expect(monitor.warning?.contains("feedback") == true)
        #expect(!CapturedAudioMonitor(defaults: saved).enabled)
        monitor.recordingStopped()
        #expect(!monitor.enabled)
    }

    @Test func rampsMuteResetAndOverlappingEditsAreContinuous() throws {
        var levels = RecordingLevels()
        let automation = GainAutomation(levels)
        levels.microphone.muted = true
        try automation.update(levels, at: 100)
        #expect(automation.event(at: 100).value(32, at: 100) == 1)
        #expect(automation.event(at: 340).value(32, at: 340) == 0.5)
        #expect(automation.event(at: 580).value(32, at: 580) == 0)
        levels.microphone.muted = false
        try automation.update(levels, at: 340)
        #expect(automation.event(at: 340).value(32, at: 340) == 0.5)
        #expect(automation.event(at: 820).value(32, at: 820) == 1)
        #expect(automation.event(at: 0).value(32, at: 0) == 1) // out-of-order source
        #expect(automation.events.allSatisfy { $0.valid })
        #expect(try !automation.update(levels, at: 900))
    }

    @Test func singleSourceDecodedFileUsesGainTrimsMasterAndJournalsAutomation() async throws {
        let folder = try directory(); defer { try? FileManager.default.removeItem(at: folder) }
        let levels = AudioLevels(defaults: defaults()), source = AudioSource.mic(deviceUID: "test")
        levels.set(source.microphoneLevelID, .init(decibels: 6.020599913, channelTrims: [1: -6.020599913]))
        levels.set("master", .init(decibels: -6.020599913))
        let recorder = AudioRecorder(encoderFactory: { _ in SessionWAVWriter() })
        recorder.configureLevels(source: source, levels: levels)
        try recorder.startRecording(to: folder.appendingPathComponent("single.wav"), format: .wav)
        recorder.processAudioSample(buffer())
        try await recorder.stopRecording()
        let audio = try decoded(#require(recorder.actualAudioURL))
        #expect(abs(audio.floatChannelData![0][700] - 0.25) < 0.0001)
        #expect(abs(audio.floatChannelData![1][700] - 0.125) < 0.0001)
        let session = try RecordingSession.read(#require(recorder.sessionManifestURL))
        #expect(session.gainScope == "processed_single_source")
        #expect(session.gainAutomation?.count == 1)
        #expect(recorder.healthSnapshot.postPeak != nil)
    }

    @Test func combinedFadersMuteMasterClippingAndRawTracksAreIndependent() throws {
        let folder = try directory(); defer { try? FileManager.default.removeItem(at: folder) }
        let current = OSAllocatedUnfairLock(initialState: RecordingLevels(playback: .init(decibels: 6.020599913), microphone: .init(muted: true)))
        let mix = SessionWAVWriter()
        try mix.createFile(at: folder.appendingPathComponent("mix.wav"), sampleRate: 48_000, channels: 2)
        let writer = try SynchronizedCaptureWriter(mix: mix, descriptors: [.init(role: .playback, name: "playback"), .init(role: .microphone, name: "mic")], epoch: 100, options: .init(), levels: { current.withLock { $0 } })
        for index in 0..<4 {
            for role in CaptureTrack.legacyPair {
                try writer.accept(.init(track: role, presentationTime: 100 + Double(index) * 0.02, buffer: buffer()))
            }
        }
        current.withLock { $0.master.decibels = 24; $0.microphone.muted = false }
        for index in 4..<8 {
            for role in CaptureTrack.legacyPair {
                try writer.accept(.init(track: role, presentationTime: 100 + Double(index) * 0.02, buffer: buffer()))
            }
        }
        try writer.finish()
        let manifest = try #require(mix.manifestURL), session = try RecordingSession.read(manifest)
        let output = try decoded(#require(mix.audioURL))
        #expect(abs(output.floatChannelData![0][1000] - 0.25) < 0.0001)
        #expect(output.floatChannelData![0][7000] > 0.99)
        #expect(session.status == .needsReview)
        #expect(session.gainScope == "derived_mix")
        #expect(session.gainAutomation?.count == 2)
        #expect(writer.health(for: .playback).clipped)
        for track in try #require(session.sourceTracks) {
            let child = try LinkedSourceSessions.read(track, parent: session, at: manifest)
            let audio = try decoded(RecordingSession.safeURL(child.session.parts[0].path, beside: child.id))
            #expect((0..<Int(audio.frameLength)).allSatisfy { abs(audio.floatChannelData![0][$0] - 0.25) < 0.0001 })
            #expect(child.session.gainAutomation == nil)
        }
    }

    @Test func liveMuteRampsSavedSamplesWithoutRestartingCapture() async throws {
        let folder = try directory(); defer { try? FileManager.default.removeItem(at: folder) }
        let levels = AudioLevels(defaults: defaults()), source = AudioSource.mic(deviceUID: "live-test")
        let recorder = AudioRecorder(encoderFactory: { _ in SessionWAVWriter() })
        recorder.configureLevels(source: source, levels: levels)
        try recorder.startRecording(to: folder.appendingPathComponent("live.wav"), format: .wav)
        recorder.processAudioSample(buffer())
        for _ in 0..<1000 where recorder.healthSnapshot.writtenFrames == 0 {
            try await Task.sleep(for: .milliseconds(1))
        }
        try #require(recorder.healthSnapshot.writtenFrames == 960)
        levels.set(source.microphoneLevelID, .init(muted: true))
        recorder.processAudioSample(buffer())
        try await recorder.stopRecording()
        let audio = try decoded(#require(recorder.actualAudioURL))
        withExtendedLifetime(audio) {
            let output = audio.floatChannelData![0]
            #expect(abs(output[960] - 0.25) < 0.0001)
            #expect(abs(output[1200] - 0.125) < 0.0001)
            #expect(output[1440] == 0)
        }
        let saved = try RecordingSession.read(#require(recorder.sessionManifestURL))
        #expect(saved.gainAutomation?.count == 2)
        #expect(saved.gainAutomation?.last?.frame == 960)
        var invalid = saved
        invalid.gainAutomation![0].to[0] = .infinity
        #expect(throws: (any Error).self) { try invalid.validated(beside: recorder.sessionManifestURL!) }
    }

    @Test func importedWAVUsesAppVolumeAndRecordingPreemption() async throws {
        let folder = try directory(); defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("imported.wav"), writer = WAVWriter()
        try writer.createFile(at: url, sampleRate: 48_000, channels: 2)
        try writer.writeBuffer(buffer()); try writer.finalize()
        let settings = PlaybackLevels(defaults: defaults())
        settings.set(.init(volume: 0.35, muted: true))
        let controller = SessionPlayback(activate: { _ in }, levels: settings)
        controller.playFile(url)
        for _ in 0..<1000 where controller.loading { try await Task.sleep(for: .milliseconds(1)) }
        #expect(controller.player?.volume == 0.35)
        #expect(controller.player?.isMuted == true)
        settings.set(.init(volume: 0.6, muted: false))
        for _ in 0..<100 where controller.player?.isMuted == true { await Task.yield() }
        #expect(controller.player?.volume == 0.6)
        #expect(controller.player?.isMuted == false)
        controller.setRecording(true)
        #expect(controller.player == nil)
        controller.playFile(url)
        #expect(!controller.loading)
    }

    @Test func sharedPlaybackControlsRenderAtCompactAndStudioWidths() async throws {
        let settings = PlaybackLevels(defaults: defaults())
        let playback = SessionPlayback(build: { _ in AVPlayerItem(asset: AVMutableComposition()) }, activate: { _ in }, levels: settings)
        playback.play(.init(id: URL(fileURLWithPath: "/render-test"), session: .init(sampleRate: 48_000, channels: 2, channelMap: ["L", "R"], options: .init())))
        for _ in 0..<100 where playback.loading { await Task.yield() }
        try #require(playback.player != nil)
        defer { playback.stop() }
        for width: CGFloat in [360, 640] {
            let hosting = NSHostingView(rootView: SessionPlaybackView(playback: playback).padding().frame(width: width).preferredColorScheme(.dark))
            hosting.frame = CGRect(x: 0, y: 0, width: width, height: 260)
            let window = NSWindow(contentRect: hosting.frame, styleMask: .borderless, backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = hosting
            hosting.layoutSubtreeIfNeeded()
            let bitmap = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
            hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
            if width == 640, let png = bitmap.representation(using: .png, properties: [:]) {
                try png.write(to: URL(fileURLWithPath: "/tmp/recscribe-playback-controls.png"))
            }
            #expect(hosting.fittingSize.width <= width + 1)
            window.contentView = nil; window.close()
        }
    }

    @Test func everyNewPlayerReceivesVolumeMuteAndRouteFallback() async {
        let settings = PlaybackLevels(defaults: defaults())
        settings.set(.init(volume: 0.3, muted: true, outputUID: "unplugged-test-output"))
        let controller = SessionPlayback(build: { _ in AVPlayerItem(asset: AVMutableComposition()) }, activate: { _ in }, levels: settings)
        for value: Float in [0.3, 0.8] {
            settings.set(.init(volume: value, muted: true, outputUID: "unplugged-test-output"))
            controller.play(.init(id: URL(fileURLWithPath: "/test"), session: .init(sampleRate: 48_000, channels: 2, channelMap: ["L", "R"], options: .init())))
            for _ in 0..<100 where controller.loading { await Task.yield() }
            #expect(controller.player?.volume == value)
            #expect(controller.player?.isMuted == true)
            #expect(controller.player?.audioOutputDeviceUniqueID == nil)
            #expect(controller.effectiveOutput.contains("unavailable"))
            controller.stop()
        }
        controller.setRecording(true)
        #expect(controller.player == nil)
        settings.set(.init())
        let player = AVPlayer()
        settings.apply(to: player, devices: [])
        #expect(player.volume == 1 && !player.isMuted)
        #expect(!AudioDeviceControls.set(.init(device: 0, input: true, element: 0, value: 0), value: .nan))
    }
}
