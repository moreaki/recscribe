import Foundation
import os

/// Keep the session together in Trash so restoring it also restores its audio.
nonisolated enum SessionDeletion {
    static let maximumRelatedJobs = 1_024
    static let maximumReferenceBytes = 1_024 * 1_024
    private static let logger = Logger(subsystem: "com.moreaki.recscribe", category: "SessionDeletion")

    @discardableResult
    static func moveToTrash(_ manifest: URL, jobsDirectory: URL? = nil,
                            cancel: WorkCancellation = WorkCancellation(), trash: (URL) throws -> Void = {
        try FileManager.default.trashItem(at: $0, resultingItemURL: nil)
    }) throws -> [URL] {
        try cancel.check()
        let lease = try SessionLease(manifest)
        defer { withExtendedLifetime(lease) {} }
        let session = try RecordingSession.read(manifest)
        let manager = FileManager.default
        var files: [URL] = []
        var names = session.parts.map(\.path) + session.artifacts.map(\.path)
        var sourceLeases: [SessionLease] = []
        var sourceSessions: [RecordingSession] = []
        defer { withExtendedLifetime(sourceLeases) {} }
        for track in session.sourceTracks ?? [] where track.manifestPath != nil {
            try cancel.check()
            let child = try LinkedSourceSessions.read(track, parent: session, at: manifest)
            sourceLeases.append(try SessionLease(child.id))
            sourceSessions.append(child.session)
            names += child.session.parts.map(\.path) + child.session.artifacts.map(\.path) + [child.id.lastPathComponent]
        }
        let jobs = try jobsDirectory.map {
            try relatedJobs(to: session, beside: manifest, in: $0, cancel: cancel, sourceSessions: sourceSessions)
        } ?? []
        for name in Set(names) {
            try cancel.check()
            let file = try RecordingSession.safeURL(name, beside: manifest)
            // Incomplete recordings can reference parts that were never created.
            guard manager.fileExists(atPath: file.path) else { continue }
            let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true else {
                throw SessionError.invalid("Recording contains a non-file or symbolic link; inspect it in Finder before deleting")
            }
            if file.standardizedFileURL != manifest.standardizedFileURL { files.append(file) }
        }
        files.append(manifest)
        let name = manifest.lastPathComponent.replacingOccurrences(of: ".recscribe.json", with: "")
        let bundle = manifest.deletingLastPathComponent()
            .appendingPathComponent("\(name)-Deleted-\(UUID().uuidString)", isDirectory: true)
        try manager.createDirectory(at: bundle, withIntermediateDirectories: false)
        var moved: [(original: URL, destination: URL)] = []
        do {
            let transcripts = bundle.appendingPathComponent("Transcripts", isDirectory: true)
            if !jobs.isEmpty { try manager.createDirectory(at: transcripts, withIntermediateDirectories: false) }
            for file in files {
                try cancel.check()
                let destination = bundle.appendingPathComponent(file.lastPathComponent)
                try manager.moveItem(at: file, to: destination)
                moved.append((file, destination))
            }
            for job in jobs {
                try cancel.check()
                let destination = transcripts.appendingPathComponent(job.lastPathComponent)
                try manager.moveItem(at: job, to: destination)
                moved.append((job, destination))
            }
            try cancel.check()
            try trash(bundle)
            return jobs
        } catch {
            let originalError = error
            var rollbackFailed = false
            for file in moved.reversed() {
                do { try manager.moveItem(at: file.destination, to: file.original) }
                catch { rollbackFailed = true }
            }
            if rollbackFailed {
                throw SessionError.invalid("Deletion failed. Some recording files remain in \(bundle.path). Restore them in Finder. \(originalError.localizedDescription)")
            }
            try? manager.removeItem(at: bundle)
            throw originalError
        }
    }

    /// A name/path alone is not a source identity. Match the session UUID (native
    /// reports or cloud snapshots), or an exact part path AND its recorded hash.
    static func relatedJobs(to session: RecordingSession, beside manifest: URL, in root: URL,
                            cancel: WorkCancellation, sourceSessions: [RecordingSession] = []) throws -> [URL] {
        struct Reference: Decodable {
            var session_id: UUID?
            var path: String?
            var sha256: String?
        }
        struct Snapshot: Decodable { let id: UUID }
        struct State: Decodable { let state: JobState }
        let manager = FileManager.default
        let sessionIDs = Set(([session] + sourceSessions).map(\.id))
        let parts = ([session] + sourceSessions).flatMap(\.parts)
        guard manager.fileExists(atPath: root.path) else { return [] }
        var enumerationError: (any Error)?
        guard try root.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]).isSymbolicLink != true,
              let iterator = manager.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                  options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants], errorHandler: { _, error in
                      enumerationError = error
                      return false
                  }) else {
            throw SessionError.invalid("Cannot inspect the Jobs directory; keep transcripts or inspect it in Finder")
        }
        func read<Value: Decodable>(_ name: String, in job: URL, as type: Value.Type) throws -> Value? {
            let url = job.appendingPathComponent(name)
            guard manager.fileExists(atPath: url.path) else { return nil }
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true else { return nil }
            let file = try FileHandle(forReadingFrom: url)
            defer { try? file.close() }
            let data = try file.read(upToCount: maximumReferenceBytes + 1) ?? Data()
            guard data.count <= maximumReferenceBytes else { throw SessionError.invalid("Job reference is too large") }
            return try JSONDecoder().decode(type, from: data)
        }
        var jobs: [URL] = []
        var scanned = 0
        for case let job as URL in iterator {
            try cancel.check()
            scanned += 1
            guard scanned <= maximumRelatedJobs else {
                throw SessionError.invalid("Too many Jobs to inspect in one pass; keep transcripts or inspect them in Finder")
            }
            let values = try job.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isDirectory == true, values.isSymbolicLink != true,
                  UUID(uuidString: job.lastPathComponent) != nil else { continue }
            do {
                guard let state = try read("manifest.json", in: job, as: State.self), state.state.isTerminal else { continue }
                let reference = try read("audio-report.json", in: job, as: Reference.self)
                let snapshot = try read("source-session.snapshot.json", in: job, as: Snapshot.self)
                let matchingPart = parts.contains { part in
                    guard let hash = part.sha256, hash.count == 64, hash == reference?.sha256,
                          let path = reference?.path else { return false }
                    return (try? RecordingSession.safeURL(part.path, beside: manifest).standardizedFileURL.path) == URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
                }
                let identities = [reference?.session_id, snapshot?.id].compactMap { $0 }
                let matches = identities.isEmpty ? matchingPart : identities.allSatisfy { sessionIDs.contains($0) }
                // Enumeration may rewrite /var to /private/var. Keep the caller's
                // root spelling so remembered job URLs can be cleared after Trash.
                if matches { jobs.append(root.appendingPathComponent(job.lastPathComponent, isDirectory: true)) }
            } catch {
                // Unverifiable evidence is retained, never guessed from a directory/file name.
                logger.error("Keeping unverifiable job path=\(job.path, privacy: .private) error=\(error.localizedDescription, privacy: .private)")
            }
        }
        if let enumerationError { throw enumerationError }
        return jobs
    }
}
