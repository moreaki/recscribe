import SwiftUI

enum StudioButtonEmphasis: Equatable {
    case primary, primaryTinted(Color), primaryNeutral, secondary, tertiary, blocked
    func foreground(_ palette: StudioColors, isEnabled: Bool) -> Color {
        let ink: Color
        switch self {
        case .primary, .primaryTinted: ink = palette.textOnAccent
        case .primaryNeutral, .secondary: ink = palette.textOnNeutralControl
        case .tertiary, .blocked: ink = palette.textPrimary
        }
        return ink.opacity(isEnabled ? 1 : 0.6)
    }
}

enum StudioPillSize: String, CaseIterable, Hashable, Sendable {
    case large, medium, small, compact, mini
    func height(_ metrics: StudioMetrics) -> CGFloat {
        let values: [Self: CGFloat] = [.large: metrics.controlHeightLarge, .medium: metrics.controlHeightMedium,
            .small: metrics.controlHeightSmall, .compact: metrics.controlHeightCompact, .mini: metrics.controlHeightMini]
        return values[self]!
    }
    var horizontalPadding: CGFloat {
        switch self {
        case .large: 26
        case .medium: 20
        case .small, .compact: 16
        case .mini: 12
        }
    }
    var textRole: StudioTextRole {
        switch self {
        case .large: .control
        case .medium: .bodyEmphasized
        case .small, .compact: .controlCompact
        case .mini: .captionSmall
        }
    }
    var symbolSize: CGFloat { self == .medium ? 10 : (self == .mini || self == .compact ? 8 : 9) }
    var iconSpacing: CGFloat { self == .large ? 9 : (self == .medium || self == .small ? 7 : 6) }
    var spinnerSize: CGFloat { self == .large ? 15 : (self == .medium ? 14 : (self == .mini ? 11 : 12)) }
}

struct StudioPillButton: View {
    private let title: String
    private let symbol: String?
    private let emphasis: StudioButtonEmphasis
    private let size: StudioPillSize
    private let fullWidth: Bool
    private let busy: Bool
    private let action: () -> Void
    @Environment(\.studioTheme) private var theme
    @Environment(\.isEnabled) private var enabled

    init(_ title: String, systemImage: String? = nil, emphasis: StudioButtonEmphasis = .primary,
         size: StudioPillSize = .large, isFullWidth: Bool = false, isLoading: Bool = false,
         action: @escaping () -> Void) {
        self.title = title
        symbol = systemImage
        self.emphasis = emphasis
        self.size = size
        fullWidth = isFullWidth
        busy = isLoading
        self.action = action
    }

    var body: some View {
        Button { if !busy { action() } } label: {
            HStack(spacing: size.iconSpacing) {
                if busy {
                    StudioPillSpinner(diameter: size.spinnerSize, color: emphasis.foreground(theme.colors, isEnabled: enabled))
                } else if let symbol {
                    Image(systemName: symbol).font(.system(size: size.symbolSize, weight: .bold)).accessibilityHidden(true)
                }
                Text(title).lineLimit(1).fixedSize(horizontal: true, vertical: false)
            }
        }
        .buttonStyle(StudioPillButtonStyle(emphasis: emphasis, size: size, isFullWidth: fullWidth, isLoading: busy))
        .accessibilityValue(busy ? "Loading" : "")
        .allowsHitTesting(!busy)
    }
}

struct StudioPillButtonStyle: ButtonStyle {
    var emphasis: StudioButtonEmphasis = .primary
    var size: StudioPillSize = .large
    var isFullWidth = false
    var isLoading = false
    func makeBody(configuration: Configuration) -> some View {
        StudioControlSurface(label: configuration.label, pressed: configuration.isPressed,
                             emphasis: emphasis, size: size, fullWidth: isFullWidth, busy: isLoading)
    }
}

private struct StudioControlSurface<Label: View>: View {
    let label: Label
    let pressed: Bool
    let emphasis: StudioButtonEmphasis
    let size: StudioPillSize
    let fullWidth: Bool
    let busy: Bool
    @Environment(\.studioTheme) private var theme
    @Environment(\.isEnabled) private var enabled
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hover = false

    private var fill: Color {
        let palette = theme.colors
        let color: Color
        switch emphasis {
        case .primary: color = pressed ? palette.accentStrong : palette.accent
        case .primaryTinted(let tint): color = tint
        case .primaryNeutral: color = palette.controlPrimaryNeutral
        case .secondary: color = palette.controlSecondary
        case .blocked: color = palette.surfaceCard
        case .tertiary: color = hover && enabled ? palette.surfaceInset : .clear
        }
        return color.opacity(enabled ? 1 : 0.45)
    }

    var body: some View {
        let typography = theme.typography
        let growth = max(0, typography.size(size.textRole, for: typeSize) - typography.style(size.textRole).size)
        label.studioText(size.textRole)
            .foregroundStyle(emphasis.foreground(theme.colors, isEnabled: enabled))
            .padding(.horizontal, size.horizontalPadding)
            .frame(maxWidth: fullWidth ? .infinity : nil)
            .frame(height: max(theme.metrics.minimumHitTarget, size.height(theme.metrics) + growth))
            .background(fill, in: Capsule())
            .contentShape(Capsule())
            .opacity(pressed && enabled && !busy ? 0.88 : 1)
            .onHover { hover = $0 }
            // Native button focus remains active; no cursor stack or custom
            // focus owner survives a disappearing/replaced transport control.
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: pressed)
            .accessibilityAddTraits(busy ? .updatesFrequently : [])
    }
}

struct StudioPillSpinner: View {
    let diameter: CGFloat
    let color: Color
    @Environment(\.accessibilityReduceMotion) private var reduced
    var body: some View {
        Group {
            if reduced { Image(systemName: "hourglass").foregroundStyle(color) }
            else { ProgressView().controlSize(.mini).tint(color) }
        }
        .frame(width: diameter, height: diameter).accessibilityHidden(true)
    }
}

struct StudioIconButton: View {
    let systemImage: String
    let accessibilityLabel: String
    var accessibilityHint: String? = nil
    var symbolSize: CGFloat = 12
    var color: StudioColorRole = .textTertiary
    let action: () -> Void
    @Environment(\.studioTheme) private var theme
    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage).font(.system(size: symbolSize, weight: .medium))
                .foregroundStyle(theme.colors[color])
                .frame(minWidth: theme.metrics.minimumHitTarget, minHeight: theme.metrics.minimumHitTarget)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityHint(accessibilityHint ?? "")
    }
}

extension ButtonStyle where Self == StudioPillButtonStyle {
    static var studioPill: Self { Self() }
    static func studioPill(_ emphasis: StudioButtonEmphasis, size: StudioPillSize = .large,
                          isFullWidth: Bool = false, isLoading: Bool = false) -> Self {
        Self(emphasis: emphasis, size: size, isFullWidth: isFullWidth, isLoading: isLoading)
    }
}
