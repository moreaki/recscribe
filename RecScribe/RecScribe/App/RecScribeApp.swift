// Based on Home Rec by Melissa de Britto Pereira; see NOTICE.
// Modified for RecScribe's single-window studio and optional live ASR (2026).
import SwiftUI

@main
struct RecScribeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var services = AppServices()

    var body: some Scene {
        Window("RecScribe", id: AppWindow.studio.rawValue) {
            StudioView().environmentObject(services.recorder)
                .environmentObject(services.live).environmentObject(services.library).environmentObject(services.settings)
                .onAppear { services.bind(to: appDelegate) }
        }
        .defaultSize(AppWindow.studio.defaultSize).windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .appSettings) { OpenSettingsCommand() }
            CommandGroup(after: .newItem) { OpenRecordingsCommand() }
            CommandGroup(replacing: .help) {
                Button("Welcome to RecScribe") {
                    NSApp.activate(ignoringOtherApps: true)
                    services.recorder.showOnboardingAgain()
                }
            }
        }
        Window("RecScribe Settings", id: AppWindow.settings.rawValue) {
            ConfigurationView().environmentObject(services.recorder)
                .environmentObject(services.settings).environmentObject(services.runtime).environmentObject(services.library)
                .onAppear { services.bind(to: appDelegate) }
        }.defaultSize(AppWindow.settings.defaultSize).windowResizability(.contentMinSize)
        Window("Recordings", id: AppWindow.recordings.rawValue) {
            RecordingLibraryView().environmentObject(services.recorder).environmentObject(services.library)
                .onAppear { services.bind(to: appDelegate) }
        }.defaultSize(AppWindow.recordings.defaultSize).windowResizability(.contentMinSize)
        Window("Audio Routing", id: AppWindow.routing.rawValue) {
            AudioRoutingView().environmentObject(services.recorder)
                .onAppear { services.bind(to: appDelegate) }
        }.defaultSize(AppWindow.routing.defaultSize).windowResizability(.contentMinSize)
    }
}

private struct OpenSettingsCommand: View {
    @Environment(\.openWindow) private var openWindow
    var body: some View { Button("Settings…") { openWindow(id: AppWindow.settings.rawValue) }.keyboardShortcut(",") }
}
private struct OpenRecordingsCommand: View {
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Button("Recording Studio") {
            openWindow(id: AppWindow.studio.rawValue)
            NotificationCenter.default.post(name: .recScribeSwitchWorkspaceMode, object: StudioWorkspaceMode.studio)
        }.keyboardShortcut("1")
        Button("Audio Routing…") {
            openWindow(id: AppWindow.studio.rawValue)
            NotificationCenter.default.post(name: .recScribeSwitchWorkspaceMode, object: StudioWorkspaceMode.routing)
        }.keyboardShortcut("2")
        Button("Recordings & Import…") {
            openWindow(id: AppWindow.studio.rawValue)
            NotificationCenter.default.post(name: .recScribeSwitchWorkspaceMode, object: StudioWorkspaceMode.recordings)
        }.keyboardShortcut("3")
        Button("Open Recordings Window…") {
            openWindow(id: AppWindow.recordings.rawValue)
        }.keyboardShortcut("o")
    }
}


enum AppWindow: String {
    case studio, settings, recordings, routing
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
