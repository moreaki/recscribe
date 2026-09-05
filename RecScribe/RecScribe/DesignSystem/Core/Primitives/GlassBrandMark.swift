import SwiftUI

// MARK: - Mark

/// The RecScribe mark combines a waveform with a red recording indicator.
/// It is drawn as vectors so it remains crisp in compact menu and window chrome.
public struct GlassBrandMark: View {
    private let size: CGFloat

    public init(size: CGFloat = 24) {
        self.size = size
    }

    private var inset: CGFloat { size * 0.04 }
    private var corner: CGFloat { size * 0.22 }
    private var squareStroke: CGFloat { max(1, size * 0.045) }

    public var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: corner, style: .continuous)
                .fill(GlassBrand.markSquare)
                .overlay {
                    RoundedRectangle(cornerRadius: corner, style: .continuous)
                        .strokeBorder(GlassBrand.markEdge, lineWidth: squareStroke)
                }
                .padding(inset)

            HStack(alignment: .center, spacing: size * 0.055) {
                waveformBar(height: 0.24)
                waveformBar(height: 0.50)
                waveformBar(height: 0.72)
                waveformBar(height: 0.42)
                waveformBar(height: 0.58)
            }
            .foregroundStyle(GlassBrand.waveform)

            Circle()
                .fill(GlassBrand.markDot)
                .frame(width: size * 0.25, height: size * 0.25)
                .overlay {
                    Circle().stroke(GlassBrand.markSquare, lineWidth: max(1, size * 0.05))
                }
                .offset(x: size * 0.25, y: -size * 0.25)
        }
        .frame(width: size, height: size)
        // The mark is decoration wherever it appears beside the name; the
        // lockup below owns the single accessible label for the pair.
        .accessibilityHidden(true)
    }

    private func waveformBar(height: CGFloat) -> some View {
        Capsule()
            .frame(width: size * 0.07, height: size * height)
    }
}

// MARK: - Brand constants

/// Brand values that are *fixed artwork*, not themeable roles.
///
/// These deliberately sit outside `GlassColors`. A palette role is something a
/// theme may re-skin; the record dot is #FF3E3E because that is what the logo
/// is, and a theme that changed it would be shipping a different logo. The
/// separation is the point — re-theming the kit must not be able to alter the
/// brand.
public enum GlassBrand {
    /// The wordmark, in the site's capitalisation. Never "home rec": the
    /// lowercase register is the *UI voice* (labels, controls, metadata), and
    /// the brand name is not a UI label.
    public static let name = "RecScribe"

    /// favicon.svg `.sq` fill, dark scheme.
    public static let markSquare = Color(glassHex: 0x2A2A2A)
    /// favicon.svg `.sq` stroke, dark scheme.
    public static let markEdge = Color(glassHex: 0x808080)
    /// favicon.svg `.dot` fill. The logo red — brighter than `colors.accent`,
    /// which is the *interface* red pulled 5% darker for large flat fills.
    public static let markDot = Color(glassHex: 0xFF3E3E)
    public static let waveform = Color(glassHex: 0xDDFBFF)
}

// MARK: - Lockup

/// Mark + wordmark in regular and compact application sizes.
public struct GlassBrandLockup: View {
    /// Lockup scales. Not free-form: two sizes, both derived from the site.
    public enum Size {
        /// 24pt mark / 15pt type — the site's nav lockup.
        case regular
        /// 20pt mark / 13pt type — the app panel header, where the lockup
        /// shares a row with metadata and must not outweigh it.
        case compact

        var mark: CGFloat {
            switch self {
            case .regular: 24
            case .compact: 20
            }
        }

        var gap: CGFloat { (mark * 10 / 24).rounded() }

        /// Archivo medium at −0.02em in both cases — the site's wordmark
        /// spec. `.compact` matches the `appTitle` role exactly; `.regular`
        /// sets it at the site's own 15pt, which is a brand measurement rather
        /// than a UI role and so is stated here instead of in the role table.
        func textStyle(_ typography: GlassTypography) -> GlassTextStyle {
            switch self {
            case .regular:
                GlassTextStyle(
                    family: typography.displayFamily,
                    size: 15, weight: .medium, tracking: -0.3
                )
            case .compact:
                typography.style(.appTitle)
            }
        }
    }

    private let size: Size
    private let showsMark: Bool

    @Environment(\.glassTheme) private var theme

    public init(size: Size = .compact, showsMark: Bool = true) {
        self.size = size
        self.showsMark = showsMark
    }

    public var body: some View {
        HStack(spacing: showsMark ? size.gap : 0) {
            if showsMark {
                GlassBrandMark(size: size.mark)
            }
            wordmark
        }
        // One element, one name. A VoiceOver user hears the product once,
        // not "image, RecScribe".
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(GlassBrand.name)
        .accessibilityAddTraits(.isHeader)
    }

    @ViewBuilder
    private var wordmark: some View {
        let style = size.textStyle(theme.typography)
        Text(GlassBrand.name)
            .font(theme.typography.font(style))
            .tracking(style.tracking)
            .foregroundStyle(theme.colors.textPrimary)
            .lineLimit(1)
    }
}

#Preview("Brand") {
    GlassPreviewStage {
        VStack(alignment: .leading, spacing: GlassSpacing.l) {
            GlassBrandLockup(size: .regular)
            GlassBrandLockup(size: .compact)
            GlassBrandLockup(size: .compact, showsMark: false)
            HStack(spacing: GlassSpacing.l) {
                ForEach([16, 24, 32, 64], id: \.self) { size in
                    GlassBrandMark(size: CGFloat(size))
                }
            }
        }
    }
}
