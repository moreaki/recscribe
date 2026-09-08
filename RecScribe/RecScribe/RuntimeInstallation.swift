import Foundation

/// Filesystem and installer work is blocking and belongs on a utility worker.
/// No operation here is invoked without an explicit install/download action.
nonisolated enum RuntimeInstallation {
    enum Policy {
        static let toolDetection: TimeInterval = 120
        static let aiDetection: TimeInterval = 15
        static let homebrew: TimeInterval = 1800
        static let unpack: TimeInterval = 30
        static let virtualEnvironment: TimeInterval = 120
        static let packages: TimeInterval = 600
        static let diagnosticCharacters = 8_000
        static let downloadProgressShare = 0.95 // Remaining work verifies the model hash.
    }

    static func install(_ software: LocalSoftware, cancel: WorkCancellation) throws -> String {
        guard software != .pipeline, let brew = LocalToolDiscovery.executable("brew") else {
            throw SessionError.invalid("Install Homebrew from brew.sh first, then retry")
        }
        return try LocalProcessRunner.run(URL(fileURLWithPath: brew), ["install", software.rawValue],
            in: FileManager.default.temporaryDirectory, cancel: cancel, timeout: Policy.homebrew)
    }

    static func pipeline(archive: URL, support: URL, cancel: WorkCancellation) throws -> URL {
        try cancel.check()
        guard FileManager.default.fileExists(atPath: archive.path), let python = LocalToolDiscovery.executable("python3") else {
            throw SessionError.invalid("Python 3.12+ from Homebrew and bundled pipeline sources are required")
        }
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        let environment = support.appendingPathComponent("Pipeline-\(cancel.id)")
        let source = support.appendingPathComponent("pipeline-source-\(cancel.id)")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: source) }
        let executable = environment.appendingPathComponent("bin/python3")
        _ = try LocalProcessRunner.run(URL(fileURLWithPath: "/usr/bin/tar"), ["-xzf", archive.path, "-C", source.path],
            in: source, cancel: cancel, timeout: Policy.unpack)
        _ = try LocalProcessRunner.run(URL(fileURLWithPath: python), ["-m", "venv", environment.path],
            in: support, cancel: cancel, timeout: Policy.virtualEnvironment)
        _ = try LocalProcessRunner.run(executable, ["-m", "pip", "install", source.path],
            in: support, cancel: cancel, timeout: Policy.packages)
        try cancel.check()
        return executable
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
