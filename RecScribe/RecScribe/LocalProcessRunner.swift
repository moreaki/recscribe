import Darwin
import Foundation
import os

/// One owned child, drained without a pipe deadlock or unbounded output allocation.
/// Only bounded private tails are retained; arguments and output never enter OSLog.
nonisolated struct LocalProcessRunner: Sendable {
    struct Policy: Sendable {
        var timeout: TimeInterval = Self.defaultTimeout
        var terminationGrace: TimeInterval = 5
        var outputBytes = 128 * 1_024
        var retainedRuns = 20
        static let readBytes = 32 * 1_024
        static let pollMicroseconds: useconds_t = 20_000
        static let drainReadsPerPass = 8
        static let finalDrainPasses = 2 // Never wait indefinitely for a descendant's pipe.
        static let errorTailCharacters = 2_000
        static let defaultTimeout: TimeInterval = 86_400
    }
    enum Outcome: String, Codable, Sendable { case exited, cancelled, timedOut, launchFailed, ioFailed }
    struct Result: Codable, Sendable {
        let id: UUID
        let operationID: UUID
        let executable: String
        let outcome: Outcome
        let exitCode: Int32?
        let startedAt: Date
        let endedAt: Date
        let durationSeconds: Double
        let outputTruncated: Bool
        var diagnostics: URL?
        var diagnosticError: String?
        var output: String
        var tail: String
    }
    struct Failure: Error, LocalizedError {
        let result: Result
        var errorDescription: String? {
            "\(result.executable): \(result.outcome.rawValue), exit \(result.exitCode.map(String.init) ?? "not started"). \(result.tail.suffix(Policy.errorTailCharacters))\nDiagnostic ID: \(result.id)\(result.diagnosticError.map { "\nDiagnostics could not be saved: \($0)" } ?? "")"
        }
    }
    var policy = Policy()
    var diagnosticsDirectory = AppSettings.supportDirectory.appendingPathComponent("Diagnostics/Processes", isDirectory: true)
    private static let logger = Logger(subsystem: "com.moreaki.recscribe", category: "LocalProcess")

    func execute(_ binary: URL, _ arguments: [String], in directory: URL? = nil, cancel: WorkCancellation) throws -> Result {
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
        process.currentDirectoryURL = directory
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
        do { try process.run() }
        catch {
            return finish(id: id, binary: binary, outcome: .launchFailed, exitCode: nil,
                          started: started, clock: clock, cancel: cancel, prefix: Data(),
                          tail: Data(error.localizedDescription.utf8.prefix(policy.outputBytes)), truncated: false)
        }
        try pipe.fileHandleForWriting.close()
        var prefix = Data(), tail = Data(), truncated = false
        var buffer = [UInt8](repeating: 0, count: Policy.readBytes)
        // Limit each drain pass so even an endlessly writing child remains cancellable.
        func drain() throws -> Bool {
            for _ in 0..<Policy.drainReadsPerPass {
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
            outcome = .ioFailed
        }
        if outcome != .exited { stop(process, drain: { _ = try? drain() }) }
        process.waitUntilExit()
        for _ in 0..<Policy.finalDrainPasses {
            do { if try !drain() { break } }
            catch { if outcome == .exited { outcome = .ioFailed }; break }
        }
        if outcome == .exited { do { try cancel.check() } catch { outcome = .cancelled } }
        return finish(id: id, binary: binary, outcome: outcome, exitCode: process.terminationStatus,
                      started: started, clock: clock, cancel: cancel, prefix: prefix, tail: tail, truncated: truncated)
    }

    private func finish(id: UUID, binary: URL, outcome: Outcome, exitCode: Int32?, started: Date,
                        clock: ContinuousClock.Instant, cancel: WorkCancellation, prefix: Data, tail: Data, truncated: Bool) -> Result {
        let elapsed = clock.duration(to: .now).components
        let seconds = Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18
        var result = Result(id: id, operationID: cancel.id, executable: binary.lastPathComponent, outcome: outcome,
                            exitCode: exitCode, startedAt: started, endedAt: Date(), durationSeconds: seconds,
                            outputTruncated: truncated, output: String(decoding: prefix, as: UTF8.self),
                            tail: String(decoding: tail, as: UTF8.self))
        do { result.diagnostics = try retain(result) }
        catch { result.diagnosticError = error.localizedDescription }
        Self.logger.notice("Process id=\(id) operation=\(cancel.id) outcome=\(outcome.rawValue, privacy: .public) exit=\(exitCode.map(String.init) ?? "none", privacy: .public) duration_s=\(seconds) truncated=\(truncated) diagnostics_saved=\(result.diagnostics != nil)")
        return result
    }

    private func stop(_ process: Process, drain: () -> Void) {
        guard process.isRunning else { return }
        process.terminate()
        let deadline = ContinuousClock.now.advanced(by: .seconds(policy.terminationGrace))
        while process.isRunning && ContinuousClock.now < deadline { drain(); usleep(Policy.pollMicroseconds) }
        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        process.waitUntilExit()
    }

    private func retain(_ result: Result) throws -> URL {
        let manager = FileManager.default
        try manager.createDirectory(at: diagnosticsDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        guard try diagnosticsDirectory.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else {
            throw SessionError.invalid("Diagnostic directory must not be a symbolic link")
        }
        try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: diagnosticsDirectory.path)
        let destination = diagnosticsDirectory.appendingPathComponent("\(result.id).json")
        var diagnostic = result
        diagnostic.output = "" // Keep only the bounded tail, never two copies.
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(diagnostic)
        let fd = Darwin.open(destination.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard fd >= 0 else {
            throw SessionError.invalid("Cannot save local process diagnostics")
        }
        let file = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? file.close() }
        try file.write(contentsOf: data)
        try file.synchronize()
        let previous = try manager.contentsOfDirectory(at: diagnosticsDirectory, includingPropertiesForKeys: [.contentModificationDateKey])
            .filter { $0.pathExtension == "json" && UUID(uuidString: $0.deletingPathExtension().lastPathComponent) != nil }
            .sorted { (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                > (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast }
        for expired in previous.dropFirst(policy.retainedRuns) { try? manager.removeItem(at: expired) }
        return destination
    }

    static func run(_ binary: URL, _ arguments: [String], in directory: URL,
                    cancel: WorkCancellation, timeout: TimeInterval = Policy.defaultTimeout) throws -> String {
        var runner = Self()
        runner.policy.timeout = timeout
        let result = try runner.execute(binary, arguments, in: directory, cancel: cancel)
        if result.outcome == .cancelled { throw CancellationError() }
        guard result.outcome == .exited, result.exitCode == 0, result.diagnosticError == nil else { throw Failure(result: result) }
        return result.output
    }
}
