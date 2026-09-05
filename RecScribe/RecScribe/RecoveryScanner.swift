//
//  RecoveryScanner.swift
//  RecScribe
//
//  BL-140: finds recordings that were never finalized — the ones a crash or
//  force-quit left behind. Detection itself belongs to each format (see
//  `AudioFileRecovery.swift`); this type only decides *which files to ask about*.
//

import Foundation

/// One recording the user could recover.
struct RecoverableRecording: Identifiable, Equatable {
    var id: URL { url }
    let url: URL
    let format: AudioFormat
    let byteCount: Int
    let modifiedAt: Date
    /// False when the file was interrupted so early that no audio reached disk —
    /// listed for honesty, but `recover` cannot help it.
    let isRepairable: Bool

    var displayName: String { url.lastPathComponent }
}

@MainActor
protocol RecoveryScanning {
    /// - Parameter excluding: the file currently being written, if any. A live
    ///   recording is unfinalized *by definition* and must never be offered.
    func scan(excluding inProgress: URL?) -> [RecoverableRecording]
}

@MainActor
final class RecoveryScanner: RecoveryScanning {

    private let saveLocation: SaveLocationProviding
    private let fileManager: FileManager

    init(saveLocation: SaveLocationProviding, fileManager: FileManager = .default) {
        self.saveLocation = saveLocation
        self.fileManager = fileManager
    }

    func scan(excluding inProgress: URL? = nil) -> [RecoverableRecording] {
        let directory = saveLocation.resolvedDirectory
        let contents = (try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
        )) ?? []

        let excluded = inProgress?.standardizedFileURL

        return contents.compactMap { url -> RecoverableRecording? in
            guard url.standardizedFileURL != excluded else { return nil }
            // Only files this app wrote. `generateFilePath` names every recording
            // `recording_<timestamp>`, optionally with a ` (n)` disambiguator.
            guard url.lastPathComponent.hasPrefix("recording_") else { return nil }
            guard let format = AudioFormat(rawValue: url.pathExtension.lowercased()),
                  let recovery = format.recovery else { return nil }

            // A file that can't be parsed is not evidence of a crash — it's just
            // not ours to reason about. Skip rather than surfacing noise.
            guard let unfinalized = try? recovery.isUnfinalized(at: url), unfinalized else { return nil }

            let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            return RecoverableRecording(
                url: url,
                format: format,
                byteCount: values?.fileSize ?? 0,
                modifiedAt: values?.contentModificationDate ?? .distantPast,
                isRepairable: (try? recovery.isRepairable(at: url)) ?? false
            )
        }
        .sorted { $0.modifiedAt > $1.modifiedAt }   // most recent first
    }

    /// Make one recording playable. Format-specific work happens behind the
    /// `AudioFileRecovering` seam; some formats (M4A) need no byte changes at all.
    static func recover(_ recording: RecoverableRecording) throws {
        guard let recovery = recording.format.recovery else {
            throw AudioFileRecoveryError.notRepairable
        }
        guard recording.isRepairable else { throw AudioFileRecoveryError.notRepairable }
        try recovery.repair(at: recording.url)
    }
}
