import SwiftUI

/// Shared app chrome, inspired by Quantivane's compact cards and Modex's
/// restrained workspace. Capture red is reserved for recording, not navigation.
enum WorkspaceStyle {
    static let blue = Color(glassHex: 0x70AEF6)
    static let violet = Color(glassHex: 0xB39CF7)
    static let mint = Color(glassHex: 0x79DCC3)
    static let background = Color(glassHex: 0x101116)
    static let panel = Color(glassHex: 0x1B1D25)
    static let selected = Color(glassHex: 0x282C38)
    static let border = Color.white.opacity(0.09)
    static let contentPadding: CGFloat = 22
    static let railWidth: CGFloat = 320
    static let iconSize: CGFloat = 34
    static let navigationHeight: CGFloat = 34
    static let popoverWidth: CGFloat = 380
    static let previewWidth: CGFloat = 480
    static let previewHeight: CGFloat = 320
    static let readingWidth: CGFloat = 720
    static let lineSpacing: CGFloat = 6
    static let waveformHeight: CGFloat = 64
}

struct WorkspaceIcon: View {
    let symbol: String
    var tint: Color = WorkspaceStyle.blue
    var body: some View {
        Image(systemName: symbol).font(.system(.body, design: .rounded, weight: .semibold))
            .foregroundStyle(tint).frame(width: WorkspaceStyle.iconSize, height: WorkspaceStyle.iconSize)
            .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: GlassRadius.control))
            .accessibilityHidden(true)
    }
}

struct WorkspaceCard<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        content.padding(GlassSpacing.xl).frame(maxWidth: .infinity, alignment: .leading)
            .background(WorkspaceStyle.panel, in: RoundedRectangle(cornerRadius: GlassRadius.card))
            .overlay { RoundedRectangle(cornerRadius: GlassRadius.card).stroke(WorkspaceStyle.border) }
    }
}

enum SettingsSection: String, CaseIterable, Identifiable {
    case storage = "Recording", transcription = "Transcription", models = "Models", ai = "Intelligence", diagnostics = "Diagnostics"
    var id: Self { self }
    var symbol: String {
        switch self {
        case .storage: "waveform.circle.fill"
        case .transcription: "text.bubble.fill"
        case .models: "cpu.fill"
        case .ai: "sparkles"
        case .diagnostics: "chart.xyaxis.line"
        }
    }
    var tint: Color {
        switch self {
        case .storage: WorkspaceStyle.mint
        case .transcription, .diagnostics: WorkspaceStyle.blue
        case .models, .ai: WorkspaceStyle.violet
        }
    }
}

struct SettingsNavigation: View {
    @Binding var selection: SettingsSection
    var body: some View {
        HStack(spacing: GlassSpacing.xs) {
            ForEach(SettingsSection.allCases) { section in
                Button { selection = section } label: {
                    Label(section.rawValue, systemImage: section.symbol).font(.callout.weight(.medium))
                        .foregroundStyle(selection == section ? section.tint : .secondary)
                        .frame(maxWidth: .infinity).frame(height: WorkspaceStyle.navigationHeight)
                        .background(selection == section ? WorkspaceStyle.selected : .clear,
                                    in: RoundedRectangle(cornerRadius: GlassRadius.control))
                        .contentShape(Rectangle())
                }.buttonStyle(.plain).accessibilityAddTraits(selection == section ? .isSelected : [])
            }
        }.padding(GlassSpacing.xs).background(WorkspaceStyle.panel, in: RoundedRectangle(cornerRadius: GlassRadius.control))
    }
}
