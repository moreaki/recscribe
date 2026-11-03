import Darwin
import Foundation

/// The canonical PCM16 RIFF layout emitted by RecScribe, not a general WAV parser.
/// RIFF fields remain UInt32; all file/sample arithmetic is checked in UInt64.
nonisolated struct PCM16WAV: Equatable, Sendable {
    static let headerBytes = 44
    static let riffOverhead = 36
    static let sampleBytes = MemoryLayout<Int16>.size
    static let bitDepth = sampleBytes * 8
    static let maximumPayload = UInt64(UInt32.max) - UInt64(riffOverhead)
    static let copyBlockBytes = 1 << 20 // Bound recovery RAM independently of recording duration.

    let sampleRate: UInt32
    let channels: UInt16
    let payloadBytes: UInt32
    var frameBytes: UInt64 { UInt64(channels) * UInt64(Self.sampleBytes) }
    var frames: UInt64 { UInt64(payloadBytes) / frameBytes }
    var fileBytes: UInt64 { UInt64(Self.headerBytes) + UInt64(payloadBytes) }

    init(sampleRate: Double, channels: Int, payloadBytes: UInt64 = 0) throws {
        guard sampleRate.isFinite, sampleRate.rounded() == sampleRate,
              sampleRate > 0, sampleRate <= Double(UInt32.max),
              channels > 0, channels <= Int(UInt16.max) / Self.sampleBytes else {
            throw WAVWriterError.invalidFormat
        }
        self.sampleRate = UInt32(sampleRate)
        self.channels = UInt16(channels)
        guard UInt64(self.sampleRate) * UInt64(channels * Self.sampleBytes) <= UInt32.max else {
            throw WAVWriterError.invalidFormat
        }
        guard payloadBytes <= Self.maximumPayload else { throw WAVWriterError.sizeLimit }
        self.payloadBytes = UInt32(payloadBytes)
    }

    init(header: Data) throws {
        enum Field {
            static let riffSize = 4, formatSize = 16, encoding = 20, channels = 22
            static let rate = 24, byteRate = 28, alignment = 32, bits = 34, payload = 40
        }
        guard header.count == Self.headerBytes,
              header[0..<4] == Data("RIFF".utf8), header[8..<12] == Data("WAVE".utf8),
              header[12..<16] == Data("fmt ".utf8), header[36..<40] == Data("data".utf8) else {
            throw WAVWriterError.invalidFormat
        }
        func number(_ offset: Int, bytes: Int = 4) -> UInt64 {
            (0..<bytes).reduce(0) { $0 | UInt64(header[offset + $1]) << ($1 * 8) }
        }
        try self.init(sampleRate: Double(number(Field.rate)), channels: Int(number(Field.channels, bytes: 2)),
                      payloadBytes: number(Field.payload))
        guard number(Field.formatSize) == 16, number(Field.encoding, bytes: 2) == 1,
              number(Field.bits, bytes: 2) == Self.bitDepth,
              number(Field.alignment, bytes: 2) == frameBytes,
              number(Field.byteRate) == UInt64(sampleRate) * frameBytes else {
            throw WAVWriterError.invalidFormat
        }
    }

    var header: Data {
        var data = Data()
        data.append(string: "RIFF")
        data.append(uint32: payloadBytes + UInt32(Self.riffOverhead))
        data.append(string: "WAVEfmt ")
        data.append(uint32: 16) // PCM format chunk length, fixed by RIFF.
        data.append(uint16: 1) // Linear PCM encoding.
        data.append(uint16: channels)
        data.append(uint32: sampleRate)
        data.append(uint32: sampleRate * UInt32(frameBytes))
        data.append(uint16: UInt16(frameBytes))
        data.append(uint16: UInt16(Self.bitDepth))
        data.append(string: "data")
        data.append(uint32: payloadBytes)
        return data
    }

    static func read(_ url: URL) throws -> Self {
        let input = try FileHandle(forReadingFrom: url)
        defer { try? input.close() }
        let bytes = try input.read(upToCount: headerBytes) ?? Data()
        let value = try Self(header: bytes)
        guard bytes == value.header, UInt64(value.payloadBytes).isMultiple(of: value.frameBytes) else {
            throw SessionError.invalid("WAV header needs recovery")
        }
        return value
    }

    /// Copy complete frames, sync, then atomically replace. Cancellation/error leaves
    /// the original intact. Caller must exclude live writers (SessionLease for sessions).
    @discardableResult
    static func repair(_ url: URL, expected: PCM16WAV? = nil, blockBytes: Int = copyBlockBytes,
                       write: (FileHandle, Data) throws -> Void = { try $0.write(contentsOf: $1) },
                       check: () throws -> Void = {}) throws -> UInt64 {
        guard blockBytes > 0 else { throw WAVWriterError.invalidFormat }
        try check()
        let original = try FileManager.default.attributesOfItem(atPath: url.path)
        let input = try FileHandle(forReadingFrom: url)
        defer { try? input.close() }
        let bytes = try input.read(upToCount: headerBytes) ?? Data()
        let format = try Self(header: bytes)
        if let expected, (format.sampleRate != expected.sampleRate || format.channels != expected.channels) {
            throw WAVWriterError.formatMismatch
        }
        let total = try input.seekToEnd()
        guard total >= headerBytes else { throw WAVWriterError.invalidFormat }
        let payload = (total - UInt64(headerBytes)) / format.frameBytes * format.frameBytes
        let repaired = try Self(sampleRate: Double(format.sampleRate), channels: Int(format.channels), payloadBytes: payload)
        if total == repaired.fileBytes && bytes == repaired.header { return repaired.frames }

        let temporary = url.deletingLastPathComponent().appendingPathComponent(".repair-\(UUID()).wav")
        let fd = Darwin.open(temporary.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        guard fd >= 0 else { throw WAVWriterError.fileCreationFailed }
        let output = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? output.close(); try? FileManager.default.removeItem(at: temporary) }
        try write(output, repaired.header)
        try input.seek(toOffset: UInt64(headerBytes))
        var remaining = payload
        while remaining > 0 {
            try check()
            let copied = try autoreleasepool {
                guard let data = try input.read(upToCount: Int(min(remaining, UInt64(blockBytes)))), !data.isEmpty else {
                    throw SessionError.invalid("WAV changed during recovery")
                }
                try write(output, data)
                return UInt64(data.count)
            }
            remaining -= copied
        }
        try output.synchronize()
        try output.close()
        try check()
        let current = try FileManager.default.attributesOfItem(atPath: url.path)
        guard original[.size] as? NSNumber == current[.size] as? NSNumber,
              original[.systemFileNumber] as? NSNumber == current[.systemFileNumber] as? NSNumber,
              original[.modificationDate] as? Date == current[.modificationDate] as? Date else {
            throw SessionError.invalid("WAV changed during recovery")
        }
        _ = try FileManager.default.replaceItemAt(url, withItemAt: temporary)
        return repaired.frames
    }
}
