import CryptoKit
import Foundation
import Testing
@testable import RecScribeCore

enum TranscriptFixture {
    static var document: JSONValue {
        let hash = JSONValue.string(String(repeating: "a", count: 64))
        return [
            "schema_version": "1.0", "job_id": "synthetic", "status": "completed",
            "source": ["path": "/synthetic/recording.wav", "sha256": hash, "duration_ms": 2_000,
                "channels": 1, "sample_rate": 16_000, "bit_depth": 16, "frames": 32_000,
                "size_bytes": 64_044, "container": "WAV", "codec": "PCM",
                "channel_metrics": [["channel": 0, "peak": 0, "rms": 0, "clipped_samples": 0, "digital_silence": false]],
                "future_audio_metadata": ["sample_counter": 9_007_199_254_740_993]],
            "processing": ["source_language": "de-CH", "target_language": nil, "mode": "verbatim", "profile": "fast",
                "diarize": "off", "local_only": true, "engine_passes": [], "pipeline_version": "synthetic",
                "started_at": "2026-01-01T00:00:00Z", "duration_ms": 0, "formats": ["json", "md", "txt", "srt", "vtt"]],
            "language_processing": ["mode": "verbatim", "status": "not_requested", "processor": nil, "derivations": []],
            "segments": [["id": "seg-000001", "start_ms": 0, "end_ms": 2_000, "channel": 0, "speaker": nil,
                "source_text": "Grüezi <world>!\n\"Test\" & [link] --> ü 🇨🇭", "normalized_text": nil, "translated_text": nil,
                "confidence": nil, "needs_review": false, "review_reasons": [], "words": []]],
            "review_reasons": []
        ]
    }
    static func transport(result: JSONValue? = nil) -> MockTransport {
        MockTransport { request in
            if request.url?.lastPathComponent == "show" { return ["model_info": ["architecture": "synthetic"]] }
            let payload = try JSONDecoder().decode(JSONValue.self, from: #require(request.httpBody))
            let prompt = try JSONDecoder().decode(JSONValue.self, from: Data(try #require(payload["prompt"].string).utf8))
            let value: JSONValue = result ?? ["segments": .array((prompt["untrusted_transcript"].array ?? []).map { ["id": $0["id"], "text": "Guten Tag!"] }),
                "notes": [["text": "A greeting.", "segment_ids": .array((prompt["untrusted_transcript"].array ?? []).map { $0["id"] })]]]
            return ["done": true, "response": .string(String(decoding: try value.encoded(), as: UTF8.self)), "prompt_eval_count": 10, "eval_count": 5]
        }
    }
}

@Suite struct TextJobTests {
    @Test func resourceIsExactlyTheAuthoritativeSchema() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        #expect(try Data(contentsOf: CanonicalTranscript.schemaURL) == Data(contentsOf: root.appendingPathComponent("schemas/transcript.schema.json")))
    }
    @Test func schemaAndSemanticValidationRejectCorruption() throws {
        let original = TranscriptFixture.document
        _ = try CanonicalTranscript(original)
        let mutations: [(inout JSONValue) -> Void] = [
            { $0["schema_version"] = "2.0" }, { $0["unexpected"] = true },
            { $0["source"]["channels"] = 0 }, { $0["source"]["sha256"] = "bad" },
            { $0["processing"]["local_only"] = false }, { $0["processing"]["mode"] = "normalize" },
            { $0["status"] = "completed_with_review" },
            { var s = $0["segments"].array!; s[0]["end_ms"] = 2_001; $0["segments"] = .array(s) },
            { var s = $0["segments"].array!; s[0]["normalized_text"] = "Unproven"; $0["segments"] = .array(s) },
            { var s = $0["segments"].array!; s[0]["channel"] = 1; $0["segments"] = .array(s) },
            { var s = $0["segments"].array!; s.append(s[0]); $0["segments"] = .array(s) }
        ]
        for mutate in mutations {
            var value = original; mutate(&value)
            #expect(throws: (any Error).self) { try CanonicalTranscript(value) }
        }
    }
    @Test func integersAndExtensibleSourceSurviveRoundTrip() throws {
        let document = TranscriptFixture.document
        let roundTrip = try JSONDecoder().decode(JSONValue.self, from: document.encoded())
        #expect(roundTrip == document)
        #expect(roundTrip["source"]["future_audio_metadata"]["sample_counter"].integer == 9_007_199_254_740_993)
    }
    @Test func exportsEscapeMarkupAndPreserveRawText() throws {
        let document = try CanonicalTranscript(TranscriptFixture.document)
        let exports = TranscriptRenderer.render(document)
        #expect(exports.count == 5)
        #expect(exports["transcript.verbatim.txt"] == document.value["segments"].array![0]["source_text"].string! + "\n")
        #expect(exports["transcript.srt"]?.hasPrefix("1\n00:00:00,000 --> 00:00:02,000\n") == true)
        #expect(exports["transcript.srt"]?.contains("&lt;world&gt;") == true)
        #expect(exports["transcript.cleaned.md"]?.contains("\\[link\\]") == true)
        #expect(TranscriptRenderer.timestamp(360_000_001) == "100:00:00.001")
    }

    @Test func nativeJobPreservesParentRawAndCreatesVerifiedInventory() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("transcript.json"), output = root.appendingPathComponent("derived")
        let original = try TranscriptFixture.document.encoded()
        try original.write(to: source)
        let job = TextJob(client: .init(transport: TranscriptFixture.transport()))
        try await job.run(source: source, output: output, options: .init(provider: .ollama, model: "synthetic", mode: .normalize, targetLanguage: "de", summarize: true))
        let document = try read(output, "transcript.json")
        _ = try CanonicalTranscript(document)
        #expect(try Data(contentsOf: source) == original)
        #expect(document["source"] == TranscriptFixture.document["source"])
        #expect(document["segments"].array?[0]["source_text"] == TranscriptFixture.document["segments"].array?[0]["source_text"])
        #expect(document["segments"].array?[0]["normalized_text"] == "Guten Tag!")
        #expect(document["summary"]["notes"].array?.first?["segment_ids"] == ["seg-000001"])
        let manifest = try read(output, "manifest.json")
        #expect(manifest["state"] == "completed_with_review")
        #expect(manifest["history"].array?.compactMap { $0["state"].string } == ["queued", "post-processing", "validating", "rendering", "completed_with_review"])
        for (name, entry) in manifest["artifacts"].object ?? [:] {
            let data = try Data(contentsOf: output.appendingPathComponent(name))
            #expect(TextJob.hash(data) == entry["sha256"].string)
            #expect(Int64(data.count) == entry["size_bytes"].integer)
        }
        #expect(try read(output, "transcript.raw.json")["raw_asr_unchanged"] == true)
        try validateWithPythonReference(output)
        let manifestBefore = try Data(contentsOf: output.appendingPathComponent("manifest.json"))
        await #expect(throws: (any Error).self) {
            try await job.run(source: source, output: output, options: .init(provider: .ollama, model: "synthetic", mode: .normalize, targetLanguage: "de"))
        }
        #expect(try Data(contentsOf: output.appendingPathComponent("manifest.json")) == manifestBefore)
        // Summary-only must retain normalized text and point back to its evidence.
        let summary = root.appendingPathComponent("summary")
        try await job.run(source: output.appendingPathComponent("transcript.json"), output: summary,
            options: .init(provider: .ollama, model: "synthetic", mode: .verbatim, summarize: true))
        let summarized = try read(summary, "transcript.json")
        #expect(summarized["segments"] == document["segments"])
        #expect(summarized["processing"]["mode"] == "normalize")
        #expect(summarized["language_processing"]["derivations"].array?.first?["raw_path"].string == output.appendingPathComponent("ai-raw-0000.json").path)
        try validateWithPythonReference(summary)
    }

