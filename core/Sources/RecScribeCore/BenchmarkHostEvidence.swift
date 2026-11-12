import Darwin
import Foundation

/// Historical static evidence can be reused; recording admission and dynamic
/// power/thermal observations are always the caller's responsibility.
public enum BenchmarkHostEvidence {
    public struct Snapshot: Sendable, Equatable {
        public let url: URL
        public let sha256: String
        public init(url: URL, sha256: String) { self.url = url; self.sha256 = sha256 }
    }

    static let schema = "benchmark-static-host-evidence-v1"
    static let maximumOutputBytes = 1_024 * 1_024
    struct Probe: Sendable {
        let name: String, executable: String, arguments: [String]
        let timeout: TimeInterval
        var command: JSONValue { .array(([executable] + arguments).map(JSONValue.string)) }
    }
    static let probes = [
        Probe(name: "hardware", executable: "/usr/sbin/system_profiler", arguments: ["SPHardwareDataType", "SPDisplaysDataType", "-json"], timeout: 30),
        Probe(name: "power-configuration", executable: "/usr/bin/pmset", arguments: ["-g", "custom"], timeout: 30),
        Probe(name: "toolchain", executable: "/usr/bin/xcodebuild", arguments: ["-version"], timeout: 30)
    ]
    static let power = Probe(name: "power", executable: "/usr/bin/pmset", arguments: ["-g", "batt"], timeout: 5)
    typealias Runner = @Sendable (Probe, URL, @Sendable () throws -> Void) throws -> Data

