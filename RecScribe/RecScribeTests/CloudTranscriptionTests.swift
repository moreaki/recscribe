import AVFoundation
import RecScribeCore
import Synchronization
import Testing
@testable import RecScribe

private nonisolated final class CloudFixtureSocket: RealtimeSocket, Sendable {
    let sent = Mutex<[JSONValue]>([])
    let position = Mutex(0)
    func send(_ value: JSONValue) async throws { sent.withLock { $0.append(value) } }
    func receive() async throws -> JSONValue {
        let index = position.withLock { value in defer { value += 1 }; return value }
        switch index {
        case 0: return ["type": "session.updated", "session": ["type": "transcription", "audio": ["input": [
            "format": ["type": "audio/pcm", "rate": 24_000], "turn_detection": nil,
            "transcription": ["model": .string(RealtimePolicy.model)]]]]]
        case 1: return ["type": "input_audio_buffer.committed", "item_id": "test-item"]
        case 2, 3: return ["type": "conversation.item.input_audio_transcription.delta", "item_id": "test-item", "event_id": "same-delta", "delta": "Test"]
        case 4: return ["type": "conversation.item.input_audio_transcription.completed", "item_id": "test-item", "transcript": "Test transcript."]
        default: throw SessionError.invalid("Synthetic disconnect")
        }
    }
    func close() { }
}

