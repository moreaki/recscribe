import AVFoundation
import CryptoKit
import Foundation
import RecScribeCore
import Testing
@testable import RecScribe

private actor SegmentTransportFixture: IntelligenceTransport {
    var requests: [URLRequest] = []
    let response: Data
    let fail: Bool
    init(response: Data = Data(#"{"text":"Cloud recognized words"}"#.utf8), fail: Bool = false) {
        self.response = response; self.fail = fail
    }
    func send(_ request: URLRequest, maximumBytes: Int) async throws -> Data {
        requests.append(request)
        if fail { throw SessionError.invalid("Synthetic network failure") }
        return response
    }
}

@MainActor
struct SegmentCloudRecognitionTests {
    private struct Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("recscribe-segment-tests-\(UUID())")
        var audio: URL { root.appendingPathComponent("private-original.wav") }
        var job: URL { root.appendingPathComponent("job") }
        var canonical: URL { job.appendingPathComponent("transcript.json") }
        var evidence: URL { root.appendingPathComponent("CloudEvidence") }
        var reviews: URL { root.appendingPathComponent("Review") }
        init() throws {
            try FileManager.default.createDirectory(at: job, withIntermediateDirectories: true)
            var data = try PCM16WAV(sampleRate: 8_000, channels: 2, payloadBytes: 24_000 * 4).header
            for frame in 0..<24_000 {
                for value in [Int16(frame % 10_000), Int16(-(frame % 10_000))] {
                    var sample = value.littleEndian
                    withUnsafeBytes(of: &sample) { data.append(contentsOf: $0) }
                }
            }
            try data.write(to: audio)
            try Data("raw original recognition".utf8).write(to: job.appendingPathComponent("raw.json"))
            try write()
        }
        func write(start: Int = 500, end: Int = 1_000, channel: Int? = 1,
                   source: URL? = nil, rate: Int = 8_000, duration: Int = 3_000) throws {
            var first = ReadingFixtures.segment("s1", "Original recognition", channel: channel ?? 0, start: start, end: end)
            if channel == nil { first.removeValue(forKey: "channel") }
            try JSONSerialization.data(withJSONObject: ["schema_version": "1.0", "processing": ["mode": "verbatim"],
                "source": ["path": (source ?? audio).path, "duration_ms": duration, "channels": 2, "sample_rate": rate],
                "segments": [first, ReadingFixtures.segment("s2", "Second source", start: 1_500, end: 1_800)],
                "review_reasons": []], options: .sortedKeys).write(to: canonical)
        }
        func selection(_ id: String = "s1") async throws -> SegmentCloudSelection {
            try await SegmentCloudSelection.prepare(job: job, document: TranscriptPreview.read(job), segmentID: id)
        }
    }
    private let key = Data("synthetic-key".utf8)
    private func rejects<T>(_ operation: () async throws -> T) async {
        do { _ = try await operation(); Issue.record("Expected selected-segment operation to fail") } catch { }
    }
    private func candidate(_ selection: SegmentCloudSelection) -> SegmentCloudCandidate {
        .init(selection: selection, reference: .init(id: UUID(), model: SegmentCloudRecognition.model, approvedAt: Date(),
            startMs: selection.startMs, endMs: selection.endMs, channel: selection.channel,
            audioSHA256: String(repeating: "a", count: 64), responseSHA256: String(repeating: "b", count: 64)),
            text: "Cloud recognized words", evidence: selection.job)
    }

    @Test func uploadContainsOnlySelectedChannelFramesAndKeepsOriginalsAndProviderEvidence() async throws {
        let f = try Fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let originals = try [f.audio, f.canonical, f.job.appendingPathComponent("raw.json")].map { try Data(contentsOf: $0) }
        let selection = try await f.selection()
        let transport = SegmentTransportFixture()
        let worker = SegmentCloudRecognition(transport: transport, root: f.evidence)
        let result = try await worker.run(selection, key: key, approvedAt: Date())
        let requests = await transport.requests
        #expect(requests.count == 1)
        let request = try #require(requests.first), body = try #require(request.httpBody)
        #expect(request.url == SegmentCloudRecognition.endpoint && request.httpMethod == "POST")
        #expect(request.timeoutInterval == 120 && request.value(forHTTPHeaderField: "Authorization") == "Bearer synthetic-key")
        let marker = Data("Content-Type: audio/wav\r\n\r\n".utf8)
        let start = try #require(body.range(of: marker)).upperBound
        let wave = body.subdata(in: start..<(start + selection.audioBytes))
        let header = try PCM16WAV(header: Data(wave.prefix(PCM16WAV.headerBytes)))
        #expect(header.channels == 1 && header.sampleRate == 8_000 && header.frames == 4_000)
        wave.withUnsafeBytes { bytes in
            for frame in 0..<4_000 {
                let actual = Int16(littleEndian: bytes.loadUnaligned(fromByteOffset: PCM16WAV.headerBytes + frame * 2, as: Int16.self))
                #expect(actual == -Int16(frame + 4_000))
            }
        }
        let envelope = String(decoding: body.prefix(start), as: UTF8.self)
        #expect(envelope.contains(SegmentCloudRecognition.model) && envelope.contains("filename=\"segment.wav\""))
        #expect(!envelope.contains(f.audio.path) && !envelope.contains("Original recognition") && !envelope.contains("s1"))
        #expect(result.text == "Cloud recognized words" && result.reference.valid)
        #expect(try Data(contentsOf: result.evidence.appendingPathComponent("response.json")) == transport.response)
        let consent = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: result.evidence.appendingPathComponent("consent.json"))) as? [String: Any])
        #expect(consent["channel"] as? Int == 1 && consent["first_frame"] as? Int == 4_000 && consent["end_frame"] as? Int == 8_000)
        #expect(try [f.audio, f.canonical, f.job.appendingPathComponent("raw.json")].map { try Data(contentsOf: $0) } == originals)
        #expect(!FileManager.default.fileExists(atPath: result.evidence.appendingPathComponent("segment.wav").path))
    }

    @Test func approvalAndCredentialsArePerAttemptAndCloudTextRequiresSeparateApplication() async throws {
        let f = try Fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let document = try await TranscriptPreview.read(f.job), original = try Data(contentsOf: f.canonical)
        let transport = SegmentTransportFixture(), worker = SegmentCloudRecognition(transport: transport, root: f.evidence)
        var reads = 0
        let state = SegmentCloudState(readKey: { reads += 1; return key }, recognize: { try await worker.run($0, key: $1, approvedAt: $2) })
        let review = TranscriptReviewState(store: .init(root: f.reviews))
        await review.load(job: f.job, document: document)
        state.request(job: f.job, document: document, segmentID: "s1")
        await waitUntil("approval available") { state.pending != nil }
        let recordedRequests111 = await transport.requests
        #expect(reads == 0 && recordedRequests111.isEmpty)
        state.dismissApproval(); state.approve()
        let recordedRequests113 = await transport.requests
        #expect(reads == 0 && recordedRequests113.isEmpty)
        state.request(job: f.job, document: document, segmentID: "s1")
        await waitUntil("new explicit approval") { state.pending != nil }
        state.approve(); state.approve()
        await waitUntil("candidate returned") { !state.busy }
        let result = try #require(state.result)
        let recordedRequests119 = await transport.requests
        #expect(reads == 1 && recordedRequests119.count == 1 && review.corrections.isEmpty)
        state.apply(to: review)
        await waitUntil("approved candidate saved as correction") { !state.busy && !review.saving && !review.corrections.isEmpty }
        #expect(review.corrections["s1"]?.cloud == result.reference)
        let corrected = document.applying(review.corrections)
        #expect(corrected.includesCloudAudio && corrected.segments[0].sourceText == "Original recognition")
        #expect(corrected.displayedText(corrected.segments[0]) == result.text)
        let saved = try await TranscriptReviewStore(root: f.reviews).loadSnapshot(TranscriptReviewContext(job: f.job, document: document))
        #expect(saved.corrections["s1"]?.cloud == result.reference)
        review.setCorrection(nil, for: "s1")
        await waitUntil("original restored") { !review.saving }
        #expect(review.corrections.isEmpty)
        #expect(try Data(contentsOf: f.canonical) == original)
        #expect(FileManager.default.fileExists(atPath: result.evidence.appendingPathComponent("response.json").path))
    }

    @Test func noApprovalMissingKeyAndNetworkFailureNeverSendOrRetryUnexpectedly() async throws {
        let f = try Fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let transport = SegmentTransportFixture(fail: true), selection = try await f.selection()
        let worker = SegmentCloudRecognition(transport: transport, root: f.evidence)
        await rejects { try await worker.run(selection, key: key, approvedAt: nil) }
        let recordedRequests140 = await transport.requests
        #expect(recordedRequests140.isEmpty && !FileManager.default.fileExists(atPath: f.evidence.path))
        let document = try await TranscriptPreview.read(f.job)
        let missing = SegmentCloudState(readKey: { throw SessionError.invalid("Missing synthetic key") },
            recognize: { try await worker.run($0, key: $1, approvedAt: $2) })
        missing.request(job: f.job, document: document, segmentID: "s1")
        await waitUntil("missing-key approval") { missing.pending != nil }
        missing.approve()
        let recordedRequests147 = await transport.requests
        #expect(missing.error != nil && missing.pending == nil && !missing.busy && recordedRequests147.isEmpty)
        let state = SegmentCloudState(readKey: { key }, recognize: { try await worker.run($0, key: $1, approvedAt: $2) })
        state.request(job: f.job, document: document, segmentID: "s1")
        await waitUntil("failure approval") { state.pending != nil }
        state.approve()
        await waitUntil("network failure surfaced") { !state.busy }
        let recordedRequests153 = await transport.requests
        #expect(state.error != nil && state.result == nil && state.pending == nil && recordedRequests153.count == 1)
        state.approve(); await settle()
        let recordedRequests155 = await transport.requests
        #expect(recordedRequests155.count == 1)
    }

    @Test(arguments: ["audio", "transcript"])
    func changedSourcesInvalidateApprovalBeforeNetwork(scenario: String) async throws {
        let f = try Fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let selection = try await f.selection(), transport = SegmentTransportFixture()
        if scenario == "audio" {
            var bytes = try Data(contentsOf: f.audio); bytes[bytes.count - 1] ^= 1
            try bytes.write(to: f.audio)
        } else { try f.write(start: 600) }
        await rejects { try await SegmentCloudRecognition(transport: transport, root: f.evidence).run(selection, key: key, approvedAt: Date()) }
        let recordedRequests167 = await transport.requests
        #expect(recordedRequests167.isEmpty)
    }

    @Test(arguments: ["channel", "missing-channel", "negative", "zero", "past-end", "too-long", "format", "byte-limit"])
    func invalidSelectionsFailClosed(scenario: String) async throws {
        let f = try Fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        switch scenario {
        case "channel": try f.write(channel: 2)
        case "missing-channel": try f.write(channel: nil)
        case "negative": try f.write(start: -1)
        case "zero": try f.write(start: 500, end: 500)
        case "past-end": try f.write(end: 4_000, duration: 4_000)
        case "too-long": try f.write(end: 121_000, duration: 121_000)
        case "byte-limit": try f.write(start: 0, end: 120_000, rate: 384_000, duration: 120_000)
        default: try f.write(rate: 16_000)
        }
        await rejects { try await f.selection() }
    }

    @Test func fractionalSampleBoundsRoundInwardAndKeepOnlyTheSelectedChannel() async throws {
        let f = try Fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        // A real imported rate with nonintegral sample-to-millisecond boundaries.
        let audio = f.root.appendingPathComponent("fractional.wav")
        var bytes = try PCM16WAV(sampleRate: 11_025, channels: 2, payloadBytes: 11_025 * 4).header
        bytes.append(Data(count: 11_025 * 4)); try bytes.write(to: audio)
        try f.write(start: 1, end: 11, source: audio, rate: 11_025, duration: 1_000)
        let selection = try await f.selection()
        #expect(selection.firstFrame == 12 && selection.endFrame == 121)
        let target = f.root.appendingPathComponent("clip.wav")
        try selection.copy(to: target)
        #expect(try PCM16WAV.read(target).frames == 109)
    }

    @Test func selectionAcrossVerifiedSessionPartsPreservesTimelineAndChannel() async throws {
        let f = try Fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let writer = SessionWAVWriter(options: .init(maximumPartBytes: 444))
        try writer.createFile(at: f.root.appendingPathComponent("multipart.wav"), sampleRate: 8_000, channels: 2)
        try writer.writeBuffer(SampleBufferFixtures.makePCMBuffer(channels: 2, frames: 1_000, sampleRate: 8_000, interleaved: false) { channel, frame in
            Float(channel == 0 ? frame : -frame) / 2_000
        })
        try writer.finalize()
        let manifest = try #require(writer.manifestURL)
        let session = try SessionProcessing.process(manifest, ffmpeg: URL(fileURLWithPath: "/unused"), cancel: WorkCancellation())
        try f.write(start: 10, end: 40, source: manifest, duration: 125)
        let selection = try await f.selection()
        #expect(selection.parts.count > 1 && selection.firstFrame == 80 && selection.endFrame == 320)
        let output = f.root.appendingPathComponent("multipart-clip.wav")
        try selection.copy(to: output)
        var source = Data()
        for part in session.parts { source.append(try Data(contentsOf: RecordingSession.safeURL(part.path, beside: manifest)).dropFirst(PCM16WAV.headerBytes)) }
        let actual = try Data(contentsOf: output).dropFirst(PCM16WAV.headerBytes)
        var expected = Data()
        for frame in 80..<320 { expected.append(source.subdata(in: (frame * 4 + 2)..<(frame * 4 + 4))) }
        #expect(actual == expected)
        #expect(try PCM16WAV.read(output).frames == 240)
    }

    @Test func duplicateEvidenceIDCannotReplayAnUploadOrOverwriteProviderResponse() async throws {
        let f = try Fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let transport = SegmentTransportFixture(), selection = try await f.selection(), id = UUID()
        let worker = SegmentCloudRecognition(transport: transport, root: f.evidence)
        let first = try await worker.run(selection, key: key, approvedAt: Date(), operationID: id)
        let raw = try Data(contentsOf: first.evidence.appendingPathComponent("response.json"))
        await rejects { try await worker.run(selection, key: key, approvedAt: Date(), operationID: id) }
        let recordedRequests231 = await transport.requests
        #expect(recordedRequests231.count == 1)
        #expect(try Data(contentsOf: first.evidence.appendingPathComponent("response.json")) == raw)
    }

    @Test(arguments: ["empty", "invalid", "oversized"])
    func providerResponsesAreBoundedAndRetainedWithoutReplacingOriginals(scenario: String) async throws {
        let f = try Fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let response = scenario == "empty" ? Data(#"{"text":" "}"#.utf8)
            : scenario == "invalid" ? Data(#"{"text":123}"#.utf8)
            : Data(count: SegmentCloudRecognition.maximumResponseBytes + 1)
        let transport = SegmentTransportFixture(response: response), selection = try await f.selection(), id = UUID()
        let worker = SegmentCloudRecognition(transport: transport, root: f.evidence)
        if scenario == "empty" {
            let result = try await worker.run(selection, key: key, approvedAt: Date(), operationID: id)
            #expect(result.text.isEmpty && result.correction == nil)
        } else { await rejects { try await worker.run(selection, key: key, approvedAt: Date(), operationID: id) } }
        let raw = f.evidence.appendingPathComponent(id.uuidString).appendingPathComponent("response.json")
        if scenario == "oversized" { #expect(!FileManager.default.fileExists(atPath: raw.path)) }
        else { #expect(try Data(contentsOf: raw) == response) }
        let recordedRequests250 = await transport.requests
        #expect(recordedRequests250.count == 1)
        #expect(try await TranscriptPreview.read(f.job).segments[0].sourceText == "Original recognition")
    }

    private actor ResultGate {
        var continuation: CheckedContinuation<SegmentCloudCandidate, any Error>?
        var selection: SegmentCloudSelection?
        func run(_ value: SegmentCloudSelection) async throws -> SegmentCloudCandidate {
            selection = value
            return try await withCheckedThrowingContinuation { continuation = $0 }
        }
        func finish(_ value: SegmentCloudCandidate) { continuation?.resume(returning: value); continuation = nil }
    }

    @Test func cancellationAndCaptureRejectLateResultsAndPreserveAnotherSelection() async throws {
        let f = try Fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let document = try await TranscriptPreview.read(f.job), selection = try await f.selection(), gate = ResultGate()
        let state = SegmentCloudState(readKey: { key }, recognize: { value, _, _ in try await gate.run(value) })
        state.request(job: f.job, document: document, segmentID: "s1")
        await waitUntil("first selection ready") { state.pending != nil }
        state.approve()
        let deadline = ContinuousClock.now + .seconds(5)
        while await gate.selection == nil, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(1)) }
        let startedSelection = await gate.selection
        _ = try #require(startedSelection)
        state.cancel()
        state.request(job: f.job, document: document, segmentID: "s2")
        await waitUntil("second selection ready") { state.pending?.segmentID == "s2" }
        await gate.finish(candidate(selection)); await settle()
        #expect(state.result == nil && state.pending?.segmentID == "s2")
        state.setBlocked(true)
        #expect(state.pending == nil && state.result == nil && !state.busy)
        state.request(job: f.job, document: document, segmentID: "s1"); state.approve()
        #expect(state.pending == nil && !state.preparing)
    }

    @Test func applyingAResultCannotOverwriteAManualEditMadeAfterApproval() async throws {
        let f = try Fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let document = try await TranscriptPreview.read(f.job)
        let state = SegmentCloudState(readKey: { key }, recognize: { selection, _, date in
            try await SegmentCloudRecognition(transport: SegmentTransportFixture(), root: f.evidence).run(selection, key: key, approvedAt: date)
        })
        let review = TranscriptReviewState(store: .init(root: f.reviews))
        await review.load(job: f.job, document: document)
        state.request(job: f.job, document: document, segmentID: "s1")
        await waitUntil("approval prepared") { state.pending != nil }
        state.approve(); await waitUntil("result ready") { !state.busy }
        review.setCorrection(.musicOnly, for: "s1")
        await waitUntil("manual change saved") { !review.saving }
        state.apply(to: review)
        #expect(state.error != nil && review.corrections["s1"] == .musicOnly)
    }

    @Test func captureDuringUploadDropsLateCompletion() async throws {
        let f = try Fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let document = try await TranscriptPreview.read(f.job), selection = try await f.selection(), gate = ResultGate()
        let state = SegmentCloudState(readKey: { key }, recognize: { value, _, _ in try await gate.run(value) })
        state.request(job: f.job, document: document, segmentID: "s1")
        await waitUntil("approval ready for capture test") { state.pending != nil }
        state.approve()
        let deadline = ContinuousClock.now + .seconds(5)
        while await gate.selection == nil, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(1)) }
        let startedSelection = await gate.selection
        _ = try #require(startedSelection)
        state.setBlocked(true)
        await gate.finish(candidate(selection)); await settle()
        #expect(state.result == nil && state.pending == nil && !state.busy && state.blocked)
    }
}
