//
//  DiskSpace.swift
//  RecScribe
//
//  Guardrails so a forgotten or doomed recording can't silently fill the disk
//  or surprise the user. (BL-043)
//

import Foundation
import Darwin

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

    /// Currently available blocks, excluding space that would require purging.
    /// statfs avoids the costly capacity-for-important-usage service on the
    /// encoding queue. Failure is explicit; callers must not assume free space.
    nonisolated static func availableBytes(at url: URL) -> Int64? {
        let directory = url.deletingLastPathComponent()
        var info = statfs()
        guard statfs(directory.path, &info) == 0 else { return nil }
        let (bytes, overflow) = info.f_bavail.multipliedReportingOverflow(by: UInt64(info.f_bsize))
        guard !overflow else { return nil }
        return Int64(min(bytes, UInt64(Int64.max)))
    }
}
