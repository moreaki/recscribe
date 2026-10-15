import SwiftUI

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
