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
/// Every implementation must deliver `AVAudioPCMBuffer` at 48kHz, stereo, Float32,
/// non-interleaved — the contract `AudioRecorder` and its encoders depend on.
@MainActor
protocol AudioCapturing: AnyObject, Sendable {
    var capturing: Bool { get }
    /// Called when the capture stream stops unexpectedly (e.g. permission revoked,
    /// display sleep, another capturer). The argument is a plain-language detail.
    var onStreamError: (@MainActor (String) -> Void)? { get set }
    /// Set up capture for `source` (BL-100). Implementations resolve `.app` to
    /// their own framework's filter; the source is otherwise opaque to callers.
    func setupCapture(source: AudioSource, audioCallback: @escaping @Sendable (AVAudioPCMBuffer) -> Void) async throws
    func startCapture() async throws
    func stopCapture() async throws
    func cleanup() async
}
