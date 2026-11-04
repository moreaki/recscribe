import Foundation

nonisolated enum SessionStatus: String, Codable, Sendable {
    case recording, finalized, verified, completed
    case needsReview = "needs_review"
    var label: String { rawValue.replacingOccurrences(of: "_", with: " ") }
}
nonisolated enum PartStatus: String, Codable, Sendable {
    case opening, recording, finalized, verified
    case needsReview = "needs_review"
}
nonisolated enum JobState: String, Codable, Sendable {
    case queued, inspecting, preparing, transcribing, validating, rendering, completed, failed, cancelled
    case inspectingSession = "inspecting-session", transcribingParts = "transcribing-parts"
    case postProcessing = "post-processing", completedWithReview = "completed_with_review"
    var isTerminal: Bool { [.completed, .completedWithReview, .failed, .cancelled].contains(self) }
    var label: String { rawValue.replacingOccurrences(of: "_", with: " ").replacingOccurrences(of: "-", with: " ") }
}
nonisolated struct SessionEntry: Identifiable, Sendable {
    var id: URL
    var session: RecordingSession
    var hasUnfinalizedSource = false
    var needsRecovery: Bool { session.needsRecovery || hasUnfinalizedSource }
    var filenameStem: String { id.lastPathComponent.replacingOccurrences(of: ".recscribe.json", with: "") }
    var displayTitle: String {
        if let title = session.title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty {
            return title
        }
        // Only replace our generated timestamp names. Imported/custom file names
        // remain meaningful, and the original path stays available separately.
        if filenameStem.range(of: #"^recording_\d{4}-\d{2}-\d{2}_\d{2}-\d{2}-\d{2}( \(\d+\))*$"#,
                              options: .regularExpression) != nil {
            let suffix = filenameStem.dropFirst("recording_yyyy-MM-dd_HH-mm-ss".count)
            return "Recording · \(session.startedAt.formatted(date: .abbreviated, time: .standard))\(suffix)"
        }
        return filenameStem
    }
}
nonisolated struct ManifestFailure: Identifiable, Sendable {
    let id: URL
    let message: String
}
nonisolated struct SessionSnapshot: Sendable {
    var entries: [SessionEntry] = []
    var failures: [ManifestFailure] = []
}
nonisolated struct JobSnapshot: Decodable, Sendable {
    static let currentSchemaVersion = "1.0"
    let schemaVersion: String
    let state: JobState
    let progress: Double
    var detail: String? = nil
    var displayLabel: String { state.isTerminal ? state.label : detail ?? state.label }
    enum CodingKeys: String, CodingKey { case schemaVersion = "schema_version", state, progress, detail }
    func validated() throws -> Self {
        guard schemaVersion == Self.currentSchemaVersion, progress.isFinite, (0...1).contains(progress),
              ![JobState.completed, .completedWithReview].contains(state) || progress == 1 else {
            throw SessionError.invalid("Unsupported job manifest schema or progress")
        }
        return self
    }
}

/// All enumeration, bounded reads and decoding execute off MainActor. Unknown
/// schema/state values are visible read failures, never silently treated as success.
actor ManifestRepository {
    static let maximumJobManifestBytes = 16 * 1_024 * 1_024
    private let readSession: @Sendable (URL) throws -> RecordingSession
    init(readSession: @escaping @Sendable (URL) throws -> RecordingSession = { try RecordingSession.read($0) }) {
        self.readSession = readSession
    }
    func sessions(in directory: URL) throws -> SessionSnapshot {
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        var result = SessionSnapshot()
        for url in files where url.lastPathComponent.hasSuffix(".recscribe.json") {
            try Task.checkCancellation()
            do {
                let session = try autoreleasepool { try readSession(url) }
                result.entries.append(SessionEntry(id: url, session: session))
            } catch { result.failures.append(ManifestFailure(id: url, message: error.localizedDescription)) }
        }
        try Task.checkCancellation()
        let roots = Set(result.entries.filter { $0.session.parentSessionID == nil }.map { $0.session.id })
        let unfinalizedParents = Set(
            result.entries.compactMap { $0.session.needsRecovery ? $0.session.parentSessionID : nil }
        )
        result.entries.removeAll { $0.session.parentSessionID.map { roots.contains($0) } ?? false }
        for index in result.entries.indices where unfinalizedParents.contains(result.entries[index].session.id) {
            result.entries[index].hasUnfinalizedSource = true
        }
        result.entries.sort {
            if $0.session.startedAt != $1.session.startedAt {
                return $0.session.startedAt > $1.session.startedAt
            }
            return $0.id.lastPathComponent < $1.id.lastPathComponent
        }
        result.failures.sort { $0.id.lastPathComponent < $1.id.lastPathComponent }
        return result
    }

    func job(at url: URL) throws -> JobSnapshot {
        try Task.checkCancellation()
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: Self.maximumJobManifestBytes + 1) ?? Data()
        guard data.count <= Self.maximumJobManifestBytes else { throw SessionError.invalid("Job manifest is too large") }
        let result = try JSONDecoder().decode(JobSnapshot.self, from: data).validated()
        try Task.checkCancellation()
        return result
    }
}
