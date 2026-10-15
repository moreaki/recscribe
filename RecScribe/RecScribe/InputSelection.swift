import Foundation

nonisolated enum InputMixPlacement: String, Codable, CaseIterable, Sendable {
    case left, center, right
}
nonisolated struct InputChannelRoute: Codable, Equatable, Sendable {
    var channel: Int
    var placement: InputMixPlacement
}
nonisolated struct InputSelection: Codable, Equatable, Sendable, Identifiable {
    var id: String { deviceUID }
    var deviceUID: String
    /// Mix routing only. All native channels are retained in the source session.
    var routes: [InputChannelRoute]
    static let maximumDevices = 8
    init(deviceUID: String, routes: [InputChannelRoute] = [.init(channel: 0, placement: .center)]) {
        self.deviceUID = deviceUID; self.routes = routes
    }
    init(device: InputDeviceInfo) {
        deviceUID = device.uid
        routes = (0..<min(2, device.inputChannels ?? 1)).map { .init(channel: $0, placement: device.inputChannels == 1 ? .center : ($0 == 0 ? .left : .right)) }
    }
    var valid: Bool {
        !deviceUID.isEmpty && deviceUID.count <= 1024 && routes.count <= 32 &&
        Set(routes.map(\.channel)).count == routes.count && routes.allSatisfy { (0..<32).contains($0.channel) }
    }
}
