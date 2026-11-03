//
//  AudioCapturing.swift
//  RecScribe
//
//  Abstraction over the system-audio capture source so the recording
//  workflow can be exercised with a mock instead of real hardware.
//

import Foundation
import AVFoundation
import CryptoKit

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
    var onSourceFailure: (@MainActor (CaptureTrack, String) -> Void)? { get set }
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
    var onSourceFailure: (@MainActor (CaptureTrack, String) -> Void)? { get { nil } set { } }
    func setupMultiCapture(source: AudioSource, sampleCallback: @escaping @Sendable (CapturedAudioSample) -> Void) async throws {
        throw SessionError.invalid("This capture backend does not support multiple sources")
    }
}

/// String encoding retains v2's playback/microphone IDs. Device IDs are stable,
/// filename-safe hashes; human/device identity lives in the source descriptor.
nonisolated struct CaptureTrack: RawRepresentable, Codable, Hashable, Sendable {
    let rawValue: String
    init(rawValue: String) { self.rawValue = rawValue }
    static let maximumSources = InputSelection.maximumDevices + 1
    static let playback = Self(rawValue: "playback")
    static let microphone = Self(rawValue: "microphone")
    static let legacyPair: [Self] = [.playback, .microphone] // legacy pair, not active-source enumeration
    static func input(_ uid: String) -> Self {
        .init(rawValue: "input-" + SHA256.hash(data: Data(uid.utf8)).map { String(format: "%02x", $0) }.joined())
    }
    var valid: Bool {
        self == .playback || self == .microphone || (rawValue.hasPrefix("input-") && rawValue.count == 70 && rawValue.dropFirst(6).allSatisfy { "0123456789abcdef".contains($0) })
    }
    init(from decoder: Decoder) throws { rawValue = try decoder.singleValueContainer().decode(String.self) }
    func encode(to encoder: Encoder) throws { var container = encoder.singleValueContainer(); try container.encode(rawValue) }
}

/// Owns copied PCM. The producer relinquishes access when this envelope is sent.
nonisolated struct CapturedAudioSample: @unchecked Sendable {
    let track: CaptureTrack
    let presentationTime: Double
    let buffer: AVAudioPCMBuffer
}
