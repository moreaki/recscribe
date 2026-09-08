import SwiftUI

struct SettingsPopover: View {
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        GlassIconButton(systemImage: "slider.horizontal.3", accessibilityLabel: "Settings",
                        accessibilityHint: "Storage, transcription, models and local AI") {
            openWindow(id: AppWindow.settings.rawValue)
        }
    }
}
