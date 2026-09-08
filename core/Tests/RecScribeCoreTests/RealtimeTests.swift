import Foundation
import Synchronization
import Testing
@testable import RecScribeCore

final class ScriptedSocket: RealtimeSocket, Sendable {
    struct State { var events: [JSONValue]; var sent: [JSONValue] = []; var closed = false }
    let state: Mutex<State>
    let stalls: Bool
    init(_ events: [JSONValue], stalls: Bool = false) { state = Mutex(State(events: events)); self.stalls = stalls }
    func send(_ event: JSONValue) async throws { state.withLock { $0.sent.append(event) } }
    func receive() async throws -> JSONValue {
        if stalls { try await Task.sleep(for: .seconds(60)) }
        return try state.withLock {
            guard !$0.events.isEmpty else { throw CoreFailure("Synthetic disconnect") }
            return $0.events.removeFirst()
        }
    }
    func close() { state.withLock { $0.closed = true } }
    static var ready: JSONValue {
        ["type": "session.updated", "session": ["type": "transcription", "audio": ["input": [
            "format": ["type": "audio/pcm", "rate": 24_000], "turn_detection": nil,
            "transcription": ["model": .string(RealtimePolicy.model)]]]]]
    }
    static let committed: JSONValue = ["type": "input_audio_buffer.committed", "item_id": "item-1", "previous_item_id": nil]
    static let completed: JSONValue = ["type": "conversation.item.input_audio_transcription.completed", "item_id": "item-1", "transcript": "Synthetic speech."]
}

@Suite struct RealtimeTests {
    let pcm = Data(repeating: 0, count: RealtimePolicy.sampleRate * RealtimePolicy.sampleBytes)

