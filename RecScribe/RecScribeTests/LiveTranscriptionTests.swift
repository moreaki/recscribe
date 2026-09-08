import AVFoundation
import Testing
@testable import RecScribe

@MainActor
struct LiveTranscriptionTests {
    private func folder() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("live-test-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        return directory
    }
    private func recording(_ directory: URL, seconds: Int = 22, identical: Bool = false) throws -> SessionWAVWriter {
        let rate = 8_000
        let writer = SessionWAVWriter(options: .init(maximumPartBytes: Int64(PCM16WAV.headerBytes + 5 * rate * 4)))
        try writer.createFile(at: directory.appendingPathComponent("synthetic.wav"), sampleRate: Double(rate), channels: 2)
        let buffer = AVAudioPCMBuffer(pcmFormat: AVAudioFormat(standardFormatWithSampleRate: Double(rate), channels: 2)!, frameCapacity: AVAudioFrameCount(seconds * rate))!
        buffer.frameLength = buffer.frameCapacity
        for frame in 0..<Int(buffer.frameLength) {
            buffer.floatChannelData![0][frame] = Float(frame % 100) / 200
            buffer.floatChannelData![1][frame] = identical ? buffer.floatChannelData![0][frame] : 0
        }
        try writer.writeBuffer(buffer)
        return writer
    }

