import Darwin
import Foundation
import os

/// One owned child, drained without a pipe deadlock or unbounded output allocation.
/// Only bounded private tails are retained; arguments and output never enter OSLog.
nonisolated struct LocalProcessRunner: Sendable {
    struct Policy: Sendable {
        var timeout: TimeInterval = 86_400
        var terminationGrace: TimeInterval = 5
        var outputBytes = 128 * 1_024
        var retainedRuns = 20
        static let readBytes = 32 * 1_024
        static let pollMicroseconds: useconds_t = 20_000
    }
    enum Outcome: String, Codable, Sendable { case exited, cancelled, timedOut }
    struct Result: Codable, Sendable {
        let id: UUID
        let executable: String
        let outcome: Outcome
        let exitCode: Int32
        let durationSeconds: Double
        let outputTruncated: Bool
        var diagnostics: URL?
        var output: String
        var tail: String
    }
    struct Failure: Error, LocalizedError {
        let result: Result
        var errorDescription: String? {
            "\(result.executable): \(result.outcome.rawValue), exit \(result.exitCode). \(result.tail.suffix(2_000))\nDiagnostic ID: \(result.id)"
        }
    }
    var policy = Policy()
    var diagnosticsDirectory = AppSettings.supportDirectory.appendingPathComponent("Diagnostics/Processes", isDirectory: true)
    private static let logger = Logger(subsystem: "com.moreaki.recscribe", category: "LocalProcess")

    func execute(_ binary: URL, _ arguments: [String], cancel: WorkCancellation) throws -> Result {
        try cancel.check()
        guard policy.timeout.isFinite, policy.timeout > 0, policy.terminationGrace >= 0,
              policy.terminationGrace.isFinite, policy.outputBytes > 0, policy.retainedRuns > 0 else {
            throw SessionError.invalid("Invalid local process policy")
        }
        let id = UUID(), started = Date()
        let clock = ContinuousClock.now
        let process = Process(), pipe = Pipe()
        process.executableURL = binary
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = pipe
        process.standardError = pipe
        process.qualityOfService = .utility
        let input = pipe.fileHandleForReading
        defer { try? input.close(); try? pipe.fileHandleForWriting.close() }
        let fd = input.fileDescriptor
        guard fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK) != -1 else {
            throw POSIXError(.EIO)
        }
        try process.run()
        try pipe.fileHandleForWriting.close()
        var prefix = Data(), tail = Data(), truncated = false
        var buffer = [UInt8](repeating: 0, count: Policy.readBytes)
        // Limit each drain pass so even an endlessly writing child remains cancellable.
        func drain() throws -> Bool {
            for _ in 0..<8 {
                let count = Darwin.read(fd, &buffer, buffer.count)
                if count == 0 { return false }
                if count < 0 {
                    if errno == EAGAIN || errno == EINTR { return false }
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }
                prefix.append(contentsOf: buffer.prefix(min(count, max(0, policy.outputBytes - prefix.count))))
                tail.append(contentsOf: buffer.prefix(count))
                if tail.count > policy.outputBytes {
                    truncated = true
                    tail.removeFirst(tail.count - policy.outputBytes)
                }
            }
            return true
        }
        var outcome = Outcome.exited
        do {
            while process.isRunning {
                try cancel.check()
                if clock.duration(to: .now) >= .seconds(policy.timeout) { outcome = .timedOut; break }
                if try !drain() { usleep(Policy.pollMicroseconds) }
            }
        } catch is CancellationError { outcome = .cancelled }
        catch {
            stop(process)
            throw error
        }
        if outcome != .exited { stop(process) }
        process.waitUntilExit()
        while try drain() {} // No waiting for unrelated descendants holding the pipe open.
        if outcome == .exited { do { try cancel.check() } catch { outcome = .cancelled } }
        var result = Result(id: id, executable: binary.lastPathComponent, outcome: outcome,
                            exitCode: process.terminationStatus, durationSeconds: Date().timeIntervalSince(started),
                            outputTruncated: truncated, output: String(decoding: prefix, as: UTF8.self),
                            tail: String(decoding: tail, as: UTF8.self))
        result.diagnostics = try retain(result)
        Self.logger.notice("Process id=\(id) outcome=\(outcome.rawValue, privacy: .public) exit=\(result.exitCode) duration_s=\(result.durationSeconds) truncated=\(truncated)")
        return result
    }

    private func stop(_ process: Process) {
        guard process.isRunning else { return }
        process.terminate()
        let deadline = ContinuousClock.now.advanced(by: .seconds(policy.terminationGrace))
        while process.isRunning && ContinuousClock.now < deadline { usleep(Policy.pollMicroseconds) }
        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        process.waitUntilExit()
    }

    private func retain(_ result: Result) throws -> URL {
        let manager = FileManager.default
        try manager.createDirectory(at: diagnosticsDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let destination = diagnosticsDirectory.appendingPathComponent("\(result.id).json")
        var diagnostic = result
        diagnostic.output = "" // Keep only the bounded tail, never two copies.
        let data = try JSONEncoder().encode(diagnostic)
        guard manager.createFile(atPath: destination.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
            throw SessionError.invalid("Cannot save local process diagnostics")
        }
        let previous = try manager.contentsOfDirectory(at: diagnosticsDirectory, includingPropertiesForKeys: [.contentModificationDateKey])
            .filter { $0.pathExtension == "json" && UUID(uuidString: $0.deletingPathExtension().lastPathComponent) != nil }
            .sorted { (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                > (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast }
        for expired in previous.dropFirst(policy.retainedRuns) { try? manager.removeItem(at: expired) }
        return destination
    }

    static func run(_ binary: URL, _ arguments: [String], in _: URL,
                    cancel: WorkCancellation, timeout: TimeInterval = 86_400) throws -> String {
        var runner = Self()
        runner.policy.timeout = timeout
        let result = try runner.execute(binary, arguments, cancel: cancel)
        if result.outcome == .cancelled { throw CancellationError() }
        guard result.outcome == .exited, result.exitCode == 0 else { throw Failure(result: result) }
        return result.output
    }
}
