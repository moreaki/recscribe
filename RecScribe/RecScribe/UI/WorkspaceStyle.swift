import SwiftUI

/// Focus palette. Semantic system labels retain accessibility contrast behavior.
enum WorkspaceStyle {
    static let blue = adaptive(light: 0x286A56, dark: 0x9BD2BB)
    static let violet = blue
    static let mint = blue
    static let background = adaptive(light: 0xFCFCFB, dark: 0x151719)
    static let panel = adaptive(light: 0xF7F8F6, dark: 0x1C1F21)
    static let selected = adaptive(light: 0xE6F0E9, dark: 0x283C33)
    static let border = adaptive(light: 0xE0E5E1, dark: 0x343B37)
    static let recording = adaptive(light: 0xB83E46, dark: 0xF39196)

    private static func adaptive(light: UInt32, dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let hex = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: Double((hex >> 16) & 255) / 255,
                           green: Double((hex >> 8) & 255) / 255,
                           blue: Double(hex & 255) / 255, alpha: 1)
        })
    }
    static let contentPadding: CGFloat = 22
    static let railWidth: CGFloat = 320
    static let iconSize: CGFloat = 34
    static let navigationHeight: CGFloat = 34
    static let popoverWidth: CGFloat = 380
    static let popoverMaximumHeight: CGFloat = 720
    static let popoverScreenMargin: CGFloat = 80
    static let popoverFooterHeight: CGFloat = 50
    static let popoverDividerHeight: CGFloat = 1
    static let previewWidth: CGFloat = 480
    static let previewHeight: CGFloat = 320
    static let readingWidth: CGFloat = 720
    static let lineSpacing: CGFloat = 6
    static let waveformHeight: CGFloat = 64
    static let playbackSliderMinimumWidth: CGFloat = 120

    /// Semantic typography roles shared across workspace chrome, popover,
    /// onboarding, and notice panels. Scales with `DynamicTypeSize` on macOS.
    enum TextRole: String, CaseIterable, Hashable, Sendable {
        case heroTitle
        case status
        case timer
        case sectionTitle
        case body
        case detail
        case badge

        var baseSize: CGFloat {
            switch self {
            case .heroTitle: 22
            case .status: 17
            case .timer: 15
            case .sectionTitle: 14
            case .body: 13
            case .detail: 12
            case .badge: 10
            }
        }

        var weight: Font.Weight {
            switch self {
            case .heroTitle, .sectionTitle, .badge: .semibold
            case .status: .medium
            case .timer, .body, .detail: .regular
            }
        }

        var design: Font.Design {
            switch self {
            case .timer: .monospaced
            default: .default
            }
        }
    }

    static func size(_ role: TextRole, for dynamicTypeSize: DynamicTypeSize = .large) -> CGFloat {
        (role.baseSize * dynamicTypeSize.studioScale).rounded()
    }

    static func font(_ role: TextRole, for dynamicTypeSize: DynamicTypeSize = .large) -> Font {
        let base = Font.system(
            size: size(role, for: dynamicTypeSize),
            weight: role.weight,
            design: role.design
        )
        return role == .timer ? base.monospacedDigit() : base
    }
}

private struct WorkspaceFontModifier: ViewModifier {
    let role: WorkspaceStyle.TextRole
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    func body(content: Content) -> some View {
        content.font(WorkspaceStyle.font(role, for: dynamicTypeSize))
    }
}

extension View {
    func workspaceFont(_ role: WorkspaceStyle.TextRole) -> some View {
        modifier(WorkspaceFontModifier(role: role))
    }
}

struct WorkspaceIcon: View {
    let symbol: String
    var tint: Color = WorkspaceStyle.blue
    var body: some View {
        Image(systemName: symbol).font(.system(.body, design: .rounded, weight: .semibold))
            .foregroundStyle(tint).frame(width: WorkspaceStyle.iconSize, height: WorkspaceStyle.iconSize)
            .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: StudioRadius.control))
            .accessibilityHidden(true)
    }
}

struct WorkspaceCard<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        content.padding(StudioSpacing.xl).frame(maxWidth: .infinity, alignment: .leading)
            .background(WorkspaceStyle.panel, in: RoundedRectangle(cornerRadius: StudioRadius.card))
            .overlay { RoundedRectangle(cornerRadius: StudioRadius.card).stroke(WorkspaceStyle.border) }
    }
}

/// A shared preference row keeps the decision and its control aligned.
struct FocusPreferenceRow<Control: View>: View {
    let title: String
    var detail: String? = nil
    @ViewBuilder var control: () -> Control
    var body: some View {
        HStack(alignment: .center, spacing: 28) {
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.body.weight(.medium))
                if let detail { Text(detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
            }.frame(maxWidth: .infinity, alignment: .leading)
            control().frame(width: 260, alignment: .trailing)
        }.padding(.vertical, 16)
            .overlay(alignment: .bottom) { Divider() }
    }
}

enum SettingsSection: String, WorkspaceTab, Identifiable {
    case general = "General", storage = "Recording", transcription = "Transcription", models = "Models", ai = "Intelligence", diagnostics = "Diagnostics"
    var id: Self { self }
    var symbol: String {
        switch self {
        case .general: "paintpalette"
        case .storage: "waveform.circle"
        case .transcription: "text.bubble"
        case .models: "cpu"
        case .ai: "sparkles"
        case .diagnostics: "chart.xyaxis.line"
        }
    }
    var tint: Color {
        switch self {
        case .general: WorkspaceStyle.blue
        case .storage: WorkspaceStyle.mint
        case .transcription, .diagnostics: WorkspaceStyle.blue
        case .models, .ai: WorkspaceStyle.violet
        }
    }
}

enum FocusAppearance: String, CaseIterable {
    case system = "System", light = "Light", dark = "Dark"
    static let defaultsKey = "workspaceAppearance"

    @MainActor func apply() {
        NSApp.appearance = switch self {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }
}


/// Recording metadata, independent of the filename or the file's modification time.
struct RecordingTimestampPill: View {
    let date: Date
    var tint: Color = .accentColor
    @Environment(\.locale) private var locale
    @Environment(\.calendar) private var calendar
    @Environment(\.timeZone) private var timeZone

    private func format(date: Date.FormatStyle.DateStyle, time: Date.FormatStyle.TimeStyle) -> Date.FormatStyle {
        .init(date: date, time: time, locale: locale, calendar: calendar, timeZone: timeZone)
    }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "calendar")
                .foregroundStyle(tint).accessibilityHidden(true)
            Text(date, format: format(date: .abbreviated, time: .omitted))
            Text("·").foregroundStyle(.secondary)
            Text(date, format: format(date: .omitted, time: .shortened))
                .monospacedDigit()
        }
        .font(.caption.weight(.medium))
        .padding(.horizontal, 10).padding(.vertical, 5)
        .background(tint.opacity(0.1), in: Capsule())
        .overlay { Capsule().strokeBorder(tint.opacity(0.25), lineWidth: 1) }
        .fixedSize(horizontal: false, vertical: true)
        .help(Text("Recorded \(date, format: format(date: .complete, time: .complete))"))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Recorded \(date, format: format(date: .complete, time: .complete))"))
    }
}
