import Foundation

/// Native permission contract: preflight is silent, user requests may prompt,
/// and passive checks share the current screen-request result.
@MainActor protocol PermissionProviding {
    func beginUserRequest(_ kind: PermissionKind)
    func preflight(_ kind: PermissionKind) -> PermissionStatus
    func checkPermission(_ kind: PermissionKind) async -> PermissionStatus
    func requestPermission(_ kind: PermissionKind) async -> Bool
    func openSystemPreferences(for kind: PermissionKind)
}

extension PermissionProviding {
    func beginUserRequest(_ kind: PermissionKind) {}
    func preflight() -> PermissionStatus { preflight(.screenCapture) }
    func checkPermission() async -> PermissionStatus { await checkPermission(.screenCapture) }
    func requestPermission() async -> Bool { await requestPermission(.screenCapture) }
    func openSystemPreferences() { openSystemPreferences(for: .screenCapture) }
}
