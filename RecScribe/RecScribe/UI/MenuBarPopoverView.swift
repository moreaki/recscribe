import Observation
import SwiftUI

struct MenuBarPopoverView: View {

    @Environment(RecorderViewModel.self) var viewModel
    var live: LiveTranscription?
    var layout = PopoverLayout()

    var body: some View {
        PopoverFrame(layout: layout) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top) {
                    GlassBrandLockup(size: .compact)

                    Spacer()

                    OverflowMenuButton()
                }

                HStack(spacing: 8) {
                    if viewModel.isRecording {
                        Circle()
                            .fill(Color.red)
                            .frame(width: 8, height: 8)
                    }

                    Text(viewModel.statusText)
                        .workspaceFont(.status)
                        .foregroundColor(viewModel.isRecording ? .red : .primary)
                        .fixedSize(horizontal: false, vertical: true)

                    Spacer()

                    if viewModel.isRecording {
                        PopoverDurationText(telemetry: viewModel.telemetry)
                    }
                }

                CaptureHealthView(recorder: viewModel, telemetry: viewModel.telemetry)
            RecordingReviewNotice(recorder: viewModel)
                MultipleInputsView(recorder: viewModel, showsRoutingLink: false)
                if viewModel.selectedSource.kind != .multiple {
                    RecordingLevelsView(recorder: viewModel)
                }

                if case .error = viewModel.state, let message = viewModel.errorMessage {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(message)
                            .workspaceFont(.detail)
                            .foregroundColor(.secondary)
                            .fixedSize(horizontal: false, vertical: true)

                        if let recovery = viewModel.recoverySuggestion {
                            GlassPillButton(
                                recovery.label,
                                emphasis: .secondary,
                                size: .mini
                            ) {
                                viewModel.performRecovery()
                            }
                        }
                    }
                }

                if viewModel.isRecording {
                    PopoverWaveformSection(telemetry: viewModel.telemetry)
                }

                if viewModel.installLocationBlocksRecording, let message = viewModel.installNotice {
                    Text(message)
                        .workspaceFont(.detail)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    GlassPillButton(
                        "Reveal in Finder",
                        emphasis: .primaryNeutral,
                        size: .medium,
                        isFullWidth: true
                    ) {
                        viewModel.revealAppInFinder()
                    }
                } else {
                    GlassPillButton(
                        viewModel.isRecording ? "Stop recording" : "Start recording",
                        systemImage: viewModel.isRecording ? "stop.circle.fill" : "record.circle",
                        emphasis: .primary,
                        size: .medium,
                        isFullWidth: true
                    ) {
                        Task {
                            await viewModel.toggleRecording()
                        }
                    }
                }

                if let live {
                    Divider()
                    LiveTranscriptionControl(live: live)
                    Text(live.status).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }

                if let url = viewModel.lastRecordingURL,
                    !viewModel.isRecording,
                    !viewModel.installLocationBlocksRecording
                {
                    HStack {
                        Image(systemName: "doc.fill")
                            .foregroundColor(.secondary)
                        Text(url.lastPathComponent)
                            .workspaceFont(.detail)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .foregroundColor(.secondary)

                        Spacer()

                        GlassPillButton(
                            "Reveal",
                            emphasis: .tertiary,
                            size: .mini
                        ) {
                            viewModel.revealInFinder()
                        }
                    }
                }

            }
            .padding(WorkspaceStyle.contentPadding)
            .frame(width: WorkspaceStyle.popoverWidth)
        } footer: {
            footer
        }
        .fixedSize(horizontal: false, vertical: true)
        .background(WorkspaceStyle.background)
        .glassThemeAdaptingToContrast()
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
        GlassLiveWaveform(
            samples: RecorderWaveformAdapter.magnitudes(
                telemetry.waveformSamples,
                bucketedTo: RecorderWaveformAdapter.popoverBarCount
            )
        )
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
