import CryptoKit
import Darwin
import Foundation
import RecScribeCore

/// Cloud evidence has its own schema version. Missing model weights, acoustic
/// analysis, word timing and speaker labels are never represented as measured facts.
nonisolated enum CloudTranscriptArtifacts {
    @concurrent static func begin(_ directory: URL, source: URL, consent: CloudAudioConsent) async throws {
        try FileManager.default.createDirectory(at: directory.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        guard mkdir(directory.path, 0o700) == 0 else { throw SessionError.invalid("Cloud job already exists; evidence will not be overwritten") }
        try write(consentJSON(consent), "consent.json", in: directory)
        try state("transcribing", directory: directory, source: source)
    }

    @concurrent static func interrupted(_ directory: URL, source: URL, cancelled: Bool) async {
        try? state(cancelled ? "cancelled" : "failed", directory: directory, source: source)
        try? Data("# Review\n\nCloud transcription was interrupted. Raw events and completed turns are retained. The local recording is independent. No automatic retry or fallback occurred.\n".utf8)
            .write(to: directory.appendingPathComponent("review.md"), options: .atomic)
    }

    @concurrent static func finish(_ directory: URL, source: URL, consent: CloudAudioConsent,
                                   cancel: WorkCancellation) async throws {
        try cancel.check()
        try state("validating", directory: directory, source: source)
        let session = try RecordingSession.read(source)
        guard session.id == consent.sourceSessionID, session.status != .recording, session.totalFrames > 0,
              consent.startSample <= session.totalFrames else { throw SessionError.invalid("Cloud transcript source is not finalized") }
        // Validate file identity, contiguous complete frames and unchanged part lengths.
        guard try LiveAudioReader.position(manifest: source, cancel: cancel) == session.totalFrames else {
            throw SessionError.invalid("Cloud transcript source has missing or changed samples")
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        let snapshot = try encoder.encode(session)
        try snapshot.write(to: directory.appendingPathComponent("source-session.snapshot.json"), options: .atomic)
        var parts: [JSONValue] = [], size: Int64 = 0
        for part in session.parts {
            try cancel.check()
            let url = try RecordingSession.safeURL(part.path, beside: source)
            let hash = try RecordingSession.hash(url, check: cancel.check)
            if let expected = part.sha256, hash != expected { throw SessionError.invalid("Source checksum changed before cloud export") }
            let (sum, overflow) = size.addingReportingOverflow(part.sizeBytes)
            guard !overflow else { throw WAVWriterError.invalidFormat }
            size = sum
            parts.append(["path": .string(url.path), "start_sample": .integer(part.startSample),
                "frames": .integer(part.frames), "size_bytes": .integer(part.sizeBytes), "sha256": .string(hash)])
        }
        let audio: JSONValue = ["path": .string(source.path), "sha256": .string(hash(snapshot)),
            "sha256_scope": "source-session.snapshot.json; individual WAV hashes are in parts",
            "duration_ms": .integer(milliseconds(session.totalFrames, session.sampleRate)), "frames": .integer(session.totalFrames),
            "sample_rate": .integer(Int64(session.sampleRate)), "channels": .integer(Int64(session.channels)),
            "bit_depth": .integer(Int64(session.bitDepth)), "channel_map": .array(session.channelMap.map(JSONValue.string)),
            "size_bytes": .integer(size), "container": "WAV", "codec": "PCM", "parts": .array(parts),
            "analysis_status": "not_performed; no acoustic quality metrics claimed"]
        let folders = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("turn-") }
        var chunks: [LiveChunkResult] = [], readBytes = 0
        for folder in folders {
            try cancel.check()
            let input = try FileHandle(forReadingFrom: folder.appendingPathComponent("result.json"))
            defer { try? input.close() }
            let data = try input.read(upToCount: LiveTranscriptionPolicy.maximumResultBytes + 1) ?? Data()
            readBytes += data.count
            guard data.count <= LiveTranscriptionPolicy.maximumResultBytes, readBytes <= TextJob.maximumTranscriptBytes else {
                throw SessionError.invalid("Cloud transcript exceeds the export size limit; raw evidence is retained")
            }
            chunks.append(try JSONDecoder().decode(LiveChunkResult.self, from: data))
        }
        chunks.sort { $0.startFrame < $1.startFrame }
        var cursor = consent.startSample
        for chunk in chunks {
            guard chunk.startFrame == cursor, chunk.endFrame > cursor, chunk.endFrame <= session.totalFrames,
                  chunk.sampleRate == session.sampleRate, chunk.model == consent.model else {
                throw SessionError.invalid("Cloud transcript contains an incomplete or overlapping turn")
            }
            cursor = chunk.endFrame
        }
        guard cursor == session.totalFrames else { throw SessionError.invalid("Cloud transcript has an unprocessed tail; raw evidence is retained") }
        let reasons: [JSONValue] = ["cloud_asr_unverified; compare_against_original_audio",
            "timestamps_are_uploaded_turn_bounds_not_word_alignment", "speaker_and_language_not_verified",
            "acoustic_quality_not_analyzed; silence_and_short_tails_need_review"]
            + (consent.startSample > 0 ? ["audio_before_consent_was_not_uploaded_or_transcribed"] : [])
            + session.issues.map(JSONValue.string)
        let segments = chunks.flatMap(\.segments).sorted {
            $0.startSeconds == $1.startSeconds ? $0.channel < $1.channel : $0.startSeconds < $1.startSeconds
        }.enumerated().map { index, segment -> JSONValue in
            ["id": .string(String(format: "seg-%06d", index + 1)),
             "start_ms": .integer(Int64((segment.startSeconds * 1_000).rounded())),
             "end_ms": .integer(min(milliseconds(session.totalFrames, session.sampleRate), Int64((segment.endSeconds * 1_000).rounded()))),
             "channel": .integer(Int64(segment.channel)), "speaker": nil, "source_text": .string(segment.text),
             "normalized_text": nil, "translated_text": nil, "confidence": nil, "words": [],
             "needs_review": true, "review_reasons": ["cloud_turn_timing_estimated; speaker_and_language_unverified"]]
        }
        let document: JSONValue = ["schema_version": "1.1", "job_id": .string(directory.lastPathComponent),
            "status": "completed_with_review", "source": audio,
            "processing": ["source_language": "undetected", "target_language": nil, "mode": "verbatim", "profile": "fast",
                "diarize": "off", "local_only": false, "allow_cloud_audio": true, "cloud_audio_consent": consentJSON(consent),
                "pipeline_version": "swift-realtime-0.1.0", "started_at": .string(consent.approvedAt.ISO8601Format()),
                "duration_ms": .integer(Int64(chunks.reduce(0) { $0 + $1.durationSeconds } * 1_000)),
                "formats": ["json", "md", "txt", "srt", "vtt"],
                "engine_passes": [["engine": "openai-realtime", "version": "api-realtime-transcription",
                    "model": .string(consent.model), "model_sha256": nil, "command": [],
                    "duration_seconds": .number(chunks.reduce(0) { $0 + $1.durationSeconds }), "local_only": false]]],
            "language_processing": ["mode": "verbatim", "status": "not_requested", "processor": nil, "derivations": []],
            "segments": .array(segments), "review_reasons": .array(reasons)]
        let canonical = try CanonicalTranscript(document)
        guard try document.encoded().count <= TextJob.maximumTranscriptBytes else { throw SessionError.invalid("Cloud transcript is too large") }
        try write(audio, "audio-report.json", in: directory)
        try write(["schema_version": "1.1", "kind": "immutable_realtime_event_references", "consent": consentJSON(consent),
            "turn_directories": .array(chunks.map { .string($0.directory.lastPathComponent) })], "transcript.raw.json", in: directory)
        try write(document, "transcript.json", in: directory)
        try state("rendering", directory: directory, source: source)
        for (name, text) in TranscriptRenderer.render(canonical) {
            try cancel.check()
            try Data(text.utf8).write(to: directory.appendingPathComponent(name), options: .atomic)
        }
        try state("completed_with_review", directory: directory, source: source)
    }

    private static func consentJSON(_ value: CloudAudioConsent) -> JSONValue {
        ["source_session_id": .string(value.sourceSessionID.uuidString), "approved_at": .string(value.approvedAt.ISO8601Format()),
         "start_sample": .integer(value.startSample), "model": .string(value.model), "scope": "this_activation; new_audio_only"]
    }
    private static func milliseconds(_ frames: Int64, _ rate: Int) -> Int64 { Int64((Double(frames) / Double(rate) * 1_000).rounded()) }
    private static func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    private static func write(_ value: JSONValue, _ name: String, in directory: URL) throws {
        try value.encoded().write(to: directory.appendingPathComponent(name), options: .atomic)
    }
    private static func state(_ state: String, directory: URL, source: URL) throws {
        let date = JSONValue.string(Date().ISO8601Format())
        let file = directory.appendingPathComponent("manifest.json")
        var previous: JSONValue = [:]
        if let input = try? FileHandle(forReadingFrom: file) {
            defer { try? input.close() }
            let data = try input.read(upToCount: RecordingSession.maximumManifestBytes + 1) ?? Data()
            guard data.count <= RecordingSession.maximumManifestBytes else { throw SessionError.invalid("Cloud job manifest exceeds the size limit") }
            previous = try JSONDecoder().decode(JSONValue.self, from: data)
        }
        var artifacts: [String: JSONValue] = [:]
        if state == "completed_with_review" {
            for url in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey]) where url != file {
                let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
                guard values.isRegularFile == true else { continue }
                artifacts[url.lastPathComponent] = ["sha256": .string(try RecordingSession.hash(url)), "size_bytes": .integer(Int64(values.fileSize ?? 0))]
            }
        }
        try write(["schema_version": "1.0", "job_id": .string(directory.lastPathComponent), "source_path": .string(source.path),
            "state": .string(state), "progress": .number(state == "completed_with_review" ? 1 : state == "rendering" ? 0.9 : state == "validating" ? 0.8 : 0),
            "created_at": previous["created_at"] == .null ? date : previous["created_at"], "updated_at": date,
            "history": .array((previous["history"].array ?? []) + [["state": .string(state), "at": date]]),
            "error": nil, "artifacts": .object(artifacts)], "manifest.json", in: directory)
    }
}
