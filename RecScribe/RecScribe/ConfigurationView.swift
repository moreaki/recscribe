import SwiftUI

struct ConfigurationView: View {
    @EnvironmentObject private var recorder: RecorderViewModel
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.glassTheme) private var theme
    @EnvironmentObject private var runtime: RuntimeManager
    @EnvironmentObject private var library: SessionLibrary
    @State private var section: SettingsSection
    @State private var installation: LocalSoftware?
    @State private var download: WhisperModel?
    init(section: SettingsSection = .storage) { _section = State(initialValue: section) }
    private enum Layout {
        static let numericFieldWidth: CGFloat = 100
        static let progressWidth: CGFloat = 90
    }

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
            SettingsNavigation(selection: $section)
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
        .confirmationDialog("Install local software?", isPresented: Binding(get: { installation != nil }, set: { if !$0 { installation = nil } })) {
            Button("Install") { if let name = installation { runtime.install(name) }; installation = nil }
        } message: {
            Text(installation == .pipeline ? "Creates a private Python environment and downloads the pipeline’s package dependencies. No models or audio are uploaded." : "Runs brew install \(installation?.rawValue ?? ""). Homebrew downloads software and dependencies; no models or recordings are sent. Ollama must then be started separately.")
        }
        .confirmationDialog("Download Whisper model?", isPresented: Binding(get: { download != nil }, set: { if !$0 { download = nil } })) {
            Button("Download and verify") { if let model = download { runtime.download(model) }; download = nil }
        } message: {
            Text("\(download?.id ?? "") · \(ByteCountFormatter.string(fromByteCount: download?.bytes ?? 0, countStyle: .file)) from ggerganov/whisper.cpp on Hugging Face. SHA-256 is checked before selection. No audio is uploaded.")
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
                Button("Install FFmpeg…") { installation = .ffmpeg }.disabled(runtime.busy)
            }
        }
    }
    private var transcription: some View {
        Group {
        card("Live draft", detail: "Switch on in the recorder at any time. Native Swift prepares 16-kHz chunks; one local Whisper worker catches up from disk. Different channels stay separate. Text is provisional, with a small delay.") {
            Picker("Chunk duration", selection: $settings.values.liveChunkSeconds) {
                ForEach(LiveTranscriptionPolicy.chunkChoices, id: \.self) { Text("\($0) seconds").tag($0) }
            }.pickerStyle(.segmented)
            Stepper("Whisper CPU threads: \(settings.values.liveThreads)", value: $settings.values.liveThreads, in: LiveTranscriptionPolicy.threadRange)
            Text("Shorter chunks update sooner but reload the model more often. Changes apply when live transcription is next enabled. Auto language detection runs per chunk; mixed-language boundaries require review.").font(.caption).foregroundStyle(.secondary)
        }
        card("Completed recordings", detail: "Capture works without Whisper, Python or AI. The full verification, normalization and summary pipeline runs after recording or file import, independently of live drafts.") {
            Toggle("Automatically transcribe completed recordings", isOn: $settings.values.autoTranscribe)
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
            Button("Set up isolated pipeline runtime…") { installation = .pipeline }.disabled(runtime.busy)
            Text("Text actions require pipeline \(PipelineRuntime.minimumVersion) or newer. Setup creates a new environment and retains previous versions.").font(.caption).foregroundStyle(.secondary)
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
                HStack { Button("Detect Whisper & Metal") { runtime.detect() }; Button("Install whisper.cpp…") { installation = .whisperCPP } }.disabled(runtime.busy || library.recordingActive)
            }
            card("Model library", detail: "Choose the memory/accuracy trade-off explicitly. Downloads are optional and verified against the published model checksum.") {
                ForEach(WhisperModel.catalog) { model in
                    HStack { Text(model.id).fontWeight(.medium); Spacer(); Text(ByteCountFormatter.string(fromByteCount: model.bytes, countStyle: .file)).foregroundStyle(.secondary); Button("Download…") { download = model } }.disabled(runtime.busy || library.recordingActive)
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
                Button("Install Ollama…") { installation = .ollama }.disabled(runtime.busy || library.recordingActive)
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
