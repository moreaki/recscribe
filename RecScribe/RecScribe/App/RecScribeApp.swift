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
                .environment(services.runtime)
                .environment(\.studioNavigation, services.navigation)
                .environment(\.makeOverflowMenu, services.makeOverflowMenu)
        }
        .defaultSize(AppWindow.studio.defaultSize).windowResizability(.contentMinSize)
        .commands {
            CommandGroup(after: .newItem) { OpenRecordingsCommand(navigation: services.navigation) }
            CommandGroup(replacing: .appSettings) { OpenSettingsCommand(navigation: services.navigation) }
            CommandGroup(replacing: .help) {
                Button("Welcome to RecScribe") {
                    NSApp.activate(ignoringOtherApps: true)
                    services.recorder.showOnboardingAgain()
                }
            }
        }
    }
}

private struct OpenSettingsCommand: View {
    let navigation: StudioNavigation
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Settings…") {
            AppWindow.open(.settings, using: openWindow, navigation: navigation)
        }.keyboardShortcut(",")
    }
}

private struct OpenRecordingsCommand: View {
    let navigation: StudioNavigation
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Button("Recording Studio") {
            AppWindow.open(.studio, using: openWindow, navigation: navigation)
        }.keyboardShortcut(KeyEquivalent(AppWindow.studio.commandKey))
        Button("Live recording") {
            AppWindow.open(.live, using: openWindow, navigation: navigation)
        }.keyboardShortcut(KeyEquivalent(AppWindow.live.commandKey))
        Button("Recordings & Import…") {
            AppWindow.open(.recordings, using: openWindow, navigation: navigation)
        }.keyboardShortcut(KeyEquivalent(AppWindow.recordings.commandKey))
        Button("Audio Routing…") {
            AppWindow.open(.routing, using: openWindow, navigation: navigation)
        }.keyboardShortcut(KeyEquivalent(AppWindow.routing.commandKey))
        Button("Settings…") {
            AppWindow.open(.settings, using: openWindow, navigation: navigation)
        }.keyboardShortcut(KeyEquivalent(AppWindow.settings.commandKey))
        Button("Open Recordings…") {
            AppWindow.open(.recordings, using: openWindow, navigation: navigation)
        }.keyboardShortcut("o")
    }
}


enum AppWindow: String {
    case studio, live, settings, recordings, routing

    var commandKey: Character {
        switch self {
        case .studio: "1"
        case .live: "2"
        case .routing: "4"
        case .recordings: "3"
        case .settings: "5" // Command-comma remains available in the app menu.
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
    static func open(_ window: AppWindow, using openWindow: OpenWindowAction, navigation: StudioNavigation?) {
        if let navigation { navigation.open(window) { openWindow(id: $0) } }
        else { openWindow(id: AppWindow.studio.rawValue) }
    }
    var title: String {
        switch self {
        case .studio: "Recording Studio"
        case .live: "Live recording"
        case .settings: "Settings…"
        case .recordings: "Recordings, Transcription & Summary…"
        case .routing: "Audio Routing…"
        }
    }
    var minimumSize: CGSize {
        switch self {
        case .studio, .live: CGSize(width: 940, height: 600)
        case .settings: CGSize(width: 800, height: 580)
        case .recordings: CGSize(width: 780, height: 500)
        case .routing: CGSize(width: 760, height: 420)
        }
    }
    var defaultSize: CGSize {
        switch self {
        case .studio, .live: CGSize(width: 1120, height: 780)
        case .settings: CGSize(width: 840, height: 700)
        case .recordings: CGSize(width: 960, height: 680)
        case .routing: CGSize(width: 1120, height: 500)
        }
    }
}
