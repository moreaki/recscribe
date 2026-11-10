import CryptoKit
import Darwin
import Foundation
import RecScribeCore

nonisolated struct SegmentCloudReference: Codable, Equatable, Sendable {
    let id: UUID
    let model: String
    let approvedAt: Date
    let startMs: Int64
    let endMs: Int64
    let channel: Int
    let audioSHA256: String
    let responseSHA256: String
    var valid: Bool {
        model == SegmentCloudRecognition.model && approvedAt.timeIntervalSince1970.isFinite
            && startMs >= 0 && endMs > startMs && endMs - startMs <= SegmentCloudSelection.maximumMilliseconds
            && (0..<32).contains(channel)
            && [audioSHA256, responseSHA256].allSatisfy { $0.count == 64 && $0.allSatisfy(\.isHexDigit) }
    }
}

nonisolated struct SegmentCloudCandidate: Sendable {
    let selection: SegmentCloudSelection
    let reference: SegmentCloudReference
    let text: String
    let evidence: URL
    var correction: TranscriptCorrection? {
        guard !text.isEmpty else { return nil }
        return TranscriptCorrection(kind: .text, text: text, cloud: reference)
    }
}

/// Exactly one file request per approval. No retries, fallback, context text or local paths.
nonisolated struct SegmentCloudRecognition: Sendable {
    static let model = "gpt-transcribe"
    static let endpoint = URL(string: "https://api.openai.com/v1/audio/transcriptions")!
    static let maximumResponseBytes = 262_144
    let transport: any IntelligenceTransport
    let root: URL

    init(transport: any IntelligenceTransport = DirectIntelligenceTransport(),
         root: URL = AppSettings.supportDirectory.appendingPathComponent("SegmentRecognition", isDirectory: true)) {
        self.transport = transport; self.root = root
    }

    @concurrent func run(_ selection: SegmentCloudSelection, key: Data, approvedAt: Date?,
                         operationID: UUID = UUID()) async throws -> SegmentCloudCandidate {
        guard let approvedAt else { throw SessionError.invalid("This passage requires explicit approval before upload") }
        guard approvedAt.timeIntervalSince1970.isFinite else { throw SessionError.invalid("Invalid passage approval") }
        guard !key.isEmpty, key.count <= 2_048, key.allSatisfy({ $0 > 32 && $0 < 127 }),
              let token = String(data: key, encoding: .utf8) else {
            throw SessionError.invalid("Save a valid OpenAI key in Settings → Intelligence")
        }
        try Task.checkCancellation()
        // This directory contains only a disposable clip, never a recording or transcript.
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("recscribe-segment-\(UUID())")
        guard mkdir(temporary.path, 0o700) == 0 else { throw SessionError.invalid("Could not prepare temporary passage audio") }
        defer { try? FileManager.default.removeItem(at: temporary) }
        let clip = temporary.appendingPathComponent("segment.wav")
        try selection.copy(to: clip)
        let audio = try Data(contentsOf: clip, options: .mappedIfSafe)
        guard audio.count == selection.audioBytes, audio.count <= SegmentCloudSelection.maximumAudioBytes else {
            throw SessionError.invalid("Prepared passage does not match its approved audio range")
        }
        let audioHash = Self.digest(audio)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let info = try root.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard info.isDirectory == true, info.isSymbolicLink != true else { throw SessionError.invalid("Recognition evidence storage is unavailable") }
        let evidence = root.appendingPathComponent(operationID.uuidString, isDirectory: true)
        guard mkdir(evidence.path, 0o700) == 0 else { throw SessionError.invalid("Recognition evidence already exists; approve a new request") }
        let consent: JSONValue = ["version": 1, "provider": "OpenAI", "endpoint": .string(Self.endpoint.absoluteString),
            "model": .string(Self.model), "approved_at": .string(approvedAt.ISO8601Format()),
            "transcript_revision": .string(selection.revision), "segment_id": .string(selection.segmentID),
            "source_path": .string(selection.source.path), "start_ms": .integer(selection.startMs), "end_ms": .integer(selection.endMs),
            "channel": .integer(Int64(selection.channel)), "first_frame": .integer(selection.firstFrame),
            "end_frame": .integer(selection.endFrame), "sample_rate": .integer(Int64(selection.sampleRate)),
            "audio_bytes": .integer(Int64(audio.count)), "audio_sha256": .string(audioHash),
            "scope": "single_selected_channel_and_interval; one_attempt; no_context_or_padding"]
        try consent.encoded().write(to: evidence.appendingPathComponent("consent.json"), options: .withoutOverwriting)
        do {
            try Task.checkCancellation()
            try selection.validate()
            let boundary = "RecScribe-" + UUID().uuidString
            var body = Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"model\"\r\n\r\n\(Self.model)\r\n--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"segment.wav\"\r\nContent-Type: audio/wav\r\n\r\n".utf8)
            body.append(audio); body.append(Data("\r\n--\(boundary)--\r\n".utf8))
            var request = URLRequest(url: Self.endpoint)
            request.httpMethod = "POST"; request.timeoutInterval = 120
            request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
            request.setValue("multipart/form-data; boundary=" + boundary, forHTTPHeaderField: "Content-Type")
            request.httpBody = body
            let raw = try await transport.send(request, maximumBytes: Self.maximumResponseBytes)
            guard raw.count <= Self.maximumResponseBytes else { throw SessionError.invalid("Cloud recognition response exceeds the size limit") }
            // Retain the provider's exact response before parsing or offering any correction.
            try raw.write(to: evidence.appendingPathComponent("response.json"), options: .withoutOverwriting)
            try Task.checkCancellation()
            struct Response: Decodable { let text: String }
            guard let response = try? JSONDecoder().decode(Response.self, from: raw),
                  response.text.utf8.count <= TranscriptCorrection.maximumTextBytes else {
                throw SessionError.invalid("Cloud recognition returned unsupported text. Raw response is preserved.")
            }
            let reference = SegmentCloudReference(id: operationID, model: Self.model, approvedAt: approvedAt,
                startMs: selection.startMs, endMs: selection.endMs, channel: selection.channel,
                audioSHA256: audioHash, responseSHA256: Self.digest(raw))
            try JSONEncoder().encode(reference).write(to: evidence.appendingPathComponent("result.json"), options: .withoutOverwriting)
            try selection.validate()
            return .init(selection: selection, reference: reference,
                text: response.text.trimmingCharacters(in: .whitespacesAndNewlines), evidence: evidence)
        } catch {
            let status = Task.isCancelled || error is CancellationError ? "cancelled" : "failed"
            try? Data(status.utf8).write(to: evidence.appendingPathComponent("status.txt"), options: .withoutOverwriting)
            if Task.isCancelled { throw CancellationError() }
            throw error
        }
    }

    static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
