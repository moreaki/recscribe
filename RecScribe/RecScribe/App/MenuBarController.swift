import AppKit
import SwiftUI

@MainActor final class MenuBarController: NSObject {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let popover = NSPopover()
    private let layout = PopoverLayout()
    private let viewModel: RecorderViewModel
    private let actions: OverflowMenu
    private let cache = PerAppListCache()
    private var appMenu: PerAppMenuDelegate?
    private var recordingObservation: ObservationSubscription?

    init(viewModel: RecorderViewModel, live: LiveTranscription? = nil, actions: OverflowMenu) {
        self.viewModel = viewModel
        self.actions = actions
        super.init()
        let content = MenuBarPopoverView(live: live, layout: layout).environment(viewModel)
            .environment(\.makeOverflowMenu, { [weak self] in self?.makeOverflowMenu() ?? actions.makeNSMenu() })
        let controller = NSHostingController(rootView: content)
        controller.sizingOptions = [.preferredContentSize]
        popover.contentViewController = controller
        popover.behavior = .transient
        popover.appearance = .init(named: .darkAqua)
        statusItem.button?.target = self
        statusItem.button?.action = #selector(activateStatusItem(_:))
        statusItem.button?.sendAction(on: [.rightMouseUp, .leftMouseUp])
        updateIcon(recording: viewModel.isRecording)
        recordingObservation = ObservationSubscription(read: { viewModel.isRecording }) { [weak self] value in
            self?.updateIcon(recording: value)
        }
    }
    private func updateIcon(recording: Bool) {
        let symbol = recording ? "record.circle.fill" : "waveform"
        let picture = NSImage(systemSymbolName: symbol, accessibilityDescription: recording ? "Recording" : "RecScribe")
        picture?.isTemplate = !recording
        statusItem.button?.image = picture
        statusItem.button?.contentTintColor = recording ? .red : nil
    }
    static func shouldShowOverflowMenu(type: NSEvent.EventType, modifiers: NSEvent.ModifierFlags) -> Bool {
        switch type {
        case .rightMouseUp: true
        case .leftMouseUp: !modifiers.intersection(.control).isEmpty
        default: false
        }
    }
    @objc private func activateStatusItem(_ sender: Any?) {
        let event = NSApp.currentEvent
        if Self.shouldShowOverflowMenu(type: event?.type ?? .leftMouseUp, modifiers: event?.modifierFlags ?? []) {
            popover.performClose(nil)
            statusItem.menu = makeOverflowMenu()
            defer { statusItem.menu = nil }
            statusItem.button?.performClick(nil)
        } else if popover.isShown { popover.performClose(sender) }
        else if let button = statusItem.button {
            layout.update(screen: button.window?.screen)
            popover.animates = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }
    private func snapshot() -> OverflowContext {
        let selection = viewModel.selectedSource
        let devices = viewModel.audioSource.availableInputDevices()
        return .init(selectedSource: selection, allowsCaptureSourceChange: viewModel.allowsCaptureSourceChange,
                     permissionGranted: viewModel.permissionStatus == .granted, apps: cache.apps,
                     selectedAppName: selection.appBundleID.flatMap(viewModel.audioSource.knownAppName(forBundleID:)),
                     inputDevices: devices, selectedMicName: devices.first { $0.uid == selection.microphoneUID }?.name)
    }
    func makeOverflowMenu() -> NSMenu {
        let result = actions.makeNSMenu(snapshot())
        let delegate = PerAppMenuDelegate(cache: cache, source: viewModel.audioSource, actions: actions,
                                         makeContext: { [weak self] in self?.snapshot() ?? .init() })
        appMenu = delegate
        let row = result.items.first { $0.identifier?.rawValue == OverflowMenu.perAppItemIdentifier }
        row?.submenu?.delegate = delegate
        return result
    }
    func close() {
        recordingObservation?.cancel()
        recordingObservation = nil
        popover.performClose(nil)
        popover.contentViewController = nil
        appMenu = nil
        NSStatusBar.system.removeStatusItem(statusItem)
    }
}
