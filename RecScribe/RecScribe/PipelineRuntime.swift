import Foundation

/// The installed Python environment is separate from the signed app bundle.
/// Fail with an upgrade action instead of sending new arguments to an old CLI.
nonisolated enum PipelineRuntime {
    static let minimumVersion = "0.2.0"
    static let upgradeMessage = "Update the pipeline in Settings → Transcription → Set up isolated pipeline runtime. Existing environments and jobs are retained."
    static func supportsTextActions(_ version: String) -> Bool {
        version.range(of: #"^\d+\.\d+\.\d+$"#, options: .regularExpression) != nil
            && version.compare(minimumVersion, options: .numeric) != .orderedAscending
    }
    static func validate(_ python: String, cancel: WorkCancellation) throws {
        let output: String
        do {
            output = try LocalProcessRunner.run(URL(fileURLWithPath: python),
                ["-c", "from recscribe import __version__; print(__version__)"],
                in: FileManager.default.temporaryDirectory, cancel: cancel, timeout: 10)
        } catch is CancellationError { throw CancellationError() }
        catch { throw SessionError.invalid(upgradeMessage) }
        guard supportsTextActions(output.trimmingCharacters(in: .whitespacesAndNewlines)) else { throw SessionError.invalid(upgradeMessage) }
    }
}
