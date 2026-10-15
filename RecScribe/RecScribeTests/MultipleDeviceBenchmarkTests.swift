import AVFoundation
import Darwin
import Foundation
import Testing
@testable import RecScribe

@Suite(.serialized)
struct MultipleDeviceBenchmarkTests {
    @Test func selectedDeviceSetThroughput() throws {
        for count in [2, 4, 8] {
            for iteration in 0..<3 {
                let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                defer { try? FileManager.default.removeItem(at: directory) }
                let descriptors: [RecordingSession.SourceTrack] = [.init(role: .playback, name: "Synthetic playback")] + (0..<count).map {
                    .init(role: .input("benchmark-\($0)"), name: "Synthetic input \($0)", deviceUID: "benchmark-\($0)", channelRoutes: [.init(channel: 0, placement: .center)])
                }
                let started = ContinuousClock.now
                let mix = SessionWAVWriter(options: .init(maximumPartBytes: 1_048_576))
                try mix.createFile(at: directory.appendingPathComponent("benchmark.wav"), sampleRate: 48_000, channels: 2)
                let writer = try SynchronizedCaptureWriter(mix: mix, descriptors: descriptors, epoch: 100, options: .init(maximumPartBytes: 1_048_576))
                for index in 0..<100 {
                    for source in descriptors {
                        let buffer = SampleBufferFixtures.makePCMBuffer(channels: 2, frames: 4800, interleaved: false) { _, _ in 0.2 }
                        try writer.accept(.init(track: source.role, presentationTime: 100 + Double(index) / 10, buffer: buffer))
                    }
                }
                try writer.finish()
                let duration = started.duration(to: .now)
                let seconds = Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
                var usage = rusage(); getrusage(RUSAGE_SELF, &usage)
                print("DEVICES_BENCH inputs=\(count) sources=\(descriptors.count) iteration=\(iteration) audio_s=10 wall_s=\(seconds) process_lifetime_peak_rss_bytes=\(usage.ru_maxrss)")
                let session = try RecordingSession.read(#require(mix.manifestURL))
                #expect(session.totalFrames == 480_000 && session.issues.isEmpty)
                #expect(session.sourceTracks?.count == count + 1)
            }
        }
    }
}
