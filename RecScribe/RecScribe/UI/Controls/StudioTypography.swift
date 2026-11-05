import AppKit
import SwiftUI

enum StudioTextRole: String, CaseIterable, Hashable, Sendable {
    case wordmark, appTitle, timer, timerCompact, title, body, bodyEmphasized
    case control, controlCompact, caption, captionSmall, meta, metaSmall, timecodeChip
}

struct StudioFontFamily: Hashable, Sendable {
    var name: String? = nil
    var design: Font.Design = .default
    static let ui = Self(), display = Self(), mono = Self(design: .monospaced)
}

struct StudioTextStyle: Hashable, Sendable {
    var family: StudioFontFamily
    var size: CGFloat
    var weight: Font.Weight = .regular
    var tracking: CGFloat = 0
    var lineSpacing: CGFloat = 0
    var maxScale: CGFloat = 2
}

struct StudioTypography {
    var uiFamily: StudioFontFamily = .ui
    var displayFamily: StudioFontFamily = .display
    var monoFamily: StudioFontFamily = .mono
    static let standard = Self()
    var usesCustomUIFamily: Bool { uiFamily.name.map(StudioFontRegistry.isAvailable) ?? false }

    func style(_ role: StudioTextRole) -> StudioTextStyle {
        var value = StudioTextStyle(family: uiFamily, size: 13)
        switch role {
        case .wordmark, .appTitle:
            value.family = displayFamily
            value.size = role == .wordmark ? 26 : 13
            value.weight = .medium
            value.tracking = -0.02 * value.size
        case .timer:
            value.family = monoFamily
            value.size = 30
            value.weight = .light
            value.maxScale = 1.4
        case .timerCompact:
            value.family = monoFamily
            value.size = 14
            value.weight = .medium
        case .title: value.size = 14
            value.weight = .medium
        case .body: break
        case .bodyEmphasized: value.weight = .medium
        case .control, .controlCompact:
            value.size = role == .control ? 14 : 12
            value.weight = .semibold
            value.tracking = 0.1
        case .caption: value.size = 12
        case .captionSmall: value.size = 11
            value.lineSpacing = 2
        case .meta, .metaSmall, .timecodeChip:
            value.family = monoFamily
            value.size = role == .metaSmall ? 9 : 10
            if role == .timecodeChip { value.weight = .medium
            value.maxScale = 1 }
        }
        return value
    }

    func size(_ role: StudioTextRole, for dynamicTypeSize: DynamicTypeSize = .large) -> CGFloat {
        let specification = style(role)
        return (specification.size * min(specification.maxScale, dynamicTypeSize.studioScale)).rounded()
    }

    func font(_ specification: StudioTextStyle) -> Font {
        guard let face = specification.family.name, StudioFontRegistry.isAvailable(face) else {
            return .system(size: specification.size, weight: specification.weight, design: specification.family.design)
        }
        return Font.custom(face, fixedSize: specification.size).weight(specification.weight)
    }

    func font(_ role: StudioTextRole, for dynamicTypeSize: DynamicTypeSize = .large) -> Font {
        var specification = style(role)
        specification.size = size(role, for: dynamicTypeSize)
        return font(specification)
    }
}

enum StudioFontRegistry {
    static func isAvailable(_ face: String) -> Bool { NSFont(name: face, size: 12) != nil }
}

extension DynamicTypeSize {
    var studioScale: CGFloat {
        let sizes: [DynamicTypeSize] = [.xSmall, .small, .medium, .large, .xLarge, .xxLarge, .xxxLarge,
                                        .accessibility1, .accessibility2, .accessibility3, .accessibility4, .accessibility5]
        let factors: [CGFloat] = [0.88, 0.92, 0.96, 1, 1.08, 1.16, 1.24, 1.40, 1.55, 1.70, 1.85, 2]
        return sizes.firstIndex(of: self).map { factors[$0] } ?? 1
    }
}

private struct StudioText: ViewModifier {
    let role: StudioTextRole
    let color: StudioColorRole?
    @Environment(\.studioTheme) var theme
    @Environment(\.dynamicTypeSize) var size
    func body(content: Content) -> some View {
        let specification = theme.typography.style(role)
        let text = content.font(theme.typography.font(role, for: size))
            .tracking(specification.tracking).lineSpacing(specification.lineSpacing)
        if let color { text.foregroundStyle(theme.colors[color]) } else { text }
    }
}

extension View {
    func studioText(_ role: StudioTextRole, color: StudioColorRole? = nil) -> some View {
        modifier(StudioText(role: role, color: color))
    }
}
