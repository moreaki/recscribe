import Darwin
import Foundation
import RecScribeCore

/// Native WAV/session transcription and canonical text tools share RecScribeCore.
@main struct RecScribeTextCLI {
    static func main() async {
        do {
            let arguments = Array(CommandLine.arguments.dropFirst())
            if arguments == ["--help"] || arguments.isEmpty { print(usage); return }
            let parsed = try Arguments(arguments)
            let task = Task { try await run(parsed) }
            let signals = [SIGINT, SIGTERM].map { number in
                signal(number, SIG_IGN)
                // main() creates this actor-isolated handler. Dispatch it on
                // the main executor while the recognition worker stays utility.
                let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
                source.setEventHandler { task.cancel() }
                source.resume()
                return source
            }
            defer { for source in signals { source.cancel() } }
            try await task.value
        } catch {
            FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8))
            exit(error is CancellationError ? 130 : 1)
        }
    }

    static func run(_ arguments: Arguments) async throws {
        let source = URL(fileURLWithPath: arguments.source)
        if arguments.command == "fit-accuracy" {
            guard let output = arguments.output else { throw CoreFailure("fit-accuracy requires --output NEW_ARTIFACT.json") }
            let work = Task.detached(priority: .utility) {
                let fd = Darwin.open(source.path, O_RDONLY | O_NONBLOCK | O_NOFOLLOW)
                guard fd >= 0 else { throw CoreFailure("Accuracy dataset is unavailable") }
                let file = FileHandle(fileDescriptor: fd, closeOnDealloc: true); defer { try? file.close() }
                var info = stat()
                guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
                      info.st_size >= 0, info.st_size <= 16 * 1_024 * 1_024 else {
                    throw CoreFailure("Accuracy dataset must be a regular file of at most 16 MiB")
                }
                let bytes = try file.read(upToCount: 16 * 1_024 * 1_024 + 1) ?? Data()
                guard bytes.count <= 16 * 1_024 * 1_024 else { throw CoreFailure("Accuracy dataset exceeds 16 MiB") }
                let dataset = try JSONDecoder().decode(PassageAccuracy.Dataset.self, from: bytes)
                let artifact = try PassageAccuracy.fit(dataset)
                let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                try Task.checkCancellation()
                try encoder.encode(artifact).write(to: URL(fileURLWithPath: output), options: .withoutOverwriting)
            }
            try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
            print("Research-only accuracy artifact saved; Studio percentages remain unavailable pending independent validation.")
            return
        }
        if arguments.command == "inspect-sound" {
            let work = Task.detached(priority: .utility) {
                try LocalSoundClassifier.assess(source) { try Task.checkCancellation() }
            }
            let report = try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            print(String(decoding: try encoder.encode(report), as: UTF8.self))
            return
        }
        if arguments.command == "benchmark" {
            guard let output = arguments.output else { throw CoreFailure("benchmark requires --output") }
            if arguments.whisperProfile != nil { _ = try loadWhisperProfile(arguments.whisperProfile) }
            guard let cli = Bundle.main.executableURL else { throw CoreFailure("Cannot locate the native CLI executable") }
            let work = Task.detached(priority: .utility) {
                if let experiment = arguments.experiment {
                    let transcriptionCLI = arguments.transcriptionCLI.map { URL(fileURLWithPath: $0) } ?? cli
                    return try BenchmarkExperiment.run(manifest: source, configuration: URL(fileURLWithPath: experiment),
                        output: URL(fileURLWithPath: output), cli: transcriptionCLI, dryRun: arguments.dryRun,
                        resumeFrom: arguments.resumeFrom.map { URL(fileURLWithPath: $0) }, resumeSHA256: arguments.resumeSHA256,
                        coordinator: arguments.transcriptionCLI == nil && arguments.resumeFrom == nil ? nil : cli)
                }
                return try CorpusBenchmark.run(manifest: source, output: URL(fileURLWithPath: output), cli: cli,
                    whisper: arguments.whisper.map { URL(fileURLWithPath: $0) },
                    model: arguments.model.map { URL(fileURLWithPath: $0) }, threads: arguments.threads, dryRun: arguments.dryRun,
                    whisperProfile: arguments.whisperProfile.map { URL(fileURLWithPath: $0) })
            }
            _ = try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
            print("Local benchmark saved in \(output)")
            return
        }
        if arguments.command == "transcribe" {
            guard let output = arguments.output, let binary = arguments.whisper, let model = arguments.model else {
                throw CoreFailure("transcribe requires --output, --whisper-cli and --model")
            }
            let work = Task.detached(priority: .utility) {
                let decoding = try loadWhisperProfile(arguments.whisperProfile)
                let engine = try NativeWhisperEngine(binary: URL(fileURLWithPath: binary), model: URL(fileURLWithPath: model),
                    vad: arguments.vad.map { URL(fileURLWithPath: $0) }, threads: arguments.threads, profile: decoding)
                let verifier = try arguments.verificationModel.map {
                    try NativeWhisperEngine(binary: URL(fileURLWithPath: binary), model: URL(fileURLWithPath: $0),
                        vad: arguments.vad.map { URL(fileURLWithPath: $0) }, threads: arguments.threads, profile: decoding)
                }
                if let verifier, engine.metadata["model_sha256"] == verifier.metadata["model_sha256"] {
                    throw CoreFailure("Verification requires two distinct model checksums")
                }
                return try AudioJob(engine: engine, verifier: verifier, preparer: NativeAudioPreparer()).run(
                    source: source, output: URL(fileURLWithPath: output),
                    options: .init(sourceLanguage: arguments.language, targetLanguage: arguments.target,
                        mode: arguments.mode, profile: arguments.profile, diarize: arguments.diarize))
            }
            let result = try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
            print("\(result.value["status"].string ?? "completed"); local audio evidence and exports retained in \(output)")
            return
        }
        if arguments.command == "render" {
            guard let output = arguments.output else { throw CoreFailure("--output is required") }
            let handle = try FileHandle(forReadingFrom: source)
            defer { try? handle.close() }
            let data = try handle.read(upToCount: TextJob.maximumTranscriptBytes + 1) ?? Data()
            guard data.count <= TextJob.maximumTranscriptBytes else { throw CoreFailure("Transcript exceeds size limit") }
            let document = try CanonicalTranscript(JSONDecoder().decode(JSONValue.self, from: data))
            let directory = URL(fileURLWithPath: output)
            guard mkdir(directory.path, 0o700) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            for (name, text) in TranscriptRenderer.render(document) {
                try Task.checkCancellation()
                try Data(text.utf8).write(to: directory.appendingPathComponent(name), options: .withoutOverwriting)
            }
            print("Validated transcript; deterministic exports written to \(directory.path)")
            return
        }
        guard let output = arguments.output, let provider = arguments.provider, let model = arguments.model else {
            throw CoreFailure("derive requires --output, --provider and --model")
        }
        guard provider != .openai || arguments.cloudConsent && arguments.keyStdin else {
            throw CoreFailure("OpenAI requires --allow-cloud-text and --key-stdin; audio is never sent")
        }
        let key = arguments.keyStdin ? try FileHandle.standardInput.read(upToCount: IntelligencePolicy().maximumKeyBytes + 1) : nil
        try await TextJob().run(source: source, output: URL(fileURLWithPath: output),
            options: .init(provider: provider, model: model, mode: arguments.mode, targetLanguage: arguments.target,
                summarize: arguments.summary, cloudConsent: arguments.cloudConsent), key: key)
        print("Text derivative complete; source evidence retained. Review generated text before use.")
    }

    static func loadWhisperProfile(_ path: String?) throws -> WhisperDecodingProfile {
        guard let path else { return .baseline }
        let file = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
        defer { try? file.close() }
        let bytes = try file.read(upToCount: 16_385) ?? Data()
        guard bytes.count <= 16_384 else { throw CoreFailure("Whisper experiment profile exceeds 16 KiB") }
        return try WhisperDecodingProfile(json: JSONDecoder().decode(JSONValue.self, from: bytes))
    }

    struct Arguments: Sendable {
        let command: String
        let source: String
        var output: String?, model: String?, target: String?
        var whisper: String?, verificationModel: String?, vad: String?, experiment: String?, whisperProfile: String?
        var resumeFrom: String?, resumeSHA256: String?, transcriptionCLI: String?
        var language = "auto", profile = "fast"
        var threads = NativeWhisperEngine.Policy.defaultThreads
        var diarize = false
        var provider: TextProvider?
        var mode: TextMode = .verbatim
        var summary = false, cloudConsent = false, keyStdin = false, dryRun = false
        init(_ args: [String]) throws {
            guard args.count >= 2, ["derive", "render", "transcribe", "benchmark", "inspect-sound", "fit-accuracy"].contains(args[0]) else { throw CoreFailure(usage) }
            command = args[0]; source = args[1]
            if command == "fit-accuracy" {
                guard args.count == 4, args[2] == "--output", !args[3].isEmpty else {
                    throw CoreFailure("fit-accuracy accepts only DATASET.json --output NEW_ARTIFACT.json; no inference, credentials or upload")
                }
                output = args[3]
                return
            }
            guard command != "inspect-sound" || args.count == 2 else {
                throw CoreFailure("inspect-sound accepts only a mono WAV path; no recognition, credentials or cloud options")
            }
            var index = 2
            while index < args.count {
                let flag = args[index]; index += 1
                switch flag {
                case "--summarize": summary = true
                case "--allow-cloud-text": cloudConsent = true
                case "--key-stdin": keyStdin = true
                case "--dry-run": dryRun = true
                case "--local-only": break // Native audio recognition is always local.
                default:
                    guard index < args.count else { throw CoreFailure("Missing option value") }
                    let value = args[index]; index += 1
                    switch flag {
                    case "--whisper-profile": whisperProfile = value
                    case "--experiment": experiment = value
                    case "--resume-from": resumeFrom = value
                    case "--resume-sha256": resumeSHA256 = value
                    case "--transcription-cli": transcriptionCLI = value
                    case "--output": output = value
                    case "--model": model = value
                    case "--whisper-cli": whisper = value
                    case "--verify-model": verificationModel = value
                    case "--vad-model": vad = value
                    case "--source-language": language = value
                    case "--profile":
                        guard ["fast", "accurate", "verified"].contains(value) else { throw CoreFailure("Profile must be fast, accurate or verified") }
                        profile = value
                    case "--threads":
                        guard let count = Int(value), NativeWhisperEngine.Policy.threadRange.contains(count) else { throw CoreFailure("Choose 1–4 transcription threads") }
                        threads = count
                    case "--diarize":
                        guard ["off", "auto"].contains(value) else { throw CoreFailure("Diarize must be off or auto (review-only, no speaker model)") }
                        diarize = value == "auto"
                    case "--formats":
                        guard Set(value.split(separator: ",")) == Set(["json","md","txt","srt","vtt"]) else { throw CoreFailure("Native jobs retain all five canonical export formats") }
                    case "--target-language": target = value
                    case "--provider":
                        guard let selected = TextProvider(rawValue: value) else { throw CoreFailure("Provider must be ollama or openai") }
                        provider = selected
                    case "--mode":
                        guard let selected = TextMode(rawValue: value) else { throw CoreFailure("Mode must be verbatim, normalize or translate") }
                        mode = selected
                    default: throw CoreFailure("Unknown option; use --help")
                    }
                }
            }
            guard provider != .ollama || !cloudConsent && !keyStdin else { throw CoreFailure("Local jobs do not accept cloud consent or credentials") }
            guard ["transcribe", "benchmark"].contains(command) || whisperProfile == nil else { throw CoreFailure("--whisper-profile is only for local recognition") }
            if experiment != nil && (whisperProfile != nil || whisper != nil || model != nil || threads != NativeWhisperEngine.Policy.defaultThreads) {
                throw CoreFailure("An experiment supplies its own binaries, models, threads and profiles")
            }
            guard command == "benchmark" || experiment == nil else { throw CoreFailure("--experiment is only for benchmark") }
            guard (resumeFrom == nil && resumeSHA256 == nil && transcriptionCLI == nil) || (command == "benchmark" && experiment != nil) else {
                throw CoreFailure("Checkpoint/retained transcription CLI options require benchmark --experiment")
            }
            guard (resumeFrom == nil) == (resumeSHA256 == nil), resumeFrom == nil || !dryRun else {
                throw CoreFailure("Resume requires --resume-from and --resume-sha256, without --dry-run")
            }
            guard command == "benchmark" || !dryRun else { throw CoreFailure("--dry-run is only for benchmark") }
            if command == "benchmark" {
                guard provider == nil, !cloudConsent, !keyStdin, !summary, verificationModel == nil, vad == nil,
                      mode == .verbatim, profile == "fast", !diarize, target == nil, language == "auto" else {
                    throw CoreFailure("benchmark uses corpus languages and verbatim fast local recognition; text/verification options are not supported")
                }
            }
            if command == "transcribe" {
                guard provider == nil, !cloudConsent, !keyStdin, !summary else { throw CoreFailure("Audio transcription is local. Use derive separately for AI text or summaries") }
                guard profile == "verified" ? verificationModel != nil : verificationModel == nil else { throw CoreFailure("Use --profile verified and --verify-model together") }
            }
        }
    }
    static let usage = """
    recscribe-text fit-accuracy reviewed-passages.json --output NEW_RESEARCH_ARTIFACT.json
    recscribe-text inspect-sound passage.wav
    recscribe-text benchmark corpus.json --output NEW_DIRECTORY [--dry-run]
      [--whisper-cli /path/to/whisper-cli --model /path/to/model.bin --threads 1..4]
      [--experiment /path/to/experiment.json] [--whisper-profile /path/to/profile.json]
      [--resume-from PRIOR_MATRIX_DIRECTORY --resume-sha256 SHA256 --transcription-cli /path/to/retained/recscribe-text]
    recscribe-text transcribe recording.wav|session.recscribe.json --output NEW_JOB
      --whisper-cli /path/to/whisper-cli --model /path/to/ggml-model.bin
      [--source-language auto|de-CH|en] [--threads 1..4] [--local-only]
      [--profile fast|accurate|verified] [--verify-model /path/to/second-model.bin]
      [--vad-model /path/to/silero.bin] [--diarize off|auto]
      [--whisper-profile /path/to/private-experiment-profile.json]
      [--mode verbatim|normalize|translate] [--target-language LANGUAGE]
      [--formats json,md,txt,srt,vtt]
    recscribe-text render transcript.json --output NEW_DIRECTORY
    recscribe-text derive transcript.json --output NEW_JOB --provider ollama|openai --model MODEL
      [--mode verbatim|normalize|translate] [--target-language LANGUAGE] [--summarize]
      [--allow-cloud-text --key-stdin]

    Native transcription requires no Python or FFmpeg. Normalize/translate remain pending
    until a separate derive action. No audio upload, model download or silent fallback.
    Cloud text requires explicit consent.
    API keys are read only from stdin, never command arguments. Ctrl-C cancels a running job.
    """
}
