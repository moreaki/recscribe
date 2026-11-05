import Foundation

/// Capture is PCM16 WAV. Compressed formats belong to post-recording archive
/// export and cannot be selected as a live encoder through this value.
nonisolated enum AudioFormat: String, CaseIterable, Sendable {
    case wav
    static let available = Self.allCases
    var fileExtension: String { rawValue }
    var shortName: String { "WAV" }
    var displayName: String { "WAV (Lossless)" }
    func makeEncoder() throws -> any AudioFileEncoder { WAVWriter() }
}
