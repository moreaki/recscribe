import AppKit
import AVFoundation
import CoreGraphics
import ScreenCaptureKit

enum PermissionStatus {
    case notDetermined, granted, denied
}

/// Screen capture is single-flight and latched per user action. Passive callers
/// reuse the answer instead of triggering another system permission dialog.
final class PermissionManager: PermissionProviding {
    private enum ScreenRequest {
        case idle
        case pending(Task<PermissionStatus, Never>)
        case completed(PermissionStatus)
    }
    private var screen = ScreenRequest.idle
    private let probe: @MainActor () async -> PermissionStatus

    init(screenCaptureProbe: @escaping @MainActor () async -> PermissionStatus = {
        do {
            _ = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            return .granted
        } catch {
            return .denied
        }
    }) {
        probe = screenCaptureProbe
    }

    func beginUserRequest(_ kind: PermissionKind) {
        guard kind == .screenCapture else { return }
        if case .pending = screen { return }
        screen = .idle
    }

    func preflight(_ kind: PermissionKind = .screenCapture) -> PermissionStatus {
        if kind == .screenCapture {
            return CGPreflightScreenCaptureAccess() ? .granted : .denied
        }
        let authorization = AVCaptureDevice.authorizationStatus(for: .audio)
        if authorization == .authorized { return .granted }
        if authorization == .notDetermined { return .notDetermined }
        return .denied
    }

    func checkPermission(_ kind: PermissionKind = .screenCapture) async -> PermissionStatus {
        guard kind == .screenCapture else { return preflight(kind) }
        switch screen {
        case .completed(let answer): return answer
        case .pending(let request): return await request.value
        case .idle:
            let request = Task { await probe() }
            screen = .pending(request)
            let answer = await request.value
            screen = .completed(answer)
            return answer
        }
    }

    func requestPermission(_ kind: PermissionKind = .screenCapture) async -> Bool {
        if kind == .screenCapture {
            beginUserRequest(kind)
            return await checkPermission(kind) == .granted
        }
        switch preflight(kind) {
        case .granted: return true
        case .denied: return false
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .audio)
        }
    }

    func openSystemPreferences(for kind: PermissionKind = .screenCapture) {
        let link = "x-apple.systempreferences:com.apple.preference.security?" + kind.settingsAnchor
        if let destination = URL(string: link) { NSWorkspace.shared.open(destination) }
    }
}
