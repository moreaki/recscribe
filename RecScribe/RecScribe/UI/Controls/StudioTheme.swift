import SwiftUI

/// RecScribe's workspace measurements. Values are kept stable while transport
/// controls migrate so source replacement does not move recording actions.
enum StudioSpacing {
    static let xxs: CGFloat = 2, xs: CGFloat = 4, sm: CGFloat = 6, s: CGFloat = 8
    static let m: CGFloat = 10, md: CGFloat = 12, l: CGFloat = 14, xl: CGFloat = 18
    static let xxl: CGFloat = 22, xxxl: CGFloat = 28
}

enum StudioRadius {
    static let window: CGFloat = 12, panel: CGFloat = 22, cardLarge: CGFloat = 14
    static let card: CGFloat = 12, inner: CGFloat = 10, control: CGFloat = 6
    static let pill = CGFloat.infinity
}

struct StudioMetrics {
    var minimumHitTarget: CGFloat = 28
    var controlHeightLarge: CGFloat = 44
    var controlHeightMedium: CGFloat = 36
    var controlHeightSmall: CGFloat = 32
    var controlHeightCompact: CGFloat = 30
    var controlHeightMini: CGFloat = 26
    var hairline: CGFloat = 1
    var waveformBarWidth: CGFloat = 2
    var waveformBarSpacing: CGFloat = 1
    var waveformDimOpacity = 0.28
    static let standard = Self()
}

enum StudioColorRole: String, CaseIterable, Hashable, Sendable {
    case ground, groundRaised, surfacePanel, surfaceCard, surfaceInset, surfaceScrim
    case line, lineStrong, textPrimary, textSecondary, textTertiary, textOnAccent, textAccent
    case accent, accentStrong, accentMuted, statusDanger, statusWarning, statusSuccess, statusNeutral
    case controlPrimaryNeutral, controlSecondary, textOnNeutralControl
}

struct StudioColors {
    var ground = Color(studioHex: 0x0D1119)
    var groundRaised = Color(studioHex: 0x21243F)
    var surfacePanel = Color(studioHex: 0x1A1C22).opacity(0.55)
    var surfaceCard = Color(studioHex: 0x1C1C1E)
    var surfaceInset = Color.white.opacity(0.06)
    var surfaceScrim = Color.black.opacity(0.45)
    var line = Color.white.opacity(0.08)
    var lineStrong = Color.white.opacity(0.16)
    var textPrimary = Color.white.opacity(0.92)
    var textSecondary = Color.white.opacity(0.65)
    var textTertiary = Color(studioHex: 0x8E8E93)
    var textOnAccent = Color.white
    var textAccent = Color(studioHex: 0xFF6B6B)
    var accent = Color(studioHex: 0xF23A3A)
    var accentStrong = Color(studioHex: 0xC72121)
    var accentMuted = Color(studioHex: 0xF23A3A).opacity(0.45)
    var statusDanger = Color(studioHex: 0xF23A3A)
    var statusWarning = Color(studioHex: 0xEBA82E)
    var statusSuccess = Color(studioHex: 0x30D158)
    var statusNeutral = Color.white.opacity(0.25)
    var controlPrimaryNeutral = Color(studioHex: 0xF2F2F5)
    var controlSecondary = Color(studioHex: 0xC2C2CA)
    var textOnNeutralControl = Color(studioHex: 0x0D0D0F)
    static let standard = Self()

    static var highContrast: Self {
        var palette = Self()
        palette.accent = palette.accentStrong
        palette.textSecondary = .white.opacity(0.78)
        palette.textTertiary = Color(studioHex: 0xAEAEB2)
        palette.line = .white.opacity(0.16)
        palette.lineStrong = .white.opacity(0.30)
        return palette
    }

    subscript(role: StudioColorRole) -> Color {
        // A key-path table keeps custom palettes and role access on the same storage.
        let paths: [StudioColorRole: KeyPath<Self, Color>] = [
            .ground: \.ground, .groundRaised: \.groundRaised, .surfacePanel: \.surfacePanel,
            .surfaceCard: \.surfaceCard, .surfaceInset: \.surfaceInset, .surfaceScrim: \.surfaceScrim,
            .line: \.line, .lineStrong: \.lineStrong, .textPrimary: \.textPrimary,
            .textSecondary: \.textSecondary, .textTertiary: \.textTertiary, .textOnAccent: \.textOnAccent,
            .textAccent: \.textAccent, .accent: \.accent, .accentStrong: \.accentStrong,
            .accentMuted: \.accentMuted, .statusDanger: \.statusDanger, .statusWarning: \.statusWarning,
            .statusSuccess: \.statusSuccess, .statusNeutral: \.statusNeutral,
            .controlPrimaryNeutral: \.controlPrimaryNeutral, .controlSecondary: \.controlSecondary,
            .textOnNeutralControl: \.textOnNeutralControl
        ]
        return self[keyPath: paths[role]!]
    }
}

struct StudioTheme {
    var colors: StudioColors = .standard
    var typography: StudioTypography = .standard
    var metrics: StudioMetrics = .standard
    static let standard = Self()
    static var highContrast: Self { Self(colors: .highContrast) }
}

private struct StudioThemeEnvironment: EnvironmentKey {
    static let defaultValue = StudioTheme.standard
}

extension EnvironmentValues {
    var studioTheme: StudioTheme {
        get { self[StudioThemeEnvironment.self] }
        set { self[StudioThemeEnvironment.self] = newValue }
    }
}

extension Color {
    init(studioHex: UInt32, opacity: Double = 1) {
        let components = [16, 8, 0].map { Double((studioHex >> $0) & 255) / 255 }
        self.init(.sRGB, red: components[0], green: components[1], blue: components[2], opacity: opacity)
    }
}

extension View {
    func studioTheme(_ value: StudioTheme) -> some View { environment(\.studioTheme, value) }
    func studioThemeAdaptingToContrast() -> some View { modifier(StudioContrastTheme()) }
}

private struct StudioContrastTheme: ViewModifier {
    @Environment(\.colorSchemeContrast) var contrast
    func body(content: Content) -> some View {
        content.studioTheme(contrast == .standard ? .standard : .highContrast)
    }
}
