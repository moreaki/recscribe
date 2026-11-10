import Darwin
import Foundation
import Testing
@testable import RecScribeCore
@testable import RecScribeTextCLI

@Suite struct CorpusBenchmarkTests {
    private var cli: URL {
        // SwiftPM may use an Xcode .xctest resource bundle or a sibling .bundle.
        var directory = Bundle.module.bundleURL
        while directory.path != "/" {
            let candidate = directory.appendingPathComponent("recscribe-text")
            if FileManager.default.isExecutableFile(atPath: candidate.path) { return candidate }
            directory.deleteLastPathComponent()
        }
        return directory.appendingPathComponent("missing-recscribe-text")
    }

    @Test func editCountsUnicodeAndEmptyReferences() {
        #expect(TranscriptAccuracy.distance(Array("kitten"), Array("sitting")) == 3)
        let score = TranscriptAccuracy.score(reference: "Das ist ein Test", hypothesis: "Das war ein Test extra")
        #expect(score["word_errors"] == 2 && score["wer"] == .number(0.5))
        #expect(TranscriptAccuracy.score(reference: "Grüezi! STRASSE", hypothesis: "GRU\u{0308}EZI Straße")["wer"].double == 0)
        let noise = TranscriptAccuracy.score(reference: "", hypothesis: "Invented speech")
        #expect(noise["wer"] == .null && noise["cer"] == .null && noise["false_speech_words"] == 2)
        #expect(TranscriptAccuracy.score(reference: "one", hypothesis: "two three four")["wer"].double == 3)
    }

