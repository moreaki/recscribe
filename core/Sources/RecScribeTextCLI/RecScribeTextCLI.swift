import Darwin
import Foundation
import RecScribeCore

/// Text-only companion during migration. WAV/ASR stays in the existing reference CLI until parity.
@main struct RecScribeTextCLI {
    static func main() async {
        do {
            let arguments = Array(CommandLine.arguments.dropFirst())
            if arguments == ["--help"] || arguments.isEmpty { print(usage); return }
            let parsed = try Arguments(arguments)
            let task = Task { try await run(parsed) }
            let signals = [SIGINT, SIGTERM].map { number in
                signal(number, SIG_IGN)
                let source = DispatchSource.makeSignalSource(signal: number, queue: .global(qos: .utility))
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

    struct Arguments: Sendable {
        let command: String
        let source: String
        var output: String?, model: String?, target: String?
        var provider: TextProvider?
        var mode: TextMode = .verbatim
        var summary = false, cloudConsent = false, keyStdin = false
        init(_ args: [String]) throws {
            guard args.count >= 2, ["derive", "render"].contains(args[0]) else { throw CoreFailure(usage) }
            command = args[0]; source = args[1]
            var index = 2
            while index < args.count {
                let flag = args[index]; index += 1
                switch flag {
                case "--summarize": summary = true
                case "--allow-cloud-text": cloudConsent = true
                case "--key-stdin": keyStdin = true
                default:
                    guard index < args.count else { throw CoreFailure("Missing option value") }
                    let value = args[index]; index += 1
                    switch flag {
                    case "--output": output = value
                    case "--model": model = value
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
        }
    }
    static let usage = """
    recscribe-text render transcript.json --output NEW_DIRECTORY
    recscribe-text derive transcript.json --output NEW_JOB --provider ollama|openai --model MODEL
      [--mode verbatim|normalize|translate] [--target-language LANGUAGE] [--summarize]
      [--allow-cloud-text --key-stdin]

    No audio upload, automatic model download or fallback. Cloud text requires explicit consent.
    API keys are read only from stdin, never command arguments. Ctrl-C cancels a running job.
    """
}
