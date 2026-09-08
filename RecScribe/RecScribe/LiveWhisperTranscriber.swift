import AVFoundation
import Foundation
import os

/// Native preparation + the existing replaceable whisper.cpp executable. No
/// Python launch, model hashing or version probe per chunk. One ASR child at a
/// time leaves capture headroom; Metal remains whisper.cpp's default backend.
nonisolated enum LiveWhisperTranscriber {
    private static let logger = Logger(subsystem: "com.moreaki.recscribe", category: "LiveTranscription")

    static func step(manifest: URL, directory: URL, cursor: Int64, finished: Bool,
                     settings: AppSettings.Values, cancel: WorkCancellation) throws -> LiveChunkResult? {
        try cancel.check()
        let manager = FileManager.default
        guard manager.isExecutableFile(atPath: settings.whisperPath),
              manager.isReadableFile(atPath: settings.modelPath),
              LiveTranscriptionPolicy.threadRange.contains(settings.liveThreads) else {
            throw SessionError.invalid("Select an installed Whisper executable and model in Settings → Models")
        }
        let clock = ContinuousClock.now
        let attempt = directory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try manager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try manager.createDirectory(at: attempt, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let source = attempt.appendingPathComponent("working.wav")
        var keepEvidence = false
        defer {
            // Only this attempt's disposable working audio, never original recordings.
            try? manager.removeItem(at: source)
            if !keepEvidence { try? manager.removeItem(at: attempt) }
        }
        guard let available = DiskSpace.availableBytes(at: attempt), available >= DiskSpace.minimumBytesToRecord else {
            throw SessionError.diskFull
        }
        guard let slice = try LiveAudioReader.copy(manifest: manifest, cursor: cursor,
            seconds: settings.liveChunkSeconds, overlapSeconds: LiveTranscriptionPolicy.overlapSeconds,
            finished: finished, to: source, cancel: cancel) else { return nil }
        keepEvidence = true
        var segments: [LiveSegment] = []
        var asrRuns = 0
        let channels = slice.identicalChannels ? [0] : Array(0..<slice.channels)
        for channel in channels {
            try cancel.check()
            let audio = attempt.appendingPathComponent("channel-\(channel).wav")
            defer { try? manager.removeItem(at: audio) }
            guard try convert(source, channel: channel, to: audio, cancel: cancel) else {
                try Data("Digital silence; no ASR run.\n".utf8).write(to: attempt.appendingPathComponent("channel-\(channel).silence.txt"))
                continue
            }
            let output = attempt.appendingPathComponent("channel-\(channel).raw")
            let language = settings.sourceLanguage == "auto" ? "auto" : String(settings.sourceLanguage.split(separator: "-").first ?? "auto")
            let arguments = ["-m", settings.modelPath, "-f", audio.path, "-l", language,
                             "-ojf", "-of", output.path, "-t", String(settings.liveThreads), "-tp", "0", "-mc", "0"]
            _ = try LocalProcessRunner.run(URL(fileURLWithPath: settings.whisperPath), arguments,
                                          in: attempt, cancel: cancel, timeout: LiveTranscriptionPolicy.timeout)
            asrRuns += 1
            segments += try parse(output.appendingPathExtension("json"), slice: slice, cursor: cursor, channel: channel)
        }
        try cancel.check()
        let elapsed = clock.duration(to: .now).components
        let seconds = Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18
        let result = LiveChunkResult(sourceManifest: manifest, model: settings.modelPath, asrRuns: asrRuns,
                                    startFrame: cursor, endFrame: slice.endFrame, availableFrames: slice.availableFrames,
                                    sampleRate: slice.sampleRate, durationSeconds: seconds,
                                    segments: segments.sorted { $0.startSeconds < $1.startSeconds }, directory: attempt)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(result).write(to: attempt.appendingPathComponent("chunk.json"), options: .atomic)
        try encoder.encode(result).write(to: directory.appendingPathComponent("latest.json"), options: .atomic)
        logger.notice("Live chunk operation=\(cancel.id) start_frame=\(cursor) end_frame=\(slice.endFrame) channels=\(channels.count) asr_runs=\(asrRuns) elapsed_s=\(seconds) audio_s=\(Double(slice.endFrame - cursor) / Double(slice.sampleRate))")
        return result
    }

    /// One converter owns one bounded input stream; flushes its tail at EOF.
    @discardableResult
    static func convert(_ source: URL, channel: Int, to destination: URL, cancel: WorkCancellation) throws -> Bool {
        let input = try AVAudioFile(forReading: source)
        guard (0..<Int(input.processingFormat.channelCount)).contains(channel),
              let format = AVAudioFormat(standardFormatWithSampleRate: Double(LiveTranscriptionPolicy.sampleRate), channels: 1),
              let converter = AVAudioConverter(from: input.processingFormat, to: format),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(LiveTranscriptionPolicy.conversionFrames)) else {
            throw WAVWriterError.invalidFormat
        }
        converter.channelMap = [NSNumber(value: channel)]
        let output = try AVAudioFile(forWriting: destination, settings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: LiveTranscriptionPolicy.sampleRate,
            AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: PCM16WAV.bitDepth,
            AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false
        ])
        let feeder = ConverterInput(input)
        var hasSignal = false
        while true {
            try cancel.check()
            var error: NSError?
            let status = converter.convert(to: buffer, error: &error) { count, state in feeder.read(count, state) }
            if let error = feeder.error ?? error { throw error }
            guard status != .error else { throw WAVWriterError.invalidFormat }
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

    private struct Raw: Decodable {
        struct Result: Decodable { let language: String? }
        struct Entry: Decodable {
            struct Offsets: Decodable { let from: Int; let to: Int }
            let offsets: Offsets
            let text: String
        }
        let result: Result?
        let transcription: [Entry]
    }

    static func parse(_ url: URL, slice: LiveAudioReader.Slice, cursor: Int64, channel: Int) throws -> [LiveSegment] {
        let input = try FileHandle(forReadingFrom: url)
        defer { try? input.close() }
        let bytes = try input.read(upToCount: LiveTranscriptionPolicy.maximumResultBytes + 1) ?? Data()
        guard bytes.count <= LiveTranscriptionPolicy.maximumResultBytes else { throw SessionError.invalid("Whisper result exceeds the live preview limit") }
        let raw = try JSONDecoder().decode(Raw.self, from: bytes)
        let offset = Double(slice.startFrame) / Double(slice.sampleRate)
        let boundary = Double(cursor) / Double(slice.sampleRate)
        let end = Double(slice.endFrame) / Double(slice.sampleRate)
        return try raw.transcription.compactMap { entry in
            guard entry.offsets.from >= 0, entry.offsets.to > entry.offsets.from else { throw SessionError.invalid("Invalid Whisper timestamps") }
            let start = offset + Double(entry.offsets.from) / 1_000
            let stop = min(end, offset + Double(entry.offsets.to) / 1_000)
            let text = entry.text.trimmingCharacters(in: .whitespacesAndNewlines)
            // Context-only segments never appear twice. A straddling segment is
            // clipped in time, not guessed word-by-word: the draft needs review.
            guard stop > boundary, stop > start, !text.isEmpty else { return nil }
            return LiveSegment(id: UUID(), startSeconds: max(boundary, start), endSeconds: stop,
                               channel: channel, language: raw.result?.language, text: text)
        }
    }
}

/// AVAudioConverter invokes its input closure synchronously on the caller's
/// thread. This file and its mutable read state never cross that boundary.
private nonisolated final class ConverterInput: @unchecked Sendable {
    let file: AVAudioFile
    var error: NSError?
    init(_ file: AVAudioFile) { self.file = file }
    func read(_ count: AVAudioPacketCount, _ status: UnsafeMutablePointer<AVAudioConverterInputStatus>) -> AVAudioBuffer? {
        guard file.framePosition < file.length else { status.pointee = .endOfStream; return nil }
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat,
            frameCapacity: min(count, AVAudioFrameCount(LiveTranscriptionPolicy.conversionFrames))) else {
            error = NSError(domain: NSOSStatusErrorDomain, code: Int(memFullErr))
            status.pointee = .endOfStream
            return nil
        }
        do { try file.read(into: buffer); status.pointee = .haveData; return buffer }
        catch { self.error = error as NSError; status.pointee = .endOfStream; return nil }
    }
}
