import Foundation
import RecScribeCore

nonisolated enum NativeAudioTranscription {
    static func run(_ source: URL, output: URL, settings: AppSettings.Values, cancel: WorkCancellation) throws {
        try cancel.check()
        let binary = URL(fileURLWithPath: settings.whisperPath)
        let vad = settings.vadModelPath.isEmpty ? nil : URL(fileURLWithPath: settings.vadModelPath)
        let engine = try NativeWhisperEngine(binary: binary, model: URL(fileURLWithPath: settings.modelPath), vad: vad, threads: settings.liveThreads, check: cancel.check)
        let verifier = settings.profile == .verified
            ? try NativeWhisperEngine(binary: binary, model: URL(fileURLWithPath: settings.verificationModelPath), vad: vad, threads: settings.liveThreads, check: cancel.check) : nil
        if let verifier, engine.metadata["model_sha256"] == verifier.metadata["model_sha256"] {
            throw SessionError.invalid("Verification requires two distinct model checksums")
        }
        try AudioJob(engine: engine, verifier: verifier, preparer: NativeAudioPreparer()).run(source: source, output: output,
            options: AudioJobOptions(sourceLanguage: settings.sourceLanguage,
                targetLanguage: settings.mode == .verbatim ? nil : settings.targetLanguage, mode: settings.mode.textMode,
                profile: settings.profile.rawValue), check: cancel.check)
    }
    static func seconds(since start: ContinuousClock.Instant) -> Double {
        let elapsed = start.duration(to: .now).components
        return Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18
    }
}
