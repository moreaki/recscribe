import Foundation
import Testing
@testable import RecScribe

@MainActor struct SaveLocationTests {
    @Test func preferenceResolutionFallsBackWithoutErasingTheChosenFolder() throws {
        let name = "save-contract-\(UUID())"
        let storage = try #require(UserDefaults(suiteName: name))
        defer { storage.removePersistentDomain(forName: name) }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let manager = SaveLocationManager(defaults: storage)
        let fallback = manager.resolvedDirectory
        #expect(manager.configuredDirectory == nil && !manager.isConfiguredLocationUnavailable)
        manager.setSaveDirectory(folder)
        #expect(manager.resolvedDirectory.path == folder.path)
        #expect(SaveLocationManager(defaults: storage).resolvedDirectory.path == folder.path)
        try FileManager.default.removeItem(at: folder)
        #expect(manager.resolvedDirectory == fallback && manager.isConfiguredLocationUnavailable)
        #expect(manager.configuredDirectory?.path == folder.path)
        try Data([1]).write(to: folder) // A file is not a usable recording directory.
        #expect(manager.resolvedDirectory == fallback && manager.isConfiguredLocationUnavailable)
        try FileManager.default.removeItem(at: folder)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: folder.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path) }
        #expect(manager.resolvedDirectory == fallback && manager.isConfiguredLocationUnavailable)
        manager.reset()
        #expect(manager.configuredDirectory == nil && manager.resolvedDirectory == fallback)
    }
    @Test func pathGenerationUsesTheChosenFolderAndPreservesExistingFiles() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let coordinator = RecordingController(captureManager: MockAudioCapturing(), audioRecorder: MockAudioFileWriting(),
            saveLocation: MockSaveLocationProviding(directory: folder), audioSource: MockAudioSourceProviding())
        let first = coordinator.generateFilePath()
        let sentinel = Data([1, 2, 3])
        try sentinel.write(to: first)
        let second = coordinator.generateFilePath()
        #expect(first != second)
        #expect(first.deletingLastPathComponent().path == folder.path)
        #expect(first.lastPathComponent.hasPrefix("recording_") && first.pathExtension == "wav")
        #expect(try Data(contentsOf: first) == sentinel)
    }
}
