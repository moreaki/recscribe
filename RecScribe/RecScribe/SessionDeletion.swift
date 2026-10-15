import Foundation

/// Keep the session together in Trash so restoring it also restores its audio.
nonisolated enum SessionDeletion {
    static func moveToTrash(_ manifest: URL, trash: (URL) throws -> Void = {
        try FileManager.default.trashItem(at: $0, resultingItemURL: nil)
    }) throws {
        let lease = try SessionLease(manifest)
        defer { withExtendedLifetime(lease) {} }
        let session = try RecordingSession.read(manifest)
        let manager = FileManager.default
        var files: [URL] = []
        for name in Set(session.parts.map(\.path) + session.artifacts.map(\.path)) {
            let file = try RecordingSession.safeURL(name, beside: manifest)
            // Incomplete recordings can reference parts that were never created.
            guard manager.fileExists(atPath: file.path) else { continue }
            let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true else {
                throw SessionError.invalid("Recording contains a non-file or symbolic link; inspect it in Finder before deleting")
            }
            if file.standardizedFileURL != manifest.standardizedFileURL { files.append(file) }
        }
        files.append(manifest)
        let name = manifest.lastPathComponent.replacingOccurrences(of: ".recscribe.json", with: "")
        let bundle = manifest.deletingLastPathComponent()
            .appendingPathComponent("\(name)-Deleted-\(UUID().uuidString)", isDirectory: true)
        try manager.createDirectory(at: bundle, withIntermediateDirectories: false)
        var moved: [URL] = []
        do {
            for file in files {
                try manager.moveItem(at: file, to: bundle.appendingPathComponent(file.lastPathComponent))
                moved.append(file)
            }
            try trash(bundle)
        } catch {
            let originalError = error
            var rollbackFailed = false
            for file in moved.reversed() {
                do { try manager.moveItem(at: bundle.appendingPathComponent(file.lastPathComponent), to: file) }
                catch { rollbackFailed = true }
            }
            if rollbackFailed {
                throw SessionError.invalid("Deletion failed. Some recording files remain in \(bundle.path). Restore them in Finder. \(originalError.localizedDescription)")
            }
            try? manager.removeItem(at: bundle)
            throw originalError
        }
    }
}
