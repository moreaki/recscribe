import Foundation

/// Disclosure identity is independent of the capture selection and audio settings.
enum AudioRoutingPanel: Hashable {
    case playback, input(String), mix, monitor, recordingPlayback
}

nonisolated enum AudioRoutingSummary {
    static func routes(_ input: InputSelection, channelCount: Int?) -> String {
        // Only currently available native channels contribute to the mix.
        let active = channelCount.map { count in input.routes.filter { (0..<count).contains($0.channel) } } ?? input.routes
        let left = active.filter { $0.placement != .right }.count
        let right = active.filter { $0.placement != .left }.count
        if left == 0 && right == 0 { return "Not connected to mix · original track retained" }
        let destination = left > 0 && right > 0 ? "L + R" : left > 0 ? "Left only" : "Right only"
        let count = active.count
        return "\(count) \(count == 1 ? "channel" : "channels") → \(destination)"
    }

    static func output(_ level: ListeningLevel, devices: [AudioOutputDevice], systemUID: String?) -> String {
        let system = devices.first { $0.uid == systemUID }?.name ?? "system output"
        if let uid = level.outputUID {
            return devices.first { $0.uid == uid }?.name ?? "Output unavailable · using \(system)"
        }
        return "System · \(system)"
    }
}
