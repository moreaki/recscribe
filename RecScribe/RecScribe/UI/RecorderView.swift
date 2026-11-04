// Based on Home Rec's capture UI; see NOTICE. RecScribe studio redesign (2026).
import SwiftUI

/// Capture controls observe the waveform; transcript and chrome are siblings
/// and do not subscribe to these high-frequency updates.
struct RecorderView: View {
    @Environment(RecorderViewModel.self) var viewModel
    @Environment(\.openWindow) private var openWindow
    @Environment(\.studioNavigation) private var navigation

    private var mainButtonTitle: String {
        if viewModel.installLocationBlocksRecording { return "Reveal in Finder" }
        if !viewModel.canRecord { return "Open System Settings" }
        return viewModel.isRecording ? "Stop recording" : "Start recording"
    }

    var body: some View {
        @Bindable var viewModel = viewModel
        VStack(alignment: .leading, spacing: GlassSpacing.xxl) {
            HStack {
                WorkspaceIcon(symbol: "waveform", tint: WorkspaceStyle.mint)
                VStack(alignment: .leading, spacing: GlassSpacing.xs) {
                    Text("Capture").font(.headline)
                    Text("Lossless PCM · WAV").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                OverflowMenuButton()
            }
            RecorderStatusBar(state: viewModel.state, statusText: viewModel.statusText, telemetry: viewModel.telemetry)
            CaptureHealthView(recorder: viewModel, telemetry: viewModel.telemetry)
            MultipleInputsView(recorder: viewModel, showsRoutingLink: false)
            if viewModel.selectedSource.kind != .multiple {
                RecordingLevelsView(recorder: viewModel)
            }
            if case .error = viewModel.state {
                Button("Review saved recordings", systemImage: "waveform.path.badge.exclamationmark") {
                    AppWindow.open(.recordings, using: openWindow, navigation: navigation)
                }.buttonStyle(.borderless)
            }
            RecordingReviewNotice(recorder: viewModel)
            RecorderWaveformSection(telemetry: viewModel.telemetry)
            if let notice = viewModel.installNotice {
                HStack(alignment: .top) {
                    Text(notice).font(.caption).foregroundStyle(.secondary)
                    if viewModel.installLocation.noticeIsDismissible {
                        GlassIconButton(systemImage: "xmark", accessibilityLabel: "Dismiss") { viewModel.dismissInstallLocationNotice() }
                    }
                }
            }
            if !viewModel.installLocationBlocksRecording && !viewModel.canRecord {
                Text(PermissionKind.screenCapture.navigationHint).font(.caption).foregroundStyle(.secondary)
            }
            GlassPillButton(mainButtonTitle,
                systemImage: viewModel.canRecord ? (viewModel.isRecording ? "stop.circle.fill" : "record.circle") : nil,
                emphasis: viewModel.canRecord ? .primary : .primaryNeutral, size: .large, isFullWidth: true) {
                    if viewModel.installLocationBlocksRecording { viewModel.revealAppInFinder() }
                    else if !viewModel.canRecord { viewModel.openSystemSettings() }
                    else { Task { await viewModel.toggleRecording() } }
                }
                .disabled(viewModel.isFinalizingAfterFailure || !viewModel.state.allowsCaptureSourceChange && !viewModel.isRecording)
                .keyboardShortcut("r", modifiers: .command)
            if viewModel.isRecording {
                Label("Mac and display stay awake while recording. Closing the lid can interrupt capture.", systemImage: "moon.zzz")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Label(viewModel.saveLocationName, systemImage: "folder").font(.caption).foregroundStyle(.secondary)
                .lineLimit(1).help(viewModel.saveLocationPath)
            if viewModel.lastRecordingURL != nil, !viewModel.isRecording {
                Button("Reveal recording", systemImage: "arrow.up.forward.square") { viewModel.revealInFinder() }
                    .buttonStyle(.borderless).font(.callout)
            }
        }
        .alert("Something went wrong", isPresented: $viewModel.showError) {
            if let recovery = viewModel.recoverySuggestion { Button(recovery.label) { viewModel.performRecovery() } }
            Button("OK", role: .cancel) { viewModel.showError = false }
        } message: { Text(viewModel.errorMessage ?? "") }
        .alert("Still recording", isPresented: $viewModel.showLongRecordingWarning) {
            Button("Keep recording", role: .cancel) { viewModel.showLongRecordingWarning = false }
            Button("Stop") { Task { await viewModel.stopRecording() } }
        } message: { Text("Long recordings use disk space. WAV parts are split automatically; originals are retained.") }
        .sheet(isPresented: $viewModel.showOnboarding) { OnboardingView().environment(viewModel) }
        .onAppear { viewModel.mainWindowDidAppear() }
        .onDisappear { viewModel.mainWindowDidDisappear() }
    }
}

struct StatusBar: View {
    let state: RecordingState
    let duration: String
    let statusText: String
    var body: some View {
        VStack(alignment: .leading, spacing: GlassSpacing.md) {
            Text(state.heading(duration: duration))
                .font(.system(.title, design: .rounded, weight: .semibold)).monospacedDigit()
            Label(statusText, systemImage: symbol)
                .font(.callout).foregroundStyle(color)
                .fixedSize(horizontal: false, vertical: true)
            if case .error(.streamFailed) = state {
                Text("Stopped at \(duration) · verify saved audio duration in Recordings")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var symbol: String {
        if case .error = state { return "exclamationmark.triangle" }
        return state == .recording ? "record.circle" : "headphones"
    }
    private var color: Color {
        if case .error = state { return .orange }
        return state == .recording ? .red : .secondary
    }
}

struct RecorderStatusBar: View {
    let state: RecordingState
    let statusText: String
    @Bindable var telemetry: RecorderTelemetry

    var body: some View {
        StatusBar(state: state, duration: telemetry.formattedDuration, statusText: statusText)
    }
}

struct RecorderWaveformSection: View {
    @Bindable var telemetry: RecorderTelemetry

    var body: some View {
        GlassLiveWaveform(
            samples: RecorderWaveformAdapter.magnitudes(
                telemetry.waveformSamples,
                bucketedTo: RecorderWaveformAdapter.popoverBarCount
            )
        )
        .frame(height: WorkspaceStyle.waveformHeight)
        .padding(GlassSpacing.md)
        .background(WorkspaceStyle.panel, in: RoundedRectangle(cornerRadius: GlassRadius.card))
    }
}

/// A completed take can need review without being a failed save or blocking the next take.
struct RecordingReviewNotice: View {
    let recorder: RecorderViewModel
    @Environment(\.openWindow) private var openWindow
    @Environment(\.studioNavigation) private var navigation
    var body: some View {
        if let message = recorder.alerts.reviewMessage {
            VStack(alignment: .leading, spacing: GlassSpacing.sm) {
                Label(message, systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                Button("Review saved recordings") {
                    AppWindow.open(.recordings, using: openWindow, navigation: navigation)
                }.buttonStyle(.borderless)
            }.accessibilityElement(children: .contain)
        }
    }
}
