import CryptoKit
import Foundation
import os

/// Synchronous, bounded file work; called only on the library's utility worker.
nonisolated struct SessionExporter {
    // One owned copy buffer; cancellation is checked between filesystem calls.
    static let defaultBlockBytes = 1_024 * 1_024
    private let blockBytes: Int
    private static let logger = Logger(subsystem: "com.moreaki.recscribe", category: "Export")

    init(blockBytes: Int = Self.defaultBlockBytes) {
        precondition(blockBytes > 0)
        self.blockBytes = blockBytes
    }

    func export(_ manifest: URL, to directory: URL, checkCancellation: () throws -> Void) throws -> URL {
        let id = UUID()
        let started = ContinuousClock.now
        var copiedBytes: Int64 = 0
        var completed = false
        Self.logger.notice("Export started id=\(id.uuidString, privacy: .public) block_bytes=\(blockBytes)")
        defer {
            Self.logger.notice("Export ended id=\(id.uuidString, privacy: .public) completed=\(completed) copied_bytes=\(copiedBytes) block_bytes=\(blockBytes) elapsed=\(String(describing: started.duration(to: .now)), privacy: .public)")
        }
        try checkCancellation()
        let lease = try SessionLease(manifest)
        defer { withExtendedLifetime(lease) {} }
        let session = try RecordingSession.read(manifest)
        guard !session.parts.isEmpty, session.parts.allSatisfy({ $0.status == "verified" }) else {
            throw SessionError.invalid("Verify or recover all parts before export")
        }
        let name = "\(manifest.deletingPathExtension().deletingPathExtension().lastPathComponent)-Export-\(id.uuidString)"
        let destination = directory.appendingPathComponent(name, isDirectory: true)
        let staging = destination.appendingPathExtension("partial")
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])

        let files = session.parts.map { ($0.path, $0.sha256) }
            + session.artifacts.map { ($0.path, Optional($0.sha256)) }
        for (name, expectedHash) in files {
            try checkCancellation()
            let source = try RecordingSession.safeURL(name, beside: manifest)
            let copy = staging.appendingPathComponent(name)
            guard try hash(source, checkCancellation: checkCancellation) == expectedHash else {
                throw SessionError.invalid("Source changed before export; incomplete export retained as .partial")
            }
            try copyFile(source, to: copy, copiedBytes: &copiedBytes, checkCancellation: checkCancellation)
            guard try hash(copy, checkCancellation: checkCancellation) == expectedHash else {
                throw SessionError.invalid("Export checksum mismatch; incomplete export retained as .partial")
            }
        }
        try checkCancellation()
        try session.save(staging.appendingPathComponent(manifest.lastPathComponent))
        try checkCancellation()
        // Commit point: only a fully verified directory loses its .partial suffix.
        // Cancellation after this point does not undo a successfully published export.
        try FileManager.default.moveItem(at: staging, to: destination)
        completed = true
        return destination
    }

    private func copyFile(_ source: URL, to destination: URL, copiedBytes: inout Int64,
                          checkCancellation: () throws -> Void) throws {
        try Data().write(to: destination, options: .withoutOverwriting)
        let output = try FileHandle(forWritingTo: destination)
        defer { try? output.close() }
        try readBlocks(source, checkCancellation: checkCancellation) { data in
            try output.write(contentsOf: data)
            copiedBytes += Int64(data.count)
        }
        try checkCancellation()
        try output.synchronize()
        try output.close()
    }

    private func hash(_ source: URL, checkCancellation: () throws -> Void) throws -> String {
        var digest = SHA256()
        try readBlocks(source, checkCancellation: checkCancellation) { digest.update(data: $0) }
        return digest.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private func readBlocks(_ source: URL, checkCancellation: () throws -> Void,
                            consume: (Data) throws -> Void) throws {
        let input = try FileHandle(forReadingFrom: source)
        defer { try? input.close() }
        while true {
            try checkCancellation()
            // Release Foundation's temporary objects after each block, not at
            // the end of a multi-GB export's worker/autorelease pool.
            let hasData = try autoreleasepool {
                guard let data = try input.read(upToCount: blockBytes), !data.isEmpty else { return false }
                try checkCancellation()
                try consume(data)
                return true
            }
            if !hasData { return }
        }
    }
}
