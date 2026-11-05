import SwiftUI

/// Configuration only: credentials and network work live outside SwiftUI.
struct IntelligenceSettingsView: View {
    @Environment(AppSettings.self) private var settings
    private var settingsBinding: Bindable<AppSettings> { Bindable(settings) }
    @Environment(RuntimeManager.self) private var runtime
    @Environment(SessionLibrary.self) private var library
    @State private var credentials = IntelligenceCredentials()
    @State private var apiKey = ""

    var body: some View {
        VStack(alignment: .leading, spacing: StudioSpacing.l) {
            FocusPreferenceRow(title: "AI post-processing", detail: "Improve text, translate and summarize through explicit Studio actions.") {
                Toggle("Enable AI post-processing", isOn: settingsBinding.values.aiEnabled).labelsHidden().toggleStyle(.switch)
            }
            if settings.values.processingLocation == .local {
                Text("Local mode permits Ollama text processing only. Configure an OpenAI key here if needed, then choose Hybrid or Cloud in Transcription before approving any upload.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            FocusPreferenceRow(title: "Provider") { Picker("Provider", selection: settingsBinding.values.aiProvider) {
                ForEach(IntelligenceProvider.allCases, id: \.self) { Text($0.label).tag($0) }
            }.labelsHidden() }
            if settings.values.aiProvider == .ollama {
                FocusPreferenceRow(title: "Local model", detail: "Ollama · 127.0.0.1:11434") { Picker("Installed model", selection: settingsBinding.values.ollamaModel) {
                    Text(settings.values.ollamaModel.isEmpty ? "Choose a model" : settings.values.ollamaModel).tag(settings.values.ollamaModel)
                    ForEach(runtime.localAIModels.filter { $0 != settings.values.ollamaModel }, id: \.self) { Text($0).tag($0) }
                }.labelsHidden() }
                Button("Detect local AI models", systemImage: "arrow.clockwise") { runtime.detectAI() }.disabled(runtime.busy || library.recordingActive)
                Text(runtime.localAIModels.isEmpty
                     ? "127.0.0.1:11434 only. Detect available models; if none are found, start Ollama and add a local model separately. Remote Ollama models are refused."
                     : "\(runtime.localAIModels.count) local models detected at 127.0.0.1:11434. Remote Ollama models are refused.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                FocusPreferenceRow(title: "OpenAI API key", detail: "Stored in this app’s Keychain access group.") {
                    SecureField("OpenAI API key", text: $apiKey).textFieldStyle(.roundedBorder)
                }
                HStack {
                    Button("Save key") { credentials.save(apiKey); apiKey = "" }.disabled(apiKey.isEmpty || credentials.busy)
                    Button("Test connection & load models") { credentials.test() }.disabled(credentials.busy)
                    Button("Remove key", role: .destructive) { credentials.remove() }.disabled(credentials.busy)
                    if credentials.busy { ProgressView().controlSize(.small); Button("Cancel") { credentials.cancel() } }
                }
                Text(credentials.status).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                FocusPreferenceRow(title: "Text model") { HStack {
                    TextField("Text model ID", text: settingsBinding.values.openaiModel).textFieldStyle(.roundedBorder)
                    Menu("Choose model") {
                        ForEach(credentials.models, id: \.self) { model in
                            Button(model) { settings.values.openaiModel = model }
                        }
                    }.disabled(credentials.models.isEmpty)
                } }
                Text("This RecScribe Keychain key also serves optional cloud transcription. Audio requires its own approval in Cloud mode. Each cloud text action requires separate confirmation and may incur API charges. Text requests use store:false; OpenAI’s abuse-monitoring retention can still apply. No automatic upload or fallback.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            FocusPreferenceRow(title: "Automatic local summary", detail: "Include a summary when local automatic processing uses Ollama.") {
            Toggle("Include summary in local automatic processing", isOn: settingsBinding.values.summarize).labelsHidden().toggleStyle(.switch)
                .disabled(!settings.values.aiEnabled || settings.values.aiProvider != .ollama)
            }
            Text("AI text is an unverified derivative, not a correction to the audio evidence. Review ambiguous words against the recording.")
                .font(.caption).foregroundStyle(.secondary)
            Text("Recordings stay on this Mac unless you explicitly approve cloud processing.")
                .font(.caption).foregroundStyle(.secondary)
        }.onDisappear { apiKey = ""; credentials.cancel() }
    }
}
