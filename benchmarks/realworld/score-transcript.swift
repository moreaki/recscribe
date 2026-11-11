// Compile together with the UNMODIFIED JSONValue.swift and TranscriptAccuracy.swift.
// This standalone research bridge imports no recognition engine and edits no core source.
import CryptoKit
import Darwin
import Dispatch
import Foundation

private final class ResearchScoringCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var requested = false

    func cancel() {
        lock.lock(); requested = true; lock.unlock()
    }

    func check(marker: URL?, started: ContinuousClock.Instant, seconds: Double) throws {
        lock.lock(); let stopped = requested; lock.unlock()
        if stopped || marker.map({ FileManager.default.fileExists(atPath: $0.path) }) == true {
            throw CoreFailure("Scoring cancelled; inputs and partial evidence retained")
        }
        let elapsed = started.duration(to: .now)
        let value = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
        guard value < seconds else { throw CoreFailure("Scoring time budget exhausted") }
    }
}

@main
private struct ResearchTranscriptScorer {
    private static let expectedOptions: Set<String> = ["--reference", "--reference-sha256", "--hypothesis",
        "--hypothesis-sha256", "--language", "--output", "--duration-seconds", "--max-seconds", "--cancel-marker"]

    private static func arguments() throws -> [String: String] {
        let values = Array(CommandLine.arguments.dropFirst())
        guard values.count % 2 == 0 else { throw CoreFailure("Supply explicit option/value pairs") }
        var result: [String: String] = [:]
        for index in stride(from: 0, to: values.count, by: 2) {
            let key = values[index]
            guard expectedOptions.contains(key), result[key] == nil else { throw CoreFailure("Unknown or duplicate scorer option") }
            result[key] = values[index + 1]
        }
        for key in ["--reference", "--reference-sha256", "--hypothesis", "--hypothesis-sha256", "--language", "--output"] {
            guard let value = result[key], !value.isEmpty else { throw CoreFailure("Missing scorer option: \(key)") }
        }
        return result
    }

