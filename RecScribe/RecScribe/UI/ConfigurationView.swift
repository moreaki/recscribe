import SwiftUI
import RecScribeCore

struct ConfigurationView: View {
    @Environment(RecorderViewModel.self) private var recorder
    @Environment(\.openWindow) private var openWindow
    @Environment(\.studioNavigation) private var navigation
    @Environment(AppSettings.self) private var settings
    private var settingsBinding: Bindable<AppSettings> { Bindable(settings) }
    @Environment(\.studioTheme) private var theme
    @Environment(RuntimeManager.self) private var runtime
    @Environment(SessionLibrary.self) private var library
    private let liveDrafts: LiveDraftStore?
    @State private var section: SettingsSection
    @State private var installation: LocalSoftware?
    @State private var download: WhisperModel?
    @State private var availabilityRefresh = 0
    @AppStorage(FocusAppearance.defaultsKey) private var appearance = FocusAppearance.system
    private let embeddedInStudio: Bool
    init(section: SettingsSection = .general, liveDrafts: LiveDraftStore? = nil, embeddedInStudio: Bool = false) {
        _section = State(initialValue: section)
        self.liveDrafts = liveDrafts
        self.embeddedInStudio = embeddedInStudio
    }
    private enum Layout {
        static let numericFieldWidth: CGFloat = 100
        static let progressWidth: CGFloat = 90
    }
    private var availabilityKey: [String] {
        [settings.values.ffmpegPath, settings.values.whisperPath,
         settings.values.modelPath, settings.values.verificationModelPath,
         section.rawValue, String(availabilityRefresh), String(runtime.busy), String(library.recordingActive), String(library.liveWorkActive)]
    }
    private var runtimeActionsDisabled: Bool { runtime.busy || library.recordingActive || library.liveWorkActive }

    var body: some View {
        VStack(alignment: .leading, spacing: StudioSpacing.xxl) {
            HStack(spacing: 14) {
                Image(systemName: "slider.horizontal.3").font(.title2).foregroundStyle(WorkspaceStyle.blue)
                VStack(alignment: .leading, spacing: 6) {
                    Text("Settings").font(.title2.weight(.semibold))
                    Text("Recording, transcription and local tools.").font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
            }
            WorkspaceTabs(title: "Settings", selection: $section)
                .overlay(alignment: .bottom) { Divider() }
            ScrollView {
                VStack(alignment: .leading, spacing: 32) {
                    switch section {
                    case .general: general
                    case .storage: storage
                    case .transcription: transcription
                    case .models: models
                    case .ai: intelligence
                    case .diagnostics: diagnostics
                    }
                }.frame(maxWidth: 960, alignment: .leading).frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 18)
            }
            Divider()
            ForEach(settings.values.migrationWarnings, id: \.self) { warning in
                Text(warning).font(.caption).foregroundStyle(theme.colors.statusWarning)
            }
            HStack {
                Image(systemName: "lock.shield").foregroundStyle(theme.colors.statusSuccess)
                Text(library.recordingActive ? "Recording takes priority. Opt-in live ASR runs at utility priority." : runtime.status)
                    .font(.caption).foregroundStyle(.secondary).lineLimit(3)
                Spacer()
                if runtime.busy { ProgressView(value: runtime.progress).frame(width: Layout.progressWidth); Button("Cancel") { runtime.cancel() } }
            }
        }
        .padding(.horizontal, 36).padding(.top, 24).padding(.bottom, 16).frame(minWidth: embeddedInStudio ? 0 : AppWindow.settings.minimumSize.width,
            idealWidth: embeddedInStudio ? nil : AppWindow.settings.defaultSize.width,
            minHeight: embeddedInStudio ? 0 : AppWindow.settings.minimumSize.height,
            idealHeight: embeddedInStudio ? nil : AppWindow.settings.defaultSize.height)
        .background(WorkspaceStyle.background).tint(WorkspaceStyle.blue).studioThemeAdaptingToContrast()
        .onChange(of: library.recordingActive) { _, active in if active { runtime.cancel() } }
        .task(id: availabilityKey) {
            guard !runtime.busy else { return }
            do { try await Task.sleep(for: .milliseconds(400)) } catch { return }
            await runtime.refreshAvailability()
        }
        .confirmationDialog("Install local software?", isPresented: Binding(get: { installation != nil }, set: { if !$0 { installation = nil } })) {
            Button("Install") {
                if let name = installation { runtime.install(name) }
                installation = nil
            }
        } message: {
            Text("Runs brew install \(installation?.rawValue ?? ""). Homebrew downloads software and dependencies; no models or recordings are sent. Ollama must then be started separately.")
        }
        .confirmationDialog("Download Whisper model?", isPresented: Binding(get: { download != nil }, set: { if !$0 { download = nil } })) {
            Button("Download and verify") { if let model = download { runtime.download(model) }; download = nil }
        } message: {
            Text("\(download?.id ?? "") · \(ByteCountFormatter.string(fromByteCount: download?.bytes ?? 0, countStyle: .file)) from ggerganov/whisper.cpp on Hugging Face. SHA-256 is checked before selection. No audio is uploaded.")
        }
    }

