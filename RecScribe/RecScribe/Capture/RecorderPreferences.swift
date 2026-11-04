import AppKit
import Observation

@MainActor
@Observable final class RecorderPreferences {
    let saveLocation: SaveLocationProviding
    private let defaults: UserDefaults
    private let onboardingCompletedKey = "hasCompletedOnboarding"
    private let selectedFormatKey = "selectedFormat"
    private(set) var saveLocationName = "Desktop"
    private(set) var hasCustomSaveLocation = false
    private(set) var selectedFormat: AudioFormat
    var showOnboarding: Bool
    var saveLocationPath: String { saveLocation.resolvedDirectory.path }

    init(saveLocation: SaveLocationProviding, defaults: UserDefaults) {
        self.saveLocation = saveLocation
        self.defaults = defaults
        showOnboarding = !defaults.bool(forKey: onboardingCompletedKey)
        selectedFormat = Self.loadFormat(from: defaults, key: selectedFormatKey)
        refreshSaveLocationDisplay()
    }
    func chooseSaveLocation() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.directoryURL = saveLocation.resolvedDirectory
        panel.prompt = "Choose"
        panel.message = "Choose where RecScribe saves recordings"

        NSApp.activate(ignoringOtherApps: true)
        if panel.runModal() == .OK, let url = panel.url {
            saveLocation.setSaveDirectory(url)
            refreshSaveLocationDisplay()
        }
    }

    func resetSaveLocation() {
        saveLocation.reset()
        refreshSaveLocationDisplay()
    }

    func setFormat(_ format: AudioFormat) {
        guard AudioFormat.available.contains(format) else { return }
        selectedFormat = format
        defaults.set(format.rawValue, forKey: selectedFormatKey)
    }

    func completeOnboarding() {
        defaults.set(true, forKey: onboardingCompletedKey)
        showOnboarding = false
    }

    private func refreshSaveLocationDisplay() {
        saveLocationName = saveLocation.configuredDirectory?.lastPathComponent ?? "Desktop"
        hasCustomSaveLocation = saveLocation.configuredDirectory != nil
    }

    private static func loadFormat(from defaults: UserDefaults, key: String) -> AudioFormat {
        guard
            let raw = defaults.string(forKey: key),
            let format = AudioFormat(rawValue: raw),
            AudioFormat.available.contains(format)
        else {
            return .wav
        }
        return format
    }
}

@MainActor
@Observable final class RecorderAlerts {
    var errorMessage: String?
    var showError = false
    var recoverySuggestion: RecoverySuggestion?
    var showLongRecordingWarning = false

    func present(_ message: String, recovery: RecoverySuggestion?) {
        errorMessage = message
        recoverySuggestion = recovery
        showError = true
    }
}
