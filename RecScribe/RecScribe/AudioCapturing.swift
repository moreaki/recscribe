//
//  AudioCapturing.swift
//  RecScribe
//
//  Abstraction over the system-audio capture source so the recording
//  workflow can be exercised with a mock instead of real hardware.
//

import Foundation
import AVFoundation

/// A source of captured system audio. Implemented by `ScreenCaptureAudioManager`.
///
/// The single-source callback delivers canonical 48-kHz stereo Float32 PCM.
/// Combined capture transfers copied native PCM with role and host-clock time;
/// independent source state performs normalization and alignment on the writer queue.
@MainActor
protocol AudioCapturing: AnyObject, Sendable {
    var capturing: Bool { get }
    /// Called when the capture stream stops unexpectedly (e.g. permission revoked,
    /// display sleep, another capturer). The argument is a plain-language detail.
    var onStreamError: (@MainActor (String) -> Void)? { get set }
    /// Set up capture for `source` (BL-100). Implementations resolve `.app` to
    /// their own framework's filter; the source is otherwise opaque to callers.
    func setupCapture(source: AudioSource, audioCallback: @escaping @Sendable (AVAudioPCMBuffer) -> Void) async throws
    func setupMultiCapture(source: AudioSource, sampleCallback: @escaping @Sendable (CapturedAudioSample) -> Void) async throws
    func startCapture() async throws
    func stopCapture() async throws
    func cleanup() async
}

extension AudioCapturing {
    func setupMultiCapture(source: AudioSource, sampleCallback: @escaping @Sendable (CapturedAudioSample) -> Void) async throws {
        throw SessionError.invalid("This capture backend does not support multiple sources")
    }
}

nonisolated enum CaptureTrack: String, Codable, CaseIterable, Sendable {
    case playback, microphone
}

/// Owns copied PCM. The producer relinquishes access when this envelope is sent.
nonisolated struct CapturedAudioSample: @unchecked Sendable {
    let track: CaptureTrack
    let presentationTime: Double
    let buffer: AVAudioPCMBuffer
}
