// Based on Home Rec's capture UI; see NOTICE. RecScribe studio redesign (2026).
import SwiftUI

/// Capture controls observe the waveform; transcript and chrome are siblings
/// and do not subscribe to these high-frequency updates.
struct RecorderView: View {
    @EnvironmentObject var viewModel: RecorderViewModel
    @Environment(\.openWindow) private var openWindow

    private var mainButtonTitle: String {
        if viewModel.installLocationBlocksRecording { return "Reveal in Finder" }
        if viewModel.permissionStatus != .granted { return "Open System Settings" }
        return viewModel.isRecording ? "Stop recording" : "Start recording"
    }

    var body: some View {
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
            StatusBar(state: viewModel.state, duration: viewModel.formattedDuration, statusText: viewModel.statusText)
            if case .error = viewModel.state {
                Button("Review saved recordings", systemImage: "waveform.path.badge.exclamationmark") {
                    openWindow(id: AppWindow.recordings.rawValue)
                }.buttonStyle(.borderless)
            }
            GlassLiveWaveform(samples: RecorderWaveformAdapter.magnitudes(viewModel.waveformSamples,
                bucketedTo: RecorderWaveformAdapter.popoverBarCount))
                .frame(height: WorkspaceStyle.waveformHeight)
                .padding(GlassSpacing.md).background(WorkspaceStyle.panel, in: RoundedRectangle(cornerRadius: GlassRadius.card))
            if let notice = viewModel.installNotice {
                HStack(alignment: .top) {
                    Text(notice).font(.caption).foregroundStyle(.secondary)
                    if viewModel.installLocation.noticeIsDismissible {
                        GlassIconButton(systemImage: "xmark", accessibilityLabel: "Dismiss") { viewModel.dismissInstallLocationNotice() }
                    }
                }
            }
            if !viewModel.installLocationBlocksRecording && viewModel.permissionStatus != .granted {
                Text(PermissionKind.screenCapture.navigationHint).font(.caption).foregroundStyle(.secondary)
            }
            GlassPillButton(mainButtonTitle,
                systemImage: viewModel.canRecord ? (viewModel.isRecording ? "stop.circle.fill" : "record.circle") : nil,
                emphasis: viewModel.canRecord ? .primary : .primaryNeutral, size: .large, isFullWidth: true) {
                    if viewModel.installLocationBlocksRecording { viewModel.revealAppInFinder() }
                    else if viewModel.permissionStatus != .granted { viewModel.openSystemSettings() }
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
        .sheet(isPresented: $viewModel.showOnboarding) { OnboardingView().environmentObject(viewModel) }
        .onAppear {
            viewModel.mainWindowDidAppear()
            OverflowMenu.openWindow = { window in
                NSApp.activate(ignoringOtherApps: true)
                openWindow(id: window.rawValue)
            }
        }
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
