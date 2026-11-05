import Observation
import SwiftUI

struct MenuBarPopoverView: View {

    @Environment(RecorderViewModel.self) var viewModel
    var live: LiveTranscription?
    var layout = PopoverLayout()

    var body: some View {
        PopoverFrame(layout: layout) {
            VStack(alignment: .leading, spacing: 12) {
                HStack { StudioBrandLockup(); Spacer(); OverflowMenuButton() }
                status
                CaptureHealthView(recorder: viewModel, telemetry: viewModel.telemetry)
                RecordingReviewNotice(recorder: viewModel)
                MultipleInputsView(recorder: viewModel)
                if viewModel.selectedSource.kind != .multiple { RecordingLevelsView(recorder: viewModel) }
                failureActions
                if viewModel.isRecording { PopoverWaveformSection(telemetry: viewModel.telemetry) }
                transport
                if let live {
                    Divider()
                    LiveTranscriptionControl(live: live)
                    Text(live.status).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
                if !viewModel.isRecording, !viewModel.installLocationBlocksRecording,
                   let recording = viewModel.lastRecordingURL {
                    HStack {
                        Label(recording.lastPathComponent, systemImage: "doc.fill")
                            .workspaceFont(.detail).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Button("Reveal") { viewModel.revealInFinder() }.buttonStyle(.borderless)
                    }
                }
            }
            .padding(WorkspaceStyle.contentPadding).frame(width: WorkspaceStyle.popoverWidth)
        } footer: { footer }
        .fixedSize(horizontal: false, vertical: true).background(WorkspaceStyle.background).studioThemeAdaptingToContrast()
    }

    private var status: some View {
        HStack(spacing: 8) {
            if viewModel.isRecording { Circle().fill(.red).frame(width: 8, height: 8) }
            Text(viewModel.statusText).workspaceFont(.status)
                .foregroundStyle(viewModel.isRecording ? Color.red : Color.primary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
            if viewModel.isRecording { PopoverDurationText(telemetry: viewModel.telemetry) }
        }
    }
    @ViewBuilder private var failureActions: some View {
        if case .error = viewModel.state, let explanation = viewModel.errorMessage {
            VStack(alignment: .leading, spacing: 6) {
                Text(explanation).workspaceFont(.detail).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if let action = viewModel.recoverySuggestion {
                    Button(action.label) { viewModel.performRecovery() }.buttonStyle(.bordered)
                }
            }
        }
    }
    @ViewBuilder private var transport: some View {
        if viewModel.installLocationBlocksRecording {
            if let explanation = viewModel.installNotice {
                Text(explanation).workspaceFont(.detail).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            StudioPillButton("Reveal in Finder", emphasis: .primaryNeutral, size: .medium, isFullWidth: true) {
                viewModel.revealAppInFinder()
            }
        } else if !viewModel.canRecord {
            StudioPillButton("Open System Settings", emphasis: .primaryNeutral, size: .medium, isFullWidth: true) {
                viewModel.openSystemSettings()
            }
        } else {
            StudioPillButton(viewModel.isRecording ? "Stop recording" : "Start recording",
                systemImage: viewModel.isRecording ? "stop.circle.fill" : "record.circle",
                size: .medium, isFullWidth: true) { Task { await viewModel.toggleRecording() } }
                .disabled(viewModel.isFinalizingAfterFailure || (!viewModel.allowsCaptureSourceChange && !viewModel.isRecording))
        }
    }

    private var footer: some View {
        HStack {
            Spacer()
            Button {
                NSApp.terminate(nil)
            } label: {
                Label("Quit", systemImage: "power")
                    .workspaceFont(.badge)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 4)
                    .frame(minHeight: 30)
                    .background(WorkspaceStyle.panel, in: RoundedRectangle(cornerRadius: 7))
            }
            .buttonStyle(.plain)
            .help("Quit RecScribe")
            .accessibilityIdentifier("popover-quit")
        }
        .padding(.horizontal, 14)
        .frame(width: WorkspaceStyle.popoverWidth)
        .frame(minHeight: WorkspaceStyle.popoverFooterHeight)
    }
}

/// One scrolling viewport with a separately measured persistent footer.
struct PopoverFrame<Content: View, Footer: View>: View {
    var layout: PopoverLayout
    @ViewBuilder var content: () -> Content
    @ViewBuilder var footer: () -> Footer
    @State private var contentHeight = WorkspaceStyle.previewHeight
    @State private var footerHeight = WorkspaceStyle.popoverFooterHeight

    var body: some View {
        VStack(spacing: 0) {
            ScrollView(.vertical) {
                content()
                    .fixedSize(horizontal: false, vertical: true)
                    .background(
                        GeometryReader { geometry in
                            Color.clear.preference(
                                key: PopoverContentHeight.self, value: geometry.size.height)
                        })
            }
            .frame(height: layout.scrollHeight(content: contentHeight, footer: footerHeight))
            .onPreferenceChange(PopoverContentHeight.self) { contentHeight = $0 }
            Divider().frame(height: WorkspaceStyle.popoverDividerHeight)
            footer()
                .fixedSize(horizontal: false, vertical: true)
                .background(
                    GeometryReader { geometry in
                        Color.clear.preference(
                            key: PopoverFooterHeight.self, value: geometry.size.height)
                    }
                )
                .onPreferenceChange(PopoverFooterHeight.self) { footerHeight = $0 }
        }
        .frame(width: WorkspaceStyle.popoverWidth)
        .fixedSize(horizontal: false, vertical: true)
    }
}

private struct PopoverFooterHeight: PreferenceKey {
    static let defaultValue: CGFloat = WorkspaceStyle.popoverFooterHeight
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

private struct PopoverContentHeight: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

private struct PopoverDurationText: View {
    @Bindable var telemetry: RecorderTelemetry

    var body: some View {
        Text(telemetry.formattedDuration)
            .workspaceFont(.timer)
            .foregroundColor(.secondary)
            .fixedSize()
    }
}

private struct PopoverWaveformSection: View {
    @Bindable var telemetry: RecorderTelemetry

    var body: some View {
        RecorderWaveformDisplay(telemetry: telemetry)
        .frame(height: 36)
    }
}

@MainActor
@Observable final class PopoverLayout {
    var availableHeight: CGFloat
    init(availableHeight: CGFloat = WorkspaceStyle.popoverMaximumHeight) {
        self.availableHeight = availableHeight
    }
    func update(screen: NSScreen?) {
        availableHeight = min(
            WorkspaceStyle.popoverMaximumHeight,
            (screen?.visibleFrame.height ?? WorkspaceStyle.popoverMaximumHeight)
                - WorkspaceStyle.popoverScreenMargin)
    }
    func scrollHeight(content: CGFloat, footer: CGFloat) -> CGFloat {
        max(0, min(content, availableHeight - footer - WorkspaceStyle.popoverDividerHeight))
    }
}
