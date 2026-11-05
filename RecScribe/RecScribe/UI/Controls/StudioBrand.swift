import SwiftUI

/// Product artwork is expressed directly in SwiftUI; no inherited logo file is
/// consulted by the window or menu-bar lockup.
enum StudioBrand {
    static let name = "RecScribe"
    static let markSquare = Color(studioHex: 0x162235)
    static let markEdge = Color(studioHex: 0x4D8CF5)
    static let markDot = Color(studioHex: 0xFF4E57)
    static let waveform = Color(studioHex: 0xDDFBFF)
}

struct StudioBrandMark: View {
    var size: CGFloat = 24
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.24).fill(StudioBrand.markSquare)
            Image(systemName: "waveform").font(.system(size: size * 0.60, weight: .medium))
                .foregroundStyle(StudioBrand.waveform)
            Circle().fill(StudioBrand.markDot).frame(width: size * 0.23, height: size * 0.23)
                .offset(x: size * 0.28, y: -size * 0.28)
        }
        .frame(width: size, height: size).accessibilityHidden(true)
    }
}

struct StudioBrandLockup: View {
    enum Size { case regular, compact }
    var size: Size = .compact
    var showsMark = true
    @Environment(\.studioTheme) private var theme
    var body: some View {
        HStack(spacing: showsMark ? 8 : 0) {
            if showsMark { StudioBrandMark(size: size == .compact ? 20 : 24) }
            Text(StudioBrand.name).font(.system(size: size == .compact ? 13 : 15, weight: .medium))
                .foregroundStyle(theme.colors.textPrimary).lineLimit(1)
        }
        .accessibilityElement(children: .ignore).accessibilityLabel(StudioBrand.name).accessibilityAddTraits(.isHeader)
    }
}
