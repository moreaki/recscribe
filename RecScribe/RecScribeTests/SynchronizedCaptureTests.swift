import AVFoundation
import Foundation
import os
import Testing
@testable import RecScribe

struct SynchronizedCaptureTests {
    private func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    private func worker(_ directory: URL, policy: SynchronizedCaptureWriter.Policy = .init()) throws -> SynchronizedCaptureWriter {
        let mix = SessionWAVWriter(options: .init(maximumPartBytes: 4_844))
        try mix.createFile(at: directory.appendingPathComponent("mix.wav"), sampleRate: 48_000, channels: 2)
        return try SynchronizedCaptureWriter(mix: mix, descriptors: [
            .init(role: .playback, name: "Test playback"), .init(role: .microphone, name: "Test input", deviceUID: "test-device")
        ], epoch: 100, options: .init(maximumPartBytes: 4_844), policy: policy)
    }
    private func sample(_ role: CaptureTrack, time: Double, frames: Int = 480, channels: Int = 2, rate: Double = 48_000) -> CapturedAudioSample {
        .init(track: role, presentationTime: 100 + time,
              buffer: SampleBufferFixtures.makePCMBuffer(channels: channels, frames: frames, sampleRate: rate, interleaved: false) { channel, _ in
                  role == .playback ? (channel == 0 ? 0.2 : 0.4) : Float(channel + 1) * 0.1 + 0.5
              })
    }
    private func decoded(_ session: RecordingSession, beside manifest: URL) throws -> [[Float]] {
        var result = Array(repeating: [Float](), count: session.channels)
        for part in session.parts {
            let file = try AVAudioFile(forReading: RecordingSession.safeURL(part.path, beside: manifest))
            let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
            try file.read(into: buffer)
            for channel in 0..<session.channels {
                result[channel] += Array(UnsafeBufferPointer(start: buffer.floatChannelData![channel], count: Int(buffer.frameLength)))
            }
        }
        return result
    }

    @Test func captureBoundaryKeepsNativeChannelsAndSourceIdentity() throws {
        let metadata = OSAllocatedUnfairLock(initialState: [(CaptureTrack, Int, Double)]())
        let output = AudioCaptureOutput(audioCallback: { _ in Issue.record("Combined capture must not use the legacy PCM-only callback") }, sampleCallback: { packet in
            let value = (packet.track, Int(packet.buffer.format.channelCount), packet.presentationTime)
            metadata.withLock { $0.append(value) }
        })
        let mic = SampleBufferFixtures.makeSampleBuffer(from: SampleBufferFixtures.makePCMBuffer(channels: 4, frames: 64, sampleRate: 44_100, interleaved: false) { _, _ in 0.2 })
        let playback = SampleBufferFixtures.nonInterleaved(frames: 64) { _, _ in 0.4 }
        output.queue.sync {
            output.process(mic, type: .microphone)
            output.process(playback, type: .audio)
        }
        let values = metadata.withLock { $0 }
        try #require(values.count == 2)
        #expect(values[0].0 == .microphone && values[0].1 == 4 && values[0].2 == 0)
        #expect(values[1].0 == .playback && values[1].1 == 2)
    }

    @Test func simultaneousSourcesAreSummedNotConcatenatedAndSourceChannelsSurvive() throws {
        let directory = try folder(); defer { try? FileManager.default.removeItem(at: directory) }
        let writer = try worker(directory)
        for index in 0..<10 {
            // Four-channel input retains all channels, but loopback-like channels
            // 3–4 are excluded from the explicitly described stereo mix.
            try writer.accept(sample(.microphone, time: Double(index) / 100, channels: 4))
            try writer.accept(sample(.playback, time: Double(index) / 100))
        }
        try writer.finish()
        let manifest = try #require(writer.mix?.manifestURL)
        let parent = try RecordingSession.read(manifest)
        #expect(parent.totalFrames == 4_800)
        #expect(parent.schemaVersion == 2)
        #expect(parent.parts.count == 4) // independent part rollover is supported
        let audio = try decoded(parent, beside: manifest)
        #expect(audio[0].allSatisfy { abs($0 - 0.4) < 0.0001 })
        #expect(audio[1].allSatisfy { abs($0 - 0.55) < 0.0001 })
        for track in try #require(parent.sourceTracks) {
            let child = try LinkedSourceSessions.read(track, parent: parent, at: manifest)
            #expect(child.session.totalFrames == parent.totalFrames)
            let saved = try decoded(child.session, beside: child.id)
            if track.role == .microphone {
                #expect(child.session.channels == 4)
                #expect(saved[3].allSatisfy { abs($0 - 0.9) < 0.0001 })
                #expect(track.mixChannels == [0, 1])
            } else { #expect(saved[0].allSatisfy { abs($0 - 0.2) < 0.0001 }) }
        }
    }

