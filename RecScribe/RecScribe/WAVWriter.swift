//
//  WAVWriter.swift
//  RecScribe
//
//  Writes PCM audio data to WAV file format
//

import Foundation
import AVFoundation
import Darwin

/// Errors that can occur during WAV file writing
enum WAVWriterError: Error, LocalizedError, Equatable {
    case fileCreationFailed
    case fileWriteFailed
    case invalidFormat
    case fileNotOpen
    /// A buffer arrived whose rate/channels differ from what the header declares.
    case formatMismatch
    case sizeLimit

    var errorDescription: String? {
        switch self {
        case .fileCreationFailed:
            return "Failed to create WAV file"
        case .fileWriteFailed:
            return "Failed to write audio data to file"
        case .invalidFormat:
            return "Invalid audio format"
        case .fileNotOpen:
            return "WAV file is not open for writing"
        case .formatMismatch:
            return "Audio format changed mid-recording"
        case .sizeLimit:
            return "WAV size limit reached; the partial recording has been preserved"
        }
    }

    var recoverySuggestion: String? {
        switch self {
        case .fileCreationFailed:
            return "Check if you have write permissions to the destination folder"
        case .fileWriteFailed:
            return "Check if there is enough disk space available"
        case .invalidFormat:
            return "Use 44.1kHz or 48kHz stereo format"
        case .fileNotOpen:
            return "Call createFile() before writing data"
        case .formatMismatch:
            return "Capture buffers must be normalised to the file's declared format before writing"
        case .sizeLimit:
            return "Start a new recording or use FLAC for long recordings"
        }
    }
}

