//
//  AudioRecorder.swift
//  RecScribe
//
//  Processes audio from ScreenCaptureKit and writes to WAV file
//

import Foundation
import AVFoundation
import os

/// Errors that can occur during audio recording
enum AudioRecorderError: Error, LocalizedError {
    case invalidSampleBuffer
    case formatNotSupported
    case bufferConversionFailed
    case notRecording

    var errorDescription: String? {
        switch self {
        case .invalidSampleBuffer:
            return "Invalid audio sample buffer"
        case .formatNotSupported:
            return "Audio format not supported"
        case .bufferConversionFailed:
            return "Failed to convert audio buffer"
        case .notRecording:
            return "Not currently recording"
        }
    }

    var recoverySuggestion: String? {
        switch self {
        case .invalidSampleBuffer:
            return "Check if system audio is playing"
        case .formatNotSupported:
            return "System audio format must be PCM"
        case .bufferConversionFailed:
            return "Try restarting the recording"
        case .notRecording:
            return "Start recording first"
        }
    }
}

/// Records audio from ScreenCaptureKit to WAV file
final class AudioRecorder: AudioFileWriting {

    // MARK: - Properties

    /// Access is confined to `processingQueue`. `nonisolated(unsafe)` expresses
    /// that external synchronization to Swift's actor checker; callers never
    /// touch this storage directly.
    nonisolated(unsafe) private var encoder: (any AudioFileEncoder)?

    /// How an encoder is built for a format. Injectable so tests can drive the
    /// stop path with an encoder that fails to finalize (BL-016) — the real app
    /// always uses `AudioFormat.makeEncoder()`.
    private let encoderFactory: (AudioFormat) throws -> any AudioFileEncoder

    init(encoderFactory: @escaping (AudioFormat) throws -> any AudioFileEncoder = { try $0.makeEncoder() }) {
        self.encoderFactory = encoderFactory
    }

    private let sampleRate: Double = 48000  // Match ScreenCaptureKit config
    private let channels: Int = 2           // Stereo

    /// Callback for waveform visualization data (downsampled amplitude values)
    var onWaveformData: (@MainActor @Sendable ([Float]) -> Void)?

    // Processing queue for writing to disk
    private let processingQueue = DispatchQueue(
        label: "com.moreaki.recscribe.audiorecorder.processing",
        qos: .userInitiated
    )

    // MARK: - Public Methods

    /// Start recording to file
    /// - Parameters:
    ///   - fileURL: destination file; its extension should match `format`.
    ///   - format: output format whose encoder is created (BL-015). `sampleRate`/
    ///     `channels` are the capture (input) format; the encoder owns its output.
    /// - Throws: the format's `makeEncoder()` error, or a file-creation error.
    func startRecording(to fileURL: URL, format: AudioFormat) throws {
        let encoder = try encoderFactory(format)
        try encoder.createFile(at: fileURL, sampleRate: sampleRate, channels: channels)

        // Confine the encoder to the processing queue: capture and stop threads
        // must never touch `encoder` directly, so there's no cross-thread race.
        processingQueue.sync { self.encoder = encoder }

        Log.recorder.debug("AudioRecorder started: \(fileURL.path, privacy: .private)")
    }

    /// Process a captured audio buffer (already converted to the canonical
    /// 48kHz/stereo/Float32/non-interleaved format by the `AudioCapturing` source).
    /// - Parameter pcmBuffer: Audio buffer from the capture source
    func processAudioSample(_ pcmBuffer: AVAudioPCMBuffer) {
        // AVAudioPCMBuffer is imported from Objective-C without Sendable
        // conformance. The capture pipeline transfers ownership here and never
        // touches this instance again, so wrapping that transfer is safe. Encoder
        // state remains confined to the serial processing queue.
        let transferredBuffer = TransferredPCMBuffer(pcmBuffer)
        let waveformHandler = onWaveformData
        processingQueue.async { [weak self, transferredBuffer, waveformHandler] in
            self?.processPCMBuffer(
                transferredBuffer.value,
                waveformHandler: waveformHandler
            )
        }
    }

    /// Stop recording
    /// - Throws: AudioRecorderError if stop fails
    func stopRecording() throws {
        // Runs on the processing queue *after* all in-flight buffers (FIFO), so no
        // trailing audio is dropped and the writer is finalized exactly once.
        try processingQueue.sync {
            guard encoder != nil else {
                throw AudioRecorderError.notRecording
            }
            // Release the encoder even if finalize fails, otherwise a failed
            // finalize would leave the recorder permanently "recording" and
            // refuse every subsequent start.
            defer { encoder = nil }
            // BL-016: this was `try?`, which discarded every conformer's finalize
            // error — a failed M4A finish was invisible to the user. The error
            // now propagates and surfaces as `.stopFailed`.
            try encoder?.finalize()
        }
    }

    /// Whether the recorder is currently writing to a file.
    var recording: Bool {
        processingQueue.sync { encoder != nil }
    }

    // MARK: - Private Methods

    /// Process a PCM buffer on background thread (orchestrator).
    /// - Parameter pcmBuffer: canonical AVAudioPCMBuffer from the capture source
    nonisolated private func processPCMBuffer(
        _ pcmBuffer: AVAudioPCMBuffer,
        waveformHandler: (@MainActor @Sendable ([Float]) -> Void)?
    ) {
        // Runs ~47×/sec on the processing queue. No logging on this hot path;
        // failures drop the buffer. CMSampleBuffer→AVAudioPCMBuffer conversion now
        // happens at the capture source's delegate boundary (BL-099); downsampling
        // is still extracted into a `nonisolated` unit (BL-007), and the write goes
        // through the format-agnostic `AudioFileEncoder` seam (BL-011).
        guard let encoder = encoder else { return }

        // Waveform visualization (skip the work entirely when nothing is listening).
        if let waveformHandler {
            let waveformSamples = WaveformDownsampler.downsample(pcmBuffer)
            DispatchQueue.main.async {
                waveformHandler(waveformSamples)
            }
        }

        // Encode the buffer. Errors intentionally not logged here (hot path).
        try? encoder.writeBuffer(pcmBuffer)
    }
}

/// A single-owner transfer from the ScreenCaptureKit callback to the recorder's
/// serial processing queue. The producer relinquishes the buffer after calling
/// `processAudioSample`; only that queue reads it afterwards.
private nonisolated struct TransferredPCMBuffer: @unchecked Sendable {
    let value: AVAudioPCMBuffer

    init(_ value: AVAudioPCMBuffer) {
        self.value = value
    }
}
