import Darwin
import Foundation
import os

public struct AudioEngineResult: Sendable {
    public var segments: [JSONValue]
    public var rawPath: URL
    public var provenance: JSONValue

    public init(segments: [JSONValue], rawPath: URL, provenance: JSONValue) {
        self.segments = segments
        self.rawPath = rawPath
        self.provenance = provenance
    }
}

/// Engines recognize audio only. Normalization/translation remain separate native
/// text jobs. Each response must retain the exact backend bytes at rawPath.
public protocol TranscriptEngine: Sendable {
    func transcribe(
        _ audio: URL,
        output: URL,
        language: String,
        check: @Sendable () throws -> Void
    ) throws -> AudioEngineResult
}

public protocol AudioPreparer: Sendable {
    func prepare(
        _ source: URL,
        channel: Int,
        output: URL,
        check: @Sendable () throws -> Void
    ) throws -> JSONValue
}

public struct AudioJobOptions: Sendable {
    public var sourceLanguage: String
    public var targetLanguage: String?
    public var mode: TextMode
    public var profile: String
    public var diarize: Bool

    public init(
        sourceLanguage: String = "auto",
        targetLanguage: String? = nil,
        mode: TextMode = .verbatim,
        profile: String = "fast",
        diarize: Bool = false
    ) {
        self.sourceLanguage = sourceLanguage
        self.targetLanguage = targetLanguage
        self.mode = mode
        self.profile = profile
        self.diarize = diarize
    }

    var json: JSONValue {
        [
            "source_language": .string(sourceLanguage),
            "target_language": targetLanguage.map(JSONValue.string) ?? .null,
            "mode": .string(mode.rawValue),
            "profile": .string(profile),
            "diarize": .string(diarize ? "auto" : "off"),
            "local_only": true,
            "formats": ["json", "md", "txt", "srt", "vtt"]
        ]
    }
}

/// Blocking work belongs on a utility worker. Originals are read-only; every job
/// owns an exclusively created directory, atomic lifecycle and immutable evidence.
public struct AudioJob: Sendable {
    public enum Policy {
        public static let decoderPaddingMS: Int64 = 30_000
        public static let partBoundaryMS: Int64 = 2_000
        public static let repetitionCount = 3
        public static let minimumConfidence = 0.6
        public static let version = "swift-audio-1.0"
    }

    private let engine: any TranscriptEngine
    private let verifier: (any TranscriptEngine)?
    private let preparer: any AudioPreparer

    public init(
        engine: any TranscriptEngine,
        verifier: (any TranscriptEngine)? = nil,
        preparer: any AudioPreparer
    ) {
        self.engine = engine
        self.verifier = verifier
        self.preparer = preparer
    }

    @discardableResult
    public func run(
        source: URL,
        output: URL,
        options: AudioJobOptions,
        check: @escaping @Sendable () throws -> Void = { try Task.checkCancellation() }
    ) throws -> CanonicalTranscript {
        try check()
        guard ["fast", "accurate", "verified"].contains(options.profile),
              options.profile != "verified" || verifier != nil else {
            throw CoreFailure("Verified recognition requires a second local model")
        }
        try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard mkdir(output.path, 0o700) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }

        let started = ContinuousClock.now
        let id = UUID().uuidString
        let created = TextJob.now
        let source = source.resolvingSymlinksInPath()
        let cancel: @Sendable () throws -> Void = {
            try check()
            if FileManager.default.fileExists(atPath: output.appendingPathComponent("cancel.request").path) {
                throw CancellationError()
            }
        }

        var manifest: JSONValue = [
            "schema_version": "1.0",
            "job_id": .string(id),
            "pipeline_version": .string(Policy.version),
            "source_path": .string(source.path),
            "created_at": .string(created),
            "options": options.json,
            "history": [],
            "artifacts": [:],
            "error": nil
        ]

        func write(_ value: JSONValue, _ name: String) throws {
            try TextJob.write(value.encoded(), named: name, in: output)
        }

        func transition(_ state: String, _ progress: Double, detail: String? = nil) throws {
            manifest["state"] = .string(state)
            manifest["progress"] = .number(progress)
            manifest["updated_at"] = .string(TextJob.now)
            manifest["detail"] = detail.map(JSONValue.string) ?? .null
            let historyEntry: JSONValue = [
                "state": .string(state),
                "at": .string(TextJob.now),
                "elapsed_seconds": .number(TextJob.seconds(since: started))
            ]
            manifest["history"] = .array((manifest["history"].array ?? []) + [historyEntry])
            try write(manifest, "manifest.json")
            Logger(subsystem: "com.moreaki.recscribe", category: "AudioJob")
                .notice("Audio job id=\(id, privacy: .public) state=\(state, privacy: .public) elapsed_s=\(TextJob.seconds(since: started))")
        }

