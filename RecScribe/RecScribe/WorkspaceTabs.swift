import SwiftUI

protocol WorkspaceTab: Hashable, CaseIterable, RawRepresentable where RawValue == String {
    var symbol: String { get }
}

/// One lightweight tab style for workspace and settings; feature state stays outside.
struct WorkspaceTabs<Section: WorkspaceTab>: View {
    let title: LocalizedStringKey
    @Binding var selection: Section

    var body: some View {
        ViewThatFits(in: .horizontal) {
            tabs.labelStyle(.titleAndIcon).fixedSize(horizontal: true, vertical: false)
            tabs.labelStyle(.titleOnly).fixedSize(horizontal: true, vertical: false)
            tabs.labelStyle(.iconOnly)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title)
    }

    private var tabs: some View {
        HStack(spacing: GlassSpacing.sm) {
            ForEach(Array(Section.allCases), id: \.self) { section in
                Button { selection = section } label: {
                    Label(section.rawValue, systemImage: section.symbol)
                        .font(.callout.weight(.medium))
                }
                .buttonStyle(WorkspaceTabStyle(selected: selection == section))
                .accessibilityLabel(section.rawValue)
                .accessibilityIdentifier("workspace-tab-\(section.rawValue.lowercased())")
                .accessibilityAddTraits(selection == section ? .isSelected : [])
                .help(section.rawValue)
            }
        }
    }
}

private struct WorkspaceTabStyle: ButtonStyle {
    let selected: Bool
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(selected ? WorkspaceStyle.blue : .secondary)
            .padding(.horizontal, GlassSpacing.md)
            .frame(minHeight: WorkspaceStyle.navigationHeight)
            .background(hovering || configuration.isPressed ? WorkspaceStyle.panel : .clear,
                        in: RoundedRectangle(cornerRadius: GlassRadius.control))
            .overlay(alignment: .bottom) {
                Capsule().fill(selected ? WorkspaceStyle.blue : .clear)
                    .frame(height: GlassSpacing.xxs).padding(.horizontal, GlassSpacing.md)
            }
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
    }
}

#Preview {
    WorkspaceTabs(title: "Text view", selection: .constant(TranscriptWorkspace.Section.transcript))
        .padding(GlassSpacing.xl).background(WorkspaceStyle.background).preferredColorScheme(.dark)
}
