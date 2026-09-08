import Foundation

extension AppSettings.Values {
    /// Shared by settings and job preflight. Never silently downgrade a verified job.
    nonisolated var verificationIssue: String? {
        guard profile == .verified else { return nil }
        guard !verificationModelPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return "Choose a second Whisper model in Settings → Transcription. Two-model comparison requires a different verification model."
        }
        let primary = URL(fileURLWithPath: modelPath).standardizedFileURL.resolvingSymlinksInPath()
        let verification = URL(fileURLWithPath: verificationModelPath).standardizedFileURL.resolvingSymlinksInPath()
        if primary == verification || sameFile(primary, verification) {
            return "The primary and verification models are the same. Choose a different verification model in Settings → Transcription, or explicitly select Single pass."
        }
        guard (try? verification.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true,
              FileManager.default.isReadableFile(atPath: verification.path) else {
            return "The verification model is missing or unreadable. Choose an installed Whisper model in Settings → Transcription."
        }
        return nil
    }

    // Catch hard links as well as symbolic links without hashing large models on the UI thread.
    private nonisolated func sameFile(_ first: URL, _ second: URL) -> Bool {
        guard let lhs = try? FileManager.default.attributesOfItem(atPath: first.path),
              let rhs = try? FileManager.default.attributesOfItem(atPath: second.path),
              let leftFile = lhs[.systemFileNumber] as? NSNumber,
              let rightFile = rhs[.systemFileNumber] as? NSNumber,
              let leftVolume = lhs[.systemNumber] as? NSNumber,
              let rightVolume = rhs[.systemNumber] as? NSNumber else { return false }
        return leftFile == rightFile && leftVolume == rightVolume
    }
}
