import AVFoundation
import CoreMedia
import Foundation
import os
import Testing
@testable import RecScribe

@MainActor
@Suite(.serialized)
struct SourceMixdownTests {
    private var tracks: [RecordingSession.SourceTrack] {
        [.init(role: .playback, name: "Synthetic playback"),
         .init(role: .microphone, name: "Synthetic input", deviceUID: "synthetic")]
    }
    private func folder() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("mix89-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        return root
    }
    private func packet(_ role: CaptureTrack, index: Int) -> CapturedAudioSample {
        .init(track: role, presentationTime: 100 + Double(index) / 10,
              buffer: SampleBufferFixtures.makePCMBuffer(channels: role == .playback ? 2 : 1,
                  frames: 4800, interleaved: false) { channel, _ in
                    role == .microphone ? 0.2 : (channel == 0 ? 0.4 : 0.6)
                  })
    }
    private func decode(_ session: RecordingSession, manifest: URL) throws -> [[Float]] {
        var result = [[Float]](repeating: [], count: session.channels)
        for part in session.parts {
            let file = try AVAudioFile(forReading: RecordingSession.safeURL(part.path, beside: manifest))
            let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)))
            try file.read(into: buffer)
            for channel in 0..<session.channels {
                result[channel] += Array(UnsafeBufferPointer(start: buffer.floatChannelData![channel], count: Int(buffer.frameLength)))
            }
        }
        return result
    }
    private func checkMix(_ manifest: URL, inputStartsAt: Int = 0) throws {
        let session = try RecordingSession.read(manifest)
        #expect(session.totalFrames == 192000)
        #expect(session.status == .finalized)
        #expect(session.issues.isEmpty)
        let pcm = try decode(session, manifest: manifest)
        for channel in 0..<2 {
            let playback: Float = channel == 0 ? 0.2 : 0.3
            #expect(pcm[channel].enumerated().allSatisfy { index, value in
                abs(value - (playback + (index >= inputStartsAt ? 0.1 : 0))) < 0.0001
            })
        }
        for track in try #require(session.sourceTracks) {
            let child = try LinkedSourceSessions.read(track, parent: session, at: manifest)
            #expect(child.session.totalFrames == session.totalFrames)
        }
    }
    private func completed(_ root: URL) throws -> (URL, RecordingSession, [SourceMixdown.Source]) {
        let mix = SessionWAVWriter()
        try mix.createFile(at: root.appendingPathComponent("mix.wav"), sampleRate: 48000, channels: 2)
        let writer = try SynchronizedCaptureWriter(mix: mix, descriptors: tracks, epoch: 100, options: .init())
        for index in 0..<4 {
            try writer.accept(packet(.playback, index: index))
            try writer.accept(packet(.microphone, index: index))
        }
        try writer.finish()
        let manifest = try #require(mix.manifestURL)
        let session = try SessionProcessing.process(manifest, ffmpeg: URL(fileURLWithPath: "/unused"), cancel: .init())
        let sources = try tracks.map { track -> SourceMixdown.Source in
            let descriptor = try #require(session.sourceTracks?.first { $0.role == track.role })
            let child = try LinkedSourceSessions.read(descriptor, parent: session, at: manifest)
            return .init(track: descriptor, session: child.session, manifest: child.id)
        }
        return (manifest, session, sources)
    }
    private func hashes(_ sources: [SourceMixdown.Source]) throws -> [String] {
        try sources.flatMap { source in
            try source.session.parts.map { try RecordingSession.hash(RecordingSession.safeURL($0.path, beside: source.manifest)) }
        }
    }

    @Test func delayedFirstPlaybackWithDefaultWindowKeepsEverySavedSample() throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let mix = SessionWAVWriter()
        try mix.createFile(at: root.appendingPathComponent("mix.wav"), sampleRate: 48000, channels: 2)
        let writer = try SynchronizedCaptureWriter(mix: mix, descriptors: tracks, epoch: 100, options: .init())
        for index in 0..<30 { try writer.accept(packet(.microphone, index: index)) }
        for index in 0..<30 { try writer.accept(packet(.playback, index: index)) }
        for index in 30..<40 {
            try writer.accept(packet(.playback, index: index))
            try writer.accept(packet(.microphone, index: index))
        }
        try writer.finish()
        try checkMix(#require(mix.manifestURL))
    }

    @Test(arguments: [0.0, 0.5, 1.0, 1.5, 3.0], [false, true])
    func twentyProductionStartsAreIndependentOfDeliveryOrder(delay: Double, inputDelayed: Bool) async throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let recorder = MultiSourceRecorder(onError: { message in Issue.record("Unexpected capture error: \(message)") })
        for take in 0..<2 {
            try recorder.start(at: root.appendingPathComponent("take-\(take).wav"), descriptors: tracks,
                               options: .init(), epoch: 100)
            let schedule = (0..<40).flatMap { index in
                CaptureTrack.legacyPair.map { role in
                    (index: index, role: role,
                     arrival: Double(index) / 10 + ((role == .microphone) == inputDelayed ? delay : 0))
                }
            }.sorted { $0.arrival < $1.arrival }
            for event in schedule { recorder.accept(packet(event.role, index: event.index)) }
            try await recorder.stop()
            #expect(recorder.reviewMessage == nil)
            let manifest = try #require(recorder.manifestURL)
            try checkMix(manifest)
            let before = try RecordingSession.read(manifest).totalFrames
            recorder.accept(packet(.playback, index: 40))
            #expect(try RecordingSession.read(manifest).totalFrames == before)
        }
    }

    @Test func actualLaterInputStartRetainsItsLeadingSilence() throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let mix = SessionWAVWriter()
        try mix.createFile(at: root.appendingPathComponent("mix.wav"), sampleRate: 48000, channels: 2)
        let writer = try SynchronizedCaptureWriter(mix: mix, descriptors: tracks, epoch: 100, options: .init())
        for index in 0..<40 {
            try writer.accept(packet(.playback, index: index))
            if index >= 20 { try writer.accept(packet(.microphone, index: index)) }
        }
        try writer.finish()
        try checkMix(#require(mix.manifestURL), inputStartsAt: 96000)
    }

    @Test func cancellationDuringMixCompletionKeepsSourcesAndRecoveryIsIdempotent() throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let mix = SessionWAVWriter()
        try mix.createFile(at: root.appendingPathComponent("mix.wav"), sampleRate: 48000, channels: 2)
        let writer = try SynchronizedCaptureWriter(mix: mix, descriptors: tracks, epoch: 100, options: .init())
        for index in 0..<40 { try writer.accept(packet(.microphone, index: index)) }
        #expect(throws: CancellationError.self) { try writer.finish(check: { throw CancellationError() }) }
        let manifest = try #require(mix.manifestURL)
        let partial = try RecordingSession.read(manifest)
        #expect(partial.status == .needsReview && partial.totalFrames == 0)
        let descriptor = try #require(partial.sourceTracks?.first { $0.role == .microphone })
        let child = try LinkedSourceSessions.read(descriptor, parent: partial, at: manifest)
        #expect(child.session.status == .finalized && child.session.totalFrames == 192000)
        let original = try hashes([.init(track: descriptor, session: child.session, manifest: child.id)])
        let recovered = try SessionProcessing.process(manifest, ffmpeg: URL(fileURLWithPath: "/unused"), cancel: .init(), recover: true)
        #expect(recovered.totalFrames == 192000 && recovered.status == .needsReview)
        #expect(try decode(recovered, manifest: manifest).allSatisfy { $0.allSatisfy { abs($0 - 0.1) < 0.0001 } })
        #expect(try hashes([.init(track: descriptor, session: child.session, manifest: child.id)]) == original)
        let repeated = try SessionProcessing.process(manifest, ffmpeg: URL(fileURLWithPath: "/unused"), cancel: .init(), recover: true)
        #expect(repeated.parts.map(\.path) == recovered.parts.map(\.path))
        #expect(repeated.artifacts.map(\.path) == recovered.artifacts.map(\.path))
    }

    @Test func interruptedCaptureRecoversTheDurableSourceTailWithoutOverwritingItsMixPrefix() throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        var writer: SynchronizedCaptureWriter?
        var mix: SessionWAVWriter? = SessionWAVWriter()
        try mix!.createFile(at: root.appendingPathComponent("mix.wav"), sampleRate: 48000, channels: 2)
        let manifest = try #require(mix!.manifestURL)
        writer = try SynchronizedCaptureWriter(mix: mix!, descriptors: tracks, epoch: 100, options: .init())
        for index in 0..<4 {
            try writer!.accept(packet(.playback, index: index))
            try writer!.accept(packet(.microphone, index: index))
        }
        // Delay only the input: playback's on-disk tail is longer than the safe mix prefix.
        for index in 4..<10 { try writer!.accept(packet(.playback, index: index)) }
        writer = nil; mix = nil // Simulate process loss, without normal finalization.
        let recovered = try SessionProcessing.process(manifest, ffmpeg: URL(fileURLWithPath: "/unused"), cancel: .init(), recover: true)
        #expect(recovered.totalFrames == 43200)
        #expect(recovered.parts.count == 2)
        let pcm = try decode(recovered, manifest: manifest)
        #expect(pcm[0].prefix(14400).allSatisfy { abs($0 - 0.3) < 0.0001 })
        #expect(pcm[0].dropFirst(14400).allSatisfy { abs($0 - 0.2) < 0.0001 })
        #expect(recovered.status == .needsReview)
    }

    @Test func damagedMixCanBeRebuiltButDamagedSourceCannotMasqueradeAsSuccess() throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let (manifest, session, sources) = try completed(root)
        let originals = try hashes(sources)
        let mixURL = try RecordingSession.safeURL(session.parts[0].path, beside: manifest)
        let file = try FileHandle(forWritingTo: mixURL)
        try file.truncate(atOffset: 44); try file.close()
        let partialHash = try RecordingSession.hash(mixURL)
        let recovered = try SessionProcessing.process(manifest, ffmpeg: URL(fileURLWithPath: "/unused"), cancel: .init(), recover: true)
        #expect(recovered.totalFrames == 19200)
        #expect(recovered.artifacts.contains { $0.path == mixURL.lastPathComponent && $0.sha256 == partialHash })
        #expect(try RecordingSession.hash(mixURL) == partialHash)
        #expect(try hashes(sources) == originals)
        #expect(try decode(recovered, manifest: manifest)[0].allSatisfy { abs($0 - 0.3) < 0.0001 })
        let sourceURL = try RecordingSession.safeURL(sources[0].session.parts[0].path, beside: sources[0].manifest)
        let source = try FileHandle(forWritingTo: sourceURL)
        try source.truncate(atOffset: 44); try source.close()
        let reviewed = try SessionProcessing.process(manifest, ffmpeg: URL(fileURLWithPath: "/unused"), cancel: .init(), recover: true)
        #expect(reviewed.status == .needsReview)
        #expect(reviewed.issues.contains { $0.contains("source") })
    }

    @Test func publicationFailurePreservesPrimaryManifestAndSourcesAndRemovesOnlyItsAttempt() throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let (manifest, initial, sources) = try completed(root)
        let originalHashes = try hashes(sources)
        let document = try Data(contentsOf: manifest)
        let backup = root.appendingPathComponent("primary-backup.json")
        try FileManager.default.moveItem(at: manifest, to: backup)
        try FileManager.default.createDirectory(at: manifest, withIntermediateDirectories: false)
        var pending = initial
        pending.parts[0].status = .needsReview
        #expect(throws: (any Error).self) { try SourceMixdown.recover(&pending, at: manifest, cancel: .init()) }
        #expect(pending.parts.map(\.path) == initial.parts.map(\.path))
        #expect(try hashes(sources) == originalHashes)
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).allSatisfy { !$0.contains("MixContinuation") })
        try FileManager.default.removeItem(at: manifest)
        try FileManager.default.moveItem(at: backup, to: manifest)
        #expect(try Data(contentsOf: manifest) == document)
    }

    @Test func rendererStopsOnCancellationOrWriteFailureAtABoundedBlockAndPreservesSources() throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let (_, session, sources) = try completed(root)
        let originalHashes = try hashes(sources)
        enum DiskFault: Error { case full }
        let renderer = SourceMixdown()
        var written = 0
        #expect(throws: DiskFault.self) {
            try renderer.render(sources: sources, tracks: tracks, events: session.gainAutomation!, to: session.totalFrames) { buffer in
                #expect(buffer.frameLength <= SourceMixdown.blockFrames)
                if written > 0 { throw DiskFault.full }
                written += Int(buffer.frameLength)
            }
        }
        #expect(renderer.position == 4096 && written == 4096)
        #expect(throws: CancellationError.self) {
            try renderer.render(sources: sources, tracks: tracks, events: session.gainAutomation!, to: session.totalFrames,
                check: { throw CancellationError() }, write: { _ in Issue.record("Cancelled renderer wrote data") })
        }
        #expect(renderer.position == 4096)
        #expect(try hashes(sources) == originalHashes)
    }

    @Test(arguments: [0.9999791667, 1.0000208333])
    func delayedMidRecordingPacketsAcrossWindowBoundaryRemainComplete(delay: Double) throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let mix = SessionWAVWriter(options: .init(maximumPartBytes: 48044))
        try mix.createFile(at: root.appendingPathComponent("mix.wav"), sampleRate: 48000, channels: 2)
        let writer = try SynchronizedCaptureWriter(mix: mix, descriptors: tracks, epoch: 100,
                                                 options: .init(maximumPartBytes: 48044))
        var schedule: [(index: Int, role: CaptureTrack, arrival: Double)] = []
        for index in 0..<40 {
            for role in CaptureTrack.legacyPair {
                let lag = role == .microphone && index >= 10 ? delay : 0.0
                schedule.append((index, role, Double(index) / 10 + lag))
            }
        }
        schedule.sort { $0.arrival < $1.arrival }
        for event in schedule { try writer.accept(packet(event.role, index: event.index)) }
        try writer.finish()
        let manifest = try #require(mix.manifestURL)
        try checkMix(manifest)
        #expect(try RecordingSession.read(manifest).parts.count > 1)
    }

    @Test(arguments: [-300.0, -100.0, 100.0, 300.0])
    func sourceClockConversionRemainsAlignedAfterThreeVirtualHours(ppm: Double) throws {
        var base: CMTimebase?
        #expect(CMTimebaseCreateWithSourceClock(allocator: kCFAllocatorDefault,
            sourceClock: CMClockGetHostTimeClock(), timebaseOut: &base) == noErr)
        let clock = try #require(base)
        let rate = 1 + ppm / 1_000_000
        #expect(CMTimebaseSetRate(clock, rate: rate) == noErr)
        #expect(CMTimebaseSetAnchorTime(clock, timebaseTime: .zero,
            immediateSourceTime: CMTime(seconds: 100, preferredTimescale: 48000)) == noErr)
        let pcm = SampleBufferFixtures.makePCMBuffer(channels: 2, frames: 480, interleaved: false) { _, _ in 0.2 }
        let original = SampleBufferFixtures.makeSampleBuffer(from: pcm)
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 48000),
            presentationTimeStamp: CMTime(seconds: 10800 * rate, preferredTimescale: 1_000_000_000), decodeTimeStamp: .invalid)
        var timed: CMSampleBuffer?
        #expect(CMSampleBufferCreateCopyWithNewTiming(allocator: kCFAllocatorDefault, sampleBuffer: original,
            sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleBufferOut: &timed) == noErr)
        let captured = OSAllocatedUnfairLock(initialState: Double.nan)
        let output = AudioCaptureOutput(audioCallback: { _ in }, sampleCallback: { sample in captured.withLock { $0 = sample.presentationTime } })
        let sample = try #require(timed)
        output.queue.sync { output.process(sample, type: .audio, clock: clock) }
        #expect(abs(captured.withLock { $0 } - 10900) < 1 / 48000.0)
        captured.withLock { $0 = .nan }
        output.queue.sync { output.process(sample, type: .audio) } // Drain after the stream no longer supplies its clock.
        #expect(abs(captured.withLock { $0 } - 10900) < 1 / 48000.0)
    }

    @Test func lateInputUsesHistoricalMuteAndMasterRamps() throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let mix = SessionWAVWriter()
        try mix.createFile(at: root.appendingPathComponent("mix.wav"), sampleRate: 48000, channels: 2)
        let levels = OSAllocatedUnfairLock(initialState: RecordingLevels())
        let writer = try SynchronizedCaptureWriter(mix: mix, descriptors: tracks, epoch: 100,
            options: .init(), levels: { levels.withLock { $0 } })
        for index in 0..<40 {
            if index == 20 { levels.withLock { $0.microphone.muted = true } }
            if index == 30 { levels.withLock { $0.master.decibels = -6.020599913 } }
            try writer.accept(packet(.playback, index: index))
        }
        for index in 0..<40 { try writer.accept(packet(.microphone, index: index)) }
        try writer.finish()
        let manifest = try #require(mix.manifestURL)
        let session = try RecordingSession.read(manifest)
        #expect(session.issues.isEmpty)
        #expect(session.gainAutomation?.map(\.frame) == [0, 91200, 139200])
        let pcm = try decode(session, manifest: manifest)
        for channel in 0..<2 {
            #expect(pcm[channel].enumerated().allSatisfy { frame, value in
                let mute = 1 - Float(min(480, max(0, frame - 91200))) / 480
                let master = 1 - 0.5 * Float(min(480, max(0, frame - 139200))) / 480
                let expected = ((channel == 0 ? Float(0.2) : 0.3) + 0.1 * mute) * master
                return abs(value - expected) < 0.0001
            })
        }
    }

    @Test func multichannel44100SourceKeepsRoutingAfterDeliveryBacklog() throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        var mapped = tracks
        mapped[1].channelRoutes = [.init(channel: 2, placement: .left), .init(channel: 3, placement: .right)]
        let mix = SessionWAVWriter()
        try mix.createFile(at: root.appendingPathComponent("mix.wav"), sampleRate: 48000, channels: 2)
        let writer = try SynchronizedCaptureWriter(mix: mix, descriptors: mapped, epoch: 100, options: .init())
        for index in 0..<40 { try writer.accept(packet(.playback, index: index)) }
        for index in 0..<40 {
            let buffer = SampleBufferFixtures.makePCMBuffer(channels: 4, frames: 4410, sampleRate: 44100,
                interleaved: false) { channel, _ in [Float(0.2), 0.4, 0.8, 0.1][channel] }
            try writer.accept(.init(track: .microphone, presentationTime: 100 + Double(index) / 10, buffer: buffer))
        }
        try writer.finish()
        let manifest = try #require(mix.manifestURL)
        let session = try RecordingSession.read(manifest)
        #expect(session.issues.isEmpty && session.totalFrames == 192000)
        let pcm = try decode(session, manifest: manifest)
        #expect(pcm[0].dropFirst(100).dropLast(100).allSatisfy { abs($0 - 0.6) < 0.0002 })
        #expect(pcm[1].dropFirst(100).dropLast(100).allSatisfy { abs($0 - 0.35) < 0.0002 })
        let child = try LinkedSourceSessions.read(#require(session.sourceTracks?.last), parent: session, at: manifest)
        #expect(child.session.channels == 4)
    }

    @Test func aDiscoveredSourceDoesNotRetroactivelyAttenuateAlreadyCapturedAudio() throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let mix = SessionWAVWriter()
        try mix.createFile(at: root.appendingPathComponent("mix.wav"), sampleRate: 48000, channels: 2)
        let writer = try SynchronizedCaptureWriter(mix: mix, descriptors: [tracks[0]], epoch: 100, options: .init())
        for index in 0..<10 { try writer.accept(packet(.playback, index: index)) }
        try writer.prepareSource(tracks[1])
        for index in 10..<40 { try writer.accept(packet(.playback, index: index)) }
        for index in 10..<40 { try writer.accept(packet(.microphone, index: index)) }
        try writer.finish()
        let manifest = try #require(mix.manifestURL)
        let session = try RecordingSession.read(manifest)
        #expect(session.sourceTracks?.last?.mixStartFrame == 48000)
        let pcm = try decode(session, manifest: manifest)
        #expect(pcm[0].prefix(48000).allSatisfy { abs($0 - 0.4) < 0.0001 })
        #expect(pcm[0].dropFirst(48000).allSatisfy { abs($0 - 0.3) < 0.0001 })
    }

    @Test func recoveryRetainsAnOldArchiveWithoutReusingItForTheCompletedMix() throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let (manifest, initial, _) = try completed(root)
        let oldArchive = root.appendingPathComponent("old.flac")
        try Data("synthetic old archive".utf8).write(to: oldArchive)
        let oldHash = try RecordingSession.hash(oldArchive)
        var session = initial
        session.options.archiveFormat = .flac
        session.artifacts.append(.init(path: "old.flac", format: .flac, sha256: oldHash,
            sizeBytes: 21, verification: "synthetic test archive"))
        session.parts[0].status = .needsReview
        try SourceMixdown.recover(&session, at: manifest, cancel: .init())
        #expect(session.artifacts.first?.superseded == true)
        var conversions = 0
        let converted = try SessionProcessing.process(manifest, ffmpeg: URL(fileURLWithPath: "/unused"),
            cancel: .init(), archiveWorker: { _, _, _, _ in
                conversions += 1
                let newArchive = root.appendingPathComponent("new.flac")
                try Data("synthetic new archive".utf8).write(to: newArchive)
                return .init(path: "new.flac", format: .flac, sha256: try RecordingSession.hash(newArchive),
                             sizeBytes: 21, verification: "synthetic test archive")
            })
        #expect(conversions == 1)
        #expect(converted.artifacts.contains { $0.path == "new.flac" && $0.superseded != true })
        #expect(try RecordingSession.hash(oldArchive) == oldHash)
    }

    @Test func aFailedMixStillDrainsEveryAdmittedPacketToHealthySourceFiles() async throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let writes = OSAllocatedUnfairLock(initialState: 0)
        let admitted = DispatchSemaphore(value: 0)
        let recorder = MultiSourceRecorder(onError: { _ in }, writerFactory: { options in
            SessionWAVWriter(options: options, freeBytes: { _ in
                let call = writes.withLock { $0 += 1; return $0 }
                if call <= 2 { return Int64.max }
                _ = admitted.wait(timeout: .now() + 10)
                return 0 // Only the mix sink fails; source sinks remain writable.
            })
        })
        try recorder.start(at: root.appendingPathComponent("mix.wav"), descriptors: tracks, options: .init(), epoch: 100)
        for index in 0..<40 {
            recorder.accept(packet(.playback, index: index))
            recorder.accept(packet(.microphone, index: index))
        }
        admitted.signal()
        await #expect(throws: SourceMixdown.Failure.self) { try await recorder.stop() }
        let manifest = try #require(recorder.manifestURL)
        let session = try RecordingSession.read(manifest)
        #expect(session.status == .needsReview)
        for track in try #require(session.sourceTracks) {
            let child = try LinkedSourceSessions.read(track, parent: session, at: manifest)
            #expect(child.session.totalFrames == 192000)
            #expect(child.session.status == .finalized)
        }
        #expect(recorder.sourceHealth.allSatisfy { $0.health.receivedFrames == 192000 && $0.health.writtenFrames == 192000 })
    }

    @Test func aClosedInputDoesNotBlockTheFileMixAndCannotRejoinBehindItsCommittedCursor() throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let mix = SessionWAVWriter()
        try mix.createFile(at: root.appendingPathComponent("mix.wav"), sampleRate: 48000, channels: 2)
        let writer = try SynchronizedCaptureWriter(mix: mix, descriptors: tracks, epoch: 100, options: .init())
        for index in 0..<4 {
            try writer.accept(packet(.playback, index: index))
            try writer.accept(packet(.microphone, index: index))
        }
        try writer.sourceFailed(.microphone, message: "Synthetic input shutdown")
        for index in 4..<40 { try writer.accept(packet(.playback, index: index)) }
        #expect(mix.frameCount == 187200)
        try writer.prepareSource(tracks[1])
        #expect(throws: SessionError.self) { try writer.accept(packet(.microphone, index: 4)) }
        try writer.accept(packet(.microphone, index: 40))
        try writer.accept(packet(.playback, index: 40))
        try writer.finish()
        let manifest = try #require(mix.manifestURL)
        let session = try RecordingSession.read(manifest)
        #expect(session.totalFrames == 196800 && session.status == .needsReview)
        let pcm = try decode(session, manifest: manifest)
        #expect(pcm[0][19200..<192000].allSatisfy { abs($0 - 0.2) < 0.0001 })
        #expect(pcm[0].suffix(4800).allSatisfy { abs($0 - 0.3) < 0.0001 })
    }
}
