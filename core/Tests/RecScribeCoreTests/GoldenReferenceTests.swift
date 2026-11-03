import Foundation
import Testing
@testable import RecScribeCore

/// Frozen independent outputs; no interpreter, model, FFmpeg or network required.
enum GoldenReference {
    static let directory = Bundle.module.resourceURL!.appendingPathComponent("Fixtures/PythonReference")
    static let jobs = ["audio-identical-normalize", "audio-distinct-silent", "audio-regions",
        "audio-verified", "audio-missing", "audio-session-v1", "audio-session-v2", "audio-session-v3",
        "text-normalize-summary", "text-summary-only", "text-translate", "text-cloud-normalize"]

    static func read(_ fixture: String, _ name: String) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: directory.appendingPathComponent(fixture).appendingPathComponent(name)))
    }

    static func normalize(_ value: JSONValue, root: URL) -> JSONValue {
        switch value {
        case .object(let fields): .object(fields.mapValues { normalize($0, root: root) })
        case .array(let values): .array(values.map { normalize($0, root: root) })
        case .string(let text):
            .string(Set([root.path, root.resolvingSymlinksInPath().path]).sorted { $0.count > $1.count }
                .reduce(text) { $0.replacingOccurrences(of: $1, with: "/fixture") })
        default: value
        }
    }

    static func inspection(_ report: JSONValue, root: URL, fixture: String) throws {
        var actual = normalize(report, root: root), expected = try read(fixture, "inspection.json")
        let metrics = try #require(actual["channel_metrics"].array)
        let reference = try #require(expected["channel_metrics"].array)
        #expect(metrics.count == reference.count)
        for (channel, golden) in zip(metrics, reference) {
            for (key, value) in try #require(golden.object) {
                guard value.double != nil else {
                    #expect(channel[key] == value)
                    continue
                }
                let number = try #require(channel[key].double), baseline = try #require(value.double)
                #expect(abs(number - baseline) <= max(1, abs(baseline)) * 1e-12)
            }
        }
        actual["channel_metrics"] = nil; expected["channel_metrics"] = nil
        #expect(actual == expected, "Inspection reference mismatch: \(fixture)")
    }

    static func exports(_ job: URL, fixture: String) throws {
        for name in TranscriptRenderer.render(try CanonicalTranscript(read(fixture, "transcript.json"))).keys {
            let expected = try Data(contentsOf: directory.appendingPathComponent(fixture).appendingPathComponent(name))
            #expect(try Data(contentsOf: job.appendingPathComponent(name)) == expected, "Export reference mismatch: \(fixture)/\(name)")
        }
    }
}

@Suite struct GoldenReferenceTests {
    @Test func capturedInventoryRetainsOriginalBytes() throws {
        let sums = try String(contentsOf: GoldenReference.directory.appendingPathComponent("SHA256SUMS"), encoding: .utf8)
        let lines = sums.split(separator: "\n")
        #expect(lines.count == 80)
        for line in lines {
            let fields = line.split(maxSplits: 1, whereSeparator: \.isWhitespace)
            let path = String(fields[1]).trimmingCharacters(in: .whitespaces)
            let data = try Data(contentsOf: GoldenReference.directory.appendingPathComponent(path))
            #expect(TextJob.hash(data) == fields[0], "Captured fixture changed: \(path)")
        }
    }
    @Test(arguments: GoldenReference.jobs)
    func frozenDocumentsValidateAndRenderByteIdentically(fixture: String) throws {
        let document = try CanonicalTranscript(GoldenReference.read(fixture, "transcript.json"))
        let rendered = TranscriptRenderer.render(document)
        #expect(rendered.count == 5)
        for (name, content) in rendered {
            let expected = try Data(contentsOf: GoldenReference.directory.appendingPathComponent(fixture).appendingPathComponent(name))
            #expect(Data(content.utf8) == expected, "Frozen renderer mismatch: \(fixture)/\(name)")
        }
    }
}
