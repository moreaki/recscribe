import CryptoKit
import Darwin
import Foundation

nonisolated struct TranscriptCorrection: Codable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable { case text, musicOnly }
    let kind: Kind
    let text: String?
    var cloud: SegmentCloudReference? = nil
    var acoustic: SegmentAcousticReference? = nil
    var automatic: AutomaticMusicEvidence? = nil
    static let musicOnly = Self(kind: .musicOnly, text: nil)
    static let maximumTextBytes = 65_536
    var valid: Bool {
        switch kind {
        case .musicOnly: text == nil && cloud == nil && acoustic?.valid != false
            && (automatic == nil || (automatic?.valid == true && acoustic != nil))
        case .text: automatic == nil && acoustic == nil && text.map { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.utf8.count <= Self.maximumTextBytes } == true && cloud?.valid != false
        }
    }
    var displayedText: String { kind == .musicOnly ? "[Music only]" : text ?? "" }
}

nonisolated struct TranscriptReviewSnapshot: Equatable, Sendable {
    var checked: Set<String> = []
    var corrections: [String: TranscriptCorrection] = [:]
    var automaticDismissals: Set<String> = []
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
        var version = 5
        let revision: String
        let checked: Set<String>
        var corrections: [String: TranscriptCorrection]?
        var automaticDismissals: Set<String>?
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
            // Any manual choice, including restoring original words, takes
            // precedence over subsequent automatic scans of this revision.
            next.automaticDismissals.insert(segmentID)
            next.checked.subtract(context.globalKeys)
            if let key = context.reviewKeysBySegment[segmentID] { next.checked.remove(key) }
        }
    }

    func suppressAutomatically(_ candidate: SegmentAcousticCandidate,
                               in context: TranscriptReviewContext) throws -> TranscriptReviewSnapshot {
        let selection = candidate.selection, id = selection.segmentID
        guard context.job == selection.job, context.revision == selection.revision,
              context.segmentIDs.contains(id), selection.baseline == nil,
              candidate.reference.startMs == selection.startMs, candidate.reference.endMs == selection.endMs,
              candidate.reference.channel == selection.channel,
              candidate.reference.audioSHA256 == candidate.report.sourceSHA256,
              AutomaticMusicEvidence.permits(candidate.report), let correction = candidate.correction else {
            throw SessionError.invalid("Automatic music analysis no longer matches this passage")
        }
        try selection.validate()
        let evidence = AutomaticMusicEvidence(candidate)
        try evidence.validate(candidate.reference)
        return try update(context) { next in
            // Merge against disk under the same lock as manual saves. Never
            // overwrite a newer edit, restoration or an already checked source.
            guard next.corrections[id] == nil, !next.automaticDismissals.contains(id),
                  context.reviewKeysBySegment[id].map({ !next.checked.contains($0) }) ?? true else { return }
            var automatic = correction
            automatic.automatic = evidence
            next.corrections[id] = automatic
            next.checked.subtract(context.globalKeys)
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
        let data = try JSONEncoder().encode(Record(revision: context.revision, checked: next.checked,
            corrections: next.corrections, automaticDismissals: next.automaticDismissals))
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
        var corrections = record.corrections ?? [:]
        let dismissals = record.automaticDismissals ?? []
        guard [1, 2, 3, 4, 5].contains(record.version), record.version != 1 || corrections.isEmpty,
              record.version == 1 || record.corrections != nil,
              record.version >= 3 || corrections.values.allSatisfy({ $0.cloud == nil }),
              record.version >= 4 || corrections.values.allSatisfy({ $0.acoustic == nil }),
              record.version >= 5 || (record.automaticDismissals == nil && corrections.values.allSatisfy({ $0.automatic == nil })),
              dismissals.count <= Self.maximumItems,
              dismissals.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 1_024 }),
              record.checked.count <= Self.maximumItems, corrections.count <= Self.maximumItems,
              corrections.allSatisfy({ !$0.key.isEmpty && $0.key.utf8.count <= 1_024 && $0.value.valid }),
              record.revision.count == 64, record.revision.allSatisfy(\.isHexDigit),
              record.checked.allSatisfy({ $0.count == 64 && $0.allSatisfy(\.isHexDigit) }) else {
            throw SessionError.invalid("Saved review status has an unsupported format")
        }
        try Task.checkCancellation()
        guard record.revision == context.revision else { return .init() }
        guard Set(corrections.keys).union(dismissals).isSubset(of: context.segmentIDs) else {
            throw SessionError.invalid("Saved corrections reference unavailable passages")
        }
        var checked = record.checked.intersection(context.keys)
        for (id, correction) in corrections where correction.automatic != nil {
            do {
                guard correction.automatic!.segmentID == id, correction.automatic!.revision == context.revision else {
                    throw SessionError.invalid("Automatic music evidence belongs to another passage")
                }
                try correction.automatic!.validate(correction.acoustic!)
            }
            catch is CancellationError { throw CancellationError() }
            catch {
                // Missing/stale evidence restores words, without disturbing manual
                // corrections or rewriting canonical/raw recognition.
                corrections.removeValue(forKey: id)
                checked.subtract(context.globalKeys)
                if let key = context.reviewKeysBySegment[id] { checked.remove(key) }
            }
        }
        return .init(checked: checked, corrections: corrections, automaticDismissals: dismissals)
    }
}
