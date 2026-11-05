import Foundation
import Testing
@testable import RecScribeCore

@Suite struct WhisperBenchmarkMetricsTests {
    @Test func timersKeepIndependentUpstreamObservationsWithoutInventedLatency() {
        let result = WhisperBenchmarkMetrics.timings(log: """
        whisper_print_timings:     load time = 100.25 ms
        whisper_print_timings:   encode time = 350.00 ms / 2 runs (175.00 ms per run)
        whisper_print_timings:   decode time = 25.00 ms / 5 runs (5.00 ms per run)
        whisper_print_timings:    total time = 500.00 ms
        private text mentioning load time = 0 ms
        whisper_print_timings:     load time = nan ms
        whisper_print_timings:     load time = 101.00 ms
        """)
        #expect(result["observations"]["load"].array?.count == 2)
        #expect(result["observations"]["load"].array?.first?["seconds"].double == 0.10025)
        #expect(result["observations"]["encode"].array?.first?["runs"] == 2)
        #expect(result["observations"]["total"].array?.first?["seconds"].double == 0.5)
        #expect(result["first_result_latency_seconds"] == .null)
        #expect(WhisperBenchmarkMetrics.timings(log: "unknown format")["observations"] == [:])
    }

    @Test func actualArtifactSizesAreIndependentFromPackagingClaims() throws {
        let root = try AudioFixture.folder(); defer { try? FileManager.default.removeItem(at: root) }
        let model = root.appendingPathComponent("model.bin"), download = root.appendingPathComponent("model.gz")
        try Data(repeating: 1, count: 1_024).write(to: model)
        try Data(repeating: 2, count: 100).write(to: download)
        let result = try WhisperBenchmarkMetrics.artifact(model, download: download)
        #expect(result["model_file_bytes"] == 1_024 && result["download_artifact_bytes"] == 100)
        #expect(result["incremental_bundle_bytes"] == .null && result["parameter_count"] == .null)
        #expect(try WhisperBenchmarkMetrics.artifact(model)["download_artifact_bytes"] == .null)
        #expect(throws: CoreFailure.self) { try WhisperBenchmarkMetrics.artifact(root) }
        #expect(throws: CancellationError.self) { try WhisperBenchmarkMetrics.artifact(model, check: { throw CancellationError() }) }
    }

    @Test func originalControlLogsRemainReadableAndEscapingPathsFail() throws {
        let root = try AudioFixture.folder(); defer { try? FileManager.default.removeItem(at: root) }
        let output = root.appendingPathComponent("asr-channel-0")
        try Data("whisper_print_timings: load time = 200.00 ms\n".utf8).write(to: output.appendingPathExtension("log"))
        let passes: JSONValue = [["command": ["/whisper", "-of", .string(output.path)], "duration_seconds": 1]]
        let result = try WhisperBenchmarkMetrics.retainedPasses(passes, job: root)
        #expect(result.array?.first?["runtime_timings"]["observations"]["load"].array?.first?["seconds"].double == 0.2)
        #expect(throws: CoreFailure.self) {
            try WhisperBenchmarkMetrics.retainedPasses([["command": ["/whisper", "-of", "/outside"]]], job: root)
        }
    }
}
