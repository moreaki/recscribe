import SwiftUI

/// An SF Symbol in a hit target.
///
/// The visual is a 12pt glyph; the target is 28pt square. That ratio is
/// deliberate and it is the reason this primitive exists — a bare `Image` in a
/// `Button` gives you a ~14pt target, which is a coin toss for anyone whose
/// hands aren't perfectly steady, and it is exactly the mistake that gets made
/// every time an icon button is hand-rolled.
///
/// `accessibilityLabel` is a required initialiser argument, not an optional
/// modifier. An icon button without a label is unusable with VoiceOver, and
/// the type system is a better reviewer than a checklist.
public struct GlassIconButton: View {
    private let systemImage: String
    private let label: String
    private let hint: String?
    private let symbolSize: CGFloat
    private let colorRole: GlassColorRole
    private let action: () -> Void

    @Environment(\.glassTheme) private var theme
    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovering = false

    public init(
        systemImage: String,
        accessibilityLabel: String,
        accessibilityHint: String? = nil,
        symbolSize: CGFloat = 12,
        color: GlassColorRole = .textTertiary,
        action: @escaping () -> Void
    ) {
        self.systemImage = systemImage
        self.label = accessibilityLabel
        self.hint = accessibilityHint
        self.symbolSize = symbolSize
        self.colorRole = color
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: symbolSize, weight: .medium))
                .foregroundStyle(foreground)
                .frame(
                    width: theme.metrics.minimumHitTarget,
                    height: theme.metrics.minimumHitTarget
                )
                .background {
                    if isHovering && isEnabled {
                        RoundedRectangle(cornerRadius: GlassRadius.control, style: .continuous)
                            .fill(theme.colors.surfaceInset)
                    }
                }
                // Rectangle, not the symbol's own shape: the target must be
                // the whole 28pt square, including its empty corners.
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .glassHover($isHovering, showsPointingHand: isEnabled)
        .glassAnimation(.hover, value: isHovering)
        .accessibilityLabel(label)
        .accessibilityHint(hint ?? "")
    }

    private var foreground: Color {
        if !isEnabled { return theme.colors.textTertiary.opacity(0.5) }
        return isHovering ? theme.colors.textPrimary : theme.colors[colorRole]
    }
}
