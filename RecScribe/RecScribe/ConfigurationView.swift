import SwiftUI
import RecScribeCore

struct ConfigurationView: View {
    @EnvironmentObject private var recorder: RecorderViewModel
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.glassTheme) private var theme
    @EnvironmentObject private var runtime: RuntimeManager
    @EnvironmentObject private var library: SessionLibrary
    @State private var section: SettingsSection
    @State private var installation: LocalSoftware?
    @State private var download: WhisperModel?
    @State private var availabilityRefresh = 0
    init(section: SettingsSection = .storage) { _section = State(initialValue: section) }
    private enum Layout {
        static let numericFieldWidth: CGFloat = 100
        static let progressWidth: CGFloat = 90
    }
    private var availabilityKey: [String] {
        [settings.values.ffmpegPath, settings.values.whisperPath, settings.values.pythonPath,
         settings.values.modelPath, settings.values.verificationModelPath,
         section.rawValue, String(availabilityRefresh), String(runtime.busy), String(library.recordingActive), String(library.liveWorkActive)]
    }
    private var runtimeActionsDisabled: Bool { runtime.busy || library.recordingActive || library.liveWorkActive }

    var body: some View {
        VStack(alignment: .leading, spacing: GlassSpacing.xxl) {
            HStack(spacing: GlassSpacing.md) {
                WorkspaceIcon(symbol: "gearshape.fill", tint: WorkspaceStyle.violet)
                VStack(alignment: .leading, spacing: GlassSpacing.xs) {
                    Text("Settings").font(.title3.weight(.semibold))
                    Text("Recording, local models and intelligence. Configured your way.").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Label("Local first", systemImage: "lock.shield").font(.caption).foregroundStyle(WorkspaceStyle.mint)
            }
            WorkspaceTabs(title: "Settings", selection: $section)
            ScrollView {
                VStack(alignment: .leading, spacing: GlassSpacing.xl) {
                    switch section {
                    case .storage: storage
                    case .transcription: transcription
                    case .models: models
                    case .ai: intelligence
                    case .diagnostics: diagnostics
                    }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(GlassSpacing.xxs)
            }.scrollIndicators(.never)
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
        .padding(GlassSpacing.xxl).frame(minWidth: AppWindow.settings.minimumSize.width,
            idealWidth: AppWindow.settings.defaultSize.width, minHeight: AppWindow.settings.minimumSize.height,
            idealHeight: AppWindow.settings.defaultSize.height)
        .background(WorkspaceStyle.background).tint(WorkspaceStyle.blue).glassThemeAdaptingToContrast()
        .onChange(of: library.recordingActive) { _, active in if active { runtime.cancel() } }
        .task(id: availabilityKey) {
            guard !runtime.busy else { return }
            do { try await Task.sleep(for: .milliseconds(400)) } catch { return }
            await runtime.refreshAvailability()
        }
        .confirmationDialog(installation == .pipeline && runtime.dependency(.pipeline) != nil ? "Reinitialize pipeline runtime?" : "Install local software?", isPresented: Binding(get: { installation != nil }, set: { if !$0 { installation = nil } })) {
            Button(installation == .pipeline && runtime.dependency(.pipeline) != nil ? "Reinitialize" : "Install") {
                if let name = installation { runtime.install(name, reinitialize: name == .pipeline && runtime.dependency(.pipeline) != nil) }
                installation = nil
            }
        } message: {
            Text(installation == .pipeline ? "Creates a new private Python environment and downloads the pipeline’s package dependencies. Existing environments, models and jobs are retained. No models or audio are uploaded." : "Runs brew install \(installation?.rawValue ?? ""). Homebrew downloads software and dependencies; no models or recordings are sent. Ollama must then be started separately.")
        }
        .confirmationDialog("Download Whisper model?", isPresented: Binding(get: { download != nil }, set: { if !$0 { download = nil } })) {
            Button("Download and verify") { if let model = download { runtime.download(model) }; download = nil }
        } message: {
            Text("\(download?.id ?? "") · \(ByteCountFormatter.string(fromByteCount: download?.bytes ?? 0, countStyle: .file)) from ggerganov/whisper.cpp on Hugging Face. SHA-256 is checked before selection. No audio is uploaded.")
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
                if software == .pipeline {
                    Button("Reinitialize pipeline…") { installation = .pipeline }
                    Button("Forget selection") { runtime.forgetPipelineSelection() }
                        .help("Clears the selected Python path. Existing environments, models and jobs are retained.")
                } else if software == .ffmpeg && settings.values.ffmpegPath != found.path
                            || software == .whisperCPP && settings.values.whisperPath != found.path {
                    Button("Use detected executable") { runtime.useDependency(software) }
                }
            }.disabled(runtimeActionsDisabled || runtime.checkingAvailability)
        } else if runtime.availabilityCurrent && !runtime.checkingAvailability {
            HStack {
                Button(software == .pipeline ? "Set up isolated pipeline runtime…" : "Install \(name)…") { installation = software }
                Button("Recheck") { availabilityRefresh += 1 }
            }.disabled(runtimeActionsDisabled)
        } else {
            Text("Checking local \(name) availability…").font(.caption).foregroundStyle(.secondary)
        }
    }

    private func card<Content: View>(_ title: String, detail: String, @ViewBuilder content: () -> Content) -> some View {
        WorkspaceCard {
            VStack(alignment: .leading, spacing: GlassSpacing.l) {
                Label(title, systemImage: section.symbol).font(.headline).foregroundStyle(section.tint)
                Text(detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                content()
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
    }
    private func file(_ title: String, value: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: GlassSpacing.sm) {
            Text(title).font(.caption).foregroundStyle(.secondary)
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
        Group {
            card("Capture sources", detail: recorder.captureSourceHint) {
                Text(recorder.captureSourceName ?? "All system audio").font(.headline)
                Text("Use the capture menu to choose an app. Add an input below to record both sides of a meeting. Source files retain all input channels; the stereo mix uses channels 1–2 (mono is centered). Interface loopback channels can duplicate playback.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button("System playback only") { recorder.setCaptureSource(.systemAll) }
                    OverflowMenuButton()
                }
                MultipleInputsView(recorder: recorder)
                ForEach(recorder.audioSource.availableInputDevices()) { device in
                    Button("\(recorder.audioSource.selectedSource.appBundleID == nil ? "System playback" : "Selected app") + \(device.name)") {
                        recorder.setCaptureSource(.mixed(appBundleID: recorder.audioSource.selectedSource.appBundleID, deviceUID: device.uid))
                    }
                }
            }.disabled(!recorder.state.allowsCaptureSourceChange)
            card("Capture safely", detail: "Recording always writes 16-bit PCM WAV. Parts share one session and a continuous sample timeline. Changes apply to the next recording.") {
                HStack {
                    Text("Maximum WAV part size (MiB)"); Spacer()
                    TextField("MiB", value: Binding(get: {
                        Double(settings.values.storage.maximumPartBytes) / Double(RecordingStorageOptions.bytesPerMiB)
                    }, set: { settings.setPartSizeMiB($0) }), format: .number)
                        .frame(width: Layout.numericFieldWidth).textFieldStyle(.roundedBorder)

                }
                if let message = settings.validationMessage { Text(message).foregroundStyle(theme.colors.statusWarning) }
                Text("Hard limit: \(RecordingStorageOptions.hardCap / RecordingStorageOptions.bytesPerMiB) MiB. Smaller parts roll over without dropping or duplicating samples.").font(.caption).foregroundStyle(.secondary)
                HStack { Text(recorder.saveLocationPath).lineLimit(1).truncationMode(.middle); Spacer(); Button("Choose folder…") { recorder.chooseSaveLocation() } }
            }.disabled(library.recordingActive)
            card("Archive after recording", detail: "Optional conversion runs after finalization and verification, at utility priority. Originals are always retained.") {
                Picker("Archive", selection: $settings.values.storage.archiveFormat) {
                    ForEach(ArchiveFormat.allCases, id: \.self) { Text($0 == .wav ? "WAV only" : $0.rawValue.uppercased()).tag($0) }
                }.pickerStyle(.segmented)
                if settings.values.storage.archiveFormat == .flac {
                    Stepper("FLAC compression: \(settings.values.storage.flacCompression)", value: $settings.values.storage.flacCompression, in: RecordingStorageOptions.flacCompressionRange)
                } else if settings.values.storage.archiveFormat != .wav {
                    Picker("Bitrate", selection: $settings.values.storage.bitrateKbps) { ForEach(RecordingStorageOptions.bitrateChoices, id: \.self) { Text("\($0) kbps").tag($0) } }
                }
                file("FFmpeg executable", value: $settings.values.ffmpegPath)
                dependencyStatus(.ffmpeg, name: "FFmpeg")
            }
        }
    }
    private var transcription: some View {
        Group {
        card("Processing location", detail: settings.values.processingLocation.detail) {
            Picker("Processing location", selection: $settings.values.processingLocation) {
                ForEach(ProcessingLocation.allCases, id: \.self) { Text($0.label).tag($0) }
            }.pickerStyle(.segmented)
            Text("Changing location stops optional live transcription and revokes audio approval. Recording continues locally. There is no automatic fallback.")
                .font(.caption).foregroundStyle(.secondary)
            if settings.values.processingLocation == .cloud {
                Picker("Cloud transcription model", selection: $settings.values.cloudTranscriptionModel) {
                    Text(RealtimePolicy.model).tag(RealtimePolicy.model)
                }
                Label("Audio leaves this Mac only after you approve each recording activation. Internet and API usage charges apply, separately for every channel.", systemImage: "cloud")
                    .font(.callout).foregroundStyle(.orange)
                Text("Uses the RecScribe OpenAI key in Intelligence. This speech model does not summarize or translate text. Account access must support the selected model. Precise timestamps, speakers and detected languages are not claimed.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack { Link("OpenAI pricing", destination: RealtimePolicy.pricing); Link("Data retention & privacy", destination: RealtimePolicy.privacy) }
            }
        }
        card("Live draft", detail: settings.values.processingLocation == .cloud
             ? "Swift prepares 24-kHz mono PCM for each channel independently. Only new audio after approval is streamed in bounded windows; incremental text arrives with a delay. Turn timestamps are approximate."
             : "Switch on in the recorder at any time. Native Swift prepares 16-kHz chunks; one local Whisper worker catches up from disk. Different channels stay separate. Text is provisional, with a small delay.") {
            Picker("Chunk duration", selection: $settings.values.liveChunkSeconds) {
                ForEach(LiveTranscriptionPolicy.chunkChoices, id: \.self) { Text("\($0) seconds").tag($0) }
            }.pickerStyle(.segmented)
            Stepper("Whisper CPU threads: \(settings.values.liveThreads)", value: $settings.values.liveThreads, in: LiveTranscriptionPolicy.threadRange)
                .disabled(settings.values.processingLocation == .cloud)
            Text(settings.values.processingLocation == .cloud
                 ? "Each window uses an isolated Realtime connection. Shorter windows reduce the initial wait, but increase connection overhead. No history is uploaded when enabling mid-recording."
                 : "Shorter chunks update sooner but reload the model more often. Changes apply when live transcription is next enabled. Auto detects language per chunk and channel; mixed-language boundaries require review. For a known language, set Source language below (for example de-CH).")
                .font(.caption).foregroundStyle(.secondary)
        }
        card("Completed recordings", detail: "Capture works without Whisper, Python or AI. The full verification, normalization and summary pipeline runs after recording or file import, independently of live drafts.") {
            Toggle("Automatically transcribe completed recordings", isOn: $settings.values.autoTranscribe)
                .disabled(settings.values.processingLocation == .cloud)
            if settings.values.processingLocation == .cloud {
                Text("Approved cloud results appear in Transcript after recording stops. Full-recording recognition requires Local or Hybrid; completed files are never silently uploaded.").font(.caption).foregroundStyle(.secondary)
            }
            Picker("Text mode", selection: $settings.values.mode) {
                Text("Verbatim ASR").tag(TranscriptionMode.verbatim); Text("Normalize").tag(TranscriptionMode.normalize); Text("Translate").tag(TranscriptionMode.translate)
            }.pickerStyle(.segmented)
            HStack { TextField("Source language (auto, de-CH, en…)", text: $settings.values.sourceLanguage); TextField("Target language", text: $settings.values.targetLanguage).disabled(settings.values.mode == .verbatim) }.textFieldStyle(.roundedBorder)
            Picker("Recognition profile", selection: $settings.values.profile) {
                Text("Single pass").tag(RecognitionProfile.fast); Text("Two distinct models, compare").tag(RecognitionProfile.verified)
            }
            if settings.values.profile == .verified { file("Verification model", value: $settings.values.verificationModelPath) }
            verificationWarning
            file("Optional whisper.cpp VAD model", value: $settings.values.vadModelPath)
            Text(VADModel.guidance).font(.caption).foregroundStyle(.secondary)
            if !settings.values.vadModelPath.isEmpty {
                Button("Clear optional VAD model") { settings.values.vadModelPath = "" }
            }
            file("Pipeline Python 3.12+", value: $settings.values.pythonPath)
            dependencyStatus(.pipeline, name: "Pipeline")
            Text("Completed local audio jobs use this runtime. AI text actions and cloud live transcription run natively in Swift. Setup retains previous versions.").font(.caption).foregroundStyle(.secondary)
            Text("Normalize/translate require AI post-processing. Cloud text processing is always a separate, confirmed action in the Studio; automatic recognition never uploads text.").font(.caption).foregroundStyle(.secondary)
        }
        }
    }
    private var models: some View {
        Group {
            card("Whisper · accelerated locally", detail: "whisper.cpp is the reference adapter. Hardware availability is not proof that a particular inference used Metal.") {
                file("Whisper executable", value: $settings.values.whisperPath)
                file("Selected local ggml model", value: $settings.values.modelPath)
                verificationWarning
                if !runtime.detectedTools.isEmpty {
                    ForEach(runtime.detectedTools.keys.sorted(), id: \.self) { name in
                        Text("\(name): \(runtime.detectedTools[name] ?? "")").font(.caption).textSelection(.enabled)
                    }
                    Button("Use detected tool paths") { runtime.useDetectedTools() }
                        .disabled(library.recordingActive)
                }
                Button("Detect Whisper & Metal") { runtime.detect() }.disabled(runtimeActionsDisabled)
                dependencyStatus(.whisperCPP, name: "whisper.cpp")
            }
            card("Model library", detail: "Choose the memory/accuracy trade-off explicitly. Downloads are optional and verified against the published model checksum.") {
                Button("Recheck local model files") { availabilityRefresh += 1 }.disabled(runtimeActionsDisabled)
                ForEach(WhisperModel.catalog) { model in
                    VStack(alignment: .leading, spacing: 5) {
                        HStack {
                            Text(model.id).fontWeight(.medium)
                            Spacer()
                            Text(ByteCountFormatter.string(fromByteCount: model.bytes, countStyle: .file)).foregroundStyle(.secondary)
                            if let found = runtime.localModel(model) {
                                Label(found.expectedSize ? "Found locally" : "File needs review", systemImage: found.expectedSize ? "checkmark.circle" : "exclamationmark.triangle")
                                if found.expectedSize && settings.values.modelPath != found.path {
                                    Button("Select") { settings.values.modelPath = found.path }
                                }
                                Button("Reveal") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: found.path)]) }
                            } else if runtime.availabilityCurrent && !runtime.checkingAvailability {
                                Button("Download…") { download = model }
                            } else { Text("Checking…").foregroundStyle(.secondary) }
                        }
                        if let found = runtime.localModel(model) {
                            Text(found.path).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                            Text(found.expectedSize ? "Local file detected; this scan does not verify its SHA-256." : "Existing file size differs from the catalog. Review the file before selecting or replacing it.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }.disabled(runtimeActionsDisabled)
                }
            }
        }
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
        card("Evidence, not guesses", detail: "Recorder timings use unified logging/signposts. Each transcription job retains stage timings, engine commands, model hashes, raw output and review reasons.") {
            Text(runtime.diagnostics.isEmpty ? "Run detection in Models or AI to inspect this Mac." : runtime.diagnostics)
                .font(.system(.caption, design: .monospaced)).textSelection(.enabled)
            Button("Reveal private process diagnostics") {
                NSWorkspace.shared.open(LocalProcessRunner().diagnosticsDirectory)
            }
            if let job = library.latestJob { Button("Reveal latest job and logs") { NSWorkspace.shared.activateFileViewerSelecting([job]) } }
        }
    }
}
