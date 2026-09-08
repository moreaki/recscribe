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
            StatusBar(isRecording: viewModel.isRecording, duration: viewModel.formattedDuration, statusText: viewModel.statusText)
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
                .disabled(viewModel.state == .starting || viewModel.state == .stopping)
                .keyboardShortcut("r", modifiers: .command)
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
    let isRecording: Bool
    let duration: String
    let statusText: String
    var body: some View {
        VStack(alignment: .leading, spacing: GlassSpacing.md) {
            Text(isRecording ? duration : "Ready when you are")
                .font(.system(.title, design: .rounded, weight: .semibold)).monospacedDigit()
            Label(statusText, systemImage: isRecording ? "record.circle" : "headphones")
                .font(.callout).foregroundStyle(isRecording ? .red : .secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
