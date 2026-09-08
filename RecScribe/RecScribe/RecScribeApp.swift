// Based on Home Rec by Melissa de Britto Pereira; see NOTICE.
// Modified for RecScribe's single-window studio and optional live ASR (2026).
import SwiftUI
import CoreText
import os

@main
struct RecScribeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var services = AppServices()

    init() {
        for name in ["Archivo-Variable", "Inter"] {
            if let url = Bundle.main.url(forResource: name, withExtension: "ttf") {
                var error: Unmanaged<CFError>?
                if !CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error) {
                    Log.recorder.error("Font registration failed: \(name, privacy: .public)")
                }
            }
        }
    }

    var body: some Scene {
        Window("RecScribe", id: AppWindow.studio.rawValue) {
            StudioView().environmentObject(services.recorder)
                .environmentObject(services.live).environmentObject(services.library)
                .onAppear {
                    appDelegate.prepareForTermination = {
                        if services.recorder.isRecording { await services.recorder.stopRecording() }
                        await services.live.shutdown()
                        await services.library.shutdown()
                        await services.runtime.shutdown()
                    }
                    if appDelegate.menuBarController == nil {
                        appDelegate.menuBarController = MenuBarController(viewModel: services.recorder, live: services.live)
                    }
                }
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
        }.defaultSize(AppWindow.settings.defaultSize).windowResizability(.contentMinSize)
        Window("Recordings", id: AppWindow.recordings.rawValue) {
            RecordingLibraryView().environmentObject(services.recorder).environmentObject(services.library)
        }.defaultSize(AppWindow.recordings.defaultSize).windowResizability(.contentMinSize)
    }
}

private struct OpenSettingsCommand: View {
    @Environment(\.openWindow) private var openWindow
    var body: some View { Button("Settings…") { openWindow(id: AppWindow.settings.rawValue) }.keyboardShortcut(",") }
}
private struct OpenRecordingsCommand: View {
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Button("Recording Studio") { openWindow(id: AppWindow.studio.rawValue) }.keyboardShortcut("1")
        Button("Recordings & Import…") { openWindow(id: AppWindow.recordings.rawValue) }.keyboardShortcut("o")
    }
}
