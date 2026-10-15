import AVFoundation
import Combine
import Foundation
import os

/// Software levels, independent of macOS device volume. Channel trims are dB.
nonisolated struct SourceLevel: Codable, Equatable, Sendable {
    var decibels: Double = 0
    var muted = false
    var channelTrims: [Int: Double] = [:]
    var valid: Bool {
        decibels.isFinite && (-60...24).contains(decibels) && channelTrims.count <= 32 &&
        channelTrims.allSatisfy { (0..<32).contains($0.key) && $0.value.isFinite && (-60...24).contains($0.value) }
    }
    func amplitude(channel: Int) -> Float {
        muted ? 0 : Float(pow(10, (decibels + (channelTrims[channel] ?? 0)) / 20))
    }
}

nonisolated struct RecordingLevels: Equatable, Sendable {
    var playback = SourceLevel()
    var microphone = SourceLevel()
    var master = SourceLevel()
    var inputs: [CaptureTrack: SourceLevel] = [:]
    // Fixed order is the on-disk automation format: playback 0...31, mic 32...63, master 64.
    var amplitudes: [Float] { amplitudes(for: CaptureTrack.legacyPair) }
    func amplitudes(for tracks: [CaptureTrack]) -> [Float] {
        tracks.flatMap { track in
            let level = track == .playback ? playback : (track == .microphone ? microphone : inputs[track] ?? .init())
            return (0..<32).map { level.amplitude(channel: $0) }
        } + [master.amplitude(channel: 0)]
    }
}

nonisolated extension AudioSource {
    var playbackLevelID: String { appBundleID.map { "app:" + $0 } ?? "system" }
    var microphoneLevelID: String { "input:" + (microphoneUID ?? "") }
    var singleLevelID: String { microphoneUID == nil ? playbackLevelID : microphoneLevelID }
}

@MainActor
final class AudioLevels: ObservableObject {
    static let shared = AudioLevels()
    nonisolated private let storage = OSAllocatedUnfairLock(initialState: [String: SourceLevel]())
    private let defaults: UserDefaults
    @Published private(set) var revision = 0
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: "audio.sourceLevels.v1"),
           let values = try? JSONDecoder().decode([String: SourceLevel].self, from: data),
           values.count <= 256, values.allSatisfy({ $0.key.count <= 1024 && $0.value.valid }) {
            storage.withLock { $0 = values }
        }
    }
    nonisolated func level(_ id: String) -> SourceLevel { storage.withLock { $0[id] ?? .init() } }
    func set(_ id: String, _ level: SourceLevel) {
        guard level.valid, id.count <= 1024 else { return }
        let values = storage.withLock { values -> [String: SourceLevel] in
            guard values[id] != nil || values.count < 256 else { return values }
            values[id] = level; return values
        }
        if let data = try? JSONEncoder().encode(values) { defaults.set(data, forKey: "audio.sourceLevels.v1") }
        revision += 1
    }
    nonisolated func snapshot(for source: AudioSource) -> RecordingLevels {
        storage.withLock { values in
            .init(playback: values[source.playbackLevelID] ?? .init(),
                  microphone: values[source.microphoneLevelID] ?? .init(), master: values["master"] ?? .init(),
                  inputs: Dictionary(uniqueKeysWithValues: source.inputSelections.map { (.input($0.deviceUID), values["input:" + $0.deviceUID] ?? .init()) }))
        }
    }
}

/// Sample-accurate 10-ms linear-amplitude ramps. Events are journaled before use.
/// At most 2048 edits per take, bounded to roughly 6 MiB of automation metadata.
nonisolated struct GainEvent: Codable, Sendable {
    var frame: Int64
    var from: [Float]
    var to: [Float]
    func value(_ index: Int, at sample: Int64) -> Float {
        let fraction = Float(min(480, max(0, sample - frame))) / 480
        return from[index] + (to[index] - from[index]) * fraction
    }
    var valid: Bool {
        frame >= 0 && (33...(CaptureTrack.maximumSources * 32 + 1)).contains(from.count) && (from.count - 1) % 32 == 0 && to.count == from.count && (from + to).allSatisfy { $0.isFinite && (0...252).contains($0) }
    }
}
nonisolated final class GainAutomation {
    private(set) var events: [GainEvent]
    private var cursor = 0
    let tracks: [CaptureTrack]
    var masterIndex: Int { tracks.count * 32 }
    private var maximumEvents: Int { min(2048, 131_072 / (masterIndex + 1)) }
    private var lastLevels: RecordingLevels
    init(_ levels: RecordingLevels = .init(), tracks: [CaptureTrack] = CaptureTrack.legacyPair) {
        self.tracks = tracks
        lastLevels = levels
        let values = levels.amplitudes(for: tracks)
        events = [.init(frame: 0, from: values, to: values)]
    }
    @discardableResult func update(_ levels: RecordingLevels, at frame: Int64) throws -> Bool {
        guard levels != lastLevels else { return false }
        let values = levels.amplitudes(for: tracks)
        guard values != events.last!.to else { lastLevels = levels; return false }
        guard events.count < maximumEvents else { throw SessionError.invalid("Recording level automation reached its bounded edit limit; the partial take is preserved") }
        let last = events.last!
        let position = max(frame, last.frame)
        lastLevels = levels
        events.append(.init(frame: position, from: (0...masterIndex).map { last.value($0, at: position) }, to: values))
        return true
    }
    func event(at frame: Int64) -> GainEvent {
        // Sources can arrive out of order, so a single forward cursor is insufficient.
        if events[cursor].frame > frame {
            var lower = 0, upper = events.count
            while lower < upper {
                let middle = (lower + upper) / 2
                if events[middle].frame <= frame { lower = middle + 1 } else { upper = middle }
            }
            cursor = max(0, lower - 1)
        }
        while cursor + 1 < events.count && events[cursor + 1].frame <= frame { cursor += 1 }
        return events[cursor]
    }
}

/// Queue-confined single-source processor. Saved file is explicitly gain-processed.
nonisolated final class SingleSourceGain {
    let automation: GainAutomation
    let microphone: Bool
    var frame: Int64 = 0
    private(set) var postPeak: Float = 0
    private(set) var clipped = false
    init(levels: RecordingLevels, microphone: Bool) {
        automation = GainAutomation(levels); self.microphone = microphone
    }
    func process(_ input: AVAudioPCMBuffer, levels: RecordingLevels, writer: SessionWAVWriter?) throws -> AVAudioPCMBuffer {
        if try automation.update(levels, at: frame) { try writer?.setGainAutomation(automation.events, scope: "processed_single_source") }
        guard let output = AVAudioPCMBuffer(pcmFormat: input.format, frameCapacity: input.frameLength),
              let src = input.floatChannelData, let dst = output.floatChannelData else { throw WAVWriterError.invalidFormat }
        output.frameLength = input.frameLength
        postPeak = 0
        for offset in 0..<Int(input.frameLength) {
            let event = automation.event(at: frame + Int64(offset))
            let master = event.value(64, at: frame + Int64(offset))
            for ch in 0..<Int(input.format.channelCount) {
                let value = src[ch][offset] * event.value((microphone ? 32 : 0) + ch, at: frame + Int64(offset)) * master
                postPeak = max(postPeak, abs(value)); clipped = clipped || abs(value) > 1
                dst[ch][offset] = max(-1, min(1, value))
            }
        }
        frame += Int64(input.frameLength)
        return output
    }
}
