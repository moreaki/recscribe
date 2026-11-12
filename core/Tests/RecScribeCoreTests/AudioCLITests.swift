import Foundation
import Testing
@testable import RecScribeCore
@testable import RecScribeTextCLI

@Suite struct AudioCLITests {
    private func tools(_ root: URL, slow: Bool = false) throws -> (URL, URL) {
        let binary = root.appendingPathComponent("whisper-cli"), model = root.appendingPathComponent("model.bin")
        let script = #"""
        #!/bin/sh
        if [ "$1" = "--version" ]; then echo 'whisper.cpp version: synthetic'; exit 0; fi
        while [ "$#" -gt 0 ]; do
          if [ "$1" = "-of" ]; then shift; prefix="$1"; fi
          shift
        done
        printf '%s\n' '{"result":{"language":"en"},"transcription":[{"offsets":{"from":0,"to":100},"text":"CLI speech"}]}' > "$prefix.json"
        """# + (slow ? "\nexec sleep 20\n" : "\n")
        try Data(script.utf8).write(to: binary)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: binary.path)
        try Data("synthetic model a".utf8).write(to: model)
        return (binary,model)
    }
    private func arguments(_ source: URL, _ output: URL, _ binary: URL, _ model: URL) -> [String] {
        ["transcribe",source.path,"--output",output.path,"--whisper-cli",binary.path,"--model",model.path,
         "--threads","3","--source-language","en","--local-only"]
    }

    @Test func nativeCLITranscribesWAVAndVerifiedSessionWithConfiguredThreadsAndNoWorkingAudioLeft() async throws {
        let root = try AudioFixture.folder(); defer { try? FileManager.default.removeItem(at: root) }
        let (binary,model) = try tools(root), source = root.appendingPathComponent("one.wav")
        try AudioFixture.wav(source)
        let output = root.appendingPathComponent("wav-job")
        try await RecScribeTextCLI.run(.init(arguments(source,output,binary,model)))
        let source2 = root.appendingPathComponent("two.wav"); try AudioFixture.wav(source2)
        let session = try AudioFixture.session(root, parts: [("one.wav",16000),("two.wav",16000)])
        let second = root.appendingPathComponent("second.bin"); try Data("synthetic model b".utf8).write(to: second)
        let sessionOutput = root.appendingPathComponent("session-job")
        let args = arguments(session,sessionOutput,binary,model) + ["--profile","verified","--verify-model",second.path]
        try await RecScribeTextCLI.run(.init(args))
        for job in [output,sessionOutput] {
            let value = try AudioFixture.read(job,"transcript.json")
            _ = try CanonicalTranscript(value)
            for pass in value["processing"]["engine_passes"].array ?? [] {
                let values = pass["command"].array?.compactMap(\.string)
                let command = try #require(values)
                let index = try #require(command.firstIndex(of: "-t"))
                #expect(command[index + 1] == "3")
            }
            let all = FileManager.default.enumerator(at: job, includingPropertiesForKeys: nil)!
            #expect(!all.compactMap { $0 as? URL }.contains { $0.pathExtension == "wav" })
            #expect(FileManager.default.fileExists(atPath: job.appendingPathComponent("transcript.raw.json").path))
        }
        #expect(try AudioFixture.read(sessionOutput,"transcript.json")["segments"].array?.map { $0["start_ms"] } == [0,1000])
    }

    @Test func nativeCLICancellationStopsOwnedASRAndCleansDisposableAudio() async throws {
        let root = try AudioFixture.folder(); defer { try? FileManager.default.removeItem(at: root) }
        let (binary,model) = try tools(root, slow: true), source = root.appendingPathComponent("source.wav")
        try AudioFixture.wav(source)
        let output = root.appendingPathComponent("job")
        let args = try RecScribeTextCLI.Arguments(arguments(source,output,binary,model))
        let task = Task { try await RecScribeTextCLI.run(args) }
        // Utility-worker setup can exceed five seconds on a contended CI host.
        // Match the bounded startup window in CLISignalCancellationTests.
        try await expectEventually(timeout: .seconds(15)) { FileManager.default.fileExists(atPath: output.appendingPathComponent("asr-channel-0.json").path) }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(try AudioFixture.read(output,"manifest.json")["state"] == "cancelled")
        #expect(FileManager.default.fileExists(atPath: output.appendingPathComponent("asr-channel-0.log").path))
        #expect(!FileManager.default.fileExists(atPath: output.appendingPathComponent("working-channel-0.wav").path))
    }

    @Test func nativeCLIRejectsCloudAudioFlagsAndInvalidVerificationOrThreads() throws {
        for suffix in [["--allow-cloud-text"],["--threads","0"],["--threads","5"],["--profile","verified"],["--verify-model","model.bin"],["--summarize"]] {
            #expect(throws: CoreFailure.self) { try RecScribeTextCLI.Arguments(["transcribe","source.wav"] + suffix) }
        }
    }

    @Test func hostEvidenceCaptureAcceptsOnlyANewAbsoluteDestinationWithoutRecognitionFlags() throws {
        let parsed = try RecScribeTextCLI.Arguments(["capture-benchmark-host", "--output", "/tmp/host evidence"])
        #expect(parsed.command == "capture-benchmark-host")
        #expect(parsed.source == "/tmp/host evidence")
        #expect(parsed.model == nil && parsed.whisper == nil && parsed.provider == nil)
        for arguments in [
            ["capture-benchmark-host"], ["capture-benchmark-host", "/tmp/host"],
            ["capture-benchmark-host", "--output", "relative"], ["capture-benchmark-host", "--model"],
            ["capture-benchmark-host", "--output", "/tmp/invalid\0path"],
            ["capture-benchmark-host", "--output", "/tmp/host", "--model", "model.bin"],
            ["capture-benchmark-host", "--output", "/tmp/host", "--whisper-cli", "/tmp/whisper"],
            ["capture-benchmark-host", "--output", "/tmp/host", "--provider", "openai"],
            ["capture-benchmark-host", "--output", "/tmp/host", "--allow-cloud-text"],
            ["capture-benchmark-host", "--output", "/tmp/host", "--output", "/tmp/other"]
        ] {
            #expect(throws: CoreFailure.self) { try RecScribeTextCLI.Arguments(arguments) }
        }
    }
}
