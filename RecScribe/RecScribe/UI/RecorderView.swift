import SwiftUI

/// Capture controls observe the waveform; transcript and chrome are siblings
/// and do not subscribe to these high-frequency updates.
struct RecorderView: View {
    @Environment(RecorderViewModel.self) var viewModel
    @Environment(\.openWindow) private var openWindow
    @Environment(\.studioNavigation) private var navigation
    @Environment(\.studioTheme) private var theme
    @State private var showsInfo = false

    private var waveformTheme: StudioTheme {
        var value = theme
        value.colors.accent = WorkspaceStyle.mint
        return value
    }

    private var mainButtonTitle: String {
        if viewModel.installLocationBlocksRecording { return "Reveal in Finder" }
        if !viewModel.canRecord { return "Open System Settings" }
        return viewModel.isRecording ? "Stop recording" : "Start recording"
    }

    var body: some View {
        @Bindable var viewModel = viewModel
        VStack(alignment: .leading, spacing: 24) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: StudioSpacing.xs) {
                    Label(viewModel.isRecording ? "Recording" : viewModel.state.heading(duration: ""),
                          systemImage: viewModel.isRecording ? "record.circle.fill" : "waveform.circle")
                        .font(.callout).foregroundStyle(viewModel.isRecording ? WorkspaceStyle.recording : .secondary)
                    Text(viewModel.isRecording ? "Current session" : "New session").font(.title2.weight(.semibold))
                    Text(viewModel.captureSourceName ?? "System audio").font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Audio routing", systemImage: "slider.horizontal.below.rectangle") {
                    AppWindow.open(.routing, using: openWindow, navigation: navigation)
                }.buttonStyle(.borderless)
                Button("Recording info", systemImage: "info.circle") { showsInfo.toggle() }
                    .buttonStyle(.borderless)
                    .popover(isPresented: $showsInfo) {
                        VStack(alignment: .leading, spacing: 14) {
                            HStack { Text("How recording works").font(.headline); Spacer(); Button("Close") { showsInfo = false } }
                            Text(viewModel.captureSourceHint)
                            Text("Switching workspaces or closing the window does not stop recording. Your Mac and display stay awake during capture; closing the lid can interrupt it.")
                            Text("Live transcription is optional and provisional. Use Studio for final transcripts and summaries.")
                            MultipleInputsView(recorder: viewModel)
                            CaptureHealthView(recorder: viewModel, showsExplanation: false)
                            OverflowMenuButton()
                        }.font(.callout).padding(20).frame(width: 360).background(WorkspaceStyle.background)
                    }
            }
            FocusRecordingTime(telemetry: viewModel.telemetry).frame(maxWidth: .infinity).padding(.top, 8)
            RecorderWaveformDisplay(telemetry: viewModel.telemetry, barCount: RecorderWaveformAdapter.mainWindowBarCount)
                .frame(height: 115).studioTheme(waveformTheme)
            if case .error = viewModel.state {
                Button("Review saved recordings", systemImage: "waveform.path.badge.exclamationmark") {
                    AppWindow.open(.recordings, using: openWindow, navigation: navigation)
                }.buttonStyle(.borderless)
            }
            RecordingReviewNotice(recorder: viewModel)
            if let notice = viewModel.installNotice {
                HStack(alignment: .top) {
                    Text(notice).font(.caption).foregroundStyle(.secondary)
                    if viewModel.installLocation.noticeIsDismissible {
                        StudioIconButton(systemImage: "xmark", accessibilityLabel: "Dismiss") { viewModel.dismissInstallLocationNotice() }
                    }
                }
            }
            if !viewModel.installLocationBlocksRecording && !viewModel.canRecord {
                Text(PermissionKind.screenCapture.navigationHint).font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button(mainButtonTitle, systemImage: viewModel.canRecord ? (viewModel.isRecording ? "stop.circle.fill" : "record.circle") : "gearshape") {
                    if viewModel.installLocationBlocksRecording { viewModel.revealAppInFinder() }
                    else if !viewModel.canRecord { viewModel.openSystemSettings() }
                    else { Task { await viewModel.toggleRecording() } }
                }
                .disabled(viewModel.isFinalizingAfterFailure || !viewModel.state.allowsCaptureSourceChange && !viewModel.isRecording)
                .keyboardShortcut("r", modifiers: .command)
                .buttonStyle(.borderedProminent).controlSize(.large).tint(WorkspaceStyle.recording)
                Spacer()
            }
            FocusLiveSources()
            if viewModel.selectedSource.kind != .multiple { RecordingLevelsView(recorder: viewModel) }
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

