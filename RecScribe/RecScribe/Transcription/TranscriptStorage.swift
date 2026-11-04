import Foundation

nonisolated enum TranscriptStorage {
    /// Restoration needs a readable recording, not just a surviving derived job.
    static func validateSource(_ source: URL) throws {
        try Task.checkCancellation()
        if source.lastPathComponent.hasSuffix(".recscribe.json") {
            let session = try RecordingSession.read(source)
            guard !session.parts.isEmpty else { throw SessionError.invalid("Recording has no audio parts") }
            for part in session.parts {
                try Task.checkCancellation()
                try validateFile(RecordingSession.safeURL(part.path, beside: source))
            }
        } else {
            try validateFile(source)
        }
    }

    private static func validateFile(_ url: URL) throws {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey])
        guard values.isRegularFile == true else { throw SessionError.invalid("Recording is not a file") }
        let handle = try FileHandle(forReadingFrom: url)
        try handle.close()
    }

    /// Never offer deletion of an arbitrary directory selected in Open transcript.
    static func isManagedJob(_ job: URL, in root: URL) -> Bool {
        UUID(uuidString: job.lastPathComponent) != nil &&
            job.deletingLastPathComponent().standardizedFileURL == root.standardizedFileURL
    }

    static func moveToTrash(_ job: URL, in root: URL, cancel: WorkCancellation,
                            trash: (URL) throws -> Void) throws {
        try cancel.check()
        guard isManagedJob(job, in: root) else { throw SessionError.invalid("Not a RecScribe transcript job") }
        let values = try job.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else {
            throw SessionError.invalid("Transcript folder is not a regular directory")
        }
        // Terminal state is checked again on the worker immediately before Trash.
        let manifest = job.appendingPathComponent("manifest.json")
        let handle = try FileHandle(forReadingFrom: manifest)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: ManifestRepository.maximumJobManifestBytes + 1) ?? Data()
        guard data.count <= ManifestRepository.maximumJobManifestBytes else {
            throw SessionError.invalid("Job manifest is too large")
        }
        let state = try JSONDecoder().decode(JobSnapshot.self, from: data).validated()
        guard state.state.isTerminal else { throw SessionError.invalid("Wait for this transcript job to finish") }
        try cancel.check()
        try trash(job)
    }
}