    @Test func corpusReadinessHasNoInventedScoresAndRejectsUnsafeOrDuplicateIDs() throws {
        let root = try AudioFixture.folder(); defer { try? FileManager.default.removeItem(at: root) }
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let manifest = repo.appendingPathComponent("benchmarks/manifests/corpus.template.json")
        let report = try CorpusBenchmark.run(manifest: manifest, output: root.appendingPathComponent("readiness"), cli: cli,
            whisper: nil, model: nil, threads: 2, dryRun: true)
        let results = try #require(report["results"].array)
        #expect(results.count == 50)
        #expect(results.allSatisfy { $0["status"] == "pending_corpus" && $0.object?["wer"] == nil })
        for ids in [["../unsafe"], ["same", "same"]] {
            let bad = root.appendingPathComponent("bad.json")
            try JSONValue.object(["schema_version": "1.0", "cases": .array(ids.map { ["id": .string($0), "category": "test"] })]).encoded().write(to: bad)
            #expect(throws: CoreFailure.self) {
                try CorpusBenchmark.run(manifest: bad, output: root.appendingPathComponent(UUID().uuidString), cli: cli,
                    whisper: nil, model: nil, threads: 2, dryRun: true)
            }
        }
    }

    @Test func measuredNativeJobRetainsEvidenceAndRejectsChecksumMismatchAndOverwrite() throws {
        let root = try AudioFixture.folder(); defer { try? FileManager.default.removeItem(at: root) }
        let audio = root.appendingPathComponent("silence.wav")
        try AudioFixture.wav(audio, frames: 1600) { _, _ in 0 }
        try Data().write(to: root.appendingPathComponent("reference.txt"))
        let model = root.appendingPathComponent("model.bin"), binary = root.appendingPathComponent("whisper-cli")
        try Data("synthetic".utf8).write(to: model)
        try Data("#!/bin/sh\necho 'whisper.cpp synthetic'\n".utf8).write(to: binary)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: binary.path)
        let manifest = root.appendingPathComponent("manifest.json")
        var value: JSONValue = ["schema_version": "1.0", "cases": [["id": "silence", "category": "noise", "language": "en",
            "audio": "silence.wav", "reference": "reference.txt", "license": "synthetic test", "sha256": .string(try WAVAudio.hash(audio))]]]
        try value.encoded().write(to: manifest)
        let output = root.appendingPathComponent("measured")
        let report: JSONValue
        do {
            report = try CorpusBenchmark.run(manifest: manifest, output: output, cli: cli, whisper: binary, model: model, threads: 3, dryRun: false)
        } catch {
            print("Synthetic benchmark failure \(cli.path): \(try String(contentsOf: output.appendingPathComponent("results.json"), encoding: .utf8))")
            print((try? String(contentsOf: output.appendingPathComponent("silence.log"), encoding: .utf8)) ?? "No child log")
            throw error
        }
        let row = try #require(report["results"].array?.first)
        #expect(row["false_speech_words"] == 0 && row["engine_passes"] == [])
        #expect(try #require(row["wall_seconds"].double) > 0)
        #expect(try #require(row["peak_rss_bytes"].integer) > 0)
        #expect(row["threads"] == 3 && row["reference_sha256"].string?.count == 64)
        #expect(!FileManager.default.fileExists(atPath: output.appendingPathComponent("silence/cancel.request").path))
        #expect(throws: (any Error).self) {
            try CorpusBenchmark.run(manifest: manifest, output: output, cli: cli, whisper: binary, model: model, threads: 3, dryRun: false)
        }
        var cases = value["cases"].array!; cases[0]["sha256"] = "wrong"; value["cases"] = .array(cases)
        try value.encoded().write(to: manifest)
        let failed = root.appendingPathComponent("failed")
        #expect(throws: CoreFailure.self) {
            try CorpusBenchmark.run(manifest: manifest, output: failed, cli: cli, whisper: nil, model: nil, threads: 2, dryRun: true)
        }
        #expect(try AudioFixture.read(failed, "results.json")["results"].array?.first?["status"] == "failed")
    }

    @Test func benchmarkCLIRejectsCloudAndTextOptions() throws {
        for flags in [["--allow-cloud-text"], ["--provider", "openai"], ["--mode", "normalize"], ["--profile", "verified"]] {
            #expect(throws: CoreFailure.self) { try RecScribeTextCLI.Arguments(["benchmark", "corpus.json"] + flags) }
        }
        #expect(try RecScribeTextCLI.Arguments(["benchmark", "corpus.json", "--dry-run"]).dryRun)
    }

    @Test func cancellationMarksActiveChildAndPersistsPartialResults() async throws {
        let root = try AudioFixture.folder(); defer { try? FileManager.default.removeItem(at: root) }
        let audio = root.appendingPathComponent("source.wav")
        try AudioFixture.wav(audio)
        let truth = root.appendingPathComponent("reference.txt")
        try Data("speech".utf8).write(to: truth)
        let manifest = root.appendingPathComponent("manifest.json")
        try JSONValue.object(["schema_version": "1.0", "cases": [["id": "active", "category": "test",
            "audio": .string(audio.path), "reference": .string(truth.path), "license": "synthetic",
            "sha256": .string(try WAVAudio.hash(audio))]]]).encoded().write(to: manifest)
        let child = root.appendingPathComponent("synthetic-cli")
        // Behaves like a native job observing cancel.request, with no engine/model.
        let script = #"""
        #!/bin/sh
        while [ "$#" -gt 0 ]; do
          if [ "$1" = "--output" ]; then shift; output="$1"; fi
          shift
        done
        mkdir "$output" || exit 1
        # Publish only a complete PID; existence alone is the reader's signal.
        echo "$$" > "$output/pid.partial"
        mv "$output/pid.partial" "$output/pid"
        while [ ! -f "$output/cancel.request" ]; do sleep 0.02; done
        touch "$output/stopped"
        """# + "\n"
        try Data(script.utf8).write(to: child)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: child.path)
        let output = root.appendingPathComponent("cancelled")
        let task = Task.detached {
            try CorpusBenchmark.run(manifest: manifest, output: output, cli: child, whisper: child, model: child, threads: 2, dryRun: false)
        }
        let pidFile = output.appendingPathComponent("active/pid")
        try await expectEventually { FileManager.default.fileExists(atPath: pidFile.path) }
        let pid = try #require(Int32(String(contentsOf: pidFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)))
        try Data().write(to: output.appendingPathComponent("cancel.request"))
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(FileManager.default.fileExists(atPath: output.appendingPathComponent("active/cancel.request").path))
        try await expectEventually { kill(pid, 0) != 0 }
        #expect(try AudioFixture.read(output, "results.json")["results"].array?.first?["status"] == "cancelled")
    }
}