    @Test func independentClockDriftUsesTimestampsInsteadOfAccumulatingSampleError() throws {
        let directory = try folder(); defer { try? FileManager.default.removeItem(at: directory) }
        let writer = try worker(directory)
        for index in 0..<100 {
            try writer.accept(sample(.playback, time: Double(index) * 0.01))
            try writer.accept(sample(.microphone, time: Double(index) * 0.01001, channels: 1))
        }
        try writer.finish()
        let manifest = try #require(writer.mix?.manifestURL)
        let parent = try RecordingSession.read(manifest)
        #expect(parent.totalFrames == Int64((0.99 * 1.001 * 48_000).rounded()) + 480)
        #expect(parent.issues.isEmpty)
        let mic = try LinkedSourceSessions.read(#require(parent.sourceTracks?.first { $0.role == .microphone }), parent: parent, at: manifest)
        #expect(mic.session.totalFrames == parent.totalFrames)
        #expect(try decoded(mic.session, beside: mic.id)[0].allSatisfy { abs($0 - 0.6) < 0.0001 })
    }

    @Test func genuineGapsKeepTheirPositionAndAreNotReportedAsCompleteCoverage() throws {
        let directory = try folder(); defer { try? FileManager.default.removeItem(at: directory) }
        let writer = try worker(directory)
        for index in 0..<4 {
            let time = Double(index) / 100
            try writer.accept(sample(.playback, time: time))
            if index != 2 { try writer.accept(sample(.microphone, time: time, channels: 1)) }
        }
        try writer.finish()
        let manifest = try #require(writer.mix?.manifestURL)
        let parent = try RecordingSession.read(manifest)
        #expect(parent.status == .needsReview)
        let descriptor = try #require(parent.sourceTracks?.first { $0.role == .microphone })
        #expect(descriptor.gapFrames == 480)
        let mic = try LinkedSourceSessions.read(descriptor, parent: parent, at: manifest)
        let saved = try decoded(mic.session, beside: mic.id)
        #expect(saved[0][960..<1440].allSatisfy { $0 == 0 })
        #expect(abs(saved[0][1440] - 0.6) < 0.0001)
    }

    @Test func mono44100InputIsCenteredAndBothTracksShareTimeline() throws {
        let directory = try folder(); defer { try? FileManager.default.removeItem(at: directory) }
        let writer = try worker(directory)
        for index in 0..<10 {
            try writer.accept(sample(.playback, time: Double(index) / 100))
            try writer.accept(sample(.microphone, time: Double(index) / 100, frames: 441, channels: 1, rate: 44_100))
        }
        try writer.finish()
        let manifest = try #require(writer.mix?.manifestURL)
        let parent = try RecordingSession.read(manifest)
        let mix = try decoded(parent, beside: manifest)
        #expect(parent.issues.isEmpty)
        #expect(mix[0].dropFirst(100).allSatisfy { abs($0 - 0.4) < 0.005 })
        #expect(mix[1].dropFirst(100).allSatisfy { abs($0 - 0.5) < 0.005 })
    }

    @Test func missingSourceAndLateCallbacksRemainVisibleAndSourceAudioIsPreserved() throws {
        let directory = try folder(); defer { try? FileManager.default.removeItem(at: directory) }
        var policy = SynchronizedCaptureWriter.Policy(); policy.mixWindowFrames = 960
        let writer = try worker(directory, policy: policy)
        for index in 0..<8 { try writer.accept(sample(.playback, time: Double(index) / 100)) }
        for index in 0..<8 { try writer.accept(sample(.microphone, time: Double(index) / 100, channels: 1)) }
        try writer.finish()
        let manifest = try #require(writer.mix?.manifestURL)
        let parent = try RecordingSession.read(manifest)
        #expect(parent.status == .needsReview)
        #expect(parent.issues.contains { $0.contains("too late") })
        let mic = try LinkedSourceSessions.read(#require(parent.sourceTracks?.last), parent: parent, at: manifest)
        #expect(try decoded(mic.session, beside: mic.id)[0].allSatisfy { abs($0 - 0.6) < 0.0001 })
    }

    @Test func formatChangesFailExplicitlyAndFinalizationPreservesPriorAudio() throws {
        let directory = try folder(); defer { try? FileManager.default.removeItem(at: directory) }
        let writer = try worker(directory)
        try writer.accept(sample(.playback, time: 0))
        try writer.accept(sample(.microphone, time: 0, channels: 1))
        #expect(throws: SessionError.self) { try writer.accept(sample(.microphone, time: 0.01, channels: 2)) }
        #expect(throws: SessionError.self) { try writer.finish(failure: SessionError.invalid("format changed")) }
        let manifest = try #require(writer.mix?.manifestURL)
        let parent = try RecordingSession.read(manifest)
        #expect(parent.totalFrames == 480)
        #expect(parent.status == .needsReview)
    }

    @Test func interruptedGroupRecoversBothSourceFilesAndMixWithoutPromotingCoverage() throws {
        let directory = try folder(); defer { try? FileManager.default.removeItem(at: directory) }
        var writer: SynchronizedCaptureWriter? = try worker(directory)
        for index in 0..<3 {
            try writer?.accept(sample(.playback, time: Double(index) / 100))
            try writer?.accept(sample(.microphone, time: Double(index) / 100, channels: 1))
        }
        let manifest = try #require(writer?.mix?.manifestURL)
        writer = nil // no finish: simulate interrupted, unfinalized WAV headers
        let recovered = try SessionProcessing.process(manifest, ffmpeg: URL(fileURLWithPath: "/unused"), cancel: .init(), recover: true)
        #expect(recovered.status == .needsReview)
        #expect(recovered.totalFrames == 960)
        #expect(recovered.parts.allSatisfy { $0.recovered })
        for source in recovered.sourceTracks ?? [] {
            let child = try LinkedSourceSessions.read(source, parent: recovered, at: manifest)
            #expect(child.session.parts.allSatisfy { $0.recovered })
            #expect(child.session.totalFrames == 960)
            #expect(child.session.status == .needsReview)
        }
    }

    @Test func verificationExportRecoveryAndTrashKeepTheSourceGroupTogether() async throws {
        let directory = try folder(); defer { try? FileManager.default.removeItem(at: directory) }
        var writer: SynchronizedCaptureWriter? = try worker(directory)
        for index in 0..<3 {
            try writer?.accept(sample(.playback, time: Double(index) / 100))
            try writer?.accept(sample(.microphone, time: Double(index) / 100, channels: 1))
        }
        try writer?.finish()
        let manifest = try #require(writer?.mix?.manifestURL)
        writer = nil // release the mix lease before verification
        let parent = try SessionProcessing.process(manifest, ffmpeg: URL(fileURLWithPath: "/unused"), cancel: .init())
        #expect(parent.status == .completed)
        let snapshot = try await ManifestRepository().sessions(in: directory)
        #expect(snapshot.entries.count == 1)
        let destination = try folder(); defer { try? FileManager.default.removeItem(at: destination) }
        let exported = try SessionExporter().export(manifest, to: destination, checkCancellation: {})
        let exportedManifest = exported.appendingPathComponent(manifest.lastPathComponent)
        let copy = try RecordingSession.read(exportedManifest)
        for source in copy.sourceTracks ?? [] {
            #expect(try LinkedSourceSessions.read(source, parent: copy, at: exportedManifest).session.status == .completed)
        }
        try SessionDeletion.moveToTrash(manifest) { bundle in
            let saved = try RecordingSession.read(bundle.appendingPathComponent(manifest.lastPathComponent))
            for source in saved.sourceTracks ?? [] {
                #expect(try LinkedSourceSessions.read(source, parent: saved, at: bundle.appendingPathComponent(manifest.lastPathComponent)).session.totalFrames == 1440)
            }
        }
        #expect(!FileManager.default.fileExists(atPath: manifest.path))
    }
}

@MainActor
struct CombinedSourceMenuTests {
    @Test func combinedSelectionIsExplicitAndHasOneCheckedRoot() {
        let source = AudioSource.mixed(appBundleID: "test.browser", deviceUID: "test.input")
        let context = OverflowContext(selectedSource: source, selectedAppName: "Test browser",
            inputDevices: [.init(uid: "test.input", name: "Test input")])
        let roots = OverflowMenu.captureSourceEntries(context)
        let checked = roots.filter {
            switch $0 {
            case .action(let action): action.isChecked
            case .submenu(let submenu): submenu.isChecked
            default: false
            }
        }
        #expect(checked.count == 1)
        #expect(source.kind == .mixed)
        let submenu = OverflowMenu.mixedSubmenu(context)
        #expect(submenu.isChecked)
        #expect(submenu.entries.contains { if case .action(let action) = $0 { action.isChecked && action.title.contains("Test browser") } else { false } })
        #expect(OverflowMenu.captureSourceEntries(.init(selectedSource: source, allowsCaptureSourceChange: false)).isEmpty)
    }
}
