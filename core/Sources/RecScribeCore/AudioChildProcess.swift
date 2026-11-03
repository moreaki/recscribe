import Darwin
import Foundation

/// A cancellable utility child for the CLI and app's audio adapter. Output is
/// drained with bounded memory and optionally retained inside the private job.
struct AudioChildProcess {
    static let versionTimeout: TimeInterval = 120
    static let recognitionTimeout: TimeInterval = 86_400
    private static let outputLimit = 128 * 1_024
    private static let terminationGrace: Duration = .seconds(5)
    static func run(_ binary: URL, _ arguments: [String], directory: URL, log: URL? = nil,
                    timeout: TimeInterval, check: @Sendable () throws -> Void) throws -> String {
        try check()
        let process = Process(), pipe = Pipe()
        process.executableURL = binary; process.arguments = arguments
        process.currentDirectoryURL = directory; process.qualityOfService = .utility
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = pipe; process.standardError = pipe
        let input = pipe.fileHandleForReading
        defer { try? input.close(); try? pipe.fileHandleForWriting.close() }
        guard fcntl(input.fileDescriptor, F_SETFL, fcntl(input.fileDescriptor, F_GETFL) | O_NONBLOCK) != -1 else { throw POSIXError(.EIO) }
        var prefix = Data(), tail = Data(), buffer = [UInt8](repeating: 0, count: 32 * 1_024)
        func drain() throws {
            for _ in 0..<8 {
                let count = Darwin.read(input.fileDescriptor, &buffer, buffer.count)
                if count == 0 { return }
                if count < 0 {
                    if errno == EAGAIN || errno == EINTR { return }
                    throw POSIXError(.EIO)
                }
                prefix.append(contentsOf: buffer.prefix(min(count, max(0, outputLimit - prefix.count))))
                tail.append(contentsOf: buffer.prefix(count))
                if tail.count > outputLimit { tail.removeFirst(tail.count - outputLimit) }
            }
        }
        func stop() {
            if process.isRunning { process.terminate() }
            let deadline = ContinuousClock.now.advanced(by: terminationGrace)
            while process.isRunning && ContinuousClock.now < deadline { try? drain(); usleep(20_000) }
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            process.waitUntilExit()
        }
        let started = ContinuousClock.now
        var launched = false
        do {
            try process.run(); launched = true; try pipe.fileHandleForWriting.close()
            while process.isRunning {
                try check()
                guard started.duration(to: .now) < .seconds(timeout) else { throw CoreFailure("Local speech process timed out") }
                try drain(); usleep(20_000)
            }
            process.waitUntilExit(); try drain(); try check()
            guard process.terminationStatus == 0 else { throw CoreFailure("Local speech process exited with status \(process.terminationStatus); inspect its retained job log") }
            if let log { try tail.write(to: log, options: .withoutOverwriting) }
            return String(decoding: prefix, as: UTF8.self)
        } catch {
            if launched { stop(); try? drain() }
            if let log { try? tail.write(to: log, options: .withoutOverwriting) }
            throw error
        }
    }
}
