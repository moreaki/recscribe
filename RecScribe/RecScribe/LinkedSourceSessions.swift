import Foundation

nonisolated enum LinkedSourceSessions {
    static func read(_ track: RecordingSession.SourceTrack, parent: RecordingSession, at manifest: URL) throws -> SessionEntry {
        guard let path = track.manifestPath else { throw SessionError.invalid("Selected \(track.role.rawValue) source has no saved audio") }
        let url = try RecordingSession.safeURL(path, beside: manifest)
        let child = try RecordingSession.read(url)
        guard child.parentSessionID == parent.id, child.sourceTracks == nil,
              child.captureEpoch == parent.captureEpoch, child.sampleRate == parent.sampleRate,
              child.channels == track.channels else { throw SessionError.invalid("Source session identity, timeline or format does not match its parent") }
        return .init(id: url, session: child)
    }
}
