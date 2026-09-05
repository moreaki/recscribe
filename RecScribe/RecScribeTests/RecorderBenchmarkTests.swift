import AVFoundation
import Darwin
import Foundation
import Testing
@testable import RecScribe

/// Run alone in Release, unchanged before/after. Synthetic 10-second bursts;
/// wall time includes allocation, submission and finalization, not live capture.
@MainActor
struct RecorderBenchmarkTests {
    @Test func encodingBaseline() async throws {
        for format in [AudioFormat.wav, .m4a, .flac] {
            for iteration in 0..<3 {
                let url = FileManager.default.temporaryDirectory
                    .appendingPathComponent("recorder-benchmark-\(UUID()).\(format.fileExtension)")
                defer { try? FileManager.default.removeItem(at: url) }
                let recorder = AudioRecorder()
                let start = ContinuousClock.now
                try recorder.startRecording(to: url, format: format)
                for _ in 0..<100 {
                    let buffer = SampleBufferFixtures.makePCMBuffer(
                        channels: 2, frames: 4_800, sampleRate: 48_000, interleaved: false
                    ) { frame, channel in
                        Float(sin(Double(frame) * 2 * .pi * Double(440 + channel * 220) / 48_000)) * 0.2
                    }
                    recorder.processAudioSample(buffer)
                }
                try await recorder.stopRecording()
                let duration = start.duration(to: .now)
                let seconds = Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
                var usage = rusage()
                getrusage(RUSAGE_SELF, &usage)
                print("RECORDER_BENCH format=\(format.fileExtension) iteration=\(iteration) audio_s=10 wall_s=\(seconds) process_lifetime_peak_rss_bytes=\(usage.ru_maxrss)")
                let file = try AVAudioFile(forReading: url)
                #expect(abs(Double(file.length) / file.fileFormat.sampleRate - 10) < 0.15)
            }
        }
    }
}
