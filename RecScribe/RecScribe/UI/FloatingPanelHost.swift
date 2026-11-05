import AppKit
import SwiftUI

/// A reusable, nonactivating explanation window. SwiftUI content is rebuilt on
/// each presentation so an earlier permission/install message cannot be retained.
@MainActor final class FloatingPanelHost: NSObject, NSWindowDelegate {
    private let title: String
    private let width: CGFloat
    private let makeContent: () -> AnyView
    private var window: NSPanel?
    var onWillClose: (() -> Void)?
    var isVisible: Bool { window?.isVisible == true }

    init(title: String, width: CGFloat, content: @escaping () -> AnyView) {
        self.title = title
        self.width = width
        makeContent = content
        super.init()
    }
    func show() {
        let panel: NSPanel
        if let existing = window { panel = existing }
        else {
            panel = NSPanel(contentRect: .init(x: 0, y: 0, width: width, height: 180),
                            styleMask: [.titled, .closable, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.title = title
            panel.isReleasedWhenClosed = false
            panel.hidesOnDeactivate = false
            panel.isFloatingPanel = true
            panel.becomesKeyOnlyIfNeeded = true
            panel.level = .floating
            panel.collectionBehavior = [.fullScreenAuxiliary, .canJoinAllSpaces]
            panel.delegate = self
            window = panel
            panel.center()
        }
        panel.contentView = NSHostingView(rootView: makeContent())
        panel.orderFront(nil)
    }
    func dismiss() { window?.orderOut(nil) }
    func windowWillClose(_ notification: Notification) { onWillClose?() }
}
