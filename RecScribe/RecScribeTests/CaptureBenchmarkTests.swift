import AVFoundation
import Darwin
import Foundation
import Testing
@testable import RecScribe

@Suite(.serialized)
struct CaptureBenchmarkTests {
    @Test func combinedCaptureThroughput() throws {
        for iteration in 0..<3 {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let start = ContinuousClock.now
            let mix = SessionWAVWriter(options: .init(maximumPartBytes: 1_048_576))
            try mix.createFile(at: directory.appendingPathComponent("benchmark.wav"), sampleRate: 48_000, channels: 2)
            let worker = try SynchronizedCaptureWriter(mix: mix, descriptors: [
                .init(role: .playback, name: "Synthetic playback"), .init(role: .microphone, name: "Synthetic input")
            ], epoch: 100, options: .init(maximumPartBytes: 1_048_576))
            for index in 0..<100 {
                for role in CaptureTrack.legacyPair {
                    let buffer = SampleBufferFixtures.makePCMBuffer(channels: 2, frames: 4_800, interleaved: false) { channel, frame in
                        Float(sin(Double(frame) * 2 * .pi * Double(channel == 0 ? 440 : 660) / 48_000)) * 0.2
                    }
                    try worker.accept(.init(track: role, presentationTime: 100 + Double(index) / 10, buffer: buffer))
                }
            }
            try worker.finish()
            let duration = start.duration(to: .now)
            let seconds = Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
            var usage = rusage(); getrusage(RUSAGE_SELF, &usage)
            print("MULTISOURCE_BENCH iteration=\(iteration) audio_s=10 sources=2 wall_s=\(seconds) process_lifetime_peak_rss_bytes=\(usage.ru_maxrss)")
            let session = try RecordingSession.read(#require(mix.manifestURL))
            #expect(session.totalFrames == 480_000)
            #expect(session.issues.isEmpty)
        }
    }
}
