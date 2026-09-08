import AVFoundation
import CryptoKit
import Darwin
import Foundation
import RecScribeCore
import os

nonisolated struct CloudAudioConsent: Codable, Sendable {
    let sourceSessionID: UUID
    let approvedAt: Date
    let startSample: Int64
    let model: String
}

/// Native, file-backed and serial. Only audio at/after the approval boundary is
/// eligible. Channels are never mixed, and no local model is needed or selected.
nonisolated struct CloudTranscriptionWorker: Sendable {
    static let maximumLagSeconds: Int64 = 120
    let consent: CloudAudioConsent
    let key: Data
    var client = RealtimeTranscriber()

    @concurrent func step(manifest: URL, directory: URL, cursor: Int64, finished: Bool,
                          settings: AppSettings.Values, cancel: WorkCancellation,
                          preview: @escaping @Sendable (LiveSegment) async -> Void) async throws -> LiveChunkResult? {
        try cancel.check()
        guard cursor >= consent.startSample, settings.processingLocation == .cloud,
              settings.cloudTranscriptionModel == consent.model,
              try RecordingSession.read(manifest).id == consent.sourceSessionID else {
            throw SessionError.invalid("Cloud consent no longer matches this recording or model")
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        guard let available = DiskSpace.availableBytes(at: directory), available >= DiskSpace.minimumBytesToRecord else {
            throw SessionError.diskFull
        }
        let turn = directory.appendingPathComponent("turn-\(cursor)", isDirectory: true)
        guard mkdir(turn.path, 0o700) == 0 else { throw SessionError.invalid("Cloud turn already exists; it will not be replayed") }
        let source = turn.appendingPathComponent("working.wav")
        defer { try? FileManager.default.removeItem(at: source) }
        guard let slice = try LiveAudioReader.copy(manifest: manifest, cursor: cursor, seconds: settings.liveChunkSeconds,
            overlapSeconds: 0, finished: finished, to: source, cancel: cancel) else {
            try FileManager.default.removeItem(at: turn) // Empty reservation only; no evidence or audio was created.
            return nil
        }
        guard slice.availableFrames - cursor <= Self.maximumLagSeconds * Int64(slice.sampleRate) else {
            throw SessionError.invalid("Cloud transcription fell too far behind. Recording continues; enable again to approve new audio. No queued audio was replayed.")
        }
        let started = ContinuousClock.now
        var segments: [LiveSegment] = []
        var metrics: [JSONValue] = []
        // Even identical channels remain distinct: channel identity is not speaker identity.
        for channel in 0..<slice.channels {
            try cancel.check()
            let converted = turn.appendingPathComponent("channel-\(channel).wav")
            defer { try? FileManager.default.removeItem(at: converted) }
            try LiveWhisperTranscriber.convert(source, channel: channel, to: converted, cancel: cancel,
                                              sampleRate: RealtimePolicy.sampleRate)
            let pcm = try Self.pcm(converted, cancel: cancel)
            guard pcm.count >= RealtimePolicy.minimumFrames * RealtimePolicy.sampleBytes else {
                metrics.append(["channel": .integer(Int64(channel)), "skipped": "tail_shorter_than_api_minimum; review_required"])
                continue
            }
            let id = UUID()
            let journal = try CloudTurnJournal(url: turn.appendingPathComponent("channel-\(channel).events.jsonl"),
                id: id, slice: slice, channel: channel, preview: preview)
            do {
                let result = try await client.transcribe(pcm: pcm, model: consent.model,
                    language: settings.sourceLanguage == "auto" ? nil : settings.sourceLanguage.split(separator: "-").first.map(String.init),
                    key: key, consent: true, event: { try await journal.append($0) })
                try await journal.close()
                try cancel.check()
                let segment = LiveSegment(id: id, startSeconds: Double(cursor) / Double(slice.sampleRate),
                    endSeconds: Double(slice.endFrame) / Double(slice.sampleRate), channel: channel, language: nil,
                    text: result.text.trimmingCharacters(in: .whitespacesAndNewlines))
                if !segment.text.isEmpty { segments.append(segment) }
                await preview(segment)
                metrics.append(["channel": .integer(Int64(channel)), "item_id": .string(result.itemID),
                    "pcm_bytes": .integer(Int64(result.audioBytes)), "elapsed_seconds": .number(result.elapsedSeconds),
                    "first_delta_seconds": result.firstDeltaSeconds.map(JSONValue.number) ?? .null])
            } catch { try? await journal.close(); throw error }
        }
        let elapsed = Self.seconds(since: started)
        let result = LiveChunkResult(engine: "openai-realtime", sourceManifest: manifest, model: consent.model,
            asrRuns: nil, startFrame: cursor, endFrame: slice.endFrame, availableFrames: slice.availableFrames,
            sampleRate: slice.sampleRate, durationSeconds: elapsed, segments: segments, directory: turn)
        try JSONEncoder().encode(result).write(to: turn.appendingPathComponent("result.json"), options: .atomic)
        try JSONValue.array(metrics).encoded().write(to: turn.appendingPathComponent("timings.json"), options: .atomic)
        Logger(subsystem: "com.moreaki.recscribe", category: "CloudTranscription").notice("Cloud turn id=\(cancel.id) start=\(cursor) end=\(slice.endFrame) channels=\(slice.channels) elapsed=\(elapsed)")
        return result
    }

    static func seconds(since start: ContinuousClock.Instant) -> Double {
        let value = start.duration(to: .now).components
        return Double(value.seconds) + Double(value.attoseconds) / 1e18
    }

    private static func pcm(_ url: URL, cancel: WorkCancellation) throws -> Data {
        // AVAudioFile can write extended WAV headers. Decode frames, never strip a guessed 44 bytes.
        let input = try AVAudioFile(forReading: url, commonFormat: .pcmFormatInt16, interleaved: true)
        guard input.processingFormat.sampleRate == Double(RealtimePolicy.sampleRate),
              input.processingFormat.channelCount == 1,
              input.length <= RealtimePolicy.maximumSeconds * RealtimePolicy.sampleRate,
              let buffer = AVAudioPCMBuffer(pcmFormat: input.processingFormat,
                                            frameCapacity: AVAudioFrameCount(RealtimePolicy.packetFrames)) else {
            throw SessionError.invalid("Invalid prepared cloud PCM")
        }
        var data = Data()
        while input.framePosition < input.length {
            try cancel.check()
            try input.read(into: buffer)
            guard buffer.frameLength > 0, let values = buffer.int16ChannelData?[0] else { throw WAVWriterError.invalidFormat }
            data.append(UnsafeRawPointer(values).assumingMemoryBound(to: UInt8.self),
                        count: Int(buffer.frameLength) * RealtimePolicy.sampleBytes)
        }
        return data
    }
}

/// One turn, bounded text and event IDs. Duplicate provider events remain in raw
/// evidence but cannot duplicate the preview. Final text replaces provisional deltas.
private actor CloudTurnJournal {
    let file: FileHandle
    let id: UUID
    let slice: LiveAudioReader.Slice
    let channel: Int
    let preview: @Sendable (LiveSegment) async -> Void
    var seen: Set<String> = []
    var text = ""
    var item: String?
    init(url: URL, id: UUID, slice: LiveAudioReader.Slice, channel: Int,
         preview: @escaping @Sendable (LiveSegment) async -> Void) throws {
        let fd = Darwin.open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw WAVWriterError.fileCreationFailed }
        file = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        self.id = id; self.slice = slice; self.channel = channel; self.preview = preview
    }
    func append(_ event: JSONValue) async throws {
        try file.write(contentsOf: event.encoded() + Data([0x0a]))
        if let id = event["event_id"].string, !seen.insert(id).inserted { return }
        guard event["type"] == "conversation.item.input_audio_transcription.delta",
              let current = event["item_id"].string else { return }
        guard item == nil || item == current else { throw SessionError.invalid("Ambiguous cloud draft item; review raw events") }
        item = current
        text += event["delta"].string ?? ""
        guard text.utf8.count <= LiveTranscriptionPolicy.previewCharacters else { throw SessionError.invalid("Cloud draft text exceeds the preview limit") }
        await preview(LiveSegment(id: id, startSeconds: Double(slice.startFrame) / Double(slice.sampleRate),
            endSeconds: Double(slice.endFrame) / Double(slice.sampleRate), channel: channel, language: nil, text: text))
    }
    func close() throws { try file.synchronize(); try file.close() }
}
