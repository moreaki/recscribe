import Foundation

/// A frozen preview never expands to include files discovered after confirmation.
nonisolated struct RecordingDeletionPlan: Sendable, Identifiable {
    let id = UUID()
    struct Item: Sendable {
        let entry: SessionEntry
        let manifestHashes: [URL: String]
        let sessions: [RecordingSession]
        let files: Set<URL>
        var jobs: [SessionDeletion.JobEvidence] = []
        var protectedManifestHashes: [URL: String] = [:]
    }
    let items: [Item]
    let retained: [SessionDeletion.JobEvidence]
    let checkedJobs: Bool
    var jobCount: Int { items.reduce(0) { $0 + $1.jobs.count } }
}

nonisolated struct RecordingDeletionResult: Sendable {
    var moved: [URL] = []
    var jobs: [URL] = []
    var remaining: [URL] = []
    var failure: String?
    var stopped = false
    var summary: String {
        "\(moved.count) recording\(moved.count == 1 ? "" : "s") and \(jobs.count) transcript jobs moved to Trash"
    }
}

nonisolated enum RecordingDeletionPlanner {
    static func prepare(_ entries: [SessionEntry], library: [SessionEntry], jobsDirectory: URL?,
                        cancel: WorkCancellation) throws -> RecordingDeletionPlan {
        guard !entries.isEmpty, entries.count <= SessionDeletion.maximumRelatedJobs,
              library.count <= SessionDeletion.maximumRelatedJobs else {
            throw SessionError.invalid("Select between 1 and 1,024 recordings in one library")
        }
        let ids = Set(entries.map(\.id))
        guard ids.count == entries.count else { throw SessionError.invalid("Duplicate recording selection") }
        var items: [RecordingDeletionPlan.Item] = []
        var ownership: [URL: URL] = [:]
        var protectedHashes: [URL: String] = [:]
        // Include unselected recordings when detecting shared audio/source files.
        for entry in library where !ids.contains(entry.id) {
            try cancel.check()
            let item = try inspect(entry, cancel: cancel)
            for file in item.files { ownership[file] = entry.id }
            protectedHashes.merge(item.manifestHashes) { a, _ in a }
        }
        for entry in entries {
            var item = try inspect(entry, cancel: cancel)
            item.protectedManifestHashes = protectedHashes
            for file in item.files {
                guard ownership[file] == nil else {
                    throw SessionError.invalid("A recording file is shared with another recording. Inspect it in Finder before deleting: \(file.lastPathComponent)")
                }
                ownership[file] = entry.id
            }
            items.append(item)
        }
        let evidence = try jobsDirectory.map { try SessionDeletion.scanJobs(in: $0, cancel: cancel) } ?? []
        var retained: [SessionDeletion.JobEvidence] = []
        for job in evidence {
            try cancel.check()
            let matches = items.indices.filter { job.matches(items[$0].sessions, beside: items[$0].entry.id) }
            if matches.count == 1, job.isTerminal, job.problem == nil {
                items[matches[0]].jobs.append(job)
            } else if !matches.isEmpty || job.problem != nil || job.identities.isEmpty || items.contains(where: { !Set($0.sessions.map(\.id)).isDisjoint(with: job.identities) }) {
                retained.append(job)
            }
        }
        try cancel.check()
        return .init(items: items, retained: retained, checkedJobs: jobsDirectory != nil)
    }

    private static func inspect(_ entry: SessionEntry, cancel: WorkCancellation) throws -> RecordingDeletionPlan.Item {
        try cancel.check()
        let lease = try SessionLease(entry.id)
        defer { withExtendedLifetime(lease) {} }
        let session = try RecordingSession.read(entry.id)
        guard session.id == entry.session.id else { throw SessionError.invalid("Recording identity changed. Refresh and select it again.") }
        var sessions = [session], manifests = [entry.id], sourceLeases: [SessionLease] = []
        defer { withExtendedLifetime(sourceLeases) {} }
        for track in session.sourceTracks ?? [] where track.manifestPath != nil {
            let child = try LinkedSourceSessions.read(track, parent: session, at: entry.id)
            sourceLeases.append(try SessionLease(child.id))
            sessions.append(child.session); manifests.append(child.id)
        }
        var files = Set(manifests.map(\.standardizedFileURL))
        for session in sessions {
            for path in session.parts.map(\.path) + session.artifacts.map(\.path) {
                try cancel.check()
                files.insert(try RecordingSession.safeURL(path, beside: entry.id).standardizedFileURL)
            }
        }
        let hashes = try Dictionary(uniqueKeysWithValues: manifests.map { ($0, try RecordingSession.hash($0)) })
        return .init(entry: .init(id: entry.id, session: session), manifestHashes: hashes, sessions: sessions, files: files)
    }
}
