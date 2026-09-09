import Foundation
import Testing
@testable import RecScribeCore

/// No network or credentials: latency, completion order, and failure are injected.
private actor BatchTransport: IntelligenceTransport {
    var active = 0, peak = 0, started = 0, cancelled = 0
    var completed: [String] = []
    let delay: Duration
    let failFirst: Bool
    let slowFirst: Bool

    init(delay: Duration = .milliseconds(20), failFirst: Bool = false, slowFirst: Bool = false) {
        self.delay = delay; self.failFirst = failFirst; self.slowFirst = slowFirst
    }

    func send(_ request: URLRequest, maximumBytes: Int) async throws -> Data {
        if request.url?.lastPathComponent == "show" { return try JSONValue.object(["model_info": ["architecture": "synthetic"]]).encoded() }
        let body = try JSONDecoder().decode(JSONValue.self, from: #require(request.httpBody))
        let cloud = request.url?.lastPathComponent == "responses"
        let text = cloud ? body["input"].array?.last?["content"].string : body["prompt"].string
        let prompt = try JSONDecoder().decode(JSONValue.self, from: Data(try #require(text).utf8))
        let segments = try #require(prompt["untrusted_transcript"].array)
        let id = try #require(segments.first?["id"].string)
        active += 1; started += 1; peak = max(peak, active)
        defer { active -= 1 }
        do {
            try await Task.sleep(for: slowFirst && id == "seg-000001" ? .milliseconds(150) : delay)
            if failFirst && id == "seg-000001" { throw CoreFailure("Synthetic batch failure") }
            completed.append(id)
            let result: JSONValue = ["segments": .array(segments.map { ["id": $0["id"], "text": $0["id"]] }),
                "notes": prompt["summarize"] == true ? [["text": .string(id), "segment_ids": .array(segments.map { $0["id"] })]] : []]
            let answer = JSONValue.string(String(decoding: try result.encoded(), as: UTF8.self))
            return try (cloud ? JSONValue.object(["status": "completed", "output": [["content": [["type": "output_text", "text": answer]]]]])
                        : ["done": true, "response": answer]).encoded()
        } catch {
            if error is CancellationError { cancelled += 1 }
            throw error
        }
    }
}

@Suite struct TextBatchingTests {
    private func document(count: Int, text: String = "A short synthetic sentence for a latency comparison.") -> JSONValue {
        var value = TranscriptFixture.document
        value["segments"] = .array((0..<count).map { index in
            var segment = TranscriptFixture.document["segments"].array![0]
            segment["id"] = .string(String(format: "seg-%06d", index + 1))
            segment["source_text"] = .string(text)
            return segment
        })
        return value
    }

    private func options(provider: TextProvider = .openai) -> TextDerivationOptions {
        .init(provider: provider, model: "synthetic", mode: .normalize, targetLanguage: "de", summarize: true, cloudConsent: provider == .openai)
    }

    private func temporaryDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        return root
    }

    @Test func shortSegmentsUseBudgetInsteadOfTwentyFourSegmentBatches() throws {
        let value = document(count: 226)
        let derivation = TextDerivation(client: .init(), options: options())
        let batches = try derivation.batches(for: value)
        #expect(batches.count < 10)
        #expect(batches.first!.count > 24)
        #expect(batches.flatMap { $0 } == Array(0..<226))
        #expect(try derivation.batches(for: document(count: 0)).isEmpty)
    }

    @Test func budgetsIncludeUTF8JSONAndOutputExpansion() throws {
        var policy = IntelligencePolicy()
        policy.maximumBatchPromptBytes = 1_000
        let client = IntelligenceClient(policy: policy)
        let ascii = try TextDerivation(client: client, options: options()).batches(for: document(count: 30, text: String(repeating: "a", count: 60)))
        let unicode = try TextDerivation(client: client, options: options()).batches(for: document(count: 30, text: String(repeating: "界", count: 60)))
        #expect(unicode.count > ascii.count)
        let escaped = try TextDerivation(client: client, options: options()).batches(for: document(count: 30, text: String(repeating: "\"", count: 60)))
        #expect(escaped.count > ascii.count)
        #expect(throws: (any Error).self) {
            try TextDerivation(client: client, options: options()).batches(for: document(count: 1, text: String(repeating: "界", count: 1_000)))
        }
        policy.maximumBatchPromptBytes = 12_000
        let normal = try TextDerivation(client: .init(policy: policy), options: options()).batches(for: document(count: 100))
        policy.cloudOutputTokens = 1_500
        let smallOutput = try TextDerivation(client: .init(policy: policy), options: options()).batches(for: document(count: 100))
        #expect(smallOutput.count > normal.count)
        policy.outputExpansionFactor = 0
        #expect(throws: (any Error).self) { try TextDerivation(client: .init(policy: policy), options: options()).batches(for: document(count: 1)) }
    }

    @Test func outOfOrderRequestsKeepCanonicalAndEvidenceOrderAndBoundConcurrency() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let transport = BatchTransport(slowFirst: true)
        var policy = IntelligencePolicy(); policy.maximumBatchSegments = 1
        let original = document(count: 6)
        var progress: [Int] = []
        let result = try await TextDerivation(client: .init(transport: transport, policy: policy), options: options())
            .apply(to: original, in: root, key: Data("synthetic".utf8)) { done, _ in progress.append(done) }
        #expect(await transport.peak == 2)
        #expect(await transport.completed.first != "seg-000001")
        #expect(progress == Array(0...6))
        let plan = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: root.appendingPathComponent("ai-batch-plan.json")))
        #expect(plan["batch_count"] == 6)
        #expect(plan["maximum_concurrency"] == 2)
        #expect(plan["segment_counts"] == [1, 1, 1, 1, 1, 1])
        let ids = original["segments"].array!.map { $0["id"] }
        #expect(result["segments"].array!.map { $0["normalized_text"] } == ids)
        #expect(result["segments"].array!.map { $0["source_text"] } == original["segments"].array!.map { $0["source_text"] })
        #expect(result["summary"]["notes"].array!.map { $0["text"] } == ids)
        for (index, evidence) in result["language_processing"]["derivations"].array!.enumerated() {
            #expect(evidence["raw_path"].string == String(format: "ai-raw-%04d.json", index))
            let raw = try Data(contentsOf: root.appendingPathComponent(evidence["raw_path"].string!))
            #expect(evidence["raw_sha256"].string == TextJob.hash(raw))
            #expect(evidence["duration_seconds"].double! > 0)
        }
    }

    @Test func localRequestsRemainSerial() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let transport = BatchTransport()
        var policy = IntelligencePolicy(); policy.maximumBatchSegments = 1
        _ = try await TextDerivation(client: .init(transport: transport, policy: policy), options: options(provider: .ollama))
            .apply(to: document(count: 3), in: root, key: nil)
        #expect(await transport.peak == 1)
        #expect(await transport.started == 3)
    }

    @Test func cancellationStopsAllInflightRequestsAndDoesNotPublishTranscript() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source.json"), output = root.appendingPathComponent("job")
        let data = try document(count: 6).encoded(); try data.write(to: source)
        let transport = BatchTransport(delay: .seconds(30))
        var policy = IntelligencePolicy(); policy.maximumBatchSegments = 1
        let client = IntelligenceClient(transport: transport, policy: policy), options = options()
        let task = Task { try await TextJob(client: client).run(source: source, output: output, options: options, key: Data("synthetic".utf8)) }
        try await expectEventually { await transport.started == 2 }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(await transport.cancelled == 2)
        #expect(await transport.started == 2)
        #expect(await transport.active == 0)
        #expect(!FileManager.default.fileExists(atPath: output.appendingPathComponent("transcript.json").path))
        #expect(try Data(contentsOf: source) == data)
        let manifest = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: output.appendingPathComponent("manifest.json")))
        #expect(manifest["state"] == "cancelled")
    }

    @Test func failedBatchCancelsSiblingsAndRetainsParent() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source.json"), output = root.appendingPathComponent("job")
        let data = try document(count: 6).encoded(); try data.write(to: source)
        let transport = BatchTransport(delay: .seconds(30), failFirst: true, slowFirst: true)
        var policy = IntelligencePolicy(); policy.maximumBatchSegments = 1
        await #expect(throws: (any Error).self) {
            try await TextJob(client: .init(transport: transport, policy: policy)).run(source: source, output: output,
                options: options(), key: Data("synthetic".utf8))
        }
        #expect(await transport.started == 2)
        #expect(await transport.cancelled == 1)
        #expect(await transport.active == 0)
        #expect(!FileManager.default.fileExists(atPath: output.appendingPathComponent("transcript.json").path))
        #expect(try Data(contentsOf: source) == data)
        let manifest = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: output.appendingPathComponent("manifest.json")))
        #expect(manifest["state"] == "failed")
    }

    @Test func syntheticLatencyComparison() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let value = document(count: 226)
        for baseline in [true, false] {
            let directory = root.appendingPathComponent(baseline ? "baseline" : "budgeted")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
            var policy = IntelligencePolicy()
            if baseline { policy.maximumBatchSegments = 24; policy.maximumConcurrentCloudBatches = 1 }
            let transport = BatchTransport(delay: .milliseconds(40))
            let start = ContinuousClock.now
            _ = try await TextDerivation(client: .init(transport: transport, policy: policy), options: options())
                .apply(to: value, in: directory, key: Data("synthetic".utf8))
            print("Synthetic text benchmark baseline=\(baseline) requests=\(await transport.started) peak=\(await transport.peak) elapsed=\(TextJob.seconds(since: start))s; mocked 40ms/request, not cloud performance")
            if baseline { #expect(await transport.started == 10) }
            else { #expect(await transport.started < 10); #expect(await transport.peak == 2) }
        }
    }
}
