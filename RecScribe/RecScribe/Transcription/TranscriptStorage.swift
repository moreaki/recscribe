import Foundation

nonisolated struct RecordingTranscriptLink: Sendable {
    let job: URL
    let needsReview: Bool
    let hasSummary: Bool
}

nonisolated enum TranscriptStorage {
    /// Reuse the bounded identity scan; never infer ownership from a filename.
    /// Only small job metadata is decoded, not every transcript or audio file.
    static func recordingLinks(_ entries: [SessionEntry], in root: URL, cancel: WorkCancellation) throws -> [URL: RecordingTranscriptLink] {
        let evidence = try SessionDeletion.scanJobs(in: root, cancel: cancel)
        let byIdentity = Dictionary(grouping: entries, by: { $0.session.id })
        var byHash: [String: [SessionEntry]] = [:]
        for entry in entries {
            try cancel.check()
            for hash in Set(entry.session.parts.compactMap(\.sha256)) { byHash[hash, default: []].append(entry) }
        }
        var result: [URL: RecordingTranscriptLink] = [:], dates: [URL: Date] = [:]
        let manager = FileManager.default
        for item in evidence where item.problem == nil && item.isTerminal {
            try cancel.check()
            let candidates: [SessionEntry]
            if let identity = item.identities.first {
                // Duplicate session IDs are ambiguous even when the title differs.
                let found = byIdentity[identity] ?? []
                candidates = found.count == 1 ? found : []
            } else { candidates = item.sourceHash.flatMap { byHash[$0] } ?? [] }
            let matches = candidates.filter { item.matches([$0.session], beside: $0.id) }
            guard !matches.isEmpty else { continue }
            do {
                let manifest = item.url.appendingPathComponent("manifest.json")
                let file = try FileHandle(forReadingFrom: manifest)
                let data: Data
                do { data = try file.read(upToCount: ManifestRepository.maximumJobManifestBytes + 1) ?? Data() }
                catch { try? file.close(); throw error }
                try? file.close()
                guard data.count <= ManifestRepository.maximumJobManifestBytes else { continue }
                let state = try JSONDecoder().decode(JobSnapshot.self, from: data).validated()
                guard [.completed, .completedWithReview].contains(state.state) else { continue }
                func hasFile(_ name: String) -> Bool {
                    guard let values = try? manager.attributesOfItem(atPath: item.url.appendingPathComponent(name).path),
                          values[.type] as? FileAttributeType == .typeRegular,
                          let size = values[.size] as? NSNumber else { return false }
                    return size.int64Value > 0
                }
                guard hasFile("transcript.json") else { continue }
                let date = (try manifest.resourceValues(forKeys: [.contentModificationDateKey])).contentModificationDate ?? .distantPast
                for entry in matches where date > (dates[entry.id] ?? .distantPast) || result[entry.id] == nil {
                    dates[entry.id] = date
                    result[entry.id] = .init(job: item.url, needsReview: state.state == .completedWithReview, hasSummary: hasFile("summary.txt"))
                }
            } catch { continue } // Unverifiable jobs remain available through Artifacts.
        }
        try cancel.check()
        return result
    }

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
