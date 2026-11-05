import Foundation
import CryptoKit

/// Keep the session together in Trash so restoring it also restores its audio.
nonisolated enum SessionDeletion {
    static let maximumRelatedJobs = 1_024
    static let maximumReferenceBytes = 1_024 * 1_024

    @discardableResult
    static func moveToTrash(_ manifest: URL, jobsDirectory: URL? = nil,
                            cancel: WorkCancellation = WorkCancellation(), expected: RecordingDeletionPlan.Item? = nil, includePlannedJobs: Bool = false, trash: (URL) throws -> Void = {
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
        var protectionLeases: [SessionLease] = []
        defer { withExtendedLifetime(protectionLeases) {} }
        if let expected {
            for (url, hash) in expected.protectedManifestHashes {
                try cancel.check()
                protectionLeases.append(try SessionLease(url))
                guard try RecordingSession.hash(url) == hash else {
                    throw SessionError.invalid("Another recording changed since confirmation. Review a new deletion preview.")
                }
            }
            for (url, hash) in expected.manifestHashes {
                guard try RecordingSession.hash(url) == hash else {
                    throw SessionError.invalid("Recording changed since confirmation. Review a new deletion preview.")
                }
            }
        }
        let jobs: [URL]
        var jobLeases: [SessionLease] = []
        defer { withExtendedLifetime(jobLeases) {} }
        if let expected {
            jobs = includePlannedJobs ? try expected.jobs.map { planned in
                try cancel.check()
                // Reject replaced/symlinked job folders before creating any lease sidecar.
                _ = try inspectJob(planned.url)
                jobLeases.append(try SessionLease(planned.url.appendingPathComponent("manifest.json")))
                let current = try inspectJob(planned.url)
                guard current.isTerminal, current.problem == nil, current.fingerprint == planned.fingerprint,
                      current.matches([session] + sourceSessions, beside: manifest) else {
                    throw SessionError.invalid("Transcription data changed since confirmation. Review a new deletion preview.")
                }
                return planned.url
            } : []
        } else {
            jobs = try jobsDirectory.map {
                try relatedJobs(to: session, beside: manifest, in: $0, cancel: cancel, sourceSessions: sourceSessions)
            } ?? []
        }
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

    struct JobEvidence: Sendable, Identifiable {
        let url: URL
        let identities: [UUID]
        let sourcePath: String?
        let sourceHash: String?
        let isTerminal: Bool
        let fingerprint: [String: String]
        let problem: String?
        var id: URL { url }
        func matches(_ sessions: [RecordingSession], beside manifest: URL) -> Bool {
            let ids = Set(sessions.map(\.id))
            if !identities.isEmpty { return identities.allSatisfy { ids.contains($0) } }
            return sessions.flatMap(\.parts).contains { part in
                guard let hash = part.sha256, hash.count == 64, hash == sourceHash, let sourcePath else { return false }
                return (try? RecordingSession.safeURL(part.path, beside: manifest).resolvingSymlinksInPath().standardizedFileURL.path)
                    == URL(fileURLWithPath: sourcePath).resolvingSymlinksInPath().standardizedFileURL.path
            }
        }
    }

    /// Scan once for a batch. Unknown, active or conflicting evidence is retained.
    static func scanJobs(in root: URL, cancel: WorkCancellation) throws -> [JobEvidence] {
        let manager = FileManager.default
        guard manager.fileExists(atPath: root.path) else { return [] }
        var enumerationError: (any Error)?
        guard try root.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]).isSymbolicLink != true,
              let iterator = manager.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                  options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants], errorHandler: { _, error in
                      enumerationError = error; return false
                  }) else { throw SessionError.invalid("Cannot inspect Jobs; keep transcripts or inspect them in Finder") }
        var result: [JobEvidence] = [], scanned = 0
        for case let found as URL in iterator {
            try cancel.check()
            scanned += 1
            guard scanned <= maximumRelatedJobs else { throw SessionError.invalid("Too many Jobs to inspect in one pass; keep transcripts or inspect them in Finder") }
            let job = root.appendingPathComponent(found.lastPathComponent, isDirectory: true)
            guard UUID(uuidString: job.lastPathComponent) != nil else { continue }
            do { result.append(try inspectJob(job)) }
            catch {
                result.append(.init(url: job, identities: [], sourcePath: nil, sourceHash: nil, isTerminal: false,
                                    fingerprint: [:], problem: error.localizedDescription))
            }
        }
        if let enumerationError { throw enumerationError }
        return result
    }

    static func inspectJob(_ job: URL) throws -> JobEvidence {
        struct Reference: Decodable { var session_id: UUID?; var path: String?; var sha256: String? }
        struct Snapshot: Decodable { let id: UUID }
        struct State: Decodable { let state: JobState }
        let manager = FileManager.default
        // URL resource values can be cached from preflight. Read current lstat-backed
        // attributes so replacing a planned directory with a symlink is detected.
        let type = try manager.attributesOfItem(atPath: job.path)[.type] as? FileAttributeType
        let rootType = try manager.attributesOfItem(atPath: job.deletingLastPathComponent().path)[.type] as? FileAttributeType
        guard type == .typeDirectory, rootType == .typeDirectory else {
            throw SessionError.invalid("Symbolic links and non-directory jobs are kept")
        }
        var fingerprints: [String: String] = [:]
        func read<Value: Decodable>(_ name: String, as type: Value.Type) throws -> Value? {
            let url = job.appendingPathComponent(name)
            guard manager.fileExists(atPath: url.path) else { return nil }
            guard try manager.attributesOfItem(atPath: url.path)[.type] as? FileAttributeType == .typeRegular else {
                throw SessionError.invalid("Unverifiable job reference")
            }
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            let data = try handle.read(upToCount: maximumReferenceBytes + 1) ?? Data()
            guard data.count <= maximumReferenceBytes else { throw SessionError.invalid("Job reference is too large") }
            fingerprints[name] = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            return try JSONDecoder().decode(type, from: data)
        }
        let state = try read("manifest.json", as: State.self)
        let reference = try read("audio-report.json", as: Reference.self)
        let snapshot = try read("source-session.snapshot.json", as: Snapshot.self)
        return .init(url: job, identities: [reference?.session_id, snapshot?.id].compactMap { $0 },
                     sourcePath: reference?.path, sourceHash: reference?.sha256, isTerminal: state?.state.isTerminal == true,
                     fingerprint: fingerprints, problem: state == nil ? "Missing job state" : nil)
    }

    static func relatedJobs(to session: RecordingSession, beside manifest: URL, in root: URL,
                            cancel: WorkCancellation, sourceSessions: [RecordingSession] = []) throws -> [URL] {
        try scanJobs(in: root, cancel: cancel).filter {
            $0.isTerminal && $0.problem == nil && $0.matches([session] + sourceSessions, beside: manifest)
        }.map(\.url)
    }
}
