import Foundation
import Testing
@testable import RecScribeCore

/// Frozen independent outputs; no interpreter, model, FFmpeg or network required.
enum GoldenReference {
    static let directory = Bundle.module.resourceURL!.appendingPathComponent("Fixtures/PythonReference")
    static let jobs = ["audio-identical-normalize", "audio-distinct-silent", "audio-regions",
        "audio-verified", "audio-missing", "audio-session-v1", "audio-session-v2", "audio-session-v3",
        "text-normalize-summary", "text-summary-only", "text-translate", "text-cloud-normalize"]

    static func record(_ fixture: String) throws -> JSONValue {
        let values = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: directory.appendingPathComponent("references.json")))
        return try #require(values.object?[fixture])
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
        var actual = normalize(report, root: root), expected = try record(fixture)["inspection"]
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
        _ = try CanonicalTranscript(AudioFixture.read(job, "transcript.json"))
        let expected = try #require(record(fixture)["exports_sha256"].object)
        #expect(expected.count == 5)
        for (name, digest) in expected {
            let data = try Data(contentsOf: job.appendingPathComponent(name))
            #expect(TextJob.hash(data) == digest.string, "Export reference mismatch: \(fixture)/\(name)")
        }
    }
}

@Suite struct GoldenReferenceTests {
    @Test func referenceCatalogKeepsEveryCapturedCase() throws {
        let values = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: GoldenReference.directory.appendingPathComponent("references.json")))
        let inspections = [8,16,24,32].map { "inspection-pcm-\($0)" }
        #expect(Set(try #require(values.object).keys) == Set(GoldenReference.jobs + inspections))
    }
    @Test func frozenMissingPartDocumentStillRendersCapturedBytes() throws {
        // Runtime filesystem error wording varies. Keep this independent input;
        // all other cases compare freshly produced jobs to the captured hashes.
        let reference = try GoldenReference.record("audio-missing")
        let document = try CanonicalTranscript(reference["transcript"])
        let rendered = TranscriptRenderer.render(document)
        #expect(rendered.count == 5)
        for (name, content) in rendered {
            #expect(TextJob.hash(Data(content.utf8)) == reference["exports_sha256"][name].string, "Frozen renderer mismatch: \(name)")
        }
    }
}