    private static func sha(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func readText(_ path: String, expected: String) throws -> (Data, String) {
        guard path.hasPrefix("/"), expected.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil else {
            throw CoreFailure("Absolute input paths and exact SHA-256s required")
        }
        let file = try FileHandle(forReadingFrom: URL(fileURLWithPath: path)); defer { try? file.close() }
        let data = try file.read(upToCount: TranscriptAccuracy.maximumScoringTextBytes + 1) ?? Data()
        guard data.count <= TranscriptAccuracy.maximumScoringTextBytes else { throw CoreFailure("Scoring input exceeds 1 MiB") }
        guard sha(data) == expected else { throw CoreFailure("Scoring input differs from its frozen SHA-256") }
        guard let text = String(data: data, encoding: .utf8) else { throw CoreFailure("Scoring input is not valid UTF-8") }
        return (data, text)
    }

    private static func newOutput(_ path: String) throws -> URL {
        guard path.hasPrefix("/") else { throw CoreFailure("Use an absolute protected output directory") }
        let output = URL(fileURLWithPath: path).standardizedFileURL
        var ancestor = output
        while ancestor.path != "/" {
            if (try? ancestor.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
                throw CoreFailure("Protected scoring output cannot follow symlinks")
            }
            ancestor.deleteLastPathComponent()
        }
        let source = URL(fileURLWithPath: #filePath).standardizedFileURL
        let checkout = source.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        guard output.path != checkout.path, !output.path.hasPrefix(checkout.path + "/") else {
            throw CoreFailure("Reference/hypothesis snapshots belong outside the checkout")
        }
        guard mkdir(output.path, 0o700) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        return output
    }

    static func main() {
        var output: URL?
        do {
            let options = try arguments()
            let language = options["--language"]!
            guard language.range(of: "^[a-z]{2}(?:-[A-Za-z0-9]{2,8})*$", options: .regularExpression) != nil,
                  let base = language.split(separator: "-").first,
                  ["de", "fr", "it", "en", "ar", "zh", "es", "pt"].contains(String(base)) else {
                throw CoreFailure("Declare the source/reference priority language; automatic is not a scoring convention")
            }
            let budget = Double(options["--max-seconds"] ?? "60") ?? .nan
            guard budget.isFinite, (1...120).contains(budget) else { throw CoreFailure("Choose a 1–120-second scoring budget") }
            let duration = options["--duration-seconds"].flatMap(Double.init)
            if options["--duration-seconds"] != nil {
                guard let duration, duration.isFinite, duration > 0, duration <= 60 else { throw CoreFailure("Duration must be finite and at most60 seconds") }
            }
            output = try newOutput(options["--output"]!)
            let folder = output!
            let marker = options["--cancel-marker"].map { URL(fileURLWithPath: $0) }
            let cancellation = ResearchScoringCancellation()
            let started = ContinuousClock.now
            let queue = DispatchQueue(label: "recscribe.research-scoring-signals")
            let sources: [DispatchSourceSignal] = [SIGINT, SIGTERM, SIGHUP].map { number in
                _ = signal(number, SIG_IGN)
                let source = DispatchSource.makeSignalSource(signal: number, queue: queue)
                source.setEventHandler { cancellation.cancel() }
                source.resume()
                return source
            }
            defer { for source in sources { source.cancel() } }
            let check: @Sendable () throws -> Void = {
                try cancellation.check(marker: marker, started: started, seconds: budget)
            }
            try check()
            let (referenceBytes, reference) = try readText(options["--reference"]!, expected: options["--reference-sha256"]!)
            let (hypothesisBytes, hypothesis) = try readText(options["--hypothesis"]!, expected: options["--hypothesis-sha256"]!)
            try referenceBytes.write(to: folder.appendingPathComponent("reference.original.txt"), options: .withoutOverwriting)
            try hypothesisBytes.write(to: folder.appendingPathComponent("hypothesis.original.txt"), options: .withoutOverwriting)
            var counts = try TranscriptAccuracy.checkedScore(reference: reference, hypothesis: hypothesis,
                policy: .legacyV1, durationSeconds: duration, check: check)
            // Match the existing v1 corpus reporter's Chinese CER-only presentation.
            // Keep native v1 normalization/character counts; do not switch to v2.
            if base == "zh" {
                for key in ["wer", "word_errors", "word_insertions", "word_deletions", "word_substitutions", "reference_words",
                            "false_speech_words", "false_speech_words_per_minute"] { counts[key] = .null }
                counts["word_segmentation"] = "unmeasured; no Chinese word segmenter"
            }
            counts["bridge_version"] = "external-transcript-score-v1"
            counts["source_language"] = .string(language)
            counts["reference_sha256"] = .string(sha(referenceBytes))
            counts["hypothesis_sha256"] = .string(sha(hypothesisBytes))
            counts["word_reporting_policy"] = base == "zh" ? "Chinese CER only; legacy-v1 normalization retained" : "native legacy-v1 whitespace WER"
            counts["quality_approval"] = false
            counts["reference_corrected"] = false
            try check()
            let encoded = try counts.encoded()
            try encoded.write(to: folder.appendingPathComponent("score.json"), options: .withoutOverwriting)
            FileHandle.standardOutput.write(encoded + Data("\n".utf8))
        } catch {
            if let output {
                let failure: JSONValue = ["bridge_version": "external-transcript-score-v1", "status": "failed",
                    "error": .string(error.localizedDescription), "scores_invented": false]
                if let data = try? failure.encoded() {
                    try? data.write(to: output.appendingPathComponent("failure.json"), options: .withoutOverwriting)
                }
            }
            FileHandle.standardError.write(Data(("Scoring failed: " + error.localizedDescription + "\n").utf8))
            exit(1)
        }
    }
}
