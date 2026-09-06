//
//  AudioFileWriting.swift
//  RecScribe
//
//  Abstraction over the object that turns captured buffers into an audio
//  file on disk, so the workflow can be tested without real capture.
//

import Foundation
import AVFoundation

/// Writes captured audio buffers to a file. Implemented by `AudioRecorder`.
@MainActor
protocol AudioFileWriting: AnyObject, Sendable {
    var onWaveformData: (@MainActor @Sendable ([Float]) -> Void)? { get set }
    var onWriteError: (@MainActor @Sendable (String) -> Void)? { get set }
    var recording: Bool { get }
    var sessionManifestURL: URL? { get }
    var actualAudioURL: URL? { get }
    /// Begin writing to `fileURL`, encoding in `format` (BL-015). The format is
    /// fixed for the lifetime of this recording.
    func startRecording(to fileURL: URL, format: AudioFormat) throws
    nonisolated func processAudioSample(_ pcmBuffer: AVAudioPCMBuffer)
    func stopRecording() async throws
}

extension AudioFileWriting {
    var sessionManifestURL: URL? { nil }
    var actualAudioURL: URL? { nil }
}
