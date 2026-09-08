import Darwin
import Foundation
import Testing
@testable import RecScribe

/// Synthetic, same-machine comparisons. Run alone in Release; RSS is the process
/// lifetime peak, not a measurement of this function's private allocation.
@MainActor
struct CleanupBenchmarkTests {
    @Test func recoveryMemoryAndLatency() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let payload: UInt64 = 16 << 20
        let header = try PCM16WAV(sampleRate: 48_000, channels: 2)
        let corrected = try PCM16WAV(sampleRate: 48_000, channels: 2, payloadBytes: payload)
        for iteration in 0..<3 {
            for strategy in iteration.isMultiple(of: 2) ? ["whole-file", "streaming"] : ["streaming", "whole-file"] {
                let file = root.appendingPathComponent("\(iteration)-\(strategy).wav")
                try header.header.write(to: file)
                let output = try FileHandle(forWritingTo: file)
                try output.truncate(atOffset: corrected.fileBytes)
                try output.close()
                var maximumBlock = 0
                let started = ContinuousClock.now
                if strategy == "whole-file" {
                    // Test-only pre-refactor strategy, never used by the app.
                    var bytes = try Data(contentsOf: file)
                    maximumBlock = bytes.count
                    bytes.replaceSubrange(0..<PCM16WAV.headerBytes, with: corrected.header)
                    try bytes.write(to: file, options: .atomic)
                } else {
                    try PCM16WAV.repair(file, write: { handle, bytes in
                        maximumBlock = max(maximumBlock, bytes.count)
                        try handle.write(contentsOf: bytes)
                    })
                    #expect(maximumBlock <= PCM16WAV.copyBlockBytes)
                }
                var usage = rusage()
                getrusage(RUSAGE_SELF, &usage)
                print("CLEANUP_BENCH recovery=\(strategy) iteration=\(iteration) bytes=\(corrected.fileBytes) wall=\(started.duration(to: .now)) maximum_buffer_bytes=\(maximumBlock) process_lifetime_peak_rss_bytes=\(usage.ru_maxrss)")
                #expect(try PCM16WAV.read(file) == corrected)
            }
        }
    }

    @Test func manifestSchedulingComparison() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let count = 300
        for index in 0..<count {
            try RecordingSession(sampleRate: 48_000, channels: 2, channelMap: ["L", "R"], options: .init())
                .save(root.appendingPathComponent("\(index).recscribe.json"))
        }
        for iteration in 0..<3 {
            let start = ContinuousClock.now
            let files = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            let old = try files.map { try RecordingSession.read($0) }
            print("CLEANUP_BENCH manifests=main_actor iteration=\(iteration) count=\(old.count) wall=\(start.duration(to: .now))")
            let repository = ManifestRepository()
            let background = ContinuousClock.now
            let snapshot = try await repository.sessions(in: root)
            print("CLEANUP_BENCH manifests=background_actor iteration=\(iteration) count=\(snapshot.entries.count) wall=\(background.duration(to: .now))")
            #expect(snapshot.entries.count == old.count)
        }
    }
}
