import SwiftUI

enum AppWindow: String {
    case settings, recordings
    var title: String {
        switch self {
        case .settings: "Settings…"
        case .recordings: "Recordings, Transcription & Summary…"
        }
    }
    var minimumSize: CGSize {
        switch self {
        case .settings: CGSize(width: 700, height: 560)
        case .recordings: CGSize(width: 780, height: 500)
        }
    }
    var defaultSize: CGSize {
        switch self {
        case .settings: CGSize(width: 740, height: 620)
        case .recordings: CGSize(width: 820, height: 620)
        }
    }
}
