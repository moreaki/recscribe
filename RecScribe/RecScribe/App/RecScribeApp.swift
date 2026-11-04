// Based on Home Rec by Melissa de Britto Pereira; see NOTICE.
// Modified for RecScribe's single-window studio and optional live ASR (2026).
import SwiftUI
import os

@main
struct RecScribeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    private var services: AppServices { appDelegate.services }

    var body: some Scene {
        Window("RecScribe", id: AppWindow.studio.rawValue) {
            StudioView().environment(services.recorder)
                .environment(services.live).environment(services.library).environment(services.settings)
                .environment(\.studioNavigation, services.navigation)
                .environment(\.makeOverflowMenu, services.makeOverflowMenu)
        }
        .defaultSize(AppWindow.studio.defaultSize).windowResizability(.contentMinSize)
        .commands {
            CommandGroup(after: .newItem) { OpenRecordingsCommand(navigation: services.navigation) }
            CommandGroup(replacing: .help) {
                Button("Welcome to RecScribe") {
                    NSApp.activate(ignoringOtherApps: true)
                    services.recorder.showOnboardingAgain()
                }
            }
        }
        Settings {
            ConfigurationView().environment(services.recorder)
                .environment(services.settings).environment(services.runtime).environment(services.library)
                .environment(\.studioNavigation, services.navigation)
        }.windowResizability(.contentMinSize)
    }
}

private struct OpenRecordingsCommand: View {
    let navigation: StudioNavigation
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Button("Recording Studio") {
            AppWindow.open(.studio, using: openWindow, navigation: navigation)
        }.keyboardShortcut(KeyEquivalent(AppWindow.studio.commandKey))
        Button("Audio Routing…") {
            AppWindow.open(.routing, using: openWindow, navigation: navigation)
        }.keyboardShortcut(KeyEquivalent(AppWindow.routing.commandKey))
        Button("Recordings & Import…") {
            AppWindow.open(.recordings, using: openWindow, navigation: navigation)
        }.keyboardShortcut(KeyEquivalent(AppWindow.recordings.commandKey))
        Button("Open Recordings…") {
            AppWindow.open(.recordings, using: openWindow, navigation: navigation)
        }.keyboardShortcut("o")
    }
}


enum AppWindow: String {
    case studio, settings, recordings, routing

    var commandKey: Character {
        switch self {
        case .studio: "1"
        case .routing: "2"
        case .recordings: "3"
        case .settings: "," // SwiftUI's native Settings command.
        }
    }

    /// AppKit surfaces invoke the same native commands as keyboard navigation.
    /// Those commands exist without a Studio view and own SwiftUI's scene actions.
    @MainActor
    static func openFromMenu(_ destination: Self) {
        NSApp.activate(ignoringOtherApps: true)
        guard let menu = NSApp.mainMenu, performOpenCommand(destination, in: menu) else {
            Logger(subsystem: "com.moreaki.recscribe", category: "Windows")
                .error("Window command unavailable: \(destination.rawValue, privacy: .public)")
            return
        }
    }

    @MainActor
    @discardableResult
    static func performOpenCommand(_ destination: Self, in menu: NSMenu) -> Bool {
        for (index, item) in menu.items.enumerated() where !item.isHidden {
            if item.keyEquivalent == String(destination.commandKey), item.keyEquivalentModifierMask == .command {
                menu.update()
                guard item.isEnabled, item.action != nil else { return false }
                menu.performActionForItem(at: index)
                return true
            }
            if let submenu = item.submenu, performOpenCommand(destination, in: submenu) { return true }
        }
        return false
    }

    @MainActor
    static func open(_ window: AppWindow, using openWindow: OpenWindowAction, navigation: StudioNavigation?,
                     openSettings: () -> Void = {}) {
        if window == .settings { openSettings(); return }
        if let navigation { navigation.open(window) { openWindow(id: $0) } }
        else { openWindow(id: AppWindow.studio.rawValue) }
    }
    var title: String {
        switch self {
        case .studio: "Recording Studio"
        case .settings: "Settings…"
        case .recordings: "Recordings, Transcription & Summary…"
        case .routing: "Audio Routing…"
        }
    }
    var minimumSize: CGSize {
        switch self {
        case .studio: CGSize(width: 940, height: 600)
        case .settings: CGSize(width: 800, height: 580)
        case .recordings: CGSize(width: 780, height: 500)
        case .routing: CGSize(width: 760, height: 420)
        }
    }
    var defaultSize: CGSize {
        switch self {
        case .studio: CGSize(width: 1060, height: 700)
        case .settings: CGSize(width: 840, height: 700)
        case .recordings: CGSize(width: 960, height: 680)
        case .routing: CGSize(width: 1120, height: 500)
        }
    }
}