    static func host() throws -> JSONValue {
        #if arch(arm64)
        let architecture = "arm64"
        #elseif arch(x86_64)
        let architecture = "x86_64"
        #else
        let architecture = "unknown"
        #endif
        let info = ProcessInfo.processInfo
        var identifier: uuid_t = (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
        var timeout = timespec(tv_sec: 2, tv_nsec: 0)
        let status = withUnsafeMutableBytes(of: &identifier) {
            gethostuuid($0.baseAddress!.assumingMemoryBound(to: UInt8.self), &timeout)
        }
        guard status == 0 else { throw CoreFailure("Static host evidence requires an available bounded same-machine identity") }
        let identifierHash = withUnsafeBytes(of: identifier) { TextJob.hash(Data($0)) }
        return ["os": .string(info.operatingSystemVersionString), "architecture": .string(architecture),
                "cpu_count": .integer(Int64(info.processorCount)), "physical_memory_bytes": .integer(Int64(info.physicalMemory)),
                "machine_identity_sha256": .string(identifierHash)]
    }

    static func timestamp() -> String { Date().ISO8601Format() }
    static func digest(_ value: String) -> Bool { value.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil }

    static func selection(config: JSONValue, override: Snapshot?) throws -> Snapshot? {
        let value = config["host_evidence_snapshot"]
        var configured: Snapshot?
        if value != .null {
            guard let object = value.object, Set(object.keys) == ["path", "sha256"],
                  let path = value["path"].string, path.hasPrefix("/"), path.utf8.count <= 4_096,
                  !path.utf8.contains(0), !path.split(separator: "/").contains(".."),
                  let hash = value["sha256"].string, digest(hash) else {
                throw CoreFailure("host_evidence_snapshot requires exactly an absolute path and lowercase SHA-256")
            }
            configured = Snapshot(url: URL(fileURLWithPath: path), sha256: hash)
        }
        guard override == nil || configured == nil || override == configured else {
            throw CoreFailure("API and experiment static host snapshot identities conflict")
        }
        return override ?? configured
    }

    /// Capture once outside measured cells. A failed/cancelled capture retains
    /// partial logs and state, but never publishes a usable snapshot.json.
    public static func capture(output: URL,
                               check: @escaping @Sendable () throws -> Void = { try Task.checkCancellation() }) throws -> JSONValue {
        guard let executable = Bundle.main.executableURL else { throw CoreFailure("Capture executable identity is unavailable") }
        return try capture(output: output, producer: executable.resolvingSymlinksInPath(), runner: execute, check: check)
    }

    static func capture(output: URL, producer: URL, runner: Runner,
                        check: @escaping @Sendable () throws -> Void) throws -> JSONValue {
        try check(); try directory(output.deletingLastPathComponent())
        guard mkdir(output.path, 0o700) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let began = ContinuousClock.now
        let bounded: @Sendable () throws -> Void = {
            try check()
            if FileManager.default.fileExists(atPath: output.appendingPathComponent("cancel.request").path) { throw CancellationError() }
            guard began.duration(to: .now) < .seconds(90) else { throw CoreFailure("Static host capture exceeded 90 seconds") }
        }
        var state: JSONValue = ["schema_version": .string(schema), "status": "running", "commands": []]
        func save() throws { try state.encoded().write(to: output.appendingPathComponent("capture.state.json"), options: .atomic) }
        try save()
        do {
            let producerHash = TextJob.hash(try readRegular(producer, maximum: 64 * 1_024 * 1_024, check: bounded))
            let producerIdentity: JSONValue = ["path": .string(producer.path), "sha256": .string(producerHash)]
            var commands: [JSONValue] = []
            for probe in probes {
                try bounded(); state["active_command"] = probe.command; try save()
                let binary = URL(fileURLWithPath: probe.executable).resolvingSymlinksInPath()
                let binaryHash = TextJob.hash(try readRegular(binary, maximum: 64 * 1_024 * 1_024, check: bounded))
                let bytes = try runner(probe, output, bounded)
                guard !bytes.isEmpty, bytes.count <= maximumOutputBytes else { throw CoreFailure("Static host command output exceeds its complete-output bound") }
                let name = probe.name + ".raw"
                let file = output.appendingPathComponent(name)
                // The real runner retains partial bytes even on failure.
                if !FileManager.default.fileExists(atPath: file.path) { try bytes.write(to: file, options: .withoutOverwriting) }
                guard try readRegular(file, maximum: maximumOutputBytes, check: bounded) == bytes else { throw CoreFailure("Static host output changed") }
                commands.append(["name": .string(probe.name), "argv": probe.command, "exit_code": 0,
                    "executable_sha256": .string(binaryHash), "output": ["path": .string(name), "sha256": .string(TextJob.hash(bytes)), "bytes": .integer(Int64(bytes.count))],
                    "output_scope": "complete combined stdout and stderr"])
                state["commands"] = .array(commands); try save()
            }
            try bounded()
            let value: JSONValue = ["schema_version": .string(schema), "captured_utc": .string(timestamp()), "host": try host(),
                "producer": producerIdentity, "commands": .array(commands), "scope": "Historical static hardware, toolchain and power policy; never recording or current-power admission"]
            try bounded()
            let bytes = try value.encoded(), file = output.appendingPathComponent("snapshot.json")
            let pending = output.appendingPathComponent("snapshot.pending.json")
            try bytes.write(to: pending, options: .withoutOverwriting)
            for probe in probes { try FileManager.default.setAttributes([.posixPermissions: 0o400], ofItemAtPath: output.appendingPathComponent(probe.name + ".raw").path) }
            try FileManager.default.setAttributes([.posixPermissions: 0o400], ofItemAtPath: pending.path)
            state["status"] = "completed"; try save()
            // Publish last, without replacement, after all capture work succeeds.
            try bounded()
            guard link(pending.path, file.path) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            _ = unlink(pending.path)
            return ["path": .string(file.path), "sha256": .string(TextJob.hash(bytes)), "bytes": .integer(Int64(bytes.count))]
        } catch {
            state["status"] = error is CancellationError ? "cancelled" : "failed"
            state["error"] = .string(error.localizedDescription); try? save(); throw error
        }
    }

    static func reuse(_ snapshot: Snapshot, output: URL, runner: Runner = execute,
                      check: @escaping @Sendable () throws -> Void) throws -> JSONValue {
        guard digest(snapshot.sha256) else { throw CoreFailure("Static host snapshot requires a lowercase SHA-256") }
        let raw = try readRegular(snapshot.url, maximum: 256 * 1_024, check: check)
        guard TextJob.hash(raw) == snapshot.sha256 else { throw CoreFailure("Static host snapshot checksum mismatch") }
        let value = try JSONDecoder().decode(JSONValue.self, from: raw)
        let currentHost = try host()
        try check()
        guard let object = value.object, Set(object.keys) == ["schema_version", "captured_utc", "host", "producer", "commands", "scope"],
              value["schema_version"] == .string(schema), value["host"] == currentHost,
              let captured = value["captured_utc"].string, let date = ISO8601DateFormatter().date(from: captured), date <= Date(),
              let producer = value["producer"].object, Set(producer.keys) == ["path", "sha256"],
              let producerPath = value["producer"]["path"].string, producerPath.hasPrefix("/"), producerPath.utf8.count <= 4_096,
              !producerPath.utf8.contains(0), !producerPath.split(separator: "/").contains(".."), digest(value["producer"]["sha256"].string ?? ""),
              value["scope"] == "Historical static hardware, toolchain and power policy; never recording or current-power admission",
              let commands = value["commands"].array, commands.count == probes.count else {
            throw CoreFailure("Invalid or different-host static evidence snapshot")
        }
        var files: [(String, Data)] = []
        for (probe, command) in zip(probes, commands) {
            guard let fields = command.object, Set(fields.keys) == ["name", "argv", "exit_code", "executable_sha256", "output", "output_scope"],
                  command["name"] == .string(probe.name), command["argv"] == probe.command, command["exit_code"].integer == 0,
                  digest(command["executable_sha256"].string ?? ""), command["output_scope"] == "complete combined stdout and stderr",
                  let lock = command["output"].object, Set(lock.keys) == ["path", "sha256", "bytes"],
                  command["output"]["path"] == .string(probe.name + ".raw"),
                  let count = command["output"]["bytes"].integer, count > 0, count <= maximumOutputBytes,
                  let hash = command["output"]["sha256"].string, digest(hash) else { throw CoreFailure("Invalid static command/output provenance") }
            let bytes = try readRegular(snapshot.url.deletingLastPathComponent().appendingPathComponent(probe.name + ".raw"), maximum: maximumOutputBytes, check: check)
            guard bytes.count == count, TextJob.hash(bytes) == hash else { throw CoreFailure("Static host raw output checksum mismatch") }
            files.append(("host-static-" + probe.name + ".raw", bytes))
        }
        try check()
        try raw.write(to: output.appendingPathComponent("host-static-snapshot.json"), options: .withoutOverwriting)
        for (name, bytes) in files {
            try check(); try bytes.write(to: output.appendingPathComponent(name), options: .withoutOverwriting)
        }
        var evidence = currentHost
        evidence["thermal_state"] = .integer(Int64(ProcessInfo.processInfo.thermalState.rawValue))
        evidence["fresh_observed_utc"] = .string(timestamp())
        evidence["static_snapshot"] = ["path": .string(snapshot.url.path), "sha256": .string(snapshot.sha256), "captured_utc": .string(captured), "retained_manifest": "host-static-snapshot.json"]
        evidence["hardware_evidence"] = "host-static-hardware.raw"; evidence["toolchain_evidence"] = "host-static-toolchain.raw"
        evidence["historical_power_policy_evidence"] = "host-static-power-configuration.raw"
        evidence["power_command"] = power.command
        let bytes = try runner(power, output, check)
        guard !bytes.isEmpty, bytes.count <= maximumOutputBytes else { throw CoreFailure("Complete nonempty fresh power output is required in cached mode") }
        try check()
        try bytes.write(to: output.appendingPathComponent("host-power.txt"), options: .withoutOverwriting)
        evidence["power_evidence"] = "host-power.txt"
        try check()
        return evidence
    }

    static func directory(_ url: URL) throws {
        guard url.isFileURL, url.path.hasPrefix("/"), url.path.utf8.count <= 4_096,
              !url.path.utf8.contains(0), !url.path.split(separator: "/").contains("..") else { throw CoreFailure("Absolute bounded file path required") }
        var current = url
        while true {
            var info = stat()
            guard lstat(current.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else { throw CoreFailure("Real non-symlink directory required") }
            if current.path == "/" { return }; current.deleteLastPathComponent()
        }
    }

    static func readRegular(_ url: URL, maximum: Int, check: @Sendable () throws -> Void) throws -> Data {
        guard url.isFileURL, url.path.utf8.count <= 4_096, !url.path.utf8.contains(0),
              !url.path.split(separator: "/").contains("..") else { throw CoreFailure("Bounded canonical file path required") }
        try check(); try directory(url.deletingLastPathComponent())
        let fd = open(url.path, O_RDONLY | O_NONBLOCK | O_NOFOLLOW)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }; defer { close(fd) }
        var before = stat(), after = stat(), named = stat()
        guard fstat(fd, &before) == 0, before.st_mode & S_IFMT == S_IFREG, before.st_size >= 0, before.st_size <= maximum else { throw CoreFailure("Bounded regular static evidence file required") }
        var bytes = Data(), buffer = [UInt8](repeating: 0, count: 64 * 1_024)
        while true {
            try check(); let count = Darwin.read(fd, &buffer, buffer.count)
            if count < 0 { if errno == EINTR { continue }; throw POSIXError(.EIO) }; if count == 0 { break }
            guard bytes.count + count <= maximum else { throw CoreFailure("Static evidence file grew beyond bound") }; bytes.append(contentsOf: buffer.prefix(count))
        }
        func same(_ a: stat, _ b: stat) -> Bool {
            a.st_dev == b.st_dev && a.st_ino == b.st_ino && a.st_size == b.st_size &&
            a.st_mtimespec.tv_sec == b.st_mtimespec.tv_sec && a.st_mtimespec.tv_nsec == b.st_mtimespec.tv_nsec &&
            a.st_ctimespec.tv_sec == b.st_ctimespec.tv_sec && a.st_ctimespec.tv_nsec == b.st_ctimespec.tv_nsec
        }
        try directory(url.deletingLastPathComponent())
        guard fstat(fd, &after) == 0, lstat(url.path, &named) == 0, same(before, after), same(after, named) else { throw CoreFailure("Static evidence changed during read") }
        try check(); return bytes
    }

    static func execute(_ probe: Probe, _ directory: URL, _ check: @Sendable () throws -> Void) throws -> Data {
        try check(); let process = Process(), pipe = Pipe(), file = directory.appendingPathComponent(probe.name + ".raw")
        process.executableURL = URL(fileURLWithPath: probe.executable); process.arguments = probe.arguments
        process.currentDirectoryURL = directory; process.qualityOfService = .utility
        process.standardInput = FileHandle.nullDevice; process.standardOutput = pipe; process.standardError = pipe
        let input = pipe.fileHandleForReading; defer { try? input.close(); try? pipe.fileHandleForWriting.close() }
        guard fcntl(input.fileDescriptor, F_SETFL, fcntl(input.fileDescriptor, F_GETFL) | O_NONBLOCK) != -1 else { throw POSIXError(.EIO) }
        var bytes = Data(), buffer = [UInt8](repeating: 0, count: 32 * 1_024)
        func drain() throws -> Bool {
            for _ in 0..<8 {
                let count = Darwin.read(input.fileDescriptor, &buffer, buffer.count)
                if count < 0 { if errno == EINTR || errno == EAGAIN { return false }; throw POSIXError(.EIO) }; if count == 0 { return true }
                bytes.append(contentsOf: buffer.prefix(min(count, max(0, maximumOutputBytes + 1 - bytes.count))))
                guard bytes.count <= maximumOutputBytes else { throw CoreFailure("Static host command output exceeded 1 MiB; partial raw bytes retained") }
            }
            return false
        }
        // Direct fixed-command child only. The outer research owned-session
        // guard remains responsible for any inherited descendant groups.
        func stop() -> Bool {
            if process.isRunning { process.terminate() }
            let end = ContinuousClock.now.advanced(by: .seconds(5))
            while process.isRunning && ContinuousClock.now < end { _ = try? drain(); usleep(20_000) }
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            let killed = ContinuousClock.now.advanced(by: .seconds(2))
            while process.isRunning && ContinuousClock.now < killed { _ = try? drain(); usleep(20_000) }
            guard !process.isRunning else { return false }
            process.waitUntilExit(); return true
        }
        let started = ContinuousClock.now; var launched = false
        do {
            try process.run(); launched = true; try pipe.fileHandleForWriting.close()
            while process.isRunning { try check(); guard started.duration(to: .now) < .seconds(probe.timeout) else { throw CoreFailure("Static host command timed out") }; _ = try drain(); usleep(20_000) }
            process.waitUntilExit()
            while try !drain() {
                try check(); guard started.duration(to: .now) < .seconds(probe.timeout) else { throw CoreFailure("Static host output did not reach EOF within its deadline") }; usleep(20_000)
            }
            try check()
            try bytes.write(to: file, options: .withoutOverwriting)
            guard process.terminationStatus == 0 else { throw CoreFailure("Static host command exited with status \(process.terminationStatus)") }
            return bytes
        } catch {
            let reaped = !launched || stop(); if reaped { _ = try? drain() }
            try? bytes.prefix(maximumOutputBytes + 1).write(to: file, options: .withoutOverwriting)
            guard reaped else { throw CoreFailure("Static host command direct-child cleanup is uncertain; outer owned-session guard is required") }
            throw error
        }
    }
}
