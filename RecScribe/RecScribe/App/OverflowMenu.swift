import AppKit
import SwiftUI

struct OverflowAction: Identifiable {
    let id: String
    let title: String
    var commandKey: Character? = nil
    var toolTip: String? = nil
    var isChecked = false
    var isEnabled = true
    var isSourceRow = false
    let perform: @MainActor () -> Void
}
struct OverflowSubmenu: Identifiable {
    let id: String
    let title: String
    var isChecked = false
    var isEnabled = true
    var isSourceRow = true
    let entries: [OverflowEntry]
}
indirect enum OverflowEntry {
    case action(OverflowAction), separator, sectionHeader(String), submenu(OverflowSubmenu), disabledNotice(String)
}

/// Menu rows are derived from a captured value, with I/O confined to deliberate
/// actions and the app-submenu delegate. Merely constructing rows never probes TCC.
@MainActor struct OverflowMenu {
    var onSelectSource: @MainActor (AudioSource) -> Void = { _ in }
    var onRequestPermission: @MainActor () -> Void = {}
    var onRecoverRecordings: @MainActor () -> Void = {}
    var openWindow: @MainActor (AppWindow) -> Void = AppWindow.openFromMenu
    static let perAppItemIdentifier = "sourcePerApp"

    func entries(_ context: OverflowContext) -> [OverflowEntry] {
        captureSourceEntries(context) + appActionEntries(context)
    }
    private func sourceRow(_ identifier: String, title: String, selection: AudioSource, checked: Bool) -> OverflowEntry {
        .action(.init(id: identifier, title: title, isChecked: checked, isSourceRow: true,
                      perform: { onSelectSource(selection) }))
    }
    private func unavailable(_ id: String, title: String) -> OverflowEntry {
        .action(.init(id: id, title: title, isChecked: true, isEnabled: false, isSourceRow: true, perform: {}))
    }
    func captureSourceEntries(_ context: OverflowContext) -> [OverflowEntry] {
        if !context.allowsCaptureSourceChange { return [] }
        return [.sectionHeader("Capture Source"),
                sourceRow("sourceSystemAll", title: "All System Audio", selection: .systemAll,
                          checked: context.selectedSource == .systemAll),
                .submenu(perAppSubmenu(context)), .submenu(microphoneSubmenu(context)), .submenu(mixedSubmenu(context)),
                .action(.init(id: "sourceMultiple", title: "Multiple inputs + playback…",
                    isChecked: context.selectedSource.kind == .multiple, isSourceRow: true, perform: {
                        let selected = context.selectedSource
                        if selected.kind != .multiple {
                            let routes = selected.inputSelections.map { input in
                                context.inputDevices.first(where: { $0.uid == input.deviceUID }).map(InputSelection.init(device:)) ?? input
                            }
                            onSelectSource(.multiple(appBundleID: selected.appBundleID, inputs: routes))
                        }
                        openWindow(.routing)
                    })), .separator]
    }
    func microphoneSubmenu(_ context: OverflowContext) -> OverflowSubmenu {
        let uid = context.selectedSource.kind == .microphone ? context.selectedSource.microphoneUID : nil
        let currentName = context.inputDevices.first(where: { $0.uid == uid })?.name
        var children: [OverflowEntry] = []
        if uid != nil, currentName == nil {
            children = [unavailable("sourceMicNotAvailable", title: "\(context.selectedMicName ?? "Microphone") (not connected)"), .separator]
        }
        children += context.inputDevices.map {
            sourceRow("sourceMic:" + $0.uid, title: $0.name, selection: .mic(deviceUID: $0.uid), checked: uid == $0.uid)
        }
        if context.inputDevices.isEmpty { children.append(.disabledNotice("No microphones found")) }
        return .init(id: "sourceMicrophone", title: currentName ?? (uid == nil ? nil : context.selectedMicName) ?? "Microphone",
                     isChecked: uid != nil, entries: children)
    }
    func mixedSubmenu(_ context: OverflowContext) -> OverflowSubmenu {
        let selected = context.selectedSource
        let bundle = selected.appBundleID
        let name = bundle.map { context.selectedAppName ?? $0 } ?? "System audio"
        var children: [OverflowEntry] = [.disabledNotice("Separate source tracks + stereo mix; use headphones")]
        if selected.isMixed, let uid = selected.microphoneUID, !context.inputDevices.contains(where: { $0.uid == uid }) {
            children.append(.disabledNotice("Selected input is not connected"))
        }
        if context.inputDevices.isEmpty { children.append(.disabledNotice("No inputs found")) }
        for device in context.inputDevices {
            let option = AudioSource.mixed(appBundleID: bundle, deviceUID: device.uid)
            children.append(sourceRow("sourceMixed:" + device.uid, title: name + " + " + device.name,
                                      selection: option, checked: option == selected))
        }
        return .init(id: "sourceMixed", title: "Playback + microphone", isChecked: selected.kind == .mixed, entries: children)
    }
    func perAppSubmenu(_ context: OverflowContext) -> OverflowSubmenu {
        let chosen = context.selectedSource.kind == .app ? context.selectedSource.appBundleID : nil
        let title = chosen.map { id in context.apps?.first(where: { $0.bundleID == id })?.applicationName ?? context.selectedAppName ?? id } ?? "App"
        var children: [OverflowEntry] = []
        if !context.permissionGranted {
            children = [.action(.init(id: "sourcePermissionNeeded", title: "Allow Screen Recording…", perform: onRequestPermission))]
        } else {
            if let chosen, context.apps?.contains(where: { $0.bundleID == chosen }) != true {
                children += [unavailable("sourceAppNotRunning", title: (context.selectedAppName ?? chosen) + " (not running)"), .separator]
            }
            if let apps = context.apps {
                children += apps.map { app in
                    sourceRow("sourceApp:" + app.bundleID,
                        title: app.applicationName + (app.isAudioActive ? " · Playing audio" : ""),
                        selection: .app(bundleID: app.bundleID), checked: app.bundleID == chosen)
                }
                if apps.isEmpty { children.append(.disabledNotice("No other apps are open")) }
            } else { children.append(.disabledNotice("Looking for open apps…")) }
        }
        return .init(id: Self.perAppItemIdentifier, title: title, isChecked: chosen != nil, entries: children)
    }

