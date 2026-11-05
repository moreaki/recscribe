import Foundation

/// Value contract between the recorder's current selection and native menu
/// construction. A missing app list means discovery has not completed yet.
struct OverflowContext: Sendable, Equatable {
    var selectedSource: AudioSource = .systemAll
    var allowsCaptureSourceChange = true
    var permissionGranted = true
    var apps: [RunningAppInfo]? = nil
    var selectedAppName: String? = nil
    var inputDevices: [InputDeviceInfo] = []
    var selectedMicName: String? = nil
}
