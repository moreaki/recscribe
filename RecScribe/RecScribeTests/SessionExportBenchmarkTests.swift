import AVFoundation
import Darwin
import Foundation
import Testing
@testable import RecScribe

/// Run alone in Release. Compare identical synthetic data, with warm filesystem
/// caches and alternating order. RSS is process-wide, not the export buffer size.
@MainActor
struct SessionExportBenchmarkTests {
    @Test func compareCopyStrategies() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("export-benchmark-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let writer = SessionWAVWriter(options: .init())
        try writer.createFile(at: directory.appendingPathComponent("Synthetic.wav"), sampleRate: 48000, channels: 2)
        let buffer = SampleBufferFixtures.makePCMBuffer(channels: 2, frames: 32768, interleaved: false) { channel, frame in
            Float((frame + channel) % 100) / 100
        }
        for _ in 0..<64 { try writer.writeBuffer(buffer) }
        try writer.finalize()
        let manifest = try #require(writer.manifestURL)
        let session = try await Task.detached(priority: .utility) {
            try SessionProcessing.process(manifest, ffmpeg: URL(fileURLWithPath: "/unused"), cancel: WorkCancellation())
        }.value
        for iteration in 0..<3 {
            let strategies = iteration.isMultiple(of: 2) ? ["legacy", "streaming"] : ["streaming", "legacy"]
            for strategy in strategies {
                let destination = try await Task.detached(priority: .utility) {
                    let start = ContinuousClock.now
                    let result = strategy == "legacy"
                        ? try Self.legacyExport(manifest, to: directory)
                        : try SessionExporter().export(manifest, to: directory, checkCancellation: {})
                    let elapsed = start.duration(to: .now)
                    let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
                    var usage = rusage()
                    getrusage(RUSAGE_SELF, &usage)
                    print("EXPORT_BENCH strategy=\(strategy) iteration=\(iteration) source_bytes=\(session.parts.reduce(0) { $0 + $1.sizeBytes }) wall_s=\(seconds) process_lifetime_peak_rss_bytes=\(usage.ru_maxrss)")
                    return result
                }.value
                #expect(FileManager.default.fileExists(atPath: destination.appendingPathComponent(manifest.lastPathComponent).path))
            }
        }
    }

    /// Test-only baseline of the file work in SessionLibrary.export at 85f1d0a.
    private nonisolated static func legacyExport(_ manifest: URL, to directory: URL) throws -> URL {
        let destination = directory.appendingPathComponent("legacy-\(UUID())")
        let lease = try SessionLease(manifest)
        defer { withExtendedLifetime(lease) {} }
        let session = try RecordingSession.read(manifest)
        guard session.parts.allSatisfy({ $0.status == "verified" }) else { throw SessionError.invalid("Unverified fixture") }
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
        for name in session.parts.map(\.path) + session.artifacts.map(\.path) {
            let source = try RecordingSession.safeURL(name, beside: manifest)
            let copy = destination.appendingPathComponent(name)
            let expected = session.parts.first(where: { $0.path == name })?.sha256 ?? session.artifacts.first(where: { $0.path == name })?.sha256
            guard try RecordingSession.hash(source) == expected else { throw SessionError.invalid("Source changed") }
            try FileManager.default.copyItem(at: source, to: copy)
            guard try RecordingSession.hash(copy) == expected else { throw SessionError.invalid("Copy changed") }
        }
        try session.save(destination.appendingPathComponent(manifest.lastPathComponent))
        return destination
    }
}