        var records: [JSONValue] = []
        var passes: [JSONValue] = []
        var segments: [JSONValue] = []
        var disposable: [URL] = []

        func cleanWorkingAudio() throws {
            for path in disposable where FileManager.default.fileExists(atPath: path.path) {
                try FileManager.default.removeItem(at: path)
            }
        }
        defer { try? cleanWorkingAudio() }

        do {
            try transition("queued", 0)
            try cancel()
            try transition("inspecting", 0.05)

            let input = try TranscriptAudioInput.inspect(source, check: cancel)
            var report = input.report
            var reasons = input.reasons
            try write(report, "audio-report.json")

            if let parts = report["parts"].array {
                try transcribeSessionParts(
                    parts: parts,
                    source: source,
                    output: output,
                    options: options,
                    reasons: &reasons,
                    passes: &passes,
                    records: &records,
                    segments: &segments,
                    transition: transition,
                    cancel: cancel
                )
            } else {
                try transcribeSingleFileChannels(
                    source: source,
                    output: output,
                    options: options,
                    report: &report,
                    reasons: &reasons,
                    passes: &passes,
                    records: &records,
                    segments: &segments,
                    disposable: &disposable,
                    setWorkingAudio: { manifest["working_audio"] = .array($0) },
                    write: write,
                    transition: transition,
                    cancel: cancel
                )
            }

            let rawIndexKind = report["parts"].array == nil
                ? "immutable_engine_output_index"
                : "immutable_multipart_engine_output_index"
            try write(
                ["schema_version": "1.0", "kind": .string(rawIndexKind), "outputs": .array(records)],
                "transcript.raw.json"
            )
            guard try WAVAudio.hash(source, check: cancel) == report["sha256"].string else {
                throw CoreFailure("Source changed during processing")
            }
            for part in report["parts"].array ?? [] where part["report"] != .null {
                let partURL = try TranscriptAudioInput.partURL(part["path"].string!, beside: source)
                guard try WAVAudio.hash(partURL, check: cancel) == part["sha256"].string else {
                    throw CoreFailure("Session audio changed during processing")
                }
            }

            try transition("post-processing", 0.7)
            let value = finalizeTranscriptValue(
                id: id,
                created: created,
                started: started,
                options: options,
                report: report,
                passes: passes,
                segments: &segments,
                reasons: &reasons
            )

            try cancel()
            try transition("validating", 0.8)
            let document = try CanonicalTranscript(value)
            try write(value, "transcript.json")
            try transition("rendering", 0.9)
            for (name, content) in TranscriptRenderer.render(document) {
                try cancel()
                try TextJob.write(Data(content.utf8), named: name, in: output)
            }
            try cleanWorkingAudio()
            manifest["working_audio_retained"] = false
            try cancel()
            manifest["artifacts"] = try inventory(output, check: cancel)
            manifest["duration_seconds"] = .number(TextJob.seconds(since: started))
            try transition(value["status"].string!, 1)
            return document
        } catch {
            let state = error is CancellationError ? "cancelled" : "failed"
            manifest["error"] = ["type": .string(state), "message": .string(error.localizedDescription)]
            do {
                try cleanWorkingAudio()
                manifest["working_audio_retained"] = false
            } catch {
                manifest["error"]["cleanup_message"] = .string(error.localizedDescription)
                manifest["working_audio_retained"] = true
            }
            let reviewNote = "# Job \(state)\n\nNo complete transcript is available. Raw evidence and original audio are retained.\n"
            try? TextJob.write(Data(reviewNote.utf8), named: "review.md", in: output)
            manifest["artifacts"] = (try? inventory(output, check: {})) ?? [:]
            try? transition(state, manifest["progress"].double ?? 0)
            throw error
        }
    }

    // MARK: - Execution Helpers

    private func transcribeSessionParts(
        parts: [JSONValue],
        source: URL,
        output: URL,
        options: AudioJobOptions,
        reasons: inout [String],
        passes: inout [JSONValue],
        records: inout [JSONValue],
        segments: inout [JSONValue],
        transition: (String, Double, String?) throws -> Void,
        cancel: @escaping @Sendable () throws -> Void
    ) throws {
        for part in parts where part["report"] != .null {
            try cancel()
            let index = Int(part["index"].integer!)
            let offset = part["offset_ms"].integer!
            let child = output.appendingPathComponent(String(format: "part-%04d", index + 1))
            try transition(
                "transcribing-parts",
                0.1 + 0.55 * Double(index) / Double(parts.count),
                "Part \(index + 1)/\(parts.count)"
            )
            var childOptions = options
            childOptions.mode = .verbatim
            childOptions.targetLanguage = nil
            let path = try TranscriptAudioInput.partURL(part["path"].string!, beside: source)
            let document = try run(source: path, output: child, options: childOptions, check: cancel).value
            guard document["source"]["sha256"] == part["sha256"] else {
                throw CoreFailure("Part changed after session inspection")
            }
            reasons += document["review_reasons"].array?.compactMap(\.string) ?? []
            passes += document["processing"]["engine_passes"].array ?? []
            records.append([
                "part": part["index"],
                "offset_ms": .integer(offset),
                "path": .string(child.lastPathComponent + "/transcript.raw.json"),
                "sha256": .string(try WAVAudio.hash(child.appendingPathComponent("transcript.raw.json"), check: cancel))
            ])
            for var segment in document["segments"].array ?? [] {
                let startMS = segment["start_ms"].integer!
                let endMS = segment["end_ms"].integer!
                let partDurationMS = part["report"]["duration_ms"].integer!
                if (index > 0 && startMS < Policy.partBoundaryMS)
                    || (index < parts.count - 1 && endMS > partDurationMS - Policy.partBoundaryMS) {
                    addReason("part_boundary; check_cut_or_duplicate_speech", to: &segment)
                }
                for key in ["start_ms", "end_ms"] {
                    segment[key] = .integer(segment[key].integer! + offset)
                }
                segment["words"] = .array((segment["words"].array ?? []).map { word in
                    var word = word
                    for key in ["start_ms", "end_ms"] {
                        if let value = word[key].integer {
                            word[key] = .integer(value + offset)
                        }
                    }
                    return word
                })
                if let original = segment["timing_adjustment"]["original_end_ms"].integer {
                    segment["timing_adjustment"]["original_end_ms"] = .integer(original + offset)
                }
                segments.append(segment)
            }
        }
    }

    private func transcribeSingleFileChannels(
        source: URL,
        output: URL,
        options: AudioJobOptions,
        report: inout JSONValue,
        reasons: inout [String],
        passes: inout [JSONValue],
        records: inout [JSONValue],
        segments: inout [JSONValue],
        disposable: inout [URL],
        setWorkingAudio: ([JSONValue]) -> Void,
        write: (JSONValue, String) throws -> Void,
        transition: (String, Double, String?) throws -> Void,
        cancel: @escaping @Sendable () throws -> Void
    ) throws {
        let channels = Int(report["channels"].integer!)
        let shared = report["channels_bit_identical"] == true
        let recognition = shared ? [0] : Array(0..<channels)
        report["recognition_channels"] = .array(recognition.map { .integer(Int64($0)) })
        try write(report, "audio-report.json")
        if channels > 1 && !shared {
            reasons.append("multiple_channels; overlapping cues and duplicate speech require review")
        }
        try transition("preparing", 0.15, nil)

        var working: [JSONValue] = []
        for channel in recognition {
            try cancel()
            let path = output.appendingPathComponent("working-channel-\(channel).wav")
            disposable.append(path)
            var prepared = try preparer.prepare(source, channel: channel, output: path, check: cancel)
            prepared["retention"] = "temporary; removed on terminal job state"
            working.append(prepared)
            setWorkingAudio(working)
            try transition(
                "preparing",
                0.15 + 0.1 * Double(working.count) / Double(recognition.count),
                "Prepared channel \(channel + 1)/\(channels)"
            )
        }

        for channel in 0..<channels {
            try cancel()
            if !recognition.contains(channel) {
                records.append([
                    "channel": .integer(Int64(channel)),
                    "status": "shared_bit_identical_channel",
                    "source_channel": 0
                ])
                continue
            }
            if report["channel_metrics"].array![channel]["digital_silence"] == true {
                records.append([
                    "channel": .integer(Int64(channel)),
                    "status": "skipped_digital_silence"
                ])
                continue
            }
            try transition(
                "transcribing",
                0.3 + 0.35 * Double(channel) / Double(channels),
                "Channel \(channel + 1)/\(channels)"
            )
            let audio = output.appendingPathComponent("working-channel-\(channel).wav")
            let regions = try WAVAudio.recognitionRegions(report, channel: channel)
            if let regions {
                records.append([
                    "channel": .integer(Int64(channel)),
                    "status": "shared_outside_different_regions",
                    "source_channel": 0,
                    "different_regions_frames": .array(regions.map { [.integer($0.lowerBound), .integer($0.upperBound)] }),
                    "policy": "exact_pcm_equality_v1"
                ])
                reasons.append("channel_window_reuse; verify_channel_variants_at_region_boundaries")
            }

            let primary = try recognize(
                engine,
                audio: audio,
                output: output.appendingPathComponent("asr-channel-\(channel)"),
                language: options.sourceLanguage,
                report: report,
                regions: regions,
                disposable: &disposable,
                check: cancel
            )
            records.append(try record(primary, channel: channel, role: "primary", beside: output, check: cancel))
            passes.append(primary.provenance)

            var disagreement = false
            if options.profile == "verified", let verifier {
                let second = try recognize(
                    verifier,
                    audio: audio,
                    output: output.appendingPathComponent("verify-channel-\(channel)"),
                    language: options.sourceLanguage,
                    report: report,
                    regions: regions,
                    disposable: &disposable,
                    check: cancel
                )
                records.append(try record(second, channel: channel, role: "verification", beside: output, check: cancel))
                passes.append(second.provenance)
                guard primary.provenance["model_sha256"] != second.provenance["model_sha256"] else {
                    throw CoreFailure("Verified recognition requires two distinct model checksums")
                }
                disagreement = text(primary.segments) != text(second.segments)
                if disagreement {
                    reasons.append("engine_pass_disagreement_channel_\(channel)")
                }
            }

            if primary.segments.isEmpty {
                reasons.append("no_speech_recognized_in_non_silent_channel_\(channel)")
            }

            let channelClipped = report["channel_metrics"].array![channel]["clipped_samples"].integer! > 0
            let duration = report["duration_ms"].integer!
            for var segment in primary.segments {
                segment["channel"] = .integer(Int64(channel))
                segment["normalized_text"] = .null
                segment["translated_text"] = .null
                let start = segment["start_ms"].integer ?? -1
                let end = segment["end_ms"].integer ?? -1
                if start >= 0 && start < duration && duration < end && end <= duration + Policy.decoderPaddingMS {
                    segment["timing_adjustment"] = [
                        "original_end_ms": .integer(end),
                        "reason": "decoder_padding_beyond_source"
                    ]
                    segment["end_ms"] = .integer(duration)
                    addReason("engine_end_exceeds_source; trimmed_with_provenance", to: &segment)
                }
                if segment["confidence"] == .null {
                    addReason("confidence_unavailable", to: &segment)
                } else if segment["confidence"].double! < Policy.minimumConfidence {
                    addReason("low_confidence", to: &segment)
                }
                if segment["source_text"].string?.range(
                    of: #"^\s*\[(?:BLANK_AUDIO|NO_SPEECH|SILENCE|MUSIC)\]\s*$"#,
                    options: [.regularExpression, .caseInsensitive]
                ) != nil {
                    addReason("engine_non_speech_marker", to: &segment)
                }
                if disagreement {
                    addReason("engine_pass_disagreement", to: &segment)
                }
                if channelClipped {
                    addReason("source_contains_clipping", to: &segment)
                }
                segments.append(segment)
            }
        }
    }

    private func finalizeTranscriptValue(
        id: String,
        created: String,
        started: ContinuousClock.Instant,
        options: AudioJobOptions,
        report: JSONValue,
        passes: [JSONValue],
        segments: inout [JSONValue],
        reasons: inout [String]
    ) -> JSONValue {
        if options.diarize {
            reasons.append("diarization_not_available; channel indices are not speaker identities")
        }
        if options.sourceLanguage == "de-CH" {
            reasons.append("dialect_fidelity_unverified; Whisper may produce Standard German")
        }
        if options.mode != .verbatim {
            reasons.append("\(options.mode.rawValue)_processor_not_configured")
        }
        segments.sort { a, b in
            for key in ["start_ms", "channel", "end_ms"] where a[key] != b[key] {
                return (a[key].integer ?? -1) < (b[key].integer ?? -1)
            }
            return false
        }
        let keys = segments.map {
            "\($0["channel"].integer ?? 0):" + text([$0]).folding(
                options: .caseInsensitive,
                locale: Locale(identifier: "en_US_POSIX")
            )
        }
        let counts = Dictionary(keys.map { ($0, 1) }, uniquingKeysWith: +)
        for index in segments.indices {
            segments[index]["id"] = .string(String(format: "seg-%06d", index + 1))
            if options.mode != .verbatim {
                addReason("\(options.mode.rawValue)_processor_not_configured", to: &segments[index])
            }
            if counts[keys[index], default: 0] >= Policy.repetitionCount {
                addReason("repeated_asr_text; verify_against_audio", to: &segments[index])
            }
            segments[index]["needs_review"] = .bool(!(segments[index]["review_reasons"].array ?? []).isEmpty)
        }
        if !passes.isEmpty && options.sourceLanguage == "auto" {
            reasons.append("automatic_language_detection_unverified; a quiet opening can select the wrong language")
        }
        if segments.contains(where: { $0["review_reasons"].array?.contains("engine_non_speech_marker") == true }) {
            reasons.append("asr_contains_non_speech_markers; inspect_source_audio")
        }
        if !passes.isEmpty && !passes.contains(where: { $0["vad_model_sha256"] != .null }) {
            reasons.append("learned_vad_not_run; silence guard only detects exact digital silence")
        }
        reasons = unique(reasons)
        let state = !reasons.isEmpty || segments.contains { $0["needs_review"] == true }
            ? "completed_with_review"
            : "completed"
        var processing = options.json
        processing["engine_passes"] = .array(passes)
        processing["pipeline_version"] = .string(Policy.version)
        processing["started_at"] = .string(created)
        processing["duration_ms"] = .integer(Int64((TextJob.seconds(since: started) * 1000).rounded()))
        return [
            "schema_version": "1.0",
            "job_id": .string(id),
            "status": .string(state),
            "source": report,
            "segments": .array(segments),
            "review_reasons": .array(reasons.map(JSONValue.string)),
            "processing": processing,
            "language_processing": [
                "mode": .string(options.mode.rawValue),
                "status": .string(options.mode == .verbatim ? "not_requested" : "pending"),
                "processor": nil,
                "derivations": []
            ]
        ]
    }

    private func recognize(
        _ engine: any TranscriptEngine,
        audio: URL,
        output: URL,
        language: String,
        report: JSONValue,
        regions: [Range<Int64>]?,
        disposable: inout [URL],
        check: @Sendable () throws -> Void
    ) throws -> AudioEngineResult {
        guard let regions else {
            return try validate(engine.transcribe(audio, output: output, language: language, check: check))
        }
        let working = try WAVAudio.layout(audio)
        let rate = report["sample_rate"].integer!
        var segments: [JSONValue] = []
        var records: [JSONValue] = []
        var provenance: JSONValue = [:]
        var elapsed = 0.0

        for (index, region) in regions.enumerated() {
            try check()
            let first = region.lowerBound * Int64(working.rate) / rate
            let last = min(working.frames, (region.upperBound * Int64(working.rate) + rate - 1) / rate)
            let part = output.deletingLastPathComponent().appendingPathComponent(output.lastPathComponent + "-region-\(index).wav")
            disposable.append(part)
            try WAVAudio.copyFrames(audio, range: first..<last, to: part, check: check)
            let prefix = part.deletingPathExtension()
            let result = try validate(engine.transcribe(part, output: prefix, language: language, check: check))
            let offset = first * 1000 / Int64(working.rate)
            let duration = ((last - first) * 1000 + Int64(working.rate) - 1) / Int64(working.rate)
            for var segment in result.segments {
                guard let begin = segment["start_ms"].integer, let end = segment["end_ms"].integer else {
                    throw CoreFailure("Invalid engine region timing")
                }
                let start = max(0, begin)
                let stop = min(duration, end)
                guard stop > start else { continue }
                segment["start_ms"] = .integer(start + offset)
                segment["end_ms"] = .integer(stop + offset)
                segment["review_reasons"] = ["channel_window_boundary; verify_partial_or_duplicate_speech"]
                segment["words"] = .array((segment["words"].array ?? []).map { word in
                    var word = word
                    for key in ["start_ms", "end_ms"] {
                        if let time = word[key].integer {
                            word[key] = .integer(min(duration, max(0, time)) + offset)
                        }
                    }
                    return word
                })
                segments.append(segment)
            }
            provenance = result.provenance
            elapsed += result.provenance["duration_seconds"].double ?? 0
            records.append([
                "path": .string(result.rawPath.lastPathComponent),
                "sha256": .string(try WAVAudio.hash(result.rawPath, check: check)),
                "working_audio": .string(part.lastPathComponent),
                "working_sha256": .string(try WAVAudio.hash(part, check: check)),
                "working_audio_retention": "temporary; removed on terminal job state",
                "offset_ms": .integer(offset),
                "duration_ms": .integer(duration),
                "source_frames": [.integer(region.lowerBound), .integer(region.upperBound)],
                "provenance": result.provenance
            ])
        }
        let raw = output.appendingPathExtension("regions.json")
        let index: JSONValue = [
            "kind": "channel_region_output_index",
            "policy": "exact_pcm_equality_v1",
            "shared_source_channel": 0,
            "regions": .array(records),
            "timing_policy": "region-relative times clipped to region and offset; originals retained"
        ]
        try index.encoded().write(to: raw, options: .withoutOverwriting)
        provenance["channel_regions"] = .array(records)
        provenance["duration_seconds"] = .number(elapsed)
        provenance["command"] = []
        return AudioEngineResult(segments: segments, rawPath: raw, provenance: provenance)
    }

    private func validate(_ result: AudioEngineResult) throws -> AudioEngineResult {
        for segment in result.segments {
            guard let start = segment["start_ms"].integer,
                  let end = segment["end_ms"].integer,
                  start >= 0,
                  end > start,
                  let text = segment["source_text"].string,
                  !text.isEmpty,
                  segment["confidence"] == .null || segment["confidence"].double.map({ $0.isFinite && (0...1).contains($0) }) == true,
                  let words = segment["words"].array else {
                throw CoreFailure("Invalid engine segment; raw evidence retained")
            }
            for word in words {
                guard word["text"].string != nil,
                      let begin = word["start_ms"].integer,
                      let finish = word["end_ms"].integer,
                      begin >= 0,
                      finish >= begin else {
                    throw CoreFailure("Invalid engine word timing; raw evidence retained")
                }
            }
        }
        return result
    }

    private func record(
        _ result: AudioEngineResult,
        channel: Int,
        role: String,
        beside directory: URL,
        check: () throws -> Void
    ) throws -> JSONValue {
        guard result.rawPath.isFileURL,
              result.rawPath.deletingLastPathComponent().resolvingSymlinksInPath().path == directory.resolvingSymlinksInPath().path else {
            throw CoreFailure("Engine output escaped the job directory")
        }
        return [
            "channel": .integer(Int64(channel)),
            "role": .string(role),
            "status": "produced",
            "path": .string(result.rawPath.lastPathComponent),
            "sha256": .string(try WAVAudio.hash(result.rawPath, check: check)),
            "provenance": result.provenance
        ]
    }

    private func text(_ segments: [JSONValue]) -> String {
        segments.map {
            ($0["source_text"].string ?? "").split(whereSeparator: \.isWhitespace).joined(separator: " ")
        }.joined(separator: " ")
    }

    private func unique(_ reasons: [String]) -> [String] {
        var seen = Set<String>()
        return reasons.filter { seen.insert($0).inserted }
    }

    private func addReason(_ reason: String, to segment: inout JSONValue) {
        let existing = (segment["review_reasons"].array ?? []).compactMap(\.string)
        segment["review_reasons"] = .array(unique(existing + [reason]).map(JSONValue.string))
    }

    private func inventory(_ directory: URL, check: () throws -> Void) throws -> JSONValue {
        guard let files = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.isRegularFileKey]) else {
            throw CoreFailure("Cannot inventory audio job")
        }
        var result: [String: JSONValue] = [:]
        for case let url as URL in files {
            try check()
            guard url.lastPathComponent != "manifest.json",
                  url.lastPathComponent != "cancel.request",
                  try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else {
                continue
            }
            let path = String(url.path.dropFirst(directory.path.count + 1))
            let size = Int64(try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
            result[path] = [
                "sha256": .string(try WAVAudio.hash(url, check: check)),
                "size_bytes": .integer(size)
            ]
        }
        return .object(result)
    }
}