    private var general: some View {
        card("Appearance", detail: "A calm workspace, in the light that suits you.") {
            FocusPreferenceRow(title: "Theme", detail: "Applies to all workspaces, sheets and the menu bar recorder.") {
                Picker("Theme", selection: $appearance) {
                    ForEach(FocusAppearance.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }.pickerStyle(.segmented).labelsHidden()
            }
        }
    }

    @ViewBuilder private func dependencyStatus(_ software: LocalSoftware, name: String) -> some View {
        if software == .ollama, runtime.localAIAvailable {
            Label("Ollama service detected · 127.0.0.1:11434", systemImage: "checkmark.circle.fill")
                .font(.callout).foregroundStyle(WorkspaceStyle.mint)
            Button("Recheck local AI") { runtime.detectAI() }.disabled(runtimeActionsDisabled)
        } else if let found = runtime.dependency(software) {
            Label("\(name) found\(found.version.map { " · \($0)" } ?? "")", systemImage: found.issue == nil ? "checkmark.circle.fill" : "exclamationmark.triangle")
                .font(.callout).foregroundStyle(found.issue == nil ? WorkspaceStyle.mint : theme.colors.statusWarning)
            Text(found.path).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            if software == .ffmpeg && !settings.values.ffmpegPath.isEmpty && settings.values.ffmpegPath != found.path
                || software == .whisperCPP && !settings.values.whisperPath.isEmpty && settings.values.whisperPath != found.path {
                Text("The configured path is unavailable. Select the detected executable to use it.")
                    .font(.caption).foregroundStyle(theme.colors.statusWarning)
            }
            if let issue = found.issue { Text(issue).font(.caption).foregroundStyle(theme.colors.statusWarning) }
            HStack {
                Button("Recheck") { availabilityRefresh += 1 }
                Button("Reveal executable") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: found.path)]) }
                if software == .ffmpeg && settings.values.ffmpegPath != found.path
                            || software == .whisperCPP && settings.values.whisperPath != found.path {
                    Button("Use detected executable") { runtime.useDependency(software) }
                }
            }.disabled(runtimeActionsDisabled || runtime.checkingAvailability)
        } else if runtime.availabilityCurrent && !runtime.checkingAvailability {
            HStack {
                Button("Install \(name)…") { installation = software }
                Button("Recheck") { availabilityRefresh += 1 }
            }.disabled(runtimeActionsDisabled)
        } else {
            Text("Checking local \(name) availability…").font(.caption).foregroundStyle(.secondary)
        }
    }

    private func card<Content: View>(_ title: String, detail: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.headline)
            Text(detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            content()
        }
    }

    private func file(_ title: String, value: Binding<String>) -> some View {
        FocusPreferenceRow(title: title) {
            HStack {
                TextField(title, text: value).textFieldStyle(.roundedBorder)
                Button("Choose…") {
                    let panel = NSOpenPanel(); panel.canChooseDirectories = false
                    if panel.runModal() == .OK, let url = panel.url { value.wrappedValue = url.path }
                }
            }
        }
    }

    private var storage: some View {
        VStack(alignment: .leading, spacing: 32) {
            card("Recording & storage", detail: "Changes apply to future recordings. Original PCM audio is retained.") {
                FocusPreferenceRow(title: "Save recordings to", detail: recorder.saveLocationPath) {
                    Button("Choose folder…") { recorder.chooseSaveLocation() }
                }.disabled(library.recordingActive)
                FocusPreferenceRow(title: "Maximum WAV part size", detail: "MiB per part. Parts share one continuous sample timeline.") {
                    HStack {
                        TextField("MiB", value: Binding(get: {
                            Double(settings.values.storage.maximumPartBytes) / Double(RecordingStorageOptions.bytesPerMiB)
                        }, set: { settings.setPartSizeMiB($0) }), format: .number)
                            .textFieldStyle(.roundedBorder).frame(width: Layout.numericFieldWidth)
                        Text("MiB").foregroundStyle(.secondary)
                    }
                }.disabled(library.recordingActive)
                if let message = settings.validationMessage { Text(message).font(.callout).foregroundStyle(theme.colors.statusWarning) }
                FocusPreferenceRow(title: "Archive format", detail: "Optional conversion follows finalization and verification; original WAV files remain.") {
                    Picker("Archive", selection: settingsBinding.values.storage.archiveFormat) {
                        ForEach(ArchiveFormat.allCases, id: \.self) { Text($0 == .wav ? "WAV only" : $0.rawValue.uppercased()).tag($0) }
                    }.labelsHidden()
                }
                if settings.values.storage.archiveFormat == .flac {
                    FocusPreferenceRow(title: "FLAC compression") {
                        Stepper("\(settings.values.storage.flacCompression)", value: settingsBinding.values.storage.flacCompression, in: RecordingStorageOptions.flacCompressionRange)
                    }
                } else if settings.values.storage.archiveFormat != .wav {
                    FocusPreferenceRow(title: "Bitrate") {
                        Picker("Bitrate", selection: settingsBinding.values.storage.bitrateKbps) {
                            ForEach(RecordingStorageOptions.bitrateChoices, id: \.self) { Text("\($0) kbps").tag($0) }
                        }.labelsHidden()
                    }
                }
            }
            FocusPreferenceRow(title: "Audio sources", detail: recorder.captureSourceName ?? "System audio") {
                Button("Audio routing…", systemImage: "slider.horizontal.below.rectangle") {
                    AppWindow.open(.routing, using: openWindow, navigation: navigation)
                }
            }
            DisclosureGroup("Capture options") {
                VStack(alignment: .leading, spacing: 14) {
                    Text(recorder.captureSourceHint).font(.callout).foregroundStyle(.secondary)
                    HStack {
                        Button("System playback only") { recorder.setCaptureSource(.systemAll) }
                        OverflowMenuButton()
                    }
                    MultipleInputsView(recorder: recorder)
                }.padding(.vertical, 12).disabled(!recorder.allowsCaptureSourceChange)
            }
            DisclosureGroup("Archive tools & limits") {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Hard part-size limit: \(RecordingStorageOptions.hardCap / RecordingStorageOptions.bytesPerMiB) MiB. Smaller parts roll over without dropping or duplicating samples.")
                        .font(.callout).foregroundStyle(.secondary)
                    file("FFmpeg executable", value: settingsBinding.values.ffmpegPath)
                    dependencyStatus(.ffmpeg, name: "FFmpeg")
                }.padding(.vertical, 12)
            }
            if let liveDrafts {
                DisclosureGroup("Preserved Live drafts") { LiveDraftManagementView(store: liveDrafts).padding(.vertical, 12) }
            }
        }
    }

    private var transcription: some View {
        VStack(alignment: .leading, spacing: 32) {
            card("Where processing happens", detail: "Choose deliberately. Changing location never grants upload approval.") {
                FocusPreferenceRow(title: "Processing location", detail: settings.values.processingLocation.detail) {
                    Picker("Processing location", selection: settingsBinding.values.processingLocation) {
                        ForEach(ProcessingLocation.allCases, id: \.self) { Text($0.label).tag($0) }
                    }.labelsHidden()
                }
                Text("Changing location stops optional live transcription and revokes audio approval. Recording continues locally; there is no automatic fallback.")
                    .font(.caption).foregroundStyle(.secondary)
                if settings.values.processingLocation == .cloud {
                    FocusPreferenceRow(title: "Cloud transcription model") {
                        Picker("Cloud model", selection: settingsBinding.values.cloudTranscriptionModel) { Text(RealtimePolicy.model).tag(RealtimePolicy.model) }.labelsHidden()
                    }
                    Label("Audio leaves this Mac only after approval for each recording activation. Internet and API usage charges apply separately for every channel.", systemImage: "cloud")
                        .font(.callout).foregroundStyle(.orange)
                    Text("Uses the OpenAI key in Intelligence. This speech model does not summarize or translate text; precise timestamps, speakers and detected languages are not claimed.")
                        .font(.caption).foregroundStyle(.secondary)
                    HStack { Link("OpenAI pricing", destination: RealtimePolicy.pricing); Link("Data retention & privacy", destination: RealtimePolicy.privacy) }
                }
            }
            card("Completed recordings", detail: "Final transcripts are separate from provisional live text.") {
                FocusPreferenceRow(title: "Automatic transcription", detail: "Process after a recording is safely finalized.") {
                    Toggle("Automatic transcription", isOn: settingsBinding.values.autoTranscribe).labelsHidden().toggleStyle(.switch)
                        .disabled(settings.values.processingLocation == .cloud)
                }
                if settings.values.processingLocation == .cloud {
                    Text("Approved cloud results are available after recording stops. Full-recording recognition requires Local or Hybrid; completed files are never silently uploaded.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                FocusPreferenceRow(title: "Text mode", detail: "Preserve the recognized words, improve readability or translate explicitly.") {
                    Picker("Text mode", selection: settingsBinding.values.mode) {
                        Text("Verbatim ASR").tag(TranscriptionMode.verbatim); Text("Normalize").tag(TranscriptionMode.normalize); Text("Translate").tag(TranscriptionMode.translate)
                    }.labelsHidden()
                }
                FocusPreferenceRow(title: "Source language", detail: "Use auto when the source language is unknown; de-CH for Swiss German.") {
                    TextField("auto, de-CH, en…", text: settingsBinding.values.sourceLanguage).textFieldStyle(.roundedBorder)
                }
                FocusPreferenceRow(title: "Target language", detail: "Used for derived text, with separate AI processing approval.") {
                    TextField("Target language", text: settingsBinding.values.targetLanguage).textFieldStyle(.roundedBorder)
                        .disabled(settings.values.mode == .verbatim)
                }
                Text("Normalize and translate require AI post-processing. Cloud text processing is a separate, confirmed Studio action; automatic recognition never uploads text.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            DisclosureGroup("Live draft & recognition options") {
                VStack(alignment: .leading, spacing: 18) {
                    Text(settings.values.processingLocation == .cloud
                         ? "Each channel uses bounded 24-kHz mono PCM windows, isolated Realtime connections and approximate timing. Only new audio after approval is streamed; shorter windows reduce initial wait but increase connection overhead."
                         : "Native Swift prepares 16-kHz chunks; one local Whisper worker catches up from disk. Shorter windows update sooner but reload the model more often. Changes apply when live transcription is next enabled.")
                        .font(.callout).foregroundStyle(.secondary)
                    FocusPreferenceRow(title: "Chunk duration") {
                        Picker("Chunk duration", selection: settingsBinding.values.liveChunkSeconds) {
                            ForEach(LiveTranscriptionPolicy.chunkChoices, id: \.self) { Text("\($0) seconds").tag($0) }
                        }.labelsHidden()
                    }
                    FocusPreferenceRow(title: "Whisper CPU threads") {
                        Stepper("\(settings.values.liveThreads)", value: settingsBinding.values.liveThreads, in: LiveTranscriptionPolicy.threadRange)
                            .disabled(settings.values.processingLocation == .cloud)
                    }
                    FocusPreferenceRow(title: "Recognition profile") {
                        Picker("Recognition profile", selection: settingsBinding.values.profile) {
                            Text("Single pass").tag(RecognitionProfile.fast); Text("Two distinct models, compare").tag(RecognitionProfile.verified)
                        }.labelsHidden()
                    }
                    if settings.values.profile == .verified { file("Verification model", value: settingsBinding.values.verificationModelPath) }
                    verificationWarning
                    file("Optional whisper.cpp VAD model", value: settingsBinding.values.vadModelPath)
                    Text(VADModel.guidance).font(.caption).foregroundStyle(.secondary)
                    if !settings.values.vadModelPath.isEmpty { Button("Clear optional VAD model") { settings.values.vadModelPath = "" } }
                    Text("WAV inspection, channel preparation, jobs and exports run in Swift. FFmpeg is optional for FLAC, Opus and M4A archive export.")
                        .font(.caption).foregroundStyle(.secondary)
                }.padding(.vertical, 12)
            }
            verificationWarning
        }
    }
    private var models: some View {
        VStack(alignment: .leading, spacing: 28) {
            HStack {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Speech models").font(.headline)
                    Text("Choose the accuracy and memory footprint that suit this Mac.").font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Recheck local files", systemImage: "arrow.clockwise") { availabilityRefresh += 1 }
                    .disabled(runtimeActionsDisabled || runtime.checkingAvailability)
            }
            FocusPreferenceRow(title: "Current model", detail: settings.values.modelPath.isEmpty ? "Choose a local model below or use a custom file." : URL(fileURLWithPath: settings.values.modelPath).lastPathComponent) {
                Button("Choose model file…") {
                    let panel = NSOpenPanel(); panel.canChooseDirectories = false
                    if panel.runModal() == .OK, let url = panel.url { settings.values.modelPath = url.path }
                }.disabled(runtimeActionsDisabled)
            }
            verificationWarning
            card("Installed", detail: "Files found on this Mac. Selection never downloads a model.") {
                let installed = WhisperModel.catalog.filter { runtime.localModel($0) != nil }
                if installed.isEmpty { Text(runtime.checkingAvailability ? "Checking local model files…" : "No catalog models found locally.").font(.callout).foregroundStyle(.secondary) }
                ForEach(installed) { model in modelRow(model) }
            }
            let available = WhisperModel.catalog.filter { runtime.localModel($0) == nil }
            if !available.isEmpty {
                card("Available to download", detail: "Downloads are optional. Size, source and checksum verification are shown before you confirm.") {
                    ForEach(available) { model in modelRow(model) }
                }
            }
            DisclosureGroup("Local tools & custom paths") {
                VStack(alignment: .leading, spacing: 16) {
                    file("Whisper executable", value: settingsBinding.values.whisperPath)
                    file("Selected local ggml model", value: settingsBinding.values.modelPath)
                    Text("whisper.cpp is the reference adapter. Hardware availability alone does not prove that an inference used Metal.").font(.caption).foregroundStyle(.secondary)
                    if !runtime.detectedTools.isEmpty {
                        ForEach(runtime.detectedTools.keys.sorted(), id: \.self) { name in
                            Text("\(name): \(runtime.detectedTools[name] ?? "")").font(.caption).textSelection(.enabled)
                        }
                        Button("Use detected tool paths") { runtime.useDetectedTools() }.disabled(library.recordingActive)
                    }
                    Button("Detect Whisper & Metal") { runtime.detect() }.disabled(runtimeActionsDisabled)
                    dependencyStatus(.whisperCPP, name: "whisper.cpp")
                }.padding(.vertical, 12)
            }
        }
    }

    private func modelRow(_ model: WhisperModel) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(model.id).font(.callout.weight(.medium))
                    Text(ByteCountFormatter.string(fromByteCount: model.bytes, countStyle: .file)).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if let found = runtime.localModel(model) {
                    if !found.expectedSize { Label("File needs review", systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange) }
                    else if settings.values.modelPath == found.path { Label("Selected", systemImage: "checkmark.circle").font(.caption).foregroundStyle(WorkspaceStyle.blue) }
                    else { Button("Select") { settings.values.modelPath = found.path } }
                    Button("Reveal", systemImage: "folder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: found.path)]) }
                } else if runtime.availabilityCurrent && !runtime.checkingAvailability {
                    Button("Download…", systemImage: "arrow.down") { download = model }
                } else { Text("Checking…").font(.caption).foregroundStyle(.secondary) }
            }
            if let found = runtime.localModel(model) {
                DisclosureGroup("File details") {
                    Text(found.path).font(.caption).textSelection(.enabled)
                    Text(found.expectedSize ? "Local file detected; this scan does not verify its SHA-256." : "Existing file size differs from the catalog. Review it before replacing or selecting it.").font(.caption).foregroundStyle(.secondary)
                }.font(.caption).foregroundStyle(.secondary)
            }
        }.padding(.vertical, 12).overlay(alignment: .bottom) { Divider() }.disabled(runtimeActionsDisabled)
    }
    @ViewBuilder private var verificationWarning: some View {
        if let issue = settings.values.verificationIssue {
            Label(issue, systemImage: "exclamationmark.triangle")
                .font(.caption).foregroundStyle(theme.colors.statusWarning)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
    private var intelligence: some View {
        card("Intelligence", detail: "Improve text, translate or summarize a finished transcript. Every action creates a new, source-linked version; audio and raw recognition stay unchanged.") {
            IntelligenceSettingsView()
            if settings.values.aiProvider == .ollama {
                dependencyStatus(.ollama, name: "Ollama")
            }
        }
    }
    private var diagnostics: some View {
        card("Diagnostics & recovery", detail: "Inspect actual runtime status and preserved recording evidence.") {
            FocusPreferenceRow(title: "Local runtime", detail: runtime.status) {
                Button("Recheck runtime", systemImage: "arrow.clockwise") { runtime.detect() }.disabled(runtimeActionsDisabled)
            }
            FocusPreferenceRow(title: "Recording health", detail: "Inspect sources, permissions, levels and interrupted-input notices.") {
                Button("Audio routing…", systemImage: "slider.horizontal.below.rectangle") { AppWindow.open(.routing, using: openWindow, navigation: navigation) }
            }
            FocusPreferenceRow(title: "Saved recordings", detail: "Review source coverage and recover unfinished parts where available.") {
                Button("Recordings…", systemImage: "rectangle.stack") { AppWindow.open(.recordings, using: openWindow, navigation: navigation) }
            }
            FocusPreferenceRow(title: "Private process diagnostics", detail: "Local engine commands, timing and diagnostic files.") {
                Button("Reveal folder", systemImage: "folder") { NSWorkspace.shared.open(LocalProcessRunner().diagnosticsDirectory) }
            }
            if let job = library.latestJob {
                FocusPreferenceRow(title: "Latest job", detail: job.lastPathComponent) {
                    Button("Reveal artifacts", systemImage: "doc.text") { NSWorkspace.shared.activateFileViewerSelecting([job]) }
                }
            }
            DisclosureGroup("Detailed runtime report") {
                Text(runtime.diagnostics.isEmpty ? "Run detection to inspect this Mac." : runtime.diagnostics)
                    .font(.system(.caption, design: .monospaced)).textSelection(.enabled).padding(.vertical, 12)
            }
        }
    }
}
