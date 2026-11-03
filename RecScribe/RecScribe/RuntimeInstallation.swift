import Foundation

/// Filesystem and installer work is blocking and belongs on a utility worker.
/// No operation here is invoked without an explicit install/download action.
nonisolated enum RuntimeInstallation {
    enum Policy {
        static let toolDetection: TimeInterval = 120
        static let aiDetection: TimeInterval = 15
        static let homebrew: TimeInterval = 1800
        static let diagnosticCharacters = 8_000
        static let downloadProgressShare = 0.95 // Remaining work verifies the model hash.
    }

    static func install(_ software: LocalSoftware, cancel: WorkCancellation) throws -> String {
        guard let brew = LocalToolDiscovery.executable("brew") else {
            throw SessionError.invalid("Install Homebrew from brew.sh first, then retry")
        }
        return try LocalProcessRunner.run(URL(fileURLWithPath: brew), ["install", software.rawValue],
            in: FileManager.default.temporaryDirectory, cancel: cancel, timeout: Policy.homebrew)
    }

    static func modelDestination(_ model: WhisperModel, directory: URL, cancel: WorkCancellation) throws -> URL {
        try cancel.check()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        guard let free = DiskSpace.availableBytes(at: directory), free > model.bytes + DiskSpace.minimumBytesToRecord else {
            throw SessionError.diskFull
        }
        let destination = directory.appendingPathComponent(model.filename)
        guard !FileManager.default.fileExists(atPath: destination.path) else {
            throw SessionError.invalid("Model already exists; select its local file instead")
        }
        return destination
    }
}
