import Foundation

/// whisper.cpp's Silero header, not the shared GGML magic alone. This catches
/// recognition models accidentally selected as VAD before any native process runs.
nonisolated enum VADModel {
    private static let prefix = Data([0x6c, 0x6d, 0x67, 0x67, 10, 0, 0, 0]) + Data("silero-16k".utf8)
    private static let versionFields = 3
    private static let layout: [UInt32] = [512, 64, 4] // Window, context, encoder layers from the Silero file format.
    static let guidance = "Select a whisper.cpp Silero VAD model, not a Whisper transcription model. VAD is optional; clear it to transcribe without it."

    static func validate(_ path: String) throws {
        guard !path.isEmpty else { return }
        let input = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
        defer { try? input.close() }
        guard try input.read(upToCount: prefix.count) == prefix else { throw SessionError.invalid(guidance) }
        let wordBytes = MemoryLayout<UInt32>.size
        let parameterBytes = (versionFields + layout.count) * wordBytes
        guard let data = try input.read(upToCount: parameterBytes), data.count == parameterBytes else { throw SessionError.invalid(guidance) }
        let parameters = stride(from: 0, to: data.count, by: wordBytes).map { offset in
            data[offset..<(offset + wordBytes)].enumerated().reduce(UInt32.zero) { $0 | UInt32($1.element) << ($1.offset * 8) }
        }
        guard Array(parameters.dropFirst(versionFields)) == layout else { throw SessionError.invalid(guidance) }
    }
}
