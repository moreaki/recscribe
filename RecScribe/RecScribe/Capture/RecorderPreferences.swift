import AppKit
import Observation

@MainActor @Observable final class RecorderPreferences {
    let saveLocation: SaveLocationProviding
    private let storage: UserDefaults
    private(set) var saveLocationName: String
    private(set) var hasCustomSaveLocation: Bool
    var showOnboarding: Bool
    var saveLocationPath: String { saveLocation.resolvedDirectory.path }

    init(saveLocation: SaveLocationProviding, defaults: UserDefaults) {
        self.saveLocation = saveLocation
        storage = defaults
        showOnboarding = !defaults.bool(forKey: "hasCompletedOnboarding")
        saveLocationName = saveLocation.configuredDirectory?.lastPathComponent ?? "Desktop"
        hasCustomSaveLocation = saveLocation.configuredDirectory != nil
    }
    func chooseSaveLocation() {
        let chooser = NSOpenPanel()
        chooser.canChooseDirectories = true
        chooser.canChooseFiles = false
        chooser.canCreateDirectories = true
        chooser.allowsMultipleSelection = false
        chooser.directoryURL = saveLocation.resolvedDirectory
        chooser.prompt = "Choose"
        chooser.message = "Choose where RecScribe saves recordings"
        NSApp.activate(ignoringOtherApps: true)
        guard chooser.runModal() == .OK, let selected = chooser.url else { return }
        saveLocation.setSaveDirectory(selected)
        refresh()
    }
    func resetSaveLocation() { saveLocation.reset(); refresh() }
    private func refresh() {
        let selected = saveLocation.configuredDirectory
        saveLocationName = selected?.lastPathComponent ?? "Desktop"
        hasCustomSaveLocation = selected != nil
    }
    func completeOnboarding() {
        storage.set(true, forKey: "hasCompletedOnboarding")
        showOnboarding = false
    }
}

@MainActor @Observable final class RecorderAlerts {
    var errorMessage: String? = nil
    var showError = false
    var reviewMessage: String? = nil
    var recoverySuggestion: RecoverySuggestion? = nil
    var showLongRecordingWarning = false
    func present(_ message: String, recovery: RecoverySuggestion?) {
        recoverySuggestion = recovery
        errorMessage = message
        showError = true
    }
}
