import Foundation

/// Reconciles available devices, retaining channel choices independently of presence.
/// Only unseen virtual inputs receive a safe initial mute; manual settings win.
@MainActor
final class AutomaticRoutingSources {
    private let defaults: UserDefaults
    private var remembered: [String: InputSelection]
    init(defaults: UserDefaults) {
        self.defaults = defaults
        remembered = defaults.data(forKey: "routing.channelSelections.v1")
            .flatMap { try? JSONDecoder().decode([String: InputSelection].self, from: $0) } ?? [:]
    }
    func selection(from current: AudioSource, devices: [InputDeviceInfo], levels: AudioLevels? = nil) -> AudioSource {
        for input in current.inputSelections { remembered[input.deviceUID] = input }
        let available = devices.filter { (1...32).contains($0.inputChannels ?? 0) }
        for device in available where device.mayLoopBack {
            let id = "input:" + device.uid
            if let levels, !levels.hasSetting(id) { levels.set(id, .init(muted: true)) }
        }
        let currentIDs = Set(current.inputSelections.map(\.deviceUID))
        // Existing routes keep priority at the capture model's device limit.
        let ordered = available.sorted {
            if currentIDs.contains($0.uid) != currentIDs.contains($1.uid) { return currentIDs.contains($0.uid) }
            return $0.uid < $1.uid
        }
        let inputs = ordered.prefix(InputSelection.maximumDevices).map { device in
            remembered[device.uid] ?? InputSelection(device: device)
        }
        remembered = Dictionary(uniqueKeysWithValues: remembered.sorted { $0.key < $1.key }.prefix(256).map { ($0.key, $0.value) })
        if let data = try? JSONEncoder().encode(remembered) { defaults.set(data, forKey: "routing.channelSelections.v1") }
        let playback = current.playback == .none ? AudioSource.Playback.systemAll : current.playback
        return AudioSource(playback: playback, inputs: inputs,
            allowDuplicateRoutes: current.allowDuplicateRoutes && inputs == current.inputSelections && playback == current.playback,
            usesMultiInputRouting: true)
    }
}
