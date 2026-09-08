import Foundation

/// Snapshot the exact source/model/mode before presenting consent. Settings may
/// change while a confirmation is open; they must not change the approved job.
nonisolated struct TextProcessingRequest: Identifiable, Sendable {
    let id = UUID()
    let transcript: URL
    let settings: AppSettings.Values
    let summary: Bool
    let sourceName: String
    var isCloud: Bool { settings.aiProvider == .openai }
    var model: String { isCloud ? settings.openaiModel : settings.ollamaModel }

    init(transcript: URL, settings: AppSettings.Values, summary: Bool, sourceName: String? = nil) throws {
        guard settings.aiEnabled else { throw SessionError.invalid("Enable AI and select a model in Settings → Intelligence") }
        guard !(settings.aiProvider == .openai ? settings.openaiModel : settings.ollamaModel).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw SessionError.invalid("Choose an AI model in Settings → Intelligence")
        }
        var snapshot = settings
        // Improve means normalize unless the user explicitly selected translation.
        snapshot.mode = summary ? .verbatim : settings.mode == .translate ? .translate : .normalize
        if snapshot.mode != .verbatim && snapshot.targetLanguage.isEmpty { throw SessionError.invalid("Choose a target language in Settings → Transcription") }
        self.transcript = transcript
        self.settings = snapshot
        self.summary = summary
        self.sourceName = sourceName ?? transcript.deletingLastPathComponent().lastPathComponent
    }

    func arguments(output: URL) -> [String] {
        var args = ["-m", "recscribe", transcript.path, "--derive", "--output", output.path,
                    "--mode", settings.mode.rawValue]
        if settings.mode != .verbatim { args += ["--target-language", settings.targetLanguage] }
        if summary { args += ["--summarize"] }
        if isCloud { args += ["--openai-model", model, "--allow-cloud-text", "--openai-key-stdin"] }
        else { args += ["--ollama-model", model, "--local-only"] }
        return args
    }
}
