//
//  FloatingPanelHost.swift
//  RecScribe
//
//  The floating utility panel every out-of-band explanation sits on (BL-081,
//  reused by BL-082).
//
//  A panel rather than a sheet or the popover, because the content has to remain
//  readable *while another app is frontmost* — the menu-bar popover is
//  `.transient` and dies on focus loss, and the main window may not exist at all
//  in a menu-bar app. Configuration verified by spike on macOS 26.5.2; see
//  private/reports/2026-07-26-bl081-panel-surface-spike.md. Every value below
//  carries the reason it was chosen — change none of them casually.
//

import AppKit
import SwiftUI

@MainActor
final class FloatingPanelHost: NSObject, NSWindowDelegate {

    private var panel: NSPanel?
    private let title: String
    private let width: CGFloat
    private let makeContent: () -> AnyView

    /// Fired whenever the window closes, including via the titlebar close button —
    /// which bypasses `dismiss()` entirely, because AppKit closes the window
    /// directly. Anything with a lifetime tied to the panel being on screen must
    /// hang off this and not off `dismiss()`.
    var onWillClose: (() -> Void)?

    init(title: String, width: CGFloat, content: @escaping () -> AnyView) {
        self.title = title
        self.width = width
        self.makeContent = content
        super.init()
    }

    func windowWillClose(_ notification: Notification) {
        onWillClose?()
    }

    var isVisible: Bool { panel?.isVisible ?? false }

    func show() {
        if let panel {
            panel.orderFront(nil)
            return
        }

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: width, height: 180),
            // `.nonactivatingPanel` keeps a click on the panel from yanking RecScribe
            // in front of the Settings window the user is working in.
            styleMask: [.titled, .closable, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.title = title
        // A panel sitting behind the window it describes would be useless.
        panel.level = .floating
        // The spike found this property is not currently honoured — every panel
        // configuration survived deactivation, including ones that should have
        // hidden. Set it anyway: it is the documented lever, it costs nothing, and
        // relying on undocumented behaviour to keep the panel on screen is exactly
        // the kind of thing that breaks in a future macOS. (Note that
        // `.nonactivatingPanel` also sets it as an undocumented side effect.)
        panel.hidesOnDeactivate = false
        panel.isFloatingPanel = true
        // Content may rewrite itself continuously (the permission guide polls); it
        // must never pull the keyboard away from System Settings.
        panel.becomesKeyOnlyIfNeeded = true
        panel.isReleasedWhenClosed = false
        // Follow the user across Spaces and over full-screen apps: a panel pinned
        // to the Space it opened on is invisible to someone who opens System
        // Settings on another one. Not verified against a real multi-Space setup —
        // it is the documented behaviour for utility panels and costs nothing.
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.delegate = self

        panel.contentView = NSHostingView(rootView: makeContent())
        panel.center()
        panel.orderFront(nil)

        self.panel = panel
    }

    func dismiss() {
        panel?.orderOut(nil)
    }
}
