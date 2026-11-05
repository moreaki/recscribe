import AVFoundation
import Darwin
import Foundation

nonisolated protocol AudioFileEncoder: AnyObject {
    func createFile(at url: URL, sampleRate: Double, channels: Int) throws
    func writeBuffer(_ buffer: AVAudioPCMBuffer) throws
    func finalize() throws
}

enum WAVWriterError: Error, LocalizedError, Equatable {
    case fileCreationFailed, fileWriteFailed, invalidFormat, fileNotOpen, formatMismatch, sizeLimit

    var errorDescription: String? {
        switch self {
        case .fileCreationFailed: "Cannot create the recording file."
        case .fileWriteFailed: "Cannot save the recording data."
        case .invalidFormat: "The audio format is unsupported."
        case .fileNotOpen: "No recording file is open."
        case .formatMismatch: "The captured audio format differs from the recording format."
        case .sizeLimit: "The recording reached the WAV size limit; its audio has been preserved."
        }
    }

    var recoverySuggestion: String? {
        switch self {
        case .fileCreationFailed: "Choose a writable recording folder."
        case .fileWriteFailed: "Check the recording volume and its free space."
        case .invalidFormat, .formatMismatch: "Convert audio to the configured PCM format before writing."
        case .fileNotOpen: "Create a recording file before writing or finalizing."
        case .sizeLimit: "Continue in a new recording part."
        }
    }
}

/// Queue-confined PCM16 sink. Payload appends and header checkpoints use separate
/// file offsets, so updating the header never changes where the next samples go.
nonisolated final class WAVWriter: AudioFileEncoder {
    static let headerUpdateInterval = 32
    private var descriptor: Int32 = -1
    private var layout: PCM16WAV?
    private var payload: UInt32 = 0
    private var checkpointCountdown = headerUpdateInterval
    private var scratch = Data()
    private var failed = false

    static func checkedDataSize(current: UInt32, adding: Int) throws -> UInt32 {
        guard adding >= 0, UInt64(current) <= PCM16WAV.maximumPayload, UInt64(adding) <= PCM16WAV.maximumPayload - UInt64(current) else {
            throw WAVWriterError.sizeLimit
        }
        return current + UInt32(adding)
    }

    func createFile(at url: URL, sampleRate: Double, channels: Int) throws {
        guard descriptor == -1 else { throw WAVWriterError.fileCreationFailed }
        let format = try PCM16WAV(sampleRate: sampleRate, channels: channels)
        let opened = Darwin.open(url.path, O_CREAT | O_EXCL | O_WRONLY | O_CLOEXEC, 0o600)
        guard opened >= 0 else { throw WAVWriterError.fileCreationFailed }
        descriptor = opened
        do {
            try store(format.header, at: 0)
        } catch {
            Darwin.close(opened)
            descriptor = -1
            throw error
        }
        layout = format
        payload = 0
        failed = false
        checkpointCountdown = Self.headerUpdateInterval
    }

    func writeBuffer(_ buffer: AVAudioPCMBuffer) throws {
        try writeFrames(buffer, offset: 0, count: Int(buffer.frameLength))
    }

    func writeFrames(_ buffer: AVAudioPCMBuffer, offset: Int, count: Int) throws {
        guard descriptor >= 0, let layout else { throw WAVWriterError.fileNotOpen }
        guard !failed else { throw WAVWriterError.fileWriteFailed }
        guard offset >= 0, count >= 0, count <= Int(buffer.frameLength),
              offset <= Int(buffer.frameLength) - count else { throw WAVWriterError.invalidFormat }
        guard buffer.format.sampleRate == Double(layout.sampleRate),
              buffer.format.channelCount == AVAudioChannelCount(layout.channels) else {
            throw WAVWriterError.formatMismatch
        }
        guard buffer.format.commonFormat == .pcmFormatFloat32,
              let planes = buffer.floatChannelData else { throw WAVWriterError.invalidFormat }
        let channels = Int(layout.channels)
        let size = count.multipliedReportingOverflow(by: channels * PCM16WAV.sampleBytes)
        guard !size.overflow else { throw WAVWriterError.sizeLimit }
        let next = try Self.checkedDataSize(current: payload, adding: size.partialValue)
        scratch.count = size.partialValue
        try withExtendedLifetime(buffer) {
            try scratch.withUnsafeMutableBytes { bytes in
                let output = bytes.bindMemory(to: Int16.self)
                for channel in 0..<channels {
                    let plane = planes[buffer.format.isInterleaved ? 0 : channel]
                    let channelOffset = buffer.format.isInterleaved ? channel : 0
                    for frame in 0..<count {
                        let sample = plane[(offset + frame) * buffer.stride + channelOffset]
                        guard sample.isFinite else { throw WAVWriterError.invalidFormat }
                        // Preserve the established on-disk quantization contract.
                        let bounded = max(-1, min(sample, 1))
                        output[frame * channels + channel] = Int16(bounded * Float(Int16.max)).littleEndian
                    }
                }
            }
        }
        do {
            try store(scratch, at: off_t(PCM16WAV.headerBytes) + off_t(payload))
            payload = next
            checkpointCountdown -= 1
            if checkpointCountdown == 0 {
                try checkpoint()
                checkpointCountdown = Self.headerUpdateInterval
            }
        } catch {
            failed = true
            throw error
        }
    }

    func finalize() throws {
        guard descriptor >= 0 else { throw WAVWriterError.fileNotOpen }
        defer {
            Darwin.close(descriptor)
            descriptor = -1
            layout = nil
        }
        try checkpoint()
        guard fsync(descriptor) == 0 else { throw WAVWriterError.fileWriteFailed }
    }

    private func checkpoint() throws {
        guard let layout else { throw WAVWriterError.fileNotOpen }
        let header = try PCM16WAV(sampleRate: Double(layout.sampleRate), channels: Int(layout.channels),
                                  payloadBytes: UInt64(payload)).header
        try store(header, at: 0)
    }

    /// pwrite may complete partially or be interrupted. Retry only those cases;
    /// any other failure stops admission so later samples cannot cover a gap.
    private func store(_ data: Data, at position: off_t) throws {
        try data.withUnsafeBytes { raw in
            var done = 0
            while done < raw.count {
                let written = pwrite(descriptor, raw.baseAddress!.advanced(by: done), raw.count - done,
                                     position + off_t(done))
                if written < 0 && errno == EINTR { continue }
                guard written > 0 else { throw WAVWriterError.fileWriteFailed }
                done += written
            }
        }
    }

    deinit {
        if descriptor >= 0 { Darwin.close(descriptor) }
    }
}

nonisolated extension Data {
    mutating func append(string: String) { append(contentsOf: string.utf8) }
    mutating func append(uint16: UInt16) { appendLittleEndian(uint16) }
    mutating func append(uint32: UInt32) { appendLittleEndian(uint32) }
    private mutating func appendLittleEndian<T: FixedWidthInteger>(_ number: T) {
        for shift in stride(from: 0, to: T.bitWidth, by: 8) {
            append(UInt8(truncatingIfNeeded: number >> shift))
        }
    }
}
