import Darwin
import Foundation
import os

nonisolated struct LiveCleanupFailure: Sendable, Equatable {
    enum Operation: String, Sendable { case stat, enumerate, unlink }
    let url: URL
    let operation: Operation
    let posixErrorCode: Int32?
    let message: String
}

nonisolated struct LiveCleanupReport: Sendable, Equatable {
    var removedFiles: [URL] = []
    var failures: [LiveCleanupFailure] = []
    var inspectedDraftDirectories = 0
    var inspectedEntries = 0
    var stoppedByLimit = false
    var cancelled = false
    var ranOnMainThread = false
}

/// Bounded, shallow scan of RecScribe's UUID/turn directories. Only generated
/// working WAVs are disposable; recordings, raw ASR and journals are never removed.
nonisolated enum LiveWorkingAudioCleanup {
    private static let logger = Logger(subsystem: "com.moreaki.recscribe", category: "LiveCleanup")

    static func isDisposable(_ name: String) -> Bool {
        name.wholeMatch(of: #/(working|(?:working-)?channel-[0-9]+|(?:asr|verify)-channel-[0-9]+-region-[0-9]+)\.wav/#) != nil
    }

    static func run(in root: URL, ownerUID: uid_t, maxDrafts: Int, maxEntries: Int,
                    isRetained: (URL) -> Bool, shouldCancel: () -> Bool) -> LiveCleanupReport {
        let started = ContinuousClock.now
        var report = LiveCleanupReport(ranOnMainThread: Thread.isMainThread)
        defer {
            let elapsed = started.duration(to: .now)
            logger.notice("Working audio cleanup entries=\(report.inspectedEntries) removed=\(report.removedFiles.count) failures=\(report.failures.count) limited=\(report.stoppedByLimit) cancelled=\(report.cancelled) elapsed=\(String(describing: elapsed), privacy: .public)")
        }

        func fail(_ url: URL, _ operation: LiveCleanupFailure.Operation) {
            let code = errno
            guard code != ENOENT else { return } // A worker may already have removed its temporary file.
            report.failures.append(.init(url: url, operation: operation, posixErrorCode: code,
                                         message: String(cString: strerror(code))))
            logger.error("Cleanup failed operation=\(operation.rawValue, privacy: .public) path=\(url.path, privacy: .private) errno=\(code)")
        }

        func stop() -> Bool {
            if shouldCancel() { report.cancelled = true }
            if report.inspectedEntries >= LiveTranscriptionPolicy.maximumCleanupEntries {
                report.stoppedByLimit = true
            }
            return report.cancelled || report.inspectedEntries >= LiveTranscriptionPolicy.maximumCleanupEntries
        }

        func owned(_ url: URL, type: mode_t) -> Bool {
            var info = stat()
            guard lstat(url.path, &info) == 0 else { fail(url, .stat); return false }
            return info.st_mode & S_IFMT == type && info.st_uid == ownerUID
        }

        func entries(_ url: URL, limit: Int) -> [URL] {
            guard !stop() else { return [] }
            guard let directory = opendir(url.path) else { fail(url, .enumerate); return [] }
            defer { closedir(directory) }
            var result: [URL] = []
            while !stop() {
                errno = 0
                guard let entry = readdir(directory) else {
                    if errno != 0 { fail(url, .enumerate) }
                    break
                }
                let name = withUnsafePointer(to: &entry.pointee.d_name) { pointer in
                    pointer.withMemoryRebound(to: CChar.self, capacity: Int(entry.pointee.d_namlen) + 1) {
                        String(cString: $0)
                    }
                }
                guard name != ".", name != ".." else { continue }
                report.inspectedEntries += 1
                guard result.count < max(0, limit) else { report.stoppedByLimit = true; break }
                // Hidden entries still count toward the global I/O budget.
                if !name.hasPrefix(".") { result.append(url.appendingPathComponent(name)) }
            }
            return result
        }

        func removeWorkingFiles(_ urls: [URL], draft: URL) {
            for file in urls where isDisposable(file.lastPathComponent) {
                guard !stop(), !isRetained(draft) else { return }
                guard owned(file, type: S_IFREG) else { continue }
                if unlink(file.path) == 0 { report.removedFiles.append(file) }
                else { fail(file, .unlink) }
            }
        }

        guard !stop(), owned(root, type: S_IFDIR) else { return report }
        for draft in entries(root, limit: maxDrafts) {
            guard !stop() else { break }
            guard UUID(uuidString: draft.lastPathComponent) != nil,
                  !isRetained(draft), owned(draft, type: S_IFDIR) else { continue }
            report.inspectedDraftDirectories += 1
            let children = entries(draft, limit: maxEntries)
            removeWorkingFiles(children, draft: draft)
            for attempt in children {
                guard !stop(), !isRetained(draft) else { break }
                let name = attempt.lastPathComponent
                guard UUID(uuidString: name) != nil || name.wholeMatch(of: #/turn-[0-9]+/#) != nil,
                      !isRetained(attempt), owned(attempt, type: S_IFDIR) else { continue }
                removeWorkingFiles(entries(attempt, limit: maxEntries), draft: draft)
            }
        }
        return report
    }
}
