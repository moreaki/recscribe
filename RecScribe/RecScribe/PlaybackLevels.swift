import AVFoundation
import Combine
import Foundation

nonisolated struct ListeningLevel: Codable, Equatable, Sendable {
    var volume: Float = 1
    var muted = false
    var outputUID: String?
    var valid: Bool { volume.isFinite && (0...1).contains(volume) && (outputUID?.count ?? 0) <= 1024 }
}

/// Shared by every app player; output controls never enter the capture pipeline.
@MainActor
final class PlaybackLevels: ObservableObject {
    static let shared = PlaybackLevels()
    @Published private(set) var value: ListeningLevel
    private let defaults: UserDefaults
    private let key: String
    init(defaults: UserDefaults = .standard, key: String = "audio.playbackLevels.v1", initialVolume: Float = 1) {
        self.defaults = defaults; self.key = key
        if let data = defaults.data(forKey: key),
           let saved = try? JSONDecoder().decode(ListeningLevel.self, from: data), saved.valid { value = saved }
        else { value = .init(volume: initialVolume) }
    }
    func set(_ newValue: ListeningLevel) {
        guard newValue.valid else { return }
        value = newValue
        if let data = try? JSONEncoder().encode(value) { defaults.set(data, forKey: key) }
    }
    func apply(to player: AVPlayer, devices: [AudioOutputDevice] = AudioDeviceControls.outputs()) {
        player.volume = value.volume
        player.isMuted = value.muted
        player.audioOutputDeviceUniqueID = devices.contains { $0.uid == value.outputUID } ? value.outputUID : nil
    }
}
