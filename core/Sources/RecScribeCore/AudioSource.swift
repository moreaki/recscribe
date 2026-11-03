import Foundation

/// Read-only final-audio input. Missing parts retain their timeline positions and
/// review reasons; a session is never silently shortened or physically joined.
struct AudioSource {
    let report: JSONValue
    let reasons: [String]

    static func inspect(_ url: URL, check: () throws -> Void) throws -> Self {
        guard url.lastPathComponent.hasSuffix(".recscribe.json") else {
            return Self(report: try WAVAudio.inspect(url, check: check).report, reasons: [])
        }
        let digest = try WAVAudio.hash(url, check: check)
        let session = try readJSON(url)
        guard let version = session["schemaVersion"].integer, (1...3).contains(version),
              let rate = session["sampleRate"].integer, (1...384_000).contains(rate),
              let channels = session["channels"].integer, (1...32).contains(channels),
              session["bitDepth"] == 16, session["channelMap"].array?.count == Int(channels),
              session["status"] != "recording", let entries = session["parts"].array else {
            throw CoreFailure("Finalize/recover the session and verify its supported PCM format first")
        }
        var parts: [JSONValue] = [], reasons = session["issues"].array?.compactMap(\.string) ?? []
        var end: Int64 = 0, size: Int64 = 0, names = Set<String>()
        for (index, entry) in entries.enumerated() {
            try check()
            guard let name = entry["path"].string, names.insert(name).inserted,
                  let start = entry["startSample"].integer, let frames = entry["frames"].integer,
                  let partSize = entry["sizeBytes"].integer, start >= end, frames >= 0, partSize >= 0,
                  !start.addingReportingOverflow(frames).overflow, !size.addingReportingOverflow(partSize).overflow else {
                throw CoreFailure("Invalid session path/order/sample range")
            }
            let source = try partURL(name, beside: url)
            guard start <= Int64.max / 1000 else { throw CoreFailure("Session timeline exceeds timestamp range") }
            if start != end { reasons.append("missing_sample_range:\(end):\(start)") }
            end = start + frames; size += partSize
            var part = entry
            part["index"] = .integer(Int64(index)); part["offset_ms"] = .integer(start * 1000 / rate); part["report"] = .null
            do {
                guard entry["status"] == "verified", entry["sha256"].string != nil else { throw CoreFailure("Part has not been verified; recover/verify it first") }
                let report = try WAVAudio.inspect(source, check: check).report
                guard report["sample_rate"] == .integer(rate), report["channels"] == .integer(channels),
                      report["bit_depth"] == 16, report["frames"] == .integer(frames), report["size_bytes"] == entry["sizeBytes"],
                      report["sha256"] == entry["sha256"] else { throw CoreFailure("Part checksum, length or format mismatch") }
                part["report"] = report
            } catch is CancellationError { throw CancellationError() }
            catch { reasons.append("part_\(index + 1)_unavailable:\(error.localizedDescription)") }
            parts.append(part)
        }
        let available = parts.filter { $0["report"] != .null }
        guard end > 0, end <= (Int64.max - rate) / 1000, !available.isEmpty else { throw CoreFailure("No verified audio parts available") }
        var report: JSONValue = ["path": .string(url.path), "sha256": .string(digest), "container": "WAV", "codec": "PCM",
            "sample_rate": .integer(rate), "channels": .integer(channels), "bit_depth": 16, "frames": .integer(end),
            "duration_ms": .integer((end * 1000 + rate - 1) / rate), "size_bytes": .integer(size),
            "session_id": session["id"], "parts": .array(parts), "channel_layout": session["channelMap"], "kind": "multipart_session"]
        if session["sourceIdentity"] != .null { report["capture_source"] = session["sourceIdentity"] }
        if !(session["sourceTracks"].array ?? []).isEmpty {
            report["kind"] = "derived_capture_mix"; report["capture_source_tracks"] = session["sourceTracks"]
            reasons.append("derived_mix:source_tracks_preserved_separately;select_source_session_for_independent_recognition")
        }
        report["channel_metrics"] = .array((0..<Int(channels)).map { channel in
            let metrics = available.map { ($0["report"]["channel_metrics"].array![channel], $0["frames"].integer!) }
            let count = metrics.reduce(0.0) { $0 + Double($1.1) }
            return ["channel": .integer(Int64(channel)), "peak": .number(metrics.map { $0.0["peak"].double! }.max()!),
                "rms": .number(sqrt(metrics.reduce(0.0) { $0 + pow($1.0["rms"].double!, 2) * Double($1.1) } / count)),
                "clipped_samples": .integer(metrics.reduce(0) { $0 + $1.0["clipped_samples"].integer! }),
                "digital_silence": .bool(metrics.allSatisfy { $0.0["digital_silence"] == true })]
        })
        return Self(report: report, reasons: reasons)
    }

    static func partURL(_ name: String, beside manifest: URL) throws -> URL {
        guard !name.isEmpty, name != ".", name != "..", !name.contains(where: { "/\\\n\r\0".contains($0) }) else {
            throw CoreFailure("Invalid session part path")
        }
        let url = manifest.deletingLastPathComponent().appendingPathComponent(name)
        guard url.resolvingSymlinksInPath().deletingLastPathComponent() == manifest.deletingLastPathComponent().resolvingSymlinksInPath() else {
            throw CoreFailure("Session path escapes its directory")
        }
        return url
    }

    static func readJSON(_ url: URL, limit: Int = TextJob.maximumTranscriptBytes) throws -> JSONValue {
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        let data = try file.read(upToCount: limit + 1) ?? Data()
        guard data.count <= limit else { throw CoreFailure("JSON evidence exceeds the size limit") }
        return try JSONDecoder().decode(JSONValue.self, from: data)
    }
}
