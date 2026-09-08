import Foundation
import Testing
@testable import RecScribe

struct LocalProcessRunnerTests {
    @Test func usageErrorsShowTheCauseAndRetainFullDiagnostics() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let runner = LocalProcessRunner(diagnosticsDirectory: root)
        let usage = "usage: python3 -m recscribe [options]\npython3 -m recscribe: error: Verification must use a distinct model\n"
        let result = try runner.execute(URL(fileURLWithPath: "/bin/sh"),
            ["-c", "printf '%s' \"$1\"; exit 2", "synthetic-cli", usage], cancel: WorkCancellation())
        let message = LocalProcessRunner.Failure(result: result).localizedDescription
        #expect(message.contains("Verification must use a distinct model"))
        #expect(message.contains("Diagnostic ID: \(result.id)"))
        #expect(!message.contains("usage:"))
        let data = try Data(contentsOf: #require(result.diagnostics))
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        #expect(try decoder.decode(LocalProcessRunner.Result.self, from: data).tail == usage)
        let other = try runner.execute(URL(fileURLWithPath: "/bin/sh"),
            ["-c", "printf '%s' 'Unrelated failure'; exit 2"], cancel: WorkCancellation())
        #expect(LocalProcessRunner.Failure(result: other).localizedDescription.contains("Unrelated failure"))
    }

    @Test func launchAndDiagnosticFailuresKeepStructuredEvidence() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        var runner = LocalProcessRunner(diagnosticsDirectory: root)
        let token = WorkCancellation()
        let failure = try runner.execute(root.appendingPathComponent("missing-binary"), [], cancel: token)
        #expect(failure.outcome == .launchFailed)
        #expect(failure.exitCode == nil)
        #expect(failure.operationID == token.id)
        #expect(failure.endedAt >= failure.startedAt)
        #expect(failure.durationSeconds >= 0)
        #expect(failure.diagnostics != nil)
        let obstruction = root.appendingPathComponent("not-a-directory")
        try Data().write(to: obstruction)
        runner.diagnosticsDirectory = obstruction
        let noLog = try runner.execute(URL(fileURLWithPath: "/usr/bin/printf"), ["ok"], cancel: token)
        #expect(noLog.exitCode == 0)
        #expect(noLog.output == "ok")
        #expect(noLog.diagnosticError != nil)
        #expect(LocalProcessRunner.Failure(result: noLog).localizedDescription.contains("Diagnostics could not be saved"))
    }

    @Test func descendantsHoldingOutputDoNotHangAndUnrelatedProcessesSurvive() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        var runner = LocalProcessRunner(diagnosticsDirectory: root)
        runner.policy.timeout = 0.1
        runner.policy.terminationGrace = 0.05
        let unrelated = Process()
        unrelated.executableURL = URL(fileURLWithPath: "/bin/sleep")
        unrelated.arguments = ["30"]
        try unrelated.run()
        defer { unrelated.terminate(); unrelated.waitUntilExit() }
        let parent = try runner.execute(URL(fileURLWithPath: "/bin/sh"),
            ["-c", "sleep 1 & printf 'parent done'"], cancel: WorkCancellation())
        #expect(parent.output == "parent done")
        #expect(parent.durationSeconds < 2)
        let timeout = try runner.execute(URL(fileURLWithPath: "/bin/sh"),
            ["-c", "trap '' TERM; while :; do printf 'synthetic output'; done"], cancel: WorkCancellation())
        #expect(timeout.outcome == .timedOut)
        #expect(timeout.durationSeconds < 2)
        #expect(timeout.output.utf8.count <= runner.policy.outputBytes)
        #expect(unrelated.isRunning)
    }
    @Test func outputIsBoundedFailuresRetainTailAndLogsExpire() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        var runner = LocalProcessRunner(diagnosticsDirectory: root)
        runner.policy.outputBytes = 128
        runner.policy.retainedRuns = 2
        for _ in 0..<3 {
            let result = try runner.execute(URL(fileURLWithPath: "/bin/sh"),
                ["-c", "i=0; while [ $i -lt 2000 ]; do printf 'synthetic output\\n'; i=$((i+1)); done; printf 'final failure'; exit 7"], cancel: WorkCancellation())
            #expect(result.exitCode == 7)
            #expect(result.outcome == .exited)
            #expect(result.outputTruncated)
            #expect(result.output.utf8.count <= 128)
            #expect(result.tail.hasSuffix("final failure"))
            #expect(result.durationSeconds > 0)
            let log = try #require(result.diagnostics)
            let attributes = try FileManager.default.attributesOfItem(atPath: log.path)
            #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).count == 2)
    }

    @Test func successTimeoutAndCancellationAreDistinct() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        var runner = LocalProcessRunner(diagnosticsDirectory: root)
        runner.policy.timeout = 0.1
        runner.policy.terminationGrace = 0.05
        let success = try runner.execute(URL(fileURLWithPath: "/usr/bin/printf"), ["ok"], cancel: WorkCancellation())
        #expect(success.output == "ok")
        #expect(success.exitCode == 0)
        let timeout = try runner.execute(URL(fileURLWithPath: "/bin/sleep"), ["10"], cancel: WorkCancellation())
        #expect(timeout.outcome == .timedOut)
        #expect(timeout.durationSeconds < 2)
        runner.policy.timeout = 10
        let worker = runner, token = WorkCancellation()
        let task = Task.detached { try worker.execute(URL(fileURLWithPath: "/bin/sleep"), ["10"], cancel: token) }
        try await Task.sleep(for: .milliseconds(100))
        token.cancel()
        #expect(try await task.value.outcome == .cancelled)
    }
}
