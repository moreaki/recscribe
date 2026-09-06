import AVFoundation
import Darwin
import Foundation
import Testing
@testable import RecScribe

/// Run alone in Release, unchanged before/after. Synthetic 10-second bursts;
/// wall time includes allocation, submission and finalization, not live capture.
@MainActor
@Suite(.serialized)
struct RecorderBenchmarkTests {
    @Test func sessionBaseline() async throws {
        for probe in ["importantUsage", "statfs"] {
        for iteration in 0..<3 {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("session-benchmark-\(UUID())")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
            defer { try? FileManager.default.removeItem(at: directory) }
            let recorder = AudioRecorder { _ in
                SessionWAVWriter(options: .init(maximumPartBytes: 1_048_576), freeBytes: { url in
                    if probe == "importantUsage" {
                        return (try? url.deletingLastPathComponent().resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?.volumeAvailableCapacityForImportantUsage
                    }
                    return DiskSpace.availableBytes(at: url)
                })
            }
            let start = ContinuousClock.now
            try recorder.startRecording(to: directory.appendingPathComponent("benchmark.wav"), format: .wav)
            for _ in 0..<100 {
                recorder.processAudioSample(SampleBufferFixtures.makePCMBuffer(channels: 2, frames: 4800, sampleRate: 48000, interleaved: false) { frame, channel in
                    Float(sin(Double(frame) * 2 * .pi * Double(440 + channel * 220) / 48000)) * 0.2
                })
            }
            try await recorder.stopRecording()
            let duration = start.duration(to: .now)
            let seconds = Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
            var usage = rusage(); getrusage(RUSAGE_SELF, &usage)
            print("RECORDER_BENCH format=wav_session_1MiB_\(probe) iteration=\(iteration) audio_s=10 wall_s=\(seconds) process_lifetime_peak_rss_bytes=\(usage.ru_maxrss)")
            let session = try RecordingSession.read(recorder.sessionManifestURL!)
            #expect(session.totalFrames == 480000)
            #expect(session.parts.count == 2)
            #expect(recorder.lastMetrics.written == 100)
            #expect(recorder.lastMetrics.rejected == 0)
        }
        }
    }
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