    func appActionEntries(_ context: OverflowContext) -> [OverflowEntry] {
        func navigate(_ destination: AppWindow) { NSApp.activate(ignoringOtherApps: true); openWindow(destination) }
        return [
            .action(.init(id: "showWindow", title: "Show Window", perform: { navigate(.studio) })),
            .action(.init(id: "recordings", title: AppWindow.recordings.title, perform: { openWindow(.recordings) })),
            .action(.init(id: "settings", title: AppWindow.settings.title, perform: { openWindow(.settings) })), .separator,
            .action(.init(id: "recoverRecordings", title: "Recover Recordings…",
                          toolTip: "Verify and recover interrupted saved sessions.", perform: { onRecoverRecordings(); navigate(.recordings) })), .separator,
            .action(.init(id: "exportDiagnostics", title: "Export Diagnostics…", perform: Diagnostics.exportReport)),
            .action(.init(id: "reportProblem", title: "Report a Problem", perform: Diagnostics.reportProblem)),
            .action(.init(id: "about", title: "About RecScribe", perform: {
                NSApp.activate(ignoringOtherApps: true)
                NSApp.orderFrontStandardAboutPanel(nil)
            })), .separator,
            .action(.init(id: "quit", title: "Quit RecScribe", commandKey: "q", perform: { NSApp.terminate(nil) }))]
    }
    func actions(_ context: OverflowContext = .init()) -> [OverflowAction] {
        var result: [OverflowAction] = []
        func visit(_ entries: [OverflowEntry]) {
            for row in entries {
                if case .action(let value) = row { result.append(value) }
                if case .submenu(let nested) = row {
                    result.append(.init(id: nested.id, title: nested.title, isChecked: nested.isChecked,
                                        isEnabled: nested.isEnabled, isSourceRow: nested.isSourceRow, perform: {}))
                    visit(nested.entries)
                }
            }
        }
        visit(entries(context))
        return result
    }
    func makeNSMenu(_ context: OverflowContext = .init()) -> NSMenu {
        let native = NSMenu()
        Self.populate(native, with: entries(context))
        return native
    }
    static func populate(_ menu: NSMenu, with entries: [OverflowEntry]) {
        menu.removeAllItems()
        menu.autoenablesItems = false
        for entry in entries { menu.addItem(nativeItem(entry)) }
    }
    private static func nativeItem(_ row: OverflowEntry) -> NSMenuItem {
        switch row {
        case .separator: return .separator()
        case .sectionHeader(let text): return .sectionHeader(title: text)
        case .disabledNotice(let text):
            let value = NSMenuItem(title: text, action: nil, keyEquivalent: "")
            value.isEnabled = false
            return value
        case .submenu(let nested):
            let value = NSMenuItem(title: nested.title, action: nil, keyEquivalent: "")
            value.identifier = .init(nested.id)
            value.isEnabled = nested.isEnabled
            value.state = nested.isChecked ? .on : .off
            let child = NSMenu(title: nested.title)
            populate(child, with: nested.entries)
            value.submenu = child
            return value
        case .action(let action):
            let value = NSMenuItem(title: action.title, action: nil, keyEquivalent: action.commandKey.map(String.init) ?? "")
            value.identifier = .init(action.id)
            value.toolTip = action.toolTip
            value.isEnabled = action.isEnabled
            value.state = action.isChecked ? .on : .off
            if action.isEnabled {
                let invocation = MenuInvocation(action.perform)
                value.representedObject = invocation
                value.target = invocation
                value.action = #selector(MenuInvocation.invoke(_:))
            }
            return value
        }
    }
}

@MainActor private final class MenuInvocation: NSObject {
    let action: @MainActor () -> Void
    init(_ action: @escaping @MainActor () -> Void) { self.action = action }
    @objc func invoke(_ sender: Any?) { action() }
}

private struct OverflowMenuEnvironment: EnvironmentKey {
    static let defaultValue: @MainActor () -> NSMenu = { OverflowMenu().makeNSMenu() }
}
extension EnvironmentValues {
    var makeOverflowMenu: @MainActor () -> NSMenu {
        get { self[OverflowMenuEnvironment.self] }
        set { self[OverflowMenuEnvironment.self] = newValue }
    }
}
struct OverflowMenuButton: View {
    @Environment(\.makeOverflowMenu) private var createMenu
    var body: some View {
        Button {
            createMenu().popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
        } label: {
            Image(systemName: "ellipsis").font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary).frame(width: 22, height: 22).contentShape(Rectangle())
        }
        .buttonStyle(.plain).help("More options").accessibilityLabel("More options")
    }
}
