import Foundation
@testable import RecScribe

/// Each lifecycle scenario receives isolated preferences and notification state.
/// The capture controller and permission provider never reach actual devices/TCC.
@MainActor struct RecorderContractHarness {
    let domain: String
    let defaults: UserDefaults
    let controller = MockRecordingControlling()
    let permissions: MockPermissionProviding
    let source: MockAudioSourceProviding
    let clock = ManualClock()
    let location: MockSaveLocationProviding
    let notifications: NotificationCenter
    let model: RecorderViewModel

    init(permission: PermissionStatus = .granted, selection: AudioSource = .systemAll,
         installation: InstallLocation = .applications, pollClock: PollClock? = nil,
         timeout: TimeInterval = 2, presenter: (() -> Void)? = nil) {
        domain = "recscribe-contract-\(UUID())"
        defaults = UserDefaults(suiteName: domain)!
        permissions = MockPermissionProviding(permission)
        source = MockAudioSourceProviding(selectedSource: selection)
        location = MockSaveLocationProviding(directory: FileManager.default.temporaryDirectory)
        notifications = NotificationCenter()
        model = RecorderViewModel(controller: controller, permissions: permissions, clock: clock, saveLocation: location,
            audioSource: source, installLocation: MockInstallLocationProviding(installation), defaults: defaults,
            installNoticePresenter: presenter, notificationCenter: notifications, pollClock: pollClock,
            registrationTimeout: timeout)
    }
    func cleanup() { defaults.removePersistentDomain(forName: domain) }
}
