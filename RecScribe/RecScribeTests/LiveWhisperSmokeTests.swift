import AVFoundation
import Testing
@testable import RecScribe

/// Opt-in by availability: never downloads a voice, tool or model. Test speech
/// is generated locally and discarded, along with its derived artifacts.
@MainActor
struct LiveWhisperSmokeTests {
    private nonisolated static var model: URL { AppSettings.supportDirectory.appendingPathComponent("Models/ggml-base.bin") }

    @Test(.enabled(if: LocalToolDiscovery.executable("whisper-cli") != nil && FileManager.default.isReadableFile(atPath: model.path)))
    func localSyntheticSpeechUsesNativePreparationAndWhisper() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("live-asr-smoke-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let speech = directory.appendingPathComponent("speech.aiff")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        process.arguments = ["-v", "Samantha", "-r", "145", "-o", speech.path,
            "This is a local recording test. The original audio stays on this computer. Transcription is optional. We can switch it on while recording. The background worker prepares small audio chunks and writes a readable draft. Please review the words before sharing them."]
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
        let input = try AVAudioFile(forReading: speech)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: input.processingFormat, frameCapacity: AVAudioFrameCount(input.length)))
        try input.read(into: buffer)
        let writer = SessionWAVWriter()
        try writer.createFile(at: directory.appendingPathComponent("synthetic.wav"), sampleRate: input.processingFormat.sampleRate,
                              channels: Int(input.processingFormat.channelCount))
        try writer.writeBuffer(buffer)
        let manifest = try #require(writer.manifestURL)
        var settings = AppSettings.Values()
        settings.whisperPath = try #require(LocalToolDiscovery.executable("whisper-cli"))
        settings.modelPath = Self.model.path
        settings.liveChunkSeconds = 10
        let configured = settings
        let output = directory.appendingPathComponent("draft")
        let first = try await Task.detached(priority: .utility) {
            try LiveWhisperTranscriber.step(manifest: manifest, directory: output, cursor: 0, finished: false,
                                            settings: configured, cancel: WorkCancellation())
        }.value
        let live = try #require(first)
        #expect(!live.segments.isEmpty)
        #expect(live.segments.contains { $0.text.lowercased().contains("local") })
        #expect(live.segments.allSatisfy { $0.language == "en" })
        try writer.finalize()
        let last = try await Task.detached(priority: .utility) {
            try LiveWhisperTranscriber.step(manifest: manifest, directory: output, cursor: live.endFrame, finished: true,
                                            settings: configured, cancel: WorkCancellation())
        }.value
        #expect(try #require(last).endFrame > live.endFrame)
        #expect(FileManager.default.fileExists(atPath: live.directory.appendingPathComponent("channel-0.raw.json").path))
        #expect(!FileManager.default.fileExists(atPath: live.directory.appendingPathComponent("working.wav").path))
        print("LIVE_ASR_SMOKE audio_s=10 first_chunk_wall_s=\(live.durationSeconds) subsequent_chunk_wall_s=\(last?.durationSeconds ?? 0) model=base engine=whisper.cpp native_preparation=true")
    }
}
