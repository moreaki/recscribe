import Darwin
import Foundation
import Testing
@testable import RecScribeCore

@Suite struct BenchmarkHostEvidenceTests {
    private func folder() throws -> URL {
        let value = try AudioFixture.folder()
        guard let physical = realpath(value.path, nil) else { throw POSIXError(.EIO) }
        defer { free(physical) }
        return URL(fileURLWithPath: String(cString: physical), isDirectory: true)
    }

    private func capture(_ folder: URL) throws -> BenchmarkHostEvidence.Snapshot {
        let producer = folder.appendingPathComponent("producer")
        try Data("synthetic identity; never executed".utf8).write(to: producer)
        let result = try BenchmarkHostEvidence.capture(output: folder.appendingPathComponent("static"), producer: producer,
            runner: { probe, _, check in
                try check()
                return Data([0xff, 0]) + Data(("synthetic " + probe.name + "\n").utf8)
            }, check: {})
        return BenchmarkHostEvidence.Snapshot(url: URL(fileURLWithPath: try #require(result["path"].string)),
                                              sha256: try #require(result["sha256"].string))
    }

    private var powerOnly: BenchmarkHostEvidence.Runner {
        { probe, _, check in
            try check()
            guard probe.command == BenchmarkHostEvidence.power.command else { throw CoreFailure("Cached use repeated a static command") }
            return Data("Now drawing from 'AC Power'\n".utf8)
        }
    }

    @Test func cachedUseRetainsExactStaticBytesAndOnlyRunsFreshPower() throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let snapshot = try capture(root)
        let original = try Data(contentsOf: snapshot.url)
        #expect(TextJob.hash(original) == snapshot.sha256)
        let output = root.appendingPathComponent("block")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: false)
        let host = try BenchmarkHostEvidence.reuse(snapshot, output: output, runner: powerOnly, check: {})
        #expect(host["static_snapshot"]["sha256"] == .string(snapshot.sha256))
        #expect(host["power_command"] == ["/usr/bin/pmset", "-g", "batt"])
        #expect(host["thermal_state"].integer != nil && host["fresh_observed_utc"].string != nil)
        #expect(host["historical_power_policy_evidence"] == "host-static-power-configuration.raw")
        #expect(try Data(contentsOf: output.appendingPathComponent("host-static-snapshot.json")) == original)
        for probe in BenchmarkHostEvidence.probes {
            #expect(try Data(contentsOf: output.appendingPathComponent("host-static-" + probe.name + ".raw")) ==
                    Data(contentsOf: snapshot.url.deletingLastPathComponent().appendingPathComponent(probe.name + ".raw")))
        }
    }

    @Test func snapshotConfigurationIsExplicitAndConflictingOverrideFails() throws {
        #expect(try BenchmarkHostEvidence.selection(config: [:], override: nil) == nil)
        let identity = BenchmarkHostEvidence.Snapshot(url: URL(fileURLWithPath: "/private/static/snapshot.json"), sha256: String(repeating: "a", count: 64))
        let value: JSONValue = ["host_evidence_snapshot": ["path": .string(identity.url.path), "sha256": .string(identity.sha256)]]
        #expect(try BenchmarkHostEvidence.selection(config: value, override: nil) == identity)
        #expect(throws: CoreFailure.self) {
            try BenchmarkHostEvidence.selection(config: value,
                override: BenchmarkHostEvidence.Snapshot(url: URL(fileURLWithPath: "/private/other.json"), sha256: identity.sha256))
        }
        let invalidValues: [JSONValue] = [1, ["path": "relative.json", "sha256": .string(identity.sha256)],
            ["path": "/private/../other.json", "sha256": .string(identity.sha256)],
            ["path": "/private/static\0.json", "sha256": .string(identity.sha256)],
            ["path": "/private/static.json", "sha256": "invalid"],
            ["path": "/private/static.json", "sha256": .string(identity.sha256), "command": "/other"]]
        for invalid in invalidValues {
            #expect(throws: CoreFailure.self) { try BenchmarkHostEvidence.selection(config: ["host_evidence_snapshot": invalid], override: nil) }
        }
    }

    @Test func conflictingSnapshotFailsBeforeManifestModelOrOutputWork() throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let configuration = root.appendingPathComponent("experiment.json")
        let configured: JSONValue = ["host_evidence_snapshot": ["path": .string(root.appendingPathComponent("snapshot.json").path),
            "sha256": .string(String(repeating: "a", count: 64))]]
        try configured.encoded().write(to: configuration)
        let output = root.appendingPathComponent("must-not-exist")
        // Missing manifest/binary must never be consulted before this conflict.
        #expect(throws: CoreFailure.self) {
            try BenchmarkExperiment.run(manifest: root.appendingPathComponent("missing-corpus.json"), configuration: configuration,
                output: output, cli: root.appendingPathComponent("missing-cli"), dryRun: true,
                hostSnapshot: BenchmarkHostEvidence.Snapshot(url: root.appendingPathComponent("different.json"), sha256: String(repeating: "b", count: 64)))
        }
        #expect(!FileManager.default.fileExists(atPath: output.path))
    }

    @Test func wrongHostManifestHashCommandAndRawBytesRejectBeforeFreshProbe() throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let snapshot = try capture(root)
        let manifest = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: snapshot.url))
        let forbidden: BenchmarkHostEvidence.Runner = { _, _, _ in throw CoreFailure("Invalid snapshot reached fresh command") }
        for index in 0..<4 {
            let directory = root.appendingPathComponent("changed-\(index)")
            try FileManager.default.copyItem(at: snapshot.url.deletingLastPathComponent(), to: directory)
            let file = directory.appendingPathComponent("snapshot.json")
            var changed = manifest
            if index == 0 { changed["host"]["machine_identity_sha256"] = .string(String(repeating: "0", count: 64)) }
            if index == 1 { changed["commands"]["unexpected"] = true }
            if index == 2 {
                var commands = try #require(changed["commands"].array)
                commands[0]["argv"] = ["/different", "--help"]; changed["commands"] = .array(commands)
            }
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            let bytes = try changed.encoded(); try bytes.write(to: file)
            let output = root.appendingPathComponent("block-\(index)")
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: false)
            let bad = BenchmarkHostEvidence.Snapshot(url: file, sha256: index == 3 ? String(repeating: "0", count: 64) : TextJob.hash(bytes))
            #expect(throws: CoreFailure.self) { try BenchmarkHostEvidence.reuse(bad, output: output, runner: forbidden, check: {}) }
            #expect(try FileManager.default.contentsOfDirectory(atPath: output.path).isEmpty)
        }
        let raw = snapshot.url.deletingLastPathComponent().appendingPathComponent("hardware.raw")
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: raw.path)
        try Data("changed".utf8).write(to: raw)
        let output = root.appendingPathComponent("bad-raw"); try FileManager.default.createDirectory(at: output, withIntermediateDirectories: false)
        #expect(throws: CoreFailure.self) { try BenchmarkHostEvidence.reuse(snapshot, output: output, runner: forbidden, check: {}) }
        #expect(try FileManager.default.contentsOfDirectory(atPath: output.path).isEmpty)
    }

    @Test func typePathAndSizeBoundsRejectFIFOAndSymlinks() throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let fifo = root.appendingPathComponent("fifo")
        #expect(mkfifo(fifo.path, 0o600) == 0)
        #expect(throws: CoreFailure.self) { try BenchmarkHostEvidence.readRegular(fifo, maximum: 100, check: {}) }
        let source = root.appendingPathComponent("regular"); try Data([1, 2, 3]).write(to: source)
        let link = root.appendingPathComponent("link"); try FileManager.default.createSymbolicLink(at: link, withDestinationURL: source)
        #expect(throws: POSIXError.self) { try BenchmarkHostEvidence.readRegular(link, maximum: 100, check: {}) }
        #expect(throws: CoreFailure.self) { try BenchmarkHostEvidence.readRegular(source, maximum: 2, check: {}) }
        let alias = root.appendingPathComponent("alias"); try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: root)
        #expect(throws: CoreFailure.self) { try BenchmarkHostEvidence.readRegular(alias.appendingPathComponent("regular"), maximum: 100, check: {}) }
    }

    @Test func cancelledOrOversizedCapturePreservesPartialEvidenceWithoutSnapshot() throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let producer = root.appendingPathComponent("producer"); try Data("never executed".utf8).write(to: producer)
        let cancelled = root.appendingPathComponent("cancelled")
        #expect(throws: CancellationError.self) {
            try BenchmarkHostEvidence.capture(output: cancelled, producer: producer, runner: { probe, output, _ in
                try Data("partial raw bytes".utf8).write(to: output.appendingPathComponent(probe.name + ".raw"))
                throw CancellationError()
            }, check: {})
        }
        #expect(!FileManager.default.fileExists(atPath: cancelled.appendingPathComponent("snapshot.json").path))
        #expect(try String(contentsOf: cancelled.appendingPathComponent("hardware.raw"), encoding: .utf8) == "partial raw bytes")
        let state = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: cancelled.appendingPathComponent("capture.state.json")))
        #expect(state["status"] == "cancelled")
        let oversized = root.appendingPathComponent("oversized")
        #expect(throws: CoreFailure.self) {
            try BenchmarkHostEvidence.capture(output: oversized, producer: producer,
                runner: { _, _, _ in Data(repeating: 1, count: BenchmarkHostEvidence.maximumOutputBytes + 1) }, check: {})
        }
        #expect(!FileManager.default.fileExists(atPath: oversized.appendingPathComponent("snapshot.json").path))
        #expect(throws: POSIXError.self) {
            try BenchmarkHostEvidence.capture(output: cancelled, producer: producer, runner: { _, _, _ in Data() }, check: {})
        }
    }

    @Test func cachedModeRequiresSuccessfulNonemptyFreshPowerAndPropagatesCancellation() throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let snapshot = try capture(root)
        let empty = root.appendingPathComponent("empty-power")
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: false)
        #expect(throws: CoreFailure.self) {
            try BenchmarkHostEvidence.reuse(snapshot, output: empty, runner: { _, _, _ in Data() }, check: {})
        }
        #expect(!FileManager.default.fileExists(atPath: empty.appendingPathComponent("host-power.txt").path))
        let failed = root.appendingPathComponent("failed-power")
        try FileManager.default.createDirectory(at: failed, withIntermediateDirectories: false)
        #expect(throws: CoreFailure.self) {
            try BenchmarkHostEvidence.reuse(snapshot, output: failed, runner: { _, output, _ in
                try Data("partial power evidence".utf8).write(to: output.appendingPathComponent("power.raw"))
                throw CoreFailure("Synthetic fresh power failure")
            }, check: {})
        }
        #expect(try String(contentsOf: failed.appendingPathComponent("power.raw"), encoding: .utf8) == "partial power evidence")
        let cancelled = root.appendingPathComponent("cancelled-power")
        try FileManager.default.createDirectory(at: cancelled, withIntermediateDirectories: false)
        #expect(throws: CancellationError.self) {
            try BenchmarkHostEvidence.reuse(snapshot, output: cancelled, runner: { _, _, _ in throw CancellationError() }, check: {})
        }
        #expect(!FileManager.default.fileExists(atPath: cancelled.appendingPathComponent("host-power.txt").path))
    }

    @Test func directCommandTimeoutAndOverflowRetainBoundedRawOutput() throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let probe = BenchmarkHostEvidence.Probe(name: "synthetic", executable: "/bin/sh",
            arguments: ["-c", "printf retained; exec /bin/sleep 30"], timeout: 0.1)
        #expect(throws: CoreFailure.self) { try BenchmarkHostEvidence.execute(probe, root, {}) }
        #expect(try String(contentsOf: root.appendingPathComponent("synthetic.raw"), encoding: .utf8) == "retained")
        let overflow = BenchmarkHostEvidence.Probe(name: "overflow", executable: "/usr/bin/yes", arguments: [], timeout: 2)
        #expect(throws: CoreFailure.self) { try BenchmarkHostEvidence.execute(overflow, root, {}) }
        #expect(try Data(contentsOf: root.appendingPathComponent("overflow.raw")).count == BenchmarkHostEvidence.maximumOutputBytes + 1)
    }

    @Test func experimentConfigUsesSnapshotWithoutModelCalls() throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let snapshot = try capture(root)
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let (_, original) = try BenchmarkExperiment.read(repo.appendingPathComponent("benchmarks/manifests/experiment.template.json"))
        var config = original
        config["host_evidence_snapshot"] = ["path": .string(snapshot.url.path), "sha256": .string(snapshot.sha256)]
        let file = root.appendingPathComponent("experiment.json"); try config.encoded().write(to: file)
        let binary = root.appendingPathComponent("binary"); try Data("never executed".utf8).write(to: binary)
        let report = try BenchmarkExperiment.run(manifest: repo.appendingPathComponent("benchmarks/manifests/corpus.template.json"),
            configuration: file, output: root.appendingPathComponent("matrix"), cli: binary, dryRun: true)
        #expect(report["host"]["static_snapshot"]["sha256"] == .string(snapshot.sha256))
        #expect(report["rows"].array?.allSatisfy { $0["measurement"] == .null } == true)
        #expect(report["host"]["power_command"] == ["/usr/bin/pmset", "-g", "batt"])
    }
}
