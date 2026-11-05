import Foundation

enum PermissionKind: Sendable {
    case screenCapture, microphone
    private var pane: (anchor: String, title: String) {
        self == .microphone ? ("Privacy_Microphone", "Microphone")
            : ("Privacy_ScreenCapture", "Screen & System Audio Recording")
    }
    var settingsAnchor: String { pane.anchor }
    var settingsSectionName: String { pane.title }
    var confusableSectionName: String? { self == .screenCapture ? "System Audio Recording Only" : nil }
    var navigationHint: String {
        let location = "In System Settings, enable RecScribe under \(pane.title)."
        guard let other = confusableSectionName else { return location }
        return location + " The \(other) list is a separate permission. Reopen RecScribe if access is not detected after enabling it."
    }
}
