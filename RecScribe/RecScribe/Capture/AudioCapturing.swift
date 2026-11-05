
import Foundation
import AVFoundation
import CryptoKit

@MainActor
protocol AudioCapturing: AnyObject, Sendable {
    var capturing: Bool { get }
    var onInputAvailable: (@MainActor (InputDeviceInfo, InputSelection) async -> Bool)? { get set }
    var onSourceFailure: (@MainActor (CaptureTrack, String) -> Void)? { get set }
    var onStreamError: (@MainActor (String) -> Void)? { get set }
    func setupCapture(source: AudioSource, audioCallback: @escaping @Sendable (AVAudioPCMBuffer) -> Void) async throws
    func setupMultiCapture(source: AudioSource, sampleCallback: @escaping @Sendable (CapturedAudioSample) -> Void) async throws
    func startCapture() async throws
    func stopCapture() async throws
    func cleanup() async
}

extension AudioCapturing {
    var onInputAvailable: (@MainActor (InputDeviceInfo, InputSelection) async -> Bool)? { get { nil } set { } }
    var onSourceFailure: (@MainActor (CaptureTrack, String) -> Void)? { get { nil } set { } }
    func setupMultiCapture(source: AudioSource, sampleCallback: @escaping @Sendable (CapturedAudioSample) -> Void) async throws {
        throw SessionError.invalid("This capture backend does not support multiple sources")
    }
}

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

nonisolated struct CapturedAudioSample: @unchecked Sendable {
    let track: CaptureTrack
    let presentationTime: Double
    let buffer: AVAudioPCMBuffer
}