/// Writes audio data to WAV file. The `.wav` conformer of `AudioFileEncoder` (BL-011).
nonisolated class WAVWriter: AudioFileEncoder {

    // MARK: - Properties

    private var fileHandle: FileHandle?
    private var fileURL: URL?
    private var sampleRate: Double = 44100.0
    private var channels: Int = 2
    private var bytesWritten: UInt32 = 0
    private var pcmData = Data()

    /// RIFF includes 36 bytes beyond the payload in its 32-bit size field.
    static func checkedDataSize(current: UInt32, adding: Int) throws -> UInt32 {
        guard adding >= 0, UInt64(current) + UInt64(adding) <= PCM16WAV.maximumPayload else {
            throw WAVWriterError.sizeLimit
        }
        return current + UInt32(adding)
    }

    /// Rewrite the header in place after this many buffers (~0.7s at 48kHz) so the
    /// on-disk file stays playable even if `finalize()` never runs (crash/force-quit).
    static let headerUpdateInterval = 32
    private var buffersSinceHeaderUpdate = 0

    // MARK: - Public Methods

    /// Create WAV file and write header
    /// - Parameters:
    ///   - url: File URL where WAV file will be created
    ///   - sampleRate: Sample rate (44100 or 48000)
    ///   - channels: Number of channels (1 for mono, 2 for stereo)
    /// - Throws: WAVWriterError if file creation fails
    func createFile(at url: URL, sampleRate: Double, channels: Int) throws {
        _ = try PCM16WAV(sampleRate: sampleRate, channels: channels)
        self.fileURL = url
        self.sampleRate = sampleRate
        self.channels = channels
        self.bytesWritten = 0
        self.buffersSinceHeaderUpdate = 0

        // Create the file
        let fd = Darwin.open(url.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        guard fd >= 0 else { throw WAVWriterError.fileCreationFailed }
        fileHandle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)

        // Write initial WAV header (will be updated in finalize())
        try writeWAVHeader(dataSize: 0)
    }

    /// Write audio buffer to file
    /// - Parameter buffer: AVAudioPCMBuffer containing audio data
    /// - Throws: WAVWriterError if write fails
    func writeBuffer(_ buffer: AVAudioPCMBuffer) throws {
        try writeFrames(buffer, offset: 0, count: Int(buffer.frameLength))
    }

    func writeFrames(_ buffer: AVAudioPCMBuffer, offset: Int, count: Int) throws {
        guard offset >= 0, count >= 0, offset <= Int(buffer.frameLength) - count else { throw WAVWriterError.invalidFormat }
        guard let fileHandle = fileHandle else {
            throw WAVWriterError.fileNotOpen
        }

        // The header was stamped with the rate and channel count `createFile`
        // was given, but the payload loop below interleaves using the *buffer's*
        // channel count. A mismatch is therefore silent corruption, not a bad
        // frame: a mono buffer written into a stereo-declared file reads back as
        // L/R pairs — half speed, an octave down — and a 44.1 kHz buffer plays
        // ~8.8% fast. `AudioFormatNormalizer` should make this unreachable; if it
        // is ever reached, refusing beats writing a pitch-shifted file (BL-112).
        //
        // Deliberately narrower than FLAC's full `AVAudioFormat` equality: these
        // two fields are what the header commits to, and interleaving is already
        // covered by the `floatChannelData` guard below.
        guard buffer.format.sampleRate == sampleRate,
              Int(buffer.format.channelCount) == channels else {
            throw WAVWriterError.formatMismatch
        }

        guard let floatChannelData = buffer.floatChannelData else {
            throw WAVWriterError.invalidFormat
        }

        let frameLength = count
        let channelCount = Int(buffer.format.channelCount)

        let byteCount = frameLength * channelCount * MemoryLayout<Int16>.size
        let nextSize = try Self.checkedDataSize(current: bytesWritten, adding: byteCount)
        // Reuse one interleaved payload instead of allocating an Array and Data
        // copy on every callback. Preserve the existing PCM quantization.
        pcmData.count = byteCount
        try pcmData.withUnsafeMutableBytes { raw in
            let samples = raw.bindMemory(to: Int16.self)
            for frame in 0..<frameLength {
                for channel in 0..<channelCount {
                    let value = floatChannelData[channel][frame + offset]
                    guard value.isFinite else { throw WAVWriterError.invalidFormat }
                    samples[frame * channelCount + channel] = Int16(max(-1, min(1, value)) * 32767).littleEndian
                }
            }
        }
        try fileHandle.write(contentsOf: pcmData)
        bytesWritten = nextSize

        // Periodically rewrite the header so the file is playable even if the
        // app is killed before finalize() runs.
        buffersSinceHeaderUpdate += 1
        if buffersSinceHeaderUpdate >= Self.headerUpdateInterval {
            buffersSinceHeaderUpdate = 0
            try updateHeaderInPlace()
        }
    }

    /// Overwrite the 44-byte header with the current data size, then seek back to
    /// the end so appending continues. A failed seek must stop writing, otherwise
    /// the next payload could overwrite the header or earlier audio.
    private func updateHeaderInPlace() throws {
        guard let fileHandle = fileHandle else { return }
        try fileHandle.seek(toOffset: 0)
        try fileHandle.write(contentsOf: createWAVHeader(dataSize: bytesWritten))
        try fileHandle.seekToEnd()
    }

    /// Finalize WAV file and update header with correct sizes
    /// - Throws: WAVWriterError if finalization fails
    func finalize() throws {
        guard let fileHandle = fileHandle, let fileURL = fileURL else {
            throw WAVWriterError.fileNotOpen
        }

        // Close the file
        defer { self.fileHandle = nil }
        try fileHandle.close()
        self.fileHandle = nil

        // Re-open for reading and writing to update header
        do {
            let handle = try FileHandle(forUpdating: fileURL)
            defer { try? handle.close() }

            // Seek to beginning and update header with actual data size
            try handle.seek(toOffset: 0)

            let headerData = try createWAVHeader(dataSize: bytesWritten)
            try handle.write(contentsOf: headerData)
        } catch {
            throw WAVWriterError.fileWriteFailed
        }
    }

    // MARK: - Private Methods

    /// Write initial WAV header to file
    /// - Parameter dataSize: Size of audio data (0 initially)
    /// - Throws: WAVWriterError if write fails
    private func writeWAVHeader(dataSize: UInt32) throws {
        guard let fileHandle = fileHandle else {
            throw WAVWriterError.fileNotOpen
        }

        let headerData = try createWAVHeader(dataSize: dataSize)
        try fileHandle.write(contentsOf: headerData)
    }

    /// Create WAV header data
    /// - Parameter dataSize: Size of audio data in bytes
    /// - Returns: WAV header as Data
    private func createWAVHeader(dataSize: UInt32) throws -> Data {
        try PCM16WAV(sampleRate: sampleRate, channels: channels, payloadBytes: UInt64(dataSize)).header
    }

    // MARK: - Cleanup

    deinit {
        try? fileHandle?.close()
    }
}

// MARK: - Data Extension Helpers

// `nonisolated` for the same reason the writer is: these run on
// `AudioRecorder.processingQueue`, and the app target would otherwise infer
// `@MainActor` on an unannotated extension.
nonisolated extension Data {
    mutating func append(string: String) {
        if let stringData = string.data(using: .ascii) {
            self.append(stringData)
        }
    }

    mutating func append(uint16: UInt16) {
        var value = uint16.littleEndian
        Swift.withUnsafeBytes(of: &value) { bytes in
            self.append(contentsOf: bytes)
        }
    }

    mutating func append(uint32: UInt32) {
        var value = uint32.littleEndian
        Swift.withUnsafeBytes(of: &value) { bytes in
            self.append(contentsOf: bytes)
        }
    }
}
