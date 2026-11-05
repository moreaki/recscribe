import CryptoKit
import Darwin
import Foundation

/// Acknowledgements are personal metadata, never changes to canonical evidence.
nonisolated struct TranscriptReviewContext: Equatable, Sendable {
    let job: URL
    let revision: String
    let keys: Set<String>

    init(job: URL, document: TranscriptPreview) throws {
        let items = document.reviewItems
        guard job.isFileURL, let revision = document.revision,
              Set(document.segments.map(\.id)).count == document.segments.count,
              Set(items.map(\.key)).count == items.count,
              items.count <= TranscriptReviewStore.maximumItems else {
            throw SessionError.invalid("Review status requires a saved transcript with unique source identifiers and at most 10,000 review items")
        }
        self.job = job.standardizedFileURL
        self.revision = revision
        self.keys = Set(items.map(\.key))
    }
}

actor TranscriptReviewStore {
    static let shared = TranscriptReviewStore(root: AppSettings.supportDirectory.appendingPathComponent("Review", isDirectory: true))
    nonisolated static let maximumItems = 10_000
    nonisolated static let maximumBytes = 1_024 * 1_024
    private let root: URL
    private struct Record: Codable {
        var version = 1
        let revision: String
        let checked: Set<String>
    }

    init(root: URL) { self.root = root }

    func load(_ context: TranscriptReviewContext) throws -> Set<String> {
        try validateRevision(context)
        return try read(context).intersection(context.keys)
    }

    func setChecked(_ key: String, checked: Bool, in context: TranscriptReviewContext) throws -> Set<String> {
        try Task.checkCancellation()
        guard context.keys.contains(key) else { throw SessionError.invalid("This review item is no longer available") }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let info = try root.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard info.isDirectory == true, info.isSymbolicLink != true else { throw SessionError.invalid("Review storage is not a regular directory") }
        let url = location(context)
        // The separate inode keeps atomic replacement safe across app processes.
        let lock = Darwin.open(url.appendingPathExtension("lock").path, O_RDWR | O_CREAT | O_NOFOLLOW, 0o600)
        guard lock >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { Darwin.close(lock) }
        guard flock(lock, LOCK_EX | LOCK_NB) == 0 else { throw SessionError.invalid("Review status is in use. Try again.") }
        try validateRevision(context)
        var next = try read(context).intersection(context.keys)
        if checked { next.insert(key) } else { next.remove(key) }
        let data = try JSONEncoder().encode(Record(revision: context.revision, checked: next))
        guard data.count <= Self.maximumBytes else { throw SessionError.invalid("Saved review status is too large") }
        try Task.checkCancellation()
        try data.write(to: url, options: .atomic)
        return next
    }

    private func validateRevision(_ context: TranscriptReviewContext) throws {
        try Task.checkCancellation()
        guard try TranscriptPreview.currentRevision(context.job) == context.revision else {
            throw SessionError.invalid("The transcript changed. Reload it before reviewing this version.")
        }
    }

    private func location(_ context: TranscriptReviewContext) -> URL {
        let key = SHA256.hash(data: Data(context.job.path.utf8)).map { String(format: "%02x", $0) }.joined()
        return root.appendingPathComponent(key + ".json")
    }

    private func read(_ context: TranscriptReviewContext) throws -> Set<String> {
        try Task.checkCancellation()
        let descriptor = Darwin.open(location(context).path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard descriptor >= 0 else {
            if errno == ENOENT { return [] }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        let file = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? file.close() }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_uid == getuid(), info.st_size >= 0, info.st_size <= Self.maximumBytes else {
            throw SessionError.invalid("Saved review status is not a small, regular file owned by this user")
        }
        let data = try file.read(upToCount: Self.maximumBytes + 1) ?? Data()
        guard data.count <= Self.maximumBytes else { throw SessionError.invalid("Saved review status is too large") }
        let record = try JSONDecoder().decode(Record.self, from: data)
        guard record.version == 1, record.checked.count <= Self.maximumItems,
              record.revision.count == 64, record.revision.allSatisfy(\.isHexDigit),
              record.checked.allSatisfy({ $0.count == 64 && $0.allSatisfy(\.isHexDigit) }) else {
            throw SessionError.invalid("Saved review status has an unsupported format")
        }
        try Task.checkCancellation()
        return record.revision == context.revision ? record.checked : []
    }
}
