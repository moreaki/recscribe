import CryptoKit
import Darwin
import Foundation

nonisolated struct TranscriptCorrection: Codable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable { case text, musicOnly }
    let kind: Kind
    let text: String?
    var cloud: SegmentCloudReference? = nil
    var acoustic: SegmentAcousticReference? = nil
    static let musicOnly = Self(kind: .musicOnly, text: nil)
    static let maximumTextBytes = 65_536
    var valid: Bool {
        switch kind {
        case .musicOnly: text == nil && cloud == nil && acoustic?.valid != false
        case .text: acoustic == nil && text.map { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.utf8.count <= Self.maximumTextBytes } == true && cloud?.valid != false
        }
    }
    var displayedText: String { kind == .musicOnly ? "[Music only]" : text ?? "" }
}

nonisolated struct TranscriptReviewSnapshot: Equatable, Sendable {
    var checked: Set<String> = []
    var corrections: [String: TranscriptCorrection] = [:]
}

/// Review metadata and manual corrections never rewrite canonical evidence.
nonisolated struct TranscriptReviewContext: Equatable, Sendable {
    let job: URL
    let revision: String
    let keys: Set<String>
    let segmentIDs: Set<String>
    let reviewKeysBySegment: [String: String]
    let globalKeys: Set<String>
    var corrections: [String: TranscriptCorrection]

    init(job: URL, document: TranscriptPreview) throws {
        let items = document.reviewItems
        guard job.isFileURL, let revision = document.revision,
              Set(document.segments.map(\.id)).count == document.segments.count,
              Set(items.map(\.key)).count == items.count,
              items.count <= TranscriptReviewStore.maximumItems,
              document.segments.count <= TranscriptReviewStore.maximumItems,
              document.segments.allSatisfy({ !$0.id.isEmpty && $0.id.utf8.count <= 1_024 }) else {
            throw SessionError.invalid("Review status requires a saved transcript with unique source identifiers and at most 10,000 review items")
        }
        self.job = job.standardizedFileURL
        self.revision = revision
        self.keys = Set(items.map(\.key))
        self.segmentIDs = Set(document.segments.map(\.id))
        self.globalKeys = Set(items.filter { $0.groupID == nil }.map(\.key))
        self.corrections = document.corrections
        let byGroup = Dictionary(uniqueKeysWithValues: items.compactMap { item in item.groupID.map { ($0, item.key) } })
        self.reviewKeysBySegment = Dictionary(uniqueKeysWithValues: document.readingGroups.flatMap { group in
            group.segments.compactMap { segment in byGroup[group.id].map { (segment.id, $0) } }
        })
    }
}

actor TranscriptReviewStore {
    static let shared = TranscriptReviewStore(root: AppSettings.supportDirectory.appendingPathComponent("Review", isDirectory: true))
    nonisolated static let maximumItems = 10_000
    nonisolated static let maximumBytes = 1_024 * 1_024
    private let root: URL
    private struct Record: Codable {
        var version = 4
        let revision: String
        let checked: Set<String>
        var corrections: [String: TranscriptCorrection]?
    }

    init(root: URL) { self.root = root }

    func load(_ context: TranscriptReviewContext) throws -> Set<String> {
        try loadSnapshot(context).checked
    }

    func loadSnapshot(_ context: TranscriptReviewContext) throws -> TranscriptReviewSnapshot {
        try validateRevision(context)
        return try read(context)
    }

    func setChecked(_ key: String, checked: Bool, in context: TranscriptReviewContext) throws -> Set<String> {
        try update(context) { next in
            guard context.keys.contains(key), next.corrections == context.corrections else {
                throw SessionError.invalid("This passage changed. Reload it before marking it checked.")
            }
            if checked { next.checked.insert(key) } else { next.checked.remove(key) }
        }.checked
    }

    func setCorrection(_ correction: TranscriptCorrection?, for segmentID: String,
                       in context: TranscriptReviewContext) throws -> TranscriptReviewSnapshot {
        guard context.segmentIDs.contains(segmentID), correction?.valid != false else {
            throw SessionError.invalid("Choose a passage and enter nonempty text of at most 64 KB, or mark it music only.")
        }
        return try update(context) { next in
            guard next.corrections[segmentID] == context.corrections[segmentID] else {
                throw SessionError.invalid("This passage was edited elsewhere. Reload before saving your correction.")
            }
            next.corrections[segmentID] = correction
            next.checked.subtract(context.globalKeys)
            if let key = context.reviewKeysBySegment[segmentID] { next.checked.remove(key) }
        }
    }

    private func update(_ context: TranscriptReviewContext,
                        change: (inout TranscriptReviewSnapshot) throws -> Void) throws -> TranscriptReviewSnapshot {
        try Task.checkCancellation()
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
        var next = try read(context)
        try change(&next)
        let data = try JSONEncoder().encode(Record(revision: context.revision, checked: next.checked, corrections: next.corrections))
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

    private func location(_ context: TranscriptReviewContext, legacy: Bool = false) -> URL {
        let key = SHA256.hash(data: Data(context.job.path.utf8)).map { String(format: "%02x", $0) }.joined()
        return root.appendingPathComponent(key + (legacy ? "" : "-" + context.revision) + ".json")
    }

    private func read(_ context: TranscriptReviewContext) throws -> TranscriptReviewSnapshot {
        try Task.checkCancellation()
        var descriptor = Darwin.open(location(context).path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        if descriptor < 0, errno == ENOENT {
            descriptor = Darwin.open(location(context, legacy: true).path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        }
        guard descriptor >= 0 else {
            if errno == ENOENT { return .init() }
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
        let corrections = record.corrections ?? [:]
        guard [1, 2, 3, 4].contains(record.version), record.version != 1 || corrections.isEmpty,
              record.version == 1 || record.corrections != nil,
              record.version >= 3 || corrections.values.allSatisfy({ $0.cloud == nil }),
              record.version == 4 || corrections.values.allSatisfy({ $0.acoustic == nil }),
              record.checked.count <= Self.maximumItems, corrections.count <= Self.maximumItems,
              corrections.allSatisfy({ !$0.key.isEmpty && $0.key.utf8.count <= 1_024 && $0.value.valid }),
              record.revision.count == 64, record.revision.allSatisfy(\.isHexDigit),
              record.checked.allSatisfy({ $0.count == 64 && $0.allSatisfy(\.isHexDigit) }) else {
            throw SessionError.invalid("Saved review status has an unsupported format")
        }
        try Task.checkCancellation()
        guard record.revision == context.revision else { return .init() }
        guard Set(corrections.keys).isSubset(of: context.segmentIDs) else {
            throw SessionError.invalid("Saved corrections reference unavailable passages")
        }
        return .init(checked: record.checked.intersection(context.keys), corrections: corrections)
    }
}
