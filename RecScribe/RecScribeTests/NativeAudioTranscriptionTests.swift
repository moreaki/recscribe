import AVFoundation
import Foundation
import RecScribeCore
import Testing
@testable import RecScribe

@MainActor struct NativeAudioTranscriptionTests {
    @Test func shippingBundleDoesNotContainTheReferencePythonArchive() {
        #expect(Bundle.main.url(forResource: "pipeline", withExtension: "tar.gz") == nil)
    }
    private func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("native-final-\(UUID())")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        return url
    }
    private func wav(_ url: URL, width: Int = 2, channels: Int = 2, rate: Int = 44_100) throws {
        let frames = 4410, bytes = frames * channels * width
        var data = Data()
        func text(_ value: String) { data.append(contentsOf: value.utf8) }
        func integer(_ value: Int64, _ count: Int) { for byte in 0..<count { data.append(UInt8(truncatingIfNeeded: value >> (byte * 8))) } }
        text("RIFF"); integer(Int64(bytes + 36),4); text("WAVEfmt "); integer(16,4); integer(1,2)
        integer(Int64(channels),2); integer(Int64(rate),4); integer(Int64(rate * channels * width),4)
        integer(Int64(channels * width),2); integer(Int64(width * 8),2); text("data"); integer(Int64(bytes),4)
        let amplitude = (Int64(1) << (width * 8 - 1)) / 4
        for frame in 0..<frames { for channel in 0..<channels {
            let value = channel == 0 ? (frame % 40 < 20 ? amplitude : -amplitude) : 0
            integer(value + (width == 1 ? 128 : 0),width)
        } }
        try data.write(to: url)
    }
    @Test(arguments: [1,2,3,4])
    func nativePreparationPreservesChannelsAndFlushesAllPCMWidths(width: Int) throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source.wav")
        try wav(source, width: width)
        let before = try WAVAudio.hash(source)
        for channel in 0..<2 {
            let output = root.appendingPathComponent("channel-\(channel).wav")
            _ = try NativeAudioPreparer().prepare(source, channel: channel, output: output, check: {})
            let inspection = try WAVAudio.inspect(output)
            #expect(inspection.layout.channels == 1 && inspection.layout.rate == 16_000 && inspection.layout.width == 2)
            #expect(abs(inspection.layout.frames - 1600) <= 1)
            #expect(inspection.report["channel_metrics"].array?[0]["digital_silence"] == .bool(channel == 1))
        }
        #expect(try WAVAudio.hash(source) == before)
    }

    @Test func finalParserSkipsOnlyKnownEmptyMarkersAndRetainsRawWordsOnTimingFailure() throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let raw = root.appendingPathComponent("raw.json")
        let bytes = Data(#"{"transcription":[{"offsets":{"from":0,"to":100},"text":"speech"},{"offsets":{"from":100,"to":100},"text":"[BLANK_AUDIO]"}]}"#.utf8)
        try bytes.write(to: raw)
        #expect(try NativeWhisperEngine.parse(raw).map { $0["source_text"] } == ["speech"])
        #expect(try Data(contentsOf: raw) == bytes)
        let untimed = Data(#"{"transcription":[{"offsets":{"from":100,"to":100},"text":"retain these words"}]}"#.utf8)
        try untimed.write(to: raw)
        #expect(throws: (any Error).self) { try NativeWhisperEngine.parse(raw) }
        #expect(try Data(contentsOf: raw) == untimed)
    }

    @Test func completedAudioRunsThroughLibraryWithoutPythonOrFFmpeg() async throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source.wav"), binary = root.appendingPathComponent("whisper-cli"), model = root.appendingPathComponent("model.bin")
        try wav(source, rate: 16_000)
        let script = #"""
        #!/bin/sh
        if [ "$1" = "--version" ]; then echo 'whisper.cpp version: synthetic'; exit 0; fi
        while [ "$#" -gt 0 ]; do
          if [ "$1" = "-of" ]; then shift; prefix="$1"; fi
          shift
        done
        printf '%s\n' '{"result":{"language":"en"},"transcription":[{"offsets":{"from":0,"to":100},"text":"synthetic speech"}]}' > "$prefix.json"
        """#
        try Data(script.utf8).write(to: binary)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: binary.path)
        try Data("synthetic local weights".utf8).write(to: model)
        var settings = AppSettings.Values()
        settings.whisperPath = binary.path; settings.modelPath = model.path
        settings.pythonPath = "/missing/python"; settings.ffmpegPath = "/missing/ffmpeg"
        settings.mode = .verbatim; settings.profile = .fast
        settings.liveThreads = 3
        let configured = settings
        let jobs = root.appendingPathComponent("jobs")
        let library = SessionLibrary(settings: { configured }, jobsDirectory: jobs)
        library.transcribe(source)
        await waitUntil("native final audio completion", timeout: .seconds(15)) { library.progress == 1 || library.errorMessage != nil }
        #expect(library.errorMessage == nil)
        let job = try #require(library.latestJob)
        #expect(job.deletingLastPathComponent().path == jobs.path)
        let document = try CanonicalTranscript(JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: job.appendingPathComponent("transcript.json"))))
        #expect(document.value["segments"].array?.count == 1)
        #expect(document.value["processing"]["pipeline_version"] == .string(AudioJob.Policy.version))
        let commandValues = document.value["processing"]["engine_passes"].array?.first?["command"].array?.compactMap(\.string)
        let command = try #require(commandValues)
        let threadIndex = try #require(command.firstIndex(of: "-t"))
        #expect(command[threadIndex + 1] == "3")
        #expect(!FileManager.default.fileExists(atPath: job.appendingPathComponent("working-channel-0.wav").path))
        await library.shutdown()
    }

}