    @Test func consentModelAndPCMPreflightNeverConnect() async {
        let calls = Mutex(0)
        let client = RealtimeTranscriber { _ in calls.withLock { $0 += 1 }; return ScriptedSocket([]) }
        for (audio, model, consent) in [(pcm, RealtimePolicy.model, false), (pcm, "summary-model", true),
                                         (Data([1]), RealtimePolicy.model, true), (Data(), RealtimePolicy.model, true)] {
            await #expect(throws: (any Error).self) {
                try await client.transcribe(pcm: audio, model: model, language: nil, key: Data("synthetic".utf8), consent: consent)
            }
        }
        #expect(calls.withLock { $0 } == 0)
    }

    @Test func confirmedSessionSendsFrameAlignedPacketsAndResolvesOutOfOrderCompletion() async throws {
        let delta: JSONValue = ["type": "conversation.item.input_audio_transcription.delta", "event_id": "delta-1", "item_id": "item-1", "delta": "Synthetic"]
        let socket = ScriptedSocket([ScriptedSocket.ready, delta, delta, ScriptedSocket.completed, ScriptedSocket.committed])
        let raw = Mutex<[JSONValue]>([])
        let result = try await RealtimeTranscriber { _ in socket }.transcribe(pcm: pcm, model: RealtimePolicy.model,
            language: "de", key: Data("synthetic".utf8), consent: true, event: { value in raw.withLock { $0.append(value) } })
        #expect(result.text == "Synthetic speech.")
        #expect(result.itemID == "item-1")
        #expect(result.firstDeltaSeconds != nil)
        let sent = socket.state.withLock { $0.sent }
        #expect(sent.first?["session"]["audio"]["input"]["transcription"]["language"] == "de")
        let packets = sent.filter { $0["type"] == "input_audio_buffer.append" }.compactMap { $0["audio"].string.flatMap { Data(base64Encoded: $0) } }
        #expect(packets.reduce(Data(), +) == pcm)
        #expect(packets.allSatisfy { $0.count <= RealtimePolicy.packetFrames * RealtimePolicy.sampleBytes && $0.count.isMultiple(of: 2) })
        #expect(sent.last?["type"] == "input_audio_buffer.commit")
        #expect(raw.withLock { $0.count } == 5)
        #expect(socket.state.withLock { $0.closed })
    }

    @Test func rejectedModelAndProviderFailureDoNotFallbackOrExposeBodies() async throws {
        var wrong = ScriptedSocket.ready
        wrong["session"]["audio"]["input"]["transcription"]["model"] = "unexpected"
        let socket = ScriptedSocket([wrong])
        await #expect(throws: (any Error).self) {
            try await RealtimeTranscriber { _ in socket }.transcribe(pcm: pcm, model: RealtimePolicy.model, language: nil,
                key: Data("synthetic".utf8), consent: true)
        }
        #expect(socket.state.withLock { $0.sent.count } == 1)
        let calls = Mutex(0)
        let failed = ScriptedSocket([["type": "error", "error": ["message": "PRIVATE PROVIDER INPUT"]]])
        do {
            _ = try await RealtimeTranscriber { _ in calls.withLock { $0 += 1 }; return failed }.transcribe(pcm: pcm,
                model: RealtimePolicy.model, language: nil, key: Data("synthetic".utf8), consent: true)
            Issue.record("Expected provider error")
        } catch { #expect(!error.localizedDescription.contains("PRIVATE")) }
        #expect(calls.withLock { $0 } == 1)
    }

    @Test func boundedResponseAndUnknownItemFailClosed() async {
        let large: JSONValue = ["type": "ignored", "payload": .string(String(repeating: "x", count: RealtimePolicy.maximumTurnBytes + 1))]
        let wrong: JSONValue = ["type": "conversation.item.input_audio_transcription.completed", "item_id": "wrong", "transcript": "wrong"]
        for events in [[large], [ScriptedSocket.ready, ScriptedSocket.committed, wrong]] {
            let socket = ScriptedSocket(events)
            await #expect(throws: (any Error).self) {
                try await RealtimeTranscriber { _ in socket }.transcribe(pcm: pcm, model: RealtimePolicy.model,
                    language: nil, key: Data("synthetic".utf8), consent: true)
            }
            #expect(socket.state.withLock { $0.closed })
        }
    }

    @Test func timeoutAndCancellationCloseTheSocket() async {
        let socket = ScriptedSocket([], stalls: true)
        await #expect(throws: (any Error).self) {
            try await RealtimeTranscriber(timeout: .milliseconds(10)) { _ in socket }.transcribe(pcm: pcm,
                model: RealtimePolicy.model, language: nil, key: Data("synthetic".utf8), consent: true)
        }
        #expect(socket.state.withLock { $0.closed })
        let cancelled = ScriptedSocket([], stalls: true)
        let task = Task {
            try await RealtimeTranscriber { _ in cancelled }.transcribe(pcm: pcm, model: RealtimePolicy.model,
                language: nil, key: Data("synthetic".utf8), consent: true)
        }
        while cancelled.state.withLock({ $0.sent.isEmpty }) { await Task.yield() }
        task.cancel()
        await #expect(throws: (any Error).self) { try await task.value }
        #expect(cancelled.state.withLock { $0.closed })
    }

    @Test func cloudSchemaRequiresTruthfulModelAndConsentProvenance() async throws {
        var doc = TranscriptFixture.document
        doc["schema_version"] = "1.1"
        doc["processing"]["local_only"] = false
        doc["processing"]["allow_cloud_audio"] = true
        doc["processing"]["cloud_audio_consent"] = ["source_session_id": "test", "approved_at": "2026-09-09", "start_sample": 0, "model": .string(RealtimePolicy.model)]
        doc["processing"]["engine_passes"] = [["engine": "openai-realtime", "version": "test", "model": .string(RealtimePolicy.model),
            "model_sha256": nil, "command": [], "duration_seconds": 1, "local_only": false]]
        _ = try CanonicalTranscript(doc)
        var invalid = doc
        invalid["processing"]["allow_cloud_audio"] = false
        #expect(throws: (any Error).self) { try CanonicalTranscript(invalid) }
        invalid = doc; invalid["schema_version"] = "1.0"
        #expect(throws: (any Error).self) { try CanonicalTranscript(invalid) }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("transcript.json"), output = root.appendingPathComponent("derived")
        try doc.encoded().write(to: source)
        try await TextJob(client: IntelligenceClient(transport: TranscriptFixture.transport())).run(source: source, output: output,
            options: .init(provider: .ollama, model: "synthetic", mode: .normalize, targetLanguage: "de", summarize: true))
        let derived = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: output.appendingPathComponent("transcript.json")))
        #expect(derived["processing"]["local_only"] == false)
        #expect(derived["processing"]["cloud_audio_consent"] == doc["processing"]["cloud_audio_consent"])
        #expect(derived["source"] == doc["source"])
        #expect(derived["summary"]["notes"].array?.count == 1)
        #expect(try Data(contentsOf: source) == doc.encoded())
    }
}
