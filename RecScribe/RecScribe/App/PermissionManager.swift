//
//  PermissionManager.swift
//  RecScribe
//
//  Screen Recording permission: probing current state and opening the pane where
//  the user grants it.
//

import Foundation
import AVFoundation
import ScreenCaptureKit
import AppKit
import CoreGraphics

/// Permission status states
enum PermissionStatus {
    case notDetermined
    case granted
    case denied
}

/// Manages the system permissions RecScribe depends on.
class PermissionManager: PermissionProviding {
    private let screenCaptureProbe: @MainActor () async -> PermissionStatus
    private var screenCaptureResult: PermissionStatus?
    private var screenCaptureTask: Task<PermissionStatus, Never>?

    init(screenCaptureProbe: @escaping @MainActor () async -> PermissionStatus = {
        do {
            _ = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            return .granted
        } catch { return .denied }
    }) {
        self.screenCaptureProbe = screenCaptureProbe
    }

    /// Only a deliberate retry may issue another prompting ScreenCaptureKit call.
    /// Automatic polling/activation reuses the result of this user request.
    func beginUserRequest(_ kind: PermissionKind) {
        if kind == .screenCapture, screenCaptureTask == nil { screenCaptureResult = nil }
    }

    /// Silent, launch-only read. See `PermissionProviding.preflight` for the
    /// latching behaviour that makes this unusable for observing changes.
    ///
    /// `CGPreflightScreenCaptureAccess` is **not** deprecated — plain
    /// `API_AVAILABLE(macos(10.15))` in `CGWindow.h` on the current SDK. The
    /// project previously believed otherwise; the real reason it can't replace
    /// `checkPermission` is that its answer is frozen at process start (BL-085).
    ///
    /// Returns `.denied` rather than `.notDetermined` when access is absent: the
    /// API is a `Bool` and cannot distinguish "never asked" from "refused", and
    /// the UI treats both identically (offer the guide).
    func preflight(_ kind: PermissionKind = .screenCapture) -> PermissionStatus {
        switch kind {
        case .screenCapture:
            return CGPreflightScreenCaptureAccess() ? .granted : .denied
        case .microphone:
            // ⚠️ The "latched at process start" caveat above is a *screen
            // capture* property, not a general one. `AVCaptureDevice`'s status
            // is live and updates within the session, so for this kind preflight
            // is trustworthy at any time — not only at launch.
            switch AVCaptureDevice.authorizationStatus(for: .audio) {
            case .authorized:                 return .granted
            case .notDetermined:              return .notDetermined
            case .denied, .restricted:        return .denied
            @unknown default:                 return .denied
            }
        }
    }

    /// One system probe per explicit request, shared by concurrent callers.
    /// ScreenCaptureKit can prompt on every call on current macOS releases;
    /// repeating it from the grant timer traps the user in a permission dialog.
    func checkPermission(_ kind: PermissionKind = .screenCapture) async -> PermissionStatus {
        switch kind {
        case .screenCapture:
            if let screenCaptureTask { return await screenCaptureTask.value }
            if let screenCaptureResult { return screenCaptureResult }
            let probe = Task { await screenCaptureProbe() }
            screenCaptureTask = probe
            let result = await probe.value
            screenCaptureResult = result
            screenCaptureTask = nil
            return result
        case .microphone:
            // No probing side effect to worry about here: reading the status is
            // free and silent. Unlike `SCShareableContent`, it neither prompts
            // nor registers the app anywhere.
            return preflight(.microphone)
        }
    }

    /// Explicit user request/retry. Automatic observations must not reset it.
    ///
    /// This deliberately does **not** open System Settings any more (BL-087). It
    /// used to, as a side effect, which meant the record-while-denied path opened
    /// the pane once with no guide attached and then again via the error's
    /// recovery action. The view model owns every decision to open Settings, so
    /// that every one of them is registered, guided, and granted-gated.
    func requestPermission(_ kind: PermissionKind = .screenCapture) async -> Bool {
        switch kind {
        case .screenCapture:
            beginUserRequest(kind)
            return await checkPermission(kind) == .granted
        case .microphone:
            // `checkPermission(.microphone)` is deliberately a silent read, so
            // it can never raise the prompt. Requesting is a different act:
            // unlike Screen Recording, macOS will genuinely re-prompt for the
            // microphone while the status is `.notDetermined`.
            //
            // This lives here rather than in the view model so the whole branch
            // sits behind `PermissionProviding` and a test can reach it — the
            // reason BL-161 shipped is that the view model called
            // `AVCaptureDevice` directly and no test could get near it.
            //
            // ⚠️ Once TCC has denied, `requestAccess` returns false immediately
            // and shows nothing. The caller must surface that, not retry.
            if preflight(.microphone) == .granted { return true }
            return await AVCaptureDevice.requestAccess(for: .audio)
        }
    }

    /// Open System Settings at the pane for `kind`.
    ///
    /// Deep-linking to the pane is the most macOS allows — there is no API to
    /// scroll to or highlight our row, which is why the guide has to describe
    /// where to look instead.
    func openSystemPreferences(for kind: PermissionKind = .screenCapture) {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(kind.settingsAnchor)") else {
            return
        }
        NSWorkspace.shared.open(url)
    }
}
