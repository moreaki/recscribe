import Foundation
import Testing
@testable import RecScribe

@MainActor struct PCM16WAVTests {
    @Test func headerRoundTripsAndChecksWideSizes() throws {
        let header = try PCM16WAV(sampleRate: 48_000, channels: 2, payloadBytes: 400)
        #expect(try PCM16WAV(header: header.header) == header)
        #expect(header.frames == 100)
        #expect(header.header.count == PCM16WAV.headerBytes)
        #expect(throws: WAVWriterError.sizeLimit) {
            try PCM16WAV(sampleRate: 48_000, channels: 2, payloadBytes: PCM16WAV.maximumPayload + 1)
        }
        #expect(throws: WAVWriterError.invalidFormat) { try PCM16WAV(sampleRate: .nan, channels: 2) }
        #expect(throws: WAVWriterError.invalidFormat) { try PCM16WAV(sampleRate: 48_000, channels: Int.max) }
        var invalid = header.header
        invalid[32] = 1 // Block alignment must agree with channels and bit depth.
        #expect(throws: WAVWriterError.invalidFormat) { try PCM16WAV(header: invalid) }
    }

    @Test func recoverySharesHeaderRulesAndTrimsOnlyIncompleteFrames() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let format = try PCM16WAV(sampleRate: 48_000, channels: 2)
        let audio = Data((0..<19).map(UInt8.init)) // Four complete stereo frames + three bytes.
        for name in ["legacy.wav", "session.wav"] {
            let url = root.appendingPathComponent(name)
            try (format.header + audio).write(to: url)
            #expect(try WAVWriter.isUnfinalized(at: url))
            if name == "legacy.wav" { try WAVWriter.repair(at: url) }
            else { #expect(try PCM16WAV.repair(url, expected: format, blockBytes: 3) == 4) }
            let repaired = try Data(contentsOf: url)
            #expect(repaired.dropFirst(PCM16WAV.headerBytes) == audio.prefix(16))
            #expect(try PCM16WAV.read(url).frames == 4)
            #expect(try !WAVWriter.isUnfinalized(at: url))
        }
    }

    @Test func interruptedOrFailedCopyPreservesOriginal() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("original.wav")
        let bytes = try PCM16WAV(sampleRate: 16_000, channels: 1).header + Data(repeating: 7, count: 100)
        try bytes.write(to: url)
        for failure in [CancellationError() as any Error, CocoaError(.fileWriteOutOfSpace)] {
            var checks = 0
            #expect(throws: (any Error).self) {
                try PCM16WAV.repair(url, blockBytes: 2) {
                    checks += 1
                    if checks == 3 { throw failure }
                }
            }
            #expect(try Data(contentsOf: url) == bytes)
            #expect(try FileManager.default.contentsOfDirectory(atPath: root.path) == ["original.wav"])
        }
    }
}
