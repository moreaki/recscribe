import SwiftUI

protocol WorkspaceTab: Hashable, CaseIterable, RawRepresentable where RawValue == String {
    var symbol: String { get }
}

/// One lightweight tab style for workspace and settings; feature state stays outside.
struct WorkspaceTabs<Section: WorkspaceTab>: View {
    let title: LocalizedStringKey
    @Binding var selection: Section
    var sections: [Section]? = nil
    var showsIcons = true

    var body: some View {
        ViewThatFits(in: .horizontal) {
            wideTabs.fixedSize(horizontal: true, vertical: false)
            tabs.labelStyle(.titleOnly).fixedSize(horizontal: true, vertical: false)
            tabs.labelStyle(.iconOnly)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title)
    }

    @ViewBuilder private var wideTabs: some View {
        if showsIcons { tabs.labelStyle(.titleAndIcon) }
        else { tabs.labelStyle(.titleOnly) }
    }

    private var tabs: some View {
        HStack(spacing: StudioSpacing.sm) {
            ForEach(sections ?? Array(Section.allCases), id: \.self) { section in
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
            .padding(.horizontal, StudioSpacing.md)
            .frame(minHeight: WorkspaceStyle.navigationHeight)
            .background(hovering || configuration.isPressed ? WorkspaceStyle.panel : .clear,
                        in: RoundedRectangle(cornerRadius: StudioRadius.control))
            .overlay(alignment: .bottom) {
                Capsule().fill(selected ? WorkspaceStyle.blue : .clear)
                    .frame(height: StudioSpacing.xxs).padding(.horizontal, StudioSpacing.md)
            }
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
    }
}

#Preview {
    WorkspaceTabs(title: "Text view", selection: .constant(TranscriptWorkspace.Section.transcript))
        .padding(StudioSpacing.xl).background(WorkspaceStyle.background).preferredColorScheme(.dark)
}
