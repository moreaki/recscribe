import AVFoundation
import Foundation

/// One bounded converter per independent channel, shared by final jobs and live
/// drafts. The converter is flushed at EOF; it never downmixes distinct sources.
public struct NativeAudioPreparer: AudioPreparer {
    public static let sampleRate = 16_000
    public static let bufferFrames = 4_096
    private static let diskReserveBytes: Int64 = 64 * 1_024 * 1_024
    public init() {}
    public func prepare(_ source: URL, channel: Int, output: URL,
                        check: @Sendable () throws -> Void) throws -> JSONValue {
        try check()
        guard !FileManager.default.fileExists(atPath: output.path) else { throw CoreFailure("Working audio already exists") }
        let sourceLayout = try WAVAudio.layout(source, check: check)
        let frames = (sourceLayout.frames * Int64(Self.sampleRate) + Int64(sourceLayout.rate) - 1) / Int64(sourceLayout.rate) + 1
        let requiredBytes = frames * 2 + 44
        guard requiredBytes <= Int64(UInt32.max) else { throw CoreFailure("Normalized channel would exceed the RIFF/WAV size limit") }
        if let free = try output.deletingLastPathComponent().resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage,
           free < requiredBytes + Self.diskReserveBytes { throw CoreFailure("Not enough free space to prepare the working channel") }
        let started = ContinuousClock.now
        try Self.convert(source, channel: channel, to: output, check: check)
        let layout = try WAVAudio.layout(output, check: check)
        guard layout.channels == 1, layout.rate == Self.sampleRate, layout.width == 2 else { throw CoreFailure("Unexpected normalized audio format") }
        return ["channel": .integer(Int64(channel)), "path": .string(output.lastPathComponent),
            "sha256": .string(try WAVAudio.hash(output, check: check)), "normalizer": "AVAudioConverter",
            "duration_seconds": .number(TextJob.seconds(since: started)), "sample_rate": .integer(Int64(Self.sampleRate)), "bit_depth": 16]
    }
    @discardableResult
    public static func convert(_ source: URL, channel: Int, to destination: URL,
                               sampleRate: Int = Self.sampleRate, check: () throws -> Void) throws -> Bool {
        let input = try AVAudioFile(forReading: source)
        guard (0..<Int(input.processingFormat.channelCount)).contains(channel),
              let format = AVAudioFormat(standardFormatWithSampleRate: Double(sampleRate), channels: 1),
              let converter = AVAudioConverter(from: input.processingFormat, to: format),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(bufferFrames)) else {
            throw CoreFailure("Invalid audio conversion format")
        }
        converter.channelMap = [NSNumber(value: channel)]
        let output = try AVAudioFile(forWriting: destination, settings: [AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate, AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false])
        let feeder = ConverterInput(input)
        var hasSignal = false
        while true {
            try check()
            var error: NSError?
            let status = converter.convert(to: buffer, error: &error) { count, state in feeder.read(count, state) }
            if let error = feeder.error ?? error { throw error }
            guard status != .error else { throw CoreFailure("Audio conversion failed") }
            if buffer.frameLength > 0 {
                if !hasSignal, let samples = buffer.floatChannelData?[0] {
                    hasSignal = (0..<Int(buffer.frameLength)).contains { samples[$0] != 0 }
                }
                try output.write(from: buffer)
            }
            if status == .endOfStream { break }
        }
        return hasSignal
    }
}

/// AVAudioConverter invokes the feeder synchronously; its mutable read cursor
/// remains on the owning utility worker and is never shared between converters.
private final class ConverterInput: @unchecked Sendable {
    let file: AVAudioFile
    var error: NSError?
    init(_ file: AVAudioFile) { self.file = file }
    func read(_ count: AVAudioPacketCount, _ status: UnsafeMutablePointer<AVAudioConverterInputStatus>) -> AVAudioBuffer? {
        guard file.framePosition < file.length else { status.pointee = .endOfStream; return nil }
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: min(count, AVAudioFrameCount(NativeAudioPreparer.bufferFrames))) else {
            error = NSError(domain: NSOSStatusErrorDomain, code: Int(memFullErr)); status.pointee = .endOfStream; return nil
        }
        do { try file.read(into: buffer); status.pointee = .haveData; return buffer }
        catch { self.error = error as NSError; status.pointee = .endOfStream; return nil }
    }
}
