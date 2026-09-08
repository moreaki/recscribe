import SwiftUI

/// Configuration only: credentials and network work live outside SwiftUI.
struct IntelligenceSettingsView: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var runtime: RuntimeManager
    @EnvironmentObject private var library: SessionLibrary
    @StateObject private var credentials = IntelligenceCredentials()
    @State private var apiKey = ""

    var body: some View {
        VStack(alignment: .leading, spacing: GlassSpacing.l) {
            Toggle("Enable AI post-processing", isOn: $settings.values.aiEnabled)
            if settings.values.processingLocation == .local {
                Text("Local mode permits Ollama text processing only. Configure an OpenAI key here if needed, then choose Hybrid or Cloud in Transcription before approving any upload.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Picker("Provider", selection: $settings.values.aiProvider) {
                ForEach(IntelligenceProvider.allCases, id: \.self) { Text($0.label).tag($0) }
            }.pickerStyle(.segmented)
            if settings.values.aiProvider == .ollama {
                Button("Detect local AI models") { runtime.detectAI() }.disabled(runtime.busy || library.recordingActive)
                Picker("Installed model", selection: $settings.values.ollamaModel) {
                    Text(settings.values.ollamaModel.isEmpty ? "Choose a model" : settings.values.ollamaModel).tag(settings.values.ollamaModel)
                    ForEach(runtime.localAIModels.filter { $0 != settings.values.ollamaModel }, id: \.self) { Text($0).tag($0) }
                }
                Text("127.0.0.1:11434 only. Start Ollama and install a local model separately. Remote Ollama models are refused.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Label("OpenAI connection", systemImage: "key.fill").font(.headline)
                SecureField("OpenAI API key", text: $apiKey).textFieldStyle(.roundedBorder)
                HStack {
                    Button("Save key") { credentials.save(apiKey); apiKey = "" }.disabled(apiKey.isEmpty || credentials.busy)
                    Button("Test connection & load models") { credentials.test() }.disabled(credentials.busy)
                    Button("Remove key", role: .destructive) { credentials.remove() }.disabled(credentials.busy)
                    if credentials.busy { ProgressView().controlSize(.small); Button("Cancel") { credentials.cancel() } }
                }
                Text(credentials.status).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                HStack {
                    TextField("Text model ID", text: $settings.values.openaiModel).textFieldStyle(.roundedBorder)
                    Menu("Choose model") {
                        ForEach(credentials.models, id: \.self) { model in
                            Button(model) { settings.values.openaiModel = model }
                        }
                    }.disabled(credentials.models.isEmpty)
                }
                Text("This RecScribe Keychain key also serves optional cloud transcription. Audio requires its own approval in Cloud mode. Each cloud text action requires separate confirmation and may incur API charges. Text requests use store:false; OpenAI’s abuse-monitoring retention can still apply. No automatic upload or fallback.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Toggle("Include summary in local automatic processing", isOn: $settings.values.summarize)
                .disabled(!settings.values.aiEnabled || settings.values.aiProvider != .ollama)
            Text("AI text is an unverified derivative, not a correction to the audio evidence. Review ambiguous words against the recording.")
                .font(.caption).foregroundStyle(.secondary)
            Text("Connections, text improvement and summaries run natively in Swift. Python is only needed for the reference audio transcription pipeline.")
                .font(.caption).foregroundStyle(.secondary)
        }.onDisappear { apiKey = ""; credentials.cancel() }
    }
}
