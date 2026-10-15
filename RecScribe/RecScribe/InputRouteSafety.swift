import Foundation

nonisolated enum InputRouteSafety {
    static func warnings(inputs: [InputSelection], devices: [InputDeviceInfo]) -> [String] {
        let uids = Set(inputs.map(\.deviceUID))
        var warnings: [String] = []
        for input in inputs {
            guard let device = devices.first(where: { $0.uid == input.deviceUID }) else { continue }
            if device.mayLoopBack { warnings.append("\(device.name) may duplicate system playback through a virtual or loopback route.") }
            if device.isAggregate {
                if device.aggregateMembers.contains(where: { uid in devices.contains { $0.uid == uid && $0.mayLoopBack } }) {
                    warnings.append("\(device.name) contains a virtual or loopback input that may duplicate system playback.")
                }
                if !uids.isDisjoint(with: device.aggregateMembers) { warnings.append("\(device.name) overlaps a selected member device.") }
                if device.aggregateMembers.isEmpty { warnings.append("The members of \(device.name) could not be identified; check for overlapping routes.") }
            }
            if input.routes.contains(where: { route in
                device.channelLabels.indices.contains(route.channel) && device.channelLabels[route.channel].localizedCaseInsensitiveContains("loopback")
            }) { warnings.append("A selected channel on \(device.name) is labelled loopback and may duplicate playback.") }
        }
        let aggregates = devices.filter { uids.contains($0.uid) && $0.isAggregate }
        for (index, device) in aggregates.enumerated() {
            for other in aggregates.dropFirst(index + 1) where !Set(device.aggregateMembers).isDisjoint(with: other.aggregateMembers) {
                warnings.append("\(device.name) and \(other.name) share member devices.")
            }
        }
        return warnings
    }
}