@MainActor struct CloudTranscriptionTests {
    private func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("cloud-test-\(UUID())")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        return url
    }
    private func append(_ seconds: Int, to writer: SessionWAVWriter) throws {
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: AVAudioFormat(standardFormatWithSampleRate: 8_000, channels: 2)!,
                                                  frameCapacity: AVAudioFrameCount(seconds * 8_000)))
        buffer.frameLength = buffer.frameCapacity
        for frame in 0..<Int(buffer.frameLength) {
            buffer.floatChannelData![0][frame] = Float(frame % 100) / 200
            buffer.floatChannelData![1][frame] = 0
        }
        try writer.writeBuffer(buffer)
    }

    @Test func preferenceMigrationNeverEnablesCloudAudio() throws {
        let decoder = JSONDecoder()
        let old = try decoder.decode(AppSettings.Values.self, from: Data(#"{"aiProvider":"openai","aiEnabled":true}"#.utf8))
        #expect(old.processingLocation == .hybrid)
        #expect(AppSettings.Values().processingLocation == .local)
        let invalid = try decoder.decode(AppSettings.Values.self, from: Data(#"{"processingLocation":"unknown","aiProvider":"openai"}"#.utf8))
        #expect(invalid.processingLocation == .local)
        #expect(!invalid.migrationWarnings.isEmpty)
        var selected = AppSettings.Values(); selected.processingLocation = .cloud
        #expect(try decoder.decode(AppSettings.Values.self, from: JSONEncoder().encode(selected)) == selected)
    }

    @Test func audioConsentIsPerActivationAndDoesNotReadAKeyUntilApproved() async throws {
        var values = AppSettings.Values(); values.processingLocation = .cloud
        var keyReads = 0
        let live = LiveTranscription(settings: { values }, cloudKey: {
            keyReads += 1; throw SessionError.invalid("Synthetic missing key")
        })
        live.setEnabled(true)
        #expect(live.pendingCloudRequest == nil)
        live.recordingStarted(URL(fileURLWithPath: "/synthetic/first.wav"))
        let first = try #require(live.pendingCloudRequest)
        #expect(keyReads == 0); #expect(!live.cloudAudioActive); #expect(!live.busy)
        live.dismissCloudAudio()
        #expect(!live.enabled)
        live.setEnabled(true)
        #expect(live.pendingCloudRequest != nil)
        live.confirmCloudAudio()
        #expect(keyReads == 1); #expect(!live.enabled); #expect(live.errorMessage != nil)
        live.setEnabled(true)
        live.recordingStarted(URL(fileURLWithPath: "/synthetic/second.wav"))
        #expect(live.pendingCloudRequest?.id != first.id)
        values.processingLocation = .local
        live.configurationChanged()
        #expect(live.pendingCloudRequest == nil); #expect(!live.enabled)
        await live.shutdown()
    }

    @Test func localModeBlocksCloudTextAndCloudModeDoesNotFallbackToLocalASR() {
        var values = AppSettings.Values()
        values.aiEnabled = true; values.aiProvider = .openai; values.openaiModel = "test-model"
        #expect(throws: (any Error).self) {
            try TextProcessingRequest(transcript: URL(fileURLWithPath: "/synthetic/transcript.json"), settings: values, summary: true)
        }
        values.processingLocation = .cloud
        let library = SessionLibrary(settings: { values })
        library.transcribe(URL(fileURLWithPath: "/synthetic/recording.wav"))
        #expect(library.latestJob == nil)
        #expect(library.errorMessage?.contains("no fallback") == true)
    }

    @Test func networkFailureDoesNotStopOrModifyTheRecorderAndNeverRetries() async throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let writer = SessionWAVWriter()
        try writer.createFile(at: root.appendingPathComponent("failure.wav"), sampleRate: 8_000, channels: 2)
        try append(10, to: writer)
        let source = try #require(writer.manifestURL)
        let session = try RecordingSession.read(source)
        let consent = CloudAudioConsent(sourceSessionID: session.id, approvedAt: Date(), startSample: 0, model: RealtimePolicy.model)
        let attempts = Mutex(0)
        let client = RealtimeTranscriber { _ in
            attempts.withLock { $0 += 1 }
            throw SessionError.invalid("Synthetic network failure")
        }
        let worker = CloudTranscriptionWorker(consent: consent, key: Data("synthetic".utf8), client: client)
        var settings = AppSettings.Values(); settings.processingLocation = .cloud; settings.liveChunkSeconds = 10
        let before = try RecordingSession.hash(try #require(writer.audioURL))
        await #expect(throws: (any Error).self) {
            try await worker.step(manifest: source, directory: root.appendingPathComponent("draft"), cursor: 0,
                finished: false, settings: settings, cancel: WorkCancellation(), preview: { _ in })
        }
        #expect(attempts.withLock { $0 } == 1)
        #expect(try RecordingSession.hash(try #require(writer.audioURL)) == before)
        try append(1, to: writer); try writer.finalize()
        #expect(try RecordingSession.read(source).totalFrames == 88_000)
        #expect(try PCM16WAV.read(try #require(writer.audioURL)).frames == 88_000)
    }

    @Test func syntheticRolloverToCloudCanonicalExportsPreservesAudioAndConsentBoundary() async throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let writer = SessionWAVWriter(options: .init(maximumPartBytes: Int64(PCM16WAV.headerBytes + 5 * 8_000 * 4)))
        try writer.createFile(at: root.appendingPathComponent("synthetic.wav"), sampleRate: 8_000, channels: 2)
        try append(2, to: writer)
        let source = try #require(writer.manifestURL)
        let token = WorkCancellation()
        let boundary = try LiveAudioReader.position(manifest: source, cancel: token)
        #expect(boundary == 16_000)
        let consent = CloudAudioConsent(sourceSessionID: try RecordingSession.read(source).id, approvedAt: Date(),
                                       startSample: boundary, model: RealtimePolicy.model)
        try append(12, to: writer); try writer.finalize()
        let session = try RecordingSession.read(source)
        let hashes = try session.parts.map { try RecordingSession.hash(root.appendingPathComponent($0.path)) }
        let sockets = Mutex<[CloudFixtureSocket]>([])
        let client = RealtimeTranscriber { _ in
            let socket = CloudFixtureSocket(); sockets.withLock { $0.append(socket) }; return socket
        }
        let worker = CloudTranscriptionWorker(consent: consent, key: Data("synthetic".utf8), client: client)
        var values = AppSettings.Values(); values.processingLocation = .cloud; values.liveChunkSeconds = 10
        let job = root.appendingPathComponent("job")
        try await CloudTranscriptArtifacts.begin(job, source: source, consent: consent)
        let previews = Mutex<[String]>([])
        var cursor = boundary
        while let chunk = try await worker.step(manifest: source, directory: job, cursor: cursor, finished: true,
            settings: values, cancel: token, preview: { value in previews.withLock { $0.append(value.text) } }) {
            #expect(chunk.startFrame == cursor); #expect(chunk.segments.count == 2)
            #expect(chunk.segments.allSatisfy { $0.language == nil })
            cursor = chunk.endFrame
        }
        #expect(cursor == 112_000)
        #expect(sockets.withLock { $0.count } == 4)
        #expect(!previews.withLock { $0.contains("TestTest") })
        try await CloudTranscriptArtifacts.finish(job, source: source, consent: consent, cancel: token)
        let json = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: job.appendingPathComponent("transcript.json")))
        let canonical = try CanonicalTranscript(json)
        #expect(json["schema_version"] == "1.1")
        #expect(json["processing"]["cloud_audio_consent"]["start_sample"] == 16_000)
        #expect(json["segments"].array?.first?["start_ms"] == 2_000)
        #expect(json["segments"].array?.last?["end_ms"] == 14_000)
        #expect(json["segments"].array?.count == 4)
        #expect(json["source"]["channel_metrics"] == .null)
        for (name, text) in TranscriptRenderer.render(canonical) {
            #expect(try String(contentsOf: job.appendingPathComponent(name), encoding: .utf8) == text)
        }
        let preview = try await TranscriptPreview.read(job)
        #expect(preview.includesCloudAudio); #expect(!preview.includesCloudText)
        #expect(try session.parts.map { try RecordingSession.hash(root.appendingPathComponent($0.path)) } == hashes)
        let snapshot = try await ManifestRepository().job(at: job.appendingPathComponent("manifest.json"))
        #expect(try snapshot.validated().state == .completedWithReview)
        let library = SessionLibrary()
        library.acceptCloudTranscript(job, source: source)
        #expect(library.latestJob == job); #expect(library.progress == 1)
    }
}
