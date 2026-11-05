import Darwin
import Foundation
import Testing
@testable import RecScribeCore

/// Exercise the real CLI entry point and OS signals, not only Task cancellation.
/// The recognizer is a bounded synthetic process; no model inference is run.
@Suite(.serialized) struct CLISignalCancellationTests {
    private var cli: URL {
        var directory = Bundle.module.bundleURL
        while directory.path != "/" {
            let candidate = directory.appendingPathComponent("recscribe-text")
            if FileManager.default.isExecutableFile(atPath: candidate.path) { return candidate }
            directory.deleteLastPathComponent()
        }
        return directory.appendingPathComponent("missing-recscribe-text")
    }

    private func tools(_ root: URL) throws -> (URL, URL) {
        let binary = root.appendingPathComponent("synthetic-whisper"), model = root.appendingPathComponent("model.bin")
        let script = #"""
        #!/bin/sh
        if [ "$1" = "--version" ]; then echo 'whisper.cpp version: synthetic'; exit 0; fi
        while [ "$#" -gt 0 ]; do
          if [ "$1" = '-of' ]; then shift; prefix="$1"; fi
          shift
        done
        printf '%s\n' '{"result":{"language":"en"},"transcription":[{"offsets":{"from":0,"to":100},"text":"synthetic words"}]}' > "${prefix}.json"
        case "$prefix" in
          *active*)
            printf '%s %s\n' "$$" "$PPID" > "${prefix}.pid.partial"
            mv "${prefix}.pid.partial" "${prefix}.pid"
            exec sleep 30
            ;;
        esac
        """# + "\n"
        try Data(script.utf8).write(to: binary)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: binary.path)
        try Data("synthetic signal-regression model".utf8).write(to: model)
        return (binary, model)
    }

    private func launch(_ arguments: [String], root: URL) throws -> Process {
        let process = Process()
        let log = root.appendingPathComponent("cli.log")
        FileManager.default.createFile(atPath: log.path, contents: nil)
        let handle = try FileHandle(forWritingTo: log)
        defer { try? handle.close() }
        process.executableURL = cli
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = handle; process.standardError = handle
        try process.run()
        return process
    }

    private func stop(_ process: Process, enginePID: URL) {
        // Cleanup is limited to this fixture's processes if an assertion fails.
        if process.isRunning { process.terminate() }
        if let text = try? String(contentsOf: enginePID, encoding: .utf8) {
            for number in text.split(whereSeparator: \.isWhitespace).compactMap({ Int32($0) }) where number > 1 {
                if kill(number, 0) == 0 { kill(number, SIGKILL) }
            }
        }
        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        process.waitUntilExit()
    }

    @Test(arguments: [SIGINT, SIGTERM])
    func transcribeSignalExitsNormallyAndRetainsCancellationEvidence(number: Int32) async throws {
        let root = try AudioFixture.folder(); defer { try? FileManager.default.removeItem(at: root) }
        let (binary, model) = try tools(root)
        let source = root.appendingPathComponent("source.wav")
        try AudioFixture.wav(source)
        let sourceHash = try WAVAudio.hash(source)
        let output = root.appendingPathComponent("active-job")
        let pidFile = output.appendingPathComponent("asr-channel-0.pid")
        let process = try launch(["transcribe", source.path, "--output", output.path,
            "--whisper-cli", binary.path, "--model", model.path, "--source-language", "en"], root: root)
        defer { stop(process, enginePID: pidFile) }
        try await expectEventually(timeout: .seconds(15)) { FileManager.default.fileExists(atPath: pidFile.path) }
        let engine = try #require(Int32(String(contentsOf: pidFile, encoding: .utf8).split(separator: " ")[0]))
        #expect(kill(process.processIdentifier, number) == 0)
        try await expectEventually(timeout: .seconds(10)) { !process.isRunning }
        #expect(process.terminationReason == .exit && process.terminationStatus == 130)
        #expect(try AudioFixture.read(output, "manifest.json")["state"] == "cancelled")
        #expect(FileManager.default.fileExists(atPath: output.appendingPathComponent("asr-channel-0.json").path))
        #expect(FileManager.default.fileExists(atPath: output.appendingPathComponent("asr-channel-0.log").path))
        #expect(!FileManager.default.fileExists(atPath: output.appendingPathComponent("working-channel-0.wav").path))
        #expect(try WAVAudio.hash(source) == sourceHash)
        try await expectEventually { kill(engine, 0) != 0 }
    }

    @Test(arguments: [SIGINT, SIGTERM])
    func benchmarkSignalPreservesCompletedCellsAndMarksActiveCellCancelled(number: Int32) async throws {
        let root = try AudioFixture.folder(); defer { try? FileManager.default.removeItem(at: root) }
        let (binary, model) = try tools(root)
        let source = root.appendingPathComponent("source.wav"), reference = root.appendingPathComponent("reference.txt")
        try AudioFixture.wav(source)
        try Data("synthetic words".utf8).write(to: reference)
        let sourceHash = try WAVAudio.hash(source), referenceHash = try WAVAudio.hash(reference)
        let corpus = root.appendingPathComponent("corpus.json")
        let cases: [JSONValue] = ["completed", "active", "later"].map { id in
            ["id": .string(id), "category": "synthetic", "language": "en", "audio": .string(source.path),
             "reference": .string(reference.path), "sha256": .string(sourceHash), "license": "synthetic regression"]
        }
        try JSONValue.object(["schema_version": "1.0", "cases": .array(cases)]).encoded().write(to: corpus)
        let revision = String(repeating: "a", count: 40)
        let config = root.appendingPathComponent("experiment.json")
        try JSONValue.object(["schema_version": "1.0", "baseline_revision": .string(revision),
            "baseline_cli": .string(cli.path), "baseline_cli_sha256": .string(try WAVAudio.hash(cli)),
            "whisper_cli": .string(binary.path), "split": "development", "threads": 2, "repetitions": 3,
            "language_modes": ["auto"], "paths": ["final"], "capture_inactive": true,
            "workload_attestation": "Synthetic subprocess regression; no inference or capture",
            "profiles": [["id": "control", "kind": "baseline", "source_revision": .string(revision), "settings": nil]],
            "models": [["id": "tiny", "checkpoint": "synthetic", "precision": "synthetic",
                        "path": .string(model.path), "sha256": .string(try WAVAudio.hash(model))]]]).encoded().write(to: config)
        let output = root.appendingPathComponent("matrix")
        let pidFile = output.appendingPathComponent("cell-3/active/asr-channel-0.pid")
        let process = try launch(["benchmark", corpus.path, "--experiment", config.path, "--output", output.path], root: root)
        defer { stop(process, enginePID: pidFile) }
        try await expectEventually(timeout: .seconds(15)) { FileManager.default.fileExists(atPath: pidFile.path) }
        let activeProcesses = try String(contentsOf: pidFile, encoding: .utf8)
            .split(whereSeparator: \.isWhitespace).compactMap { Int32($0) }
        #expect(activeProcesses.count == 2)
        let previous = output.appendingPathComponent("cell-0/completed/transcript.raw.json")
        let rawHash = try WAVAudio.hash(previous)
        #expect(kill(process.processIdentifier, number) == 0)
        try await expectEventually(timeout: .seconds(10)) { !process.isRunning }
        #expect(process.terminationReason == .exit && process.terminationStatus == 130)
        let rows = try #require(try AudioFixture.read(output, "matrix.json")["rows"].array)
        #expect(rows.count == 9)
        #expect(rows.filter { $0["status"] == "completed" || $0["status"] == "completed_with_review" }.count == 3)
        #expect(rows.filter { $0["status"] == "cancelled" }.count == 1)
        #expect(rows.filter { $0["status"] == "queued" }.count == 5)
        #expect(!rows.contains { $0["status"] == "failed" })
        #expect(try WAVAudio.hash(previous) == rawHash)
        #expect(try WAVAudio.hash(source) == sourceHash && WAVAudio.hash(reference) == referenceHash)
        #expect(FileManager.default.fileExists(atPath: output.appendingPathComponent("cell-3/results.json").path))
        try await expectEventually { activeProcesses.allSatisfy { kill($0, 0) != 0 } }
        #expect(try AudioFixture.read(output.appendingPathComponent("cell-3/active"), "manifest.json")["state"] == "cancelled")
    }
}
