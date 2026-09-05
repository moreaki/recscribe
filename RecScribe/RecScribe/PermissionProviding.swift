//
//  PermissionProviding.swift
//  RecScribe
//
//  Abstraction over system permission state so the view model can be tested
//  with a fake provider instead of the real system permission.
//

import Foundation

/// Supplies permission state and the request flow. Implemented by `PermissionManager`.
///
/// Every method takes a `PermissionKind` with a default, so today's single-permission
/// call sites read unchanged while BL-130's microphone permission slots in without
/// touching this seam again. The *copy* for each kind lives on `PermissionKind`
/// rather than here: it's pure data with no system state behind it, so routing it
/// through a mockable protocol would only force every test double to restate the
/// same strings.
@MainActor
protocol PermissionProviding {
    /// Cheap, silent read of permission state — **only trustworthy at launch** (BL-085).
    ///
    /// ⚠️ **The result is latched when the process starts and never refreshes.**
    /// Measured 2026-07-26 on macOS 26.5.2: with permission revoked in System
    /// Settings while the app was running, `preflight` kept answering `.granted`
    /// for 57 seconds across ~50 samples, while `checkPermission` reported the
    /// revocation instantly. A launch that began ungranted read `.denied`
    /// correctly — so it is accurate at launch and frozen thereafter.
    ///
    /// **Never poll this, and never use it to observe a change.** Doing so would
    /// latch `.denied` at launch and wait forever, which is precisely what
    /// BL-081's guide must not do. Use `checkPermission` for anything live.
    ///
    /// What it buys: no system prompt and no side effects, so the app can know
    /// its own state at startup without asking the user for anything.
    func preflight(_ kind: PermissionKind) -> PermissionStatus

    /// Authoritative, live permission state.
    ///
    /// Tracks changes made while the process is running, which is why the guide's
    /// poll loop and the activation re-probe both depend on it. The cost is that
    /// this call **can raise the system prompt** and registers the app into the
    /// System Settings list — so it must only run behind a deliberate user action
    /// or while the guide is on screen. See BL-085.
    func checkPermission(_ kind: PermissionKind) async -> PermissionStatus

    func requestPermission(_ kind: PermissionKind) async -> Bool
    func openSystemPreferences(for kind: PermissionKind)
}

extension PermissionProviding {
    func preflight() -> PermissionStatus {
        preflight(.screenCapture)
    }

    func checkPermission() async -> PermissionStatus {
        await checkPermission(.screenCapture)
    }

    func requestPermission() async -> Bool {
        await requestPermission(.screenCapture)
    }

    func openSystemPreferences() {
        openSystemPreferences(for: .screenCapture)
    }
}