    @Test func invalidAIOutputRetainsRawResponseButNeverPublishesTranscript() async throws {
        let results: [JSONValue] = [
            ["segments": [], "notes": []],
            ["segments": [["id": "seg-999999", "text": "invented"]], "notes": []],
            ["segments": [["id": "seg-000001", "text": " "]], "notes": []],
            ["segments": [["id": "seg-000001", "text": "derived"]], "notes": [["text": "unsupported", "segment_ids": ["seg-999999"]]]]
        ]
        for result in results {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
            defer { try? FileManager.default.removeItem(at: root) }
            let source = root.appendingPathComponent("input.json"), output = root.appendingPathComponent("job")
            try TranscriptFixture.document.encoded().write(to: source)
            await #expect(throws: (any Error).self) {
                try await TextJob(client: .init(transport: TranscriptFixture.transport(result: result))).run(source: source, output: output,
                    options: .init(provider: .ollama, model: "synthetic", mode: .normalize, targetLanguage: "de", summarize: true))
            }
            #expect(try read(output, "manifest.json")["state"] == "failed")
            #expect(FileManager.default.fileExists(atPath: output.appendingPathComponent("ai-raw-0000.json").path))
            #expect(!FileManager.default.fileExists(atPath: output.appendingPathComponent("transcript.json").path))
        }
    }

    @Test func cancellationInterruptsNetworkingAndRecordsTerminalState() async throws {
        actor WaitingTransport: IntelligenceTransport {
            var started = false
            func send(_ request: URLRequest, maximumBytes: Int) async throws -> Data {
                started = true
                try await Task.sleep(for: .seconds(30))
                return Data()
            }
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("input.json"), output = root.appendingPathComponent("job")
        let original = try TranscriptFixture.document.encoded()
        try original.write(to: source)
        let transport = WaitingTransport()
        let task = Task {
            try await TextJob(client: .init(transport: transport)).run(source: source, output: output,
                options: .init(provider: .ollama, model: "synthetic", mode: .normalize, targetLanguage: "de"))
        }
        try await expectEventually { await transport.started }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(try read(output, "manifest.json")["state"] == "cancelled")
        #expect(try Data(contentsOf: source) == original)
    }

    @Test func translationUsesBoundedBatchesAndNeverChangesRawText() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        var original = TranscriptFixture.document
        let template = original["segments"].array![0]
        original["segments"] = .array((0..<50).map { index in
            var segment = template
            segment["id"] = .string(String(format: "seg-%06d", index + 1))
            segment["start_ms"] = .integer(Int64(index * 40)); segment["end_ms"] = .integer(Int64((index + 1) * 40))
            return segment
        })
        let source = root.appendingPathComponent("input.json"), output = root.appendingPathComponent("job")
        try original.encoded().write(to: source)
        let transport = TranscriptFixture.transport()
        try await TextJob(client: .init(transport: transport)).run(source: source, output: output,
            options: .init(provider: .ollama, model: "synthetic", mode: .translate, targetLanguage: "en"))
        let requests = await transport.requests.filter { $0.url?.lastPathComponent == "generate" }
        #expect(requests.count == 3)
        for request in requests {
            let body = try JSONDecoder().decode(JSONValue.self, from: #require(request.httpBody))
            let prompt = try JSONDecoder().decode(JSONValue.self, from: Data(try #require(body["prompt"].string).utf8))
            #expect((prompt["untrusted_transcript"].array?.count ?? 0) <= IntelligencePolicy().maximumBatchSegments)
            #expect(prompt["mode"] == "translate")
            #expect(prompt["target_language"] == "en")
        }
        let document = try read(output, "transcript.json")
        #expect(document["segments"].array?.allSatisfy { $0["normalized_text"] == .null && $0["translated_text"] == "Guten Tag!" } == true)
        #expect(document["segments"].array?.map { $0["source_text"] } == original["segments"].array?.map { $0["source_text"] })
        try validateWithPythonReference(output)
    }

    @Test func approvedCloudJobRecordsConsentTokensAndProviderEvidence() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("input.json"), output = root.appendingPathComponent("job")
        try TranscriptFixture.document.encoded().write(to: source)
        let transport = MockTransport { _ in
            let result: JSONValue = ["segments": [["id": "seg-000001", "text": "Guten Tag"]], "notes": []]
            return ["status": "completed", "output": [["content": [["type": "output_text", "text": .string(String(decoding: try result.encoded(), as: UTF8.self))]]]],
                "usage": ["input_tokens": 12, "output_tokens": 6]]
        }
        try await TextJob(client: .init(transport: transport)).run(source: source, output: output,
            options: .init(provider: .openai, model: "synthetic", mode: .normalize, targetLanguage: "de", cloudConsent: true),
            key: Data("synthetic-secret".utf8))
        let document = try read(output, "transcript.json")
        #expect(document["processing"]["local_only"] == false)
        #expect(document["processing"]["allow_cloud_text"] == true)
        #expect(document["language_processing"]["derivations"].array?.first?["prompt_tokens"] == 12)
        #expect(try read(output, "ai-model.json")["audio_uploaded"] == false)
        for url in try FileManager.default.contentsOfDirectory(at: output, includingPropertiesForKeys: nil) {
            #expect(!String(decoding: try Data(contentsOf: url), as: UTF8.self).contains("synthetic-secret"))
        }
        try validateWithPythonReference(output)
    }

    private func read(_ directory: URL, _ name: String) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: directory.appendingPathComponent(name)))
    }

    /// Optional migration acceptance check; the shipping library/CLI never invokes Python.
    private func validateWithPythonReference(_ directory: URL) throws {
        guard let python = ProcessInfo.processInfo.environment["RECSCRIBE_REFERENCE_PYTHON"] else { return }
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: python)
        process.environment = ProcessInfo.processInfo.environment.merging(["PYTHONPATH": root.appendingPathComponent("pipeline/src").path]) { _, new in new }
        process.arguments = ["-c", """
        import json, sys
        from pathlib import Path
        from recscribe.job import validate
        from recscribe.renderers import render
        root = Path(sys.argv[1])
        document = json.loads((root / 'transcript.json').read_bytes())
        validate(document)
        for name, expected in render(document).items():
            assert (root / name).read_bytes() == expected.encode(), name
        print('Python schema/semantic validation and all five byte-for-byte exports match')
        """, directory.path]
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
    }
}
