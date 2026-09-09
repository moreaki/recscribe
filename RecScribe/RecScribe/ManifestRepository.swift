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
        result.entries.sort { $0.session.startedAt > $1.session.startedAt }
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
