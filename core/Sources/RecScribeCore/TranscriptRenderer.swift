import Foundation

/// Byte-compatible deterministic views of canonical v1 JSON. No model calls or file I/O.
public enum TranscriptRenderer {
    public static func timestamp(_ milliseconds: Int64, separator: String = ".") -> String {
        String(format: "%02lld:%02lld:%02lld%@%03lld", milliseconds / 3_600_000, milliseconds / 60_000 % 60,
               milliseconds / 1_000 % 60, separator, milliseconds % 1_000)
    }
    private static func line(_ text: String) -> String { text.split(whereSeparator: \.isWhitespace).joined(separator: " ") }
    private static func html(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#x27;")
    }
    private static func markdown(_ text: String) -> String {
        html(line(text)).map { "\\`*_{}[]()#+.!|>~-".contains($0) ? "\\" + String($0) : String($0) }.joined()
    }
    public static func render(_ transcript: CanonicalTranscript) -> [String: String] {
        let doc = transcript.value, segments = doc["segments"].array ?? []
        let mode = doc["processing"]["mode"].string ?? "verbatim"
        var md = ["# RecScribe transcript", "", "Requested mode: \(mode)", ""]
        var review = ["# Review", ""] + (doc["review_reasons"].array ?? []).map { "- " + ($0.string ?? "") } + [""]
        var srt: [String] = [], vtt = ["WEBVTT", ""]
        if doc["language_processing"]["status"] == "pending" {
            md += ["Language processing is pending; the text below remains raw ASR source text.", ""]
        }
        if doc["summary"] != .null {
            md += ["## Summary notes [REVIEW]", ""]
            for note in doc["summary"]["notes"].array ?? [] {
                md += ["- \(markdown(note["text"].string ?? "")) (\((note["segment_ids"].array ?? []).compactMap(\.string).joined(separator: ", ")))" ]
            }
            md += [""]
        }
        for (index, segment) in segments.enumerated() {
            let source = segment["source_text"].string ?? "", id = segment["id"].string ?? ""
            let derived = segment[mode == "normalize" ? "normalized_text" : mode == "translate" ? "translated_text" : "source_text"].string ?? ""
            let text = line(derived.isEmpty ? source : derived), marker = segment["needs_review"] == true ? "[REVIEW] " : ""
            let payload = html(marker + text).replacingOccurrences(of: "-->", with: "—>")
            let start = segment["start_ms"].integer ?? 0, end = segment["end_ms"].integer ?? 0
            md += ["## \(timestamp(start)) · \(id) · channel \((segment["channel"].integer ?? 0) + 1)", "", marker + markdown(text), ""]
            if !marker.isEmpty {
                review += ["## \(id) (\(timestamp(start)))", "", markdown(source), ""]
                review += (segment["review_reasons"].array ?? []).map { "- " + ($0.string ?? "") } + [""]
            }
            srt += [String(index + 1), "\(timestamp(start, separator: ",")) --> \(timestamp(end, separator: ","))", payload, ""]
            vtt += [id, "\(timestamp(start)) --> \(timestamp(end))", payload, ""]
        }
        return ["transcript.verbatim.txt": segments.compactMap { $0["source_text"].string }.joined(separator: "\n") + (segments.isEmpty ? "" : "\n"),
                "transcript.cleaned.md": md.joined(separator: "\n"), "transcript.srt": srt.joined(separator: "\n"),
                "transcript.vtt": vtt.joined(separator: "\n"), "review.md": review.joined(separator: "\n")]
    }
}
