import Foundation
import Testing
@testable import RecScribe

struct LocalProcessRunnerTests {
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