    @Test func liveRolloverReadsCommittedFramesWithoutChangingOriginals() throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let writer = try recording(root)
        let manifest = try #require(writer.manifestURL)
        let before = try RecordingSession.read(manifest)
        let hashes = try before.parts.map { try RecordingSession.hash(root.appendingPathComponent($0.path)) }
        let first = try #require(try LiveAudioReader.copy(manifest: manifest, cursor: 0, seconds: 20, overlapSeconds: 1,
            finished: false, to: root.appendingPathComponent("first.wav"), cancel: WorkCancellation()))
        #expect(first.endFrame == 160_000)
        #expect(first.availableFrames == 176_000)
        #expect(!first.identicalChannels)
        #expect(try PCM16WAV.read(first.file).frames == 160_000)
        #expect(try LiveAudioReader.copy(manifest: manifest, cursor: first.endFrame, seconds: 20, overlapSeconds: 1,
            finished: false, to: root.appendingPathComponent("waiting.wav"), cancel: WorkCancellation()) == nil)
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("waiting.wav").path))
        #expect(try before.parts.map { try RecordingSession.hash(root.appendingPathComponent($0.path)) } == hashes)
        try writer.finalize()
        let tail = try #require(try LiveAudioReader.copy(manifest: manifest, cursor: first.endFrame, seconds: 20, overlapSeconds: 1,
            finished: true, to: root.appendingPathComponent("tail.wav"), cancel: WorkCancellation()))
        #expect(tail.startFrame == 152_000)
        #expect(tail.endFrame == 176_000)
        let all = try before.parts.reduce(into: Data()) { bytes, part in bytes.append(try Data(contentsOf: root.appendingPathComponent(part.path)).dropFirst(PCM16WAV.headerBytes)) }
        #expect(try Data(contentsOf: first.file).dropFirst(PCM16WAV.headerBytes) == all.prefix(160_000 * 4))
        #expect(try Data(contentsOf: tail.file).dropFirst(PCM16WAV.headerBytes) == all.suffix(24_000 * 4))
    }

    @Test func identicalChannelsAndOutputCollisionsAreHandledWithoutOverwriting() throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let writer = try recording(root, seconds: 1, identical: true)
        try writer.finalize()
        let destination = root.appendingPathComponent("chunk.wav")
        let manifest = try #require(writer.manifestURL)
        let chunk = try #require(try LiveAudioReader.copy(manifest: manifest, cursor: 0, seconds: 10, overlapSeconds: 1,
            finished: true, to: destination, cancel: WorkCancellation()))
        #expect(chunk.identicalChannels)
        let hash = try RecordingSession.hash(destination)
        #expect(throws: WAVWriterError.fileCreationFailed) {
            try LiveAudioReader.copy(manifest: manifest, cursor: 0, seconds: 10, overlapSeconds: 1,
                finished: true, to: destination, cancel: WorkCancellation())
        }
        #expect(try RecordingSession.hash(destination) == hash)
        let token = WorkCancellation(); token.cancel()
        #expect(throws: CancellationError.self) {
            try LiveAudioReader.copy(manifest: manifest, cursor: 0, seconds: 10, overlapSeconds: 1,
                finished: true, to: root.appendingPathComponent("cancelled.wav"), cancel: token)
        }
    }

    @Test func missingReplacedAndGappedPartsFailClosed() throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let writer = try recording(root, seconds: 1); try writer.finalize()
        let manifest = try #require(writer.manifestURL)
        var session = try RecordingSession.read(manifest)
        session.parts[0].fileID = 0
        try session.save(manifest)
        #expect(throws: (any Error).self) {
            try LiveAudioReader.copy(manifest: manifest, cursor: 0, seconds: 10, overlapSeconds: 1,
                finished: true, to: root.appendingPathComponent("replaced.wav"), cancel: WorkCancellation())
        }
        session.parts[0].startSample = 1
        try session.save(manifest)
        #expect(throws: (any Error).self) {
            try LiveAudioReader.copy(manifest: manifest, cursor: 0, seconds: 10, overlapSeconds: 1,
                finished: true, to: root.appendingPathComponent("gap.wav"), cancel: WorkCancellation())
        }
    }

    @Test func nativeResamplingKeepsDistinctChannelsAndFlushesTail() throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let writer = try recording(root, seconds: 1); try writer.finalize()
        let source = try #require(writer.audioURL)
        for channel in 0..<2 {
            let output = root.appendingPathComponent("mono-\(channel).wav")
            try LiveWhisperTranscriber.convert(source, channel: channel, to: output, cancel: WorkCancellation())
            let file = try AVAudioFile(forReading: output)
            #expect(file.fileFormat.sampleRate == 16_000)
            #expect(file.fileFormat.channelCount == 1)
            #expect(abs(file.length - 16_000) <= 1)
            let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
            try file.read(into: buffer)
            let peak = (0..<Int(buffer.frameLength)).map { abs(buffer.floatChannelData![0][$0]) }.max() ?? 0
            #expect(channel == 0 ? peak > 0.1 : peak == 0)
        }
    }

    @Test func timestampsOwnNewAudioAndLanguageIsRetained() throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let raw = root.appendingPathComponent("raw.json")
        try Data(#"{"result":{"language":"de"},"transcription":[{"offsets":{"from":0,"to":900},"text":"context"},{"offsets":{"from":900,"to":3000},"text":" Neue Worte "}]}"#.utf8).write(to: raw)
        let slice = LiveAudioReader.Slice(file: raw, startFrame: 19_000, endFrame: 22_000, availableFrames: 22_000, sampleRate: 1_000, channels: 2, identicalChannels: false)
        let parsed = try LiveWhisperTranscriber.parse(raw, slice: slice, cursor: 20_000, channel: 1)
        #expect(parsed.count == 1)
        #expect(parsed[0].startSeconds == 20)
        #expect(parsed[0].endSeconds == 22)
        #expect(parsed[0].language == "de")
        #expect(parsed[0].channel == 1)
        #expect(parsed[0].text == "Neue Worte")
    }

    @Test func digitalSilenceRecordsSkippedASRWithoutLaunchingTheExecutable() async throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 8_000, channels: 2))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8_000))
        buffer.frameLength = buffer.frameCapacity
        for channel in 0..<2 { buffer.floatChannelData![channel].update(repeating: 0, count: 8_000) }
        let writer = SessionWAVWriter()
        let audio = root.appendingPathComponent("silence.wav")
        try writer.createFile(at: audio, sampleRate: 8_000, channels: 2)
        try writer.writeBuffer(buffer)
        try writer.finalize()
        let manifest = try #require(writer.manifestURL)
        var settings = AppSettings.Values()
        // Any accidental ASR launch fails: no actual model is needed for silence.
        settings.whisperPath = "/usr/bin/false"
        settings.modelPath = audio.path
        let configured = settings
        let result = try await Task.detached(priority: .utility) {
            try LiveWhisperTranscriber.step(manifest: manifest, directory: root.appendingPathComponent("draft"),
                cursor: 0, finished: true, settings: configured, cancel: WorkCancellation())
        }.value
        let chunk = try #require(result)
        #expect(chunk.asrRuns == 0)
        #expect(chunk.segments.isEmpty)
        #expect(chunk.endFrame == 8_000)
        let saved = try JSONDecoder().decode(LiveChunkResult.self, from: Data(contentsOf: chunk.directory.appendingPathComponent("chunk.json")))
        #expect(saved.asrRuns == 0)
    }

    @MainActor final class Worker {
        var requests: [(Int64, Bool)] = []
        var pending: [CheckedContinuation<LiveChunkResult?, any Error>] = []
        func run(cursor: Int64, final: Bool) async throws -> LiveChunkResult? {
            requests.append((cursor, final))
            return try await withCheckedThrowingContinuation { pending.append($0) }
        }
        func finish(_ result: LiveChunkResult?) { pending.removeFirst().resume(returning: result) }
    }

    @Test func optInIsSerialAndCancelledResultsCannotAdvanceCursor() async {
        let worker = Worker()
        let live = LiveTranscription(work: { _, _, cursor, final, _, _ in try await worker.run(cursor: cursor, final: final) })
        let source = URL(fileURLWithPath: "/synthetic.wav")
        live.recordingStarted(source)
        #expect(worker.requests.isEmpty)
        live.setEnabled(true)
        await waitUntil("first live request") { worker.pending.count == 1 }
        live.setEnabled(false)
        live.setEnabled(true)
        #expect(worker.requests.count == 1)
        let stale = LiveChunkResult(startFrame: 0, endFrame: 20, availableFrames: 20, sampleRate: 1, durationSeconds: 1, segments: [], directory: source)
        worker.finish(stale)
        await waitUntil("replacement request") { worker.requests.count == 2 }
        #expect(live.cursor == 0)
        #expect(worker.requests.last?.0 == 0)
        live.recordingStopped()
        worker.finish(stale)
        await waitUntil("tail request") { worker.requests.count == 3 }
        #expect(worker.requests.last?.0 == 20)
        #expect(worker.requests.last?.1 == true)
        worker.finish(nil)
        await waitUntil("live drain complete") { !live.busy }
        #expect(live.cursor == 20)
        #expect(live.errorMessage == nil)
        await live.shutdown()
    }

    @Test func livePreviewAndPreferencesAreBounded() throws {
        let values = (0..<1000).map { index in LiveSegment(id: UUID(), startSeconds: Double(index), endSeconds: Double(index + 1), channel: 0, language: "en", text: "text") }
        #expect(LiveTranscription.preview(values).count == LiveTranscriptionPolicy.previewSegments)
        #expect(LiveTranscription.preview(values).last == values.last)
        let preferences = try JSONDecoder().decode(AppSettings.Values.self, from: Data(#"{"liveChunkSeconds":-1,"liveThreads":99,"modelPath":"/keep/model"}"#.utf8))
        #expect(preferences.liveThreads == LiveTranscriptionPolicy.defaultThreads)
        #expect(preferences.liveChunkSeconds == LiveTranscriptionPolicy.defaultChunkSeconds)
        #expect(preferences.modelPath == "/keep/model")
        #expect(preferences.migrationWarnings.count == 2)
        let text = "[hello](https://example.com) **literal**"
        #expect(String(MarkdownReadingText.literal(text).characters) == text)
        #expect(MarkdownReadingText.literal(text).runs.allSatisfy { $0.link == nil })
    }

    @Test func interruptedDraftCannotBecomeReadyAndANewRecordingResetsIt() async {
        let worker = Worker()
        let live = LiveTranscription(work: { _, _, cursor, final, _, _ in try await worker.run(cursor: cursor, final: final) })
        let source = URL(fileURLWithPath: "/synthetic.wav")
        live.setEnabled(true)
        live.recordingStarted(source)
        await waitUntil("live chunk") { worker.pending.count == 1 }
        live.recordingStopped(needsReview: true)
        worker.finish(.init(asrRuns: 0, startFrame: 0, endFrame: 20, availableFrames: 20, sampleRate: 1,
                            durationSeconds: 0.013, segments: [], directory: source))
        await waitUntil("final chunk") { worker.pending.count == 1 }
        worker.finish(nil)
        await waitUntil("draft drained") { !live.busy }
        #expect(live.captureNeedsReview)
        #expect(live.status == "Partial live draft · recording needs review")
        #expect(live.lastChunk?.label.contains("ASR skipped") == true)
        #expect(live.lastChunk?.label.contains("13") == true)
        live.setEnabled(false)
        #expect(live.captureNeedsReview)
        live.recordingStarted(source)
        #expect(!live.captureNeedsReview)
        #expect(live.lastChunk == nil)
        await live.shutdown()
    }

    @Test func processingTimingsDistinguishSilenceFromEmptyRecognitionAndOldEvidence() throws {
        let run = LiveChunkTiming(wallSeconds: 1.25, audioSeconds: 20, asrRuns: 1)
        #expect(!run.label.contains("silence"))
        let old = LiveChunkResult(startFrame: 0, endFrame: 20, availableFrames: 20, sampleRate: 1,
                                  durationSeconds: 0.013, segments: [], directory: URL(fileURLWithPath: "/synthetic"))
        let data = try JSONEncoder().encode(old)
        let decoded = try JSONDecoder().decode(LiveChunkResult.self, from: data)
        #expect(decoded.asrRuns == nil)
        #expect(!LiveChunkTiming(wallSeconds: decoded.durationSeconds, audioSeconds: 20,
                                asrRuns: decoded.asrRuns).label.contains("silence"))
    }

    @Test func disabledLiveStatusTracksStopAndNewRecordingAfterASRError() async {
        let live = LiveTranscription(work: { _, _, _, _, _, _ in throw SessionError.invalid("Synthetic ASR failure") })
        let source = URL(fileURLWithPath: "/synthetic.wav")
        live.setEnabled(true)
        live.recordingStarted(source)
        await waitUntil("live failure") { !live.busy }
        live.recordingStopped(needsReview: true)
        #expect(live.status.contains("draft is incomplete"))
        #expect(!live.status.contains("recording is unaffected"))
        live.recordingStarted(source)
        #expect(live.status == "Live transcription is off · audio is still recorded")
        #expect(live.errorMessage == nil)
        live.recordingStopped()
        #expect(live.status == "Live transcription is off")
        await live.shutdown()
    }

    @Test func canonicalPreviewKeepsModesSourcesAndReviewSeparate() async throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("transcript.json")
        let json = #"{"schema_version":"1.0","processing":{"mode":"normalize"},"segments":[{"id":"s1","source_text":"raw words","normalized_text":"clean words","translated_text":"translated words","needs_review":true}],"summary":{"notes":[{"text":"a note","segment_ids":["s1"]}]},"review_reasons":["verify names"]}"#
        try Data(json.utf8).write(to: file)
        let preview = try await TranscriptPreview.read(root)
        #expect(preview.text == "[Review] clean words")
        #expect(preview.segments[0].sourceText == "raw words")
        #expect(preview.summaryText == "a note\nSources: s1")
        #expect(preview.reviewReasons == ["verify names"])
        try Data(json.replacingOccurrences(of: "1.0", with: "future").utf8).write(to: file)
        await #expect(throws: (any Error).self) { try await TranscriptPreview.read(root) }
    }

    @Test func failuresDisableOnlyLiveWorkAndNewRecordingRejectsOldResults() async {
        let broken = LiveTranscription(work: { _, _, _, _, _, _ in throw SessionError.invalid("Synthetic ASR failure") })
        broken.setEnabled(true)
        broken.recordingStarted(URL(fileURLWithPath: "/first.wav"))
        await waitUntil("ASR failure surfaced") { !broken.busy }
        #expect(!broken.enabled)
        #expect(broken.errorMessage?.contains("Synthetic") == true)
        #expect(broken.status.contains("recording is unaffected"))
        await broken.shutdown()
        let worker = Worker()
        let live = LiveTranscription(work: { _, _, cursor, final, _, _ in try await worker.run(cursor: cursor, final: final) })
        live.setEnabled(true)
        live.recordingStarted(URL(fileURLWithPath: "/first.wav"))
        await waitUntil("old request") { worker.pending.count == 1 }
        live.recordingStarted(URL(fileURLWithPath: "/second.wav"))
        worker.finish(.init(startFrame: 0, endFrame: 99, availableFrames: 99, sampleRate: 1, durationSeconds: 1,
                            segments: [], directory: URL(fileURLWithPath: "/old")))
        await waitUntil("new session request") { worker.requests.count == 2 }
        #expect(live.cursor == 0)
        live.setEnabled(false)
        worker.finish(nil)
        await live.shutdown()
    }
}
