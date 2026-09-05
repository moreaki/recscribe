//
//  DiskSpace.swift
//  RecScribe
//
//  Guardrails so a forgotten or doomed recording can't silently fill the disk
//  or surprise the user. (BL-043)
//

import Foundation

enum DiskSpace {
    /// Minimum free space required to begin a recording (~8 min of WAV headroom
    /// at ~11.5 MB/min). Below this, starting is refused with a clear message.
    nonisolated static let minimumBytesToRecord: Int64 = 100 * 1024 * 1024  // 100 MB

    /// A single recording passing this length triggers a one-time warning.
    nonisolated static let longRecordingThreshold: TimeInterval = 30 * 60   // 30 minutes

    /// Whether there's enough free space to start a recording.
    nonisolated static func hasEnoughSpace(availableBytes: Int64) -> Bool {
        availableBytes >= minimumBytesToRecord
    }

    /// Available capacity (for important usage) on the volume holding `url`,
    /// or `nil` if it can't be determined.
    nonisolated static func availableBytes(at url: URL) -> Int64? {
        let directory = url.deletingLastPathComponent()
        let values = try? directory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
    }
}
