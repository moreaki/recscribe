import Darwin
import Foundation

nonisolated enum DiskSpace {
    static let minimumBytesToRecord: Int64 = 104_857_600
    static let longRecordingThreshold: TimeInterval = 1_800
    static func hasEnoughSpace(availableBytes: Int64) -> Bool { availableBytes >= minimumBytesToRecord }
    static func availableBytes(at url: URL) -> Int64? {
        var volume = statfs()
        let path = url.deletingLastPathComponent().path
        guard statfs(path, &volume) == 0 else { return nil }
        let capacity = volume.f_bavail.multipliedReportingOverflow(by: UInt64(volume.f_bsize))
        if capacity.overflow { return nil }
        return Int64(clamping: capacity.partialValue)
    }
}