/// Shares routing controls and telemetry leaves; source rows never observe PCM.
private struct FocusLiveSources: View {
    @Environment(RecorderViewModel.self) private var recorder
    private var source: AudioSource { recorder.selectedSource }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Divider()
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 300), spacing: 24)], alignment: .leading, spacing: 18) {
                if source.requiresScreenCapture {
                    row(title: RoutingSourceNames.playback(source, appName: recorder.audioSource.knownAppName),
                        levelID: source.playbackLevelID, track: .playback, available: true, symbol: "app.connected.to.app.below.fill")
                }
                ForEach(source.inputSelections) { input in
                    let device = recorder.audioSource.availableInputDevices().first { $0.uid == input.deviceUID }
                    row(title: device?.name ?? RoutingSourceNames.shared.input(input.deviceUID),
                        levelID: "input:" + input.deviceUID, track: .input(input.deviceUID),
                        available: device != nil, symbol: "mic.fill")
                }
            }
            FocusLiveSourceWarnings(recorder: recorder, telemetry: recorder.telemetry)
            Divider()
        }
    }

    private func row(title: String, levelID: String, track: CaptureTrack, available: Bool, symbol: String) -> some View {
        let levels = recorder.audio.levels
        let muted = levels.level(levelID).muted
        return HStack(spacing: 10) {
            Image(systemName: symbol).foregroundStyle(.secondary).frame(width: 18)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.callout.weight(.medium)).lineLimit(2).help(title)
                CompactRoutingStatus(track: track, muted: muted, available: available, captured: true, preservesSources: source.isMixed)
            }.frame(maxWidth: .infinity, alignment: .leading)
            Group {
                if recorder.isRecording { RecordingCompactPeaks(telemetry: recorder.telemetry, track: track, channel: -1) }
                else { CompactPeakPair(meters: .init(), now: 0, channel: -1) }
            }.frame(width: 110)
            Button {
                var next = levels.level(levelID); next.muted.toggle(); levels.set(levelID, next)
            } label: {
                Image(systemName: muted ? "speaker.slash.fill" : "speaker.wave.2")
                    .foregroundStyle(muted ? Color.orange : Color.secondary)
            }.buttonStyle(.borderless)
                .accessibilityLabel("\(muted ? "Unmute" : "Mute") \(title) \(source.isMixed ? "in recording mix" : "in saved recording")")
                .accessibilityValue(muted ? "Muted" : "Not muted")
                .help(source.isMixed ? "Changes the mix contribution. Original source audio remains recorded." : "Gain and mute change the saved recording.")
        }.accessibilityElement(children: .contain)
    }
}

/// Structural health transitions update warnings; meter ticks stay in their leaves.
private struct FocusLiveSourceWarnings: View {
    let recorder: RecorderViewModel
    @Bindable var telemetry: RecorderTelemetry
    var body: some View {
        if recorder.isRecording {
            if let summary = recorder.interruptedSourceSummary {
                HStack(alignment: .top) {
                    Label(summary, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Spacer(minLength: 8)
                    Button("Stop & start new take") { Task { await recorder.stopAndStartNewTake() } }.controlSize(.small)
                }.font(.caption).fixedSize(horizontal: false, vertical: true)
            }
            ForEach(telemetry.layoutSources) { item in
                if let failure = item.health.failureMessage {
                    Label("\(item.name): \(failure)", systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                }
                if item.health.clipped {
                    Label("\(item.name): Clipping detected · reduce recording gain", systemImage: "waveform.badge.exclamationmark")
                        .font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

/// Observe duration locally rather than invalidating the surrounding workspace.
private struct FocusRecordingTime: View {
    @Bindable var telemetry: RecorderTelemetry
    var body: some View {
        Text(telemetry.formattedDuration).font(.system(size: 46, weight: .light, design: .monospaced)).monospacedDigit()
            .accessibilityLabel("Recording duration").accessibilityValue(telemetry.formattedDuration)
    }
}

struct StatusBar: View {
    let state: RecordingState
    let duration: String
    let statusText: String
    var body: some View {
        VStack(alignment: .leading, spacing: StudioSpacing.md) {
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
        if state == .recording {
            VStack(alignment: .leading, spacing: StudioSpacing.md) {
                RecorderElapsedDisplay(telemetry: telemetry)
                Label(statusText, systemImage: "record.circle")
                    .font(.callout).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } else {
            StatusBar(state: state, duration: telemetry.formattedDuration, statusText: statusText)
        }
    }
}

struct RecorderWaveformSection: View {
    @Bindable var telemetry: RecorderTelemetry

    var body: some View {
        RecorderWaveformDisplay(telemetry: telemetry)
        .frame(height: WorkspaceStyle.waveformHeight)
        .padding(StudioSpacing.md)
        .background(WorkspaceStyle.panel, in: RoundedRectangle(cornerRadius: StudioRadius.card))
    }
}

/// A completed take can need review without being a failed save or blocking the next take.
struct RecordingReviewNotice: View {
    let recorder: RecorderViewModel
    @Environment(\.openWindow) private var openWindow
    @Environment(\.studioNavigation) private var navigation
    var body: some View {
        if let message = recorder.alerts.reviewMessage {
            VStack(alignment: .leading, spacing: StudioSpacing.sm) {
                Label(message, systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                Button("Review saved recordings") {
                    AppWindow.open(.recordings, using: openWindow, navigation: navigation)
                }.buttonStyle(.borderless)
            }.accessibilityElement(children: .contain)
        }
    }
}
