import Foundation
import Testing
@testable import RecScribe

@MainActor
struct RuntimeAvailabilityTests {
    private func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    private func executable(_ url: URL) throws {
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    }
    private func sparseFile(_ url: URL, bytes: Int64) throws {
        try Data().write(to: url)
        let file = try FileHandle(forWritingTo: url)
        defer { try? file.close() }
        try file.truncate(atOffset: UInt64(bytes))
    }

    @Test func configuredExecutableWinsAndSymlinkedDiscoveryIncludesFFmpegVersion() throws {
        let directory = try folder(); defer { try? FileManager.default.removeItem(at: directory) }
        let binary = directory.appendingPathComponent("custom-ffmpeg")
        try executable(binary)
        let link = directory.appendingPathComponent("ffmpeg")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: binary)
        try executable(directory.appendingPathComponent("whisper-cli"))
        try executable(directory.appendingPathComponent("ollama"))
        var values = AppSettings.Values()
        values.ffmpegPath = binary.path
        let paths = RuntimeAvailability.Paths(values)
        let snapshot = try RuntimeAvailability.scan(paths: paths, support: directory, cancel: WorkCancellation(), directories: [directory.path], probe: { path, args in
            guard path == binary.path, args == ["-version"] else { throw SessionError.invalid("Unexpected probe") }
            return "ffmpeg version 9.0.2 Copyright\nbuild details"
        })
        #expect(snapshot.tools[.ffmpeg]?.path == binary.path)
        #expect(snapshot.tools[.ffmpeg]?.version == "9.0.2")
        #expect(snapshot.tools[.ffmpeg]?.issue == nil)
        #expect(snapshot.tools[.whisperCPP] != nil)
        #expect(snapshot.tools[.ollama] != nil)
        values.ffmpegPath = "/missing/custom-ffmpeg"
        #expect(RuntimeAvailability.toolPath(.ffmpeg, paths: .init(values), directories: [directory.path]) == link.path)
        #expect(!RuntimeAvailability.executable(directory.path))
    }

    @Test func failedVersionProbeStillRetainsPresenceAndRecordingScanRunsNoProcesses() throws {
        let directory = try folder(); defer { try? FileManager.default.removeItem(at: directory) }
        let binary = directory.appendingPathComponent("ffmpeg"); try executable(binary)
        let paths = RuntimeAvailability.Paths(AppSettings.Values())
        let failure = try RuntimeAvailability.scan(paths: paths, support: directory, cancel: WorkCancellation(), directories: [directory.path], probe: { _, _ in throw SessionError.invalid("Timeout") })
        #expect(failure.tools[.ffmpeg]?.path == binary.path)
        #expect(failure.tools[.ffmpeg]?.version == nil)
        #expect(failure.tools[.ffmpeg]?.issue != nil)
        let passive = try RuntimeAvailability.scan(paths: paths, support: directory, cancel: WorkCancellation(), directories: [directory.path], probeVersions: false, probe: { _, _ in
            throw SessionError.invalid("Probe must not run during recording")
        })
        #expect(passive.tools[.ffmpeg]?.path == binary.path)
        #expect(passive.tools[.ffmpeg]?.issue == nil)
        let cancelled = WorkCancellation(); cancelled.cancel()
        #expect(throws: CancellationError.self) { try RuntimeAvailability.scan(paths: paths, support: directory, cancel: cancelled, directories: []) }
    }

    @Test func modelsIncludeExistingIncompleteFilesAndExternalSelectionsWithoutHashClaims() throws {
        let directory = try folder(); defer { try? FileManager.default.removeItem(at: directory) }
        let managed = directory.appendingPathComponent("Models")
        try FileManager.default.createDirectory(at: managed, withIntermediateDirectories: true)
        let model = WhisperModel.catalog[0]
        let incomplete = managed.appendingPathComponent(model.filename)
        try sparseFile(incomplete, bytes: 10)
        var paths = RuntimeAvailability.Paths(AppSettings.Values())
        #expect(RuntimeAvailability.model(model, paths: paths, support: directory)?.expectedSize == false)
        try FileManager.default.removeItem(at: incomplete)
        let external = directory.appendingPathComponent("my-model.bin")
        try sparseFile(external, bytes: model.bytes)
        paths.model = external.path
        #expect(RuntimeAvailability.model(model, paths: paths, support: directory)?.path == external.path)
        #expect(RuntimeAvailability.model(model, paths: paths, support: directory)?.expectedSize == true)
        try sparseFile(incomplete, bytes: 10)
        #expect(RuntimeAvailability.model(model, paths: paths, support: directory)?.path == external.path)
        try FileManager.default.removeItem(at: incomplete)
        #expect(RuntimeAvailability.model(WhisperModel.catalog[1], paths: paths, support: directory) == nil)
        try FileManager.default.removeItem(at: external)
        #expect(RuntimeAvailability.model(model, paths: paths, support: directory) == nil)
    }

    @Test func pipelineProbeReportsVersionAndKeepsOutdatedRuntimeAvailableForExplicitReset() throws {
        let directory = try folder(); defer { try? FileManager.default.removeItem(at: directory) }
        let python = directory.appendingPathComponent("python3"); try executable(python)
        var paths = RuntimeAvailability.Paths(AppSettings.Values()); paths.python = python.path
        for version in ["0.2.3", "0.1.0"] {
            let snapshot = try RuntimeAvailability.scan(paths: paths, support: directory, cancel: WorkCancellation(), directories: [], probe: { path, arguments in
                guard path == python.path, arguments.first == "-I" else { throw SessionError.invalid("Unexpected pipeline probe") }
                return version + "\n"
            })
            #expect(snapshot.tools[.pipeline]?.path == python.path)
            #expect(snapshot.tools[.pipeline]?.version == version)
            #expect((snapshot.tools[.pipeline]?.issue == nil) == (version == "0.2.3"))
        }
    }

    @Test func existingToolsAndExternalModelsBlockStaleInstallAndDownloadActions() async throws {
        let directory = try folder(); defer { try? FileManager.default.removeItem(at: directory) }
        let suite = "runtime-availability-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        let binary = directory.appendingPathComponent("ffmpeg"); try executable(binary)
        settings.values.ffmpegPath = binary.path
        let runtime = RuntimeManager(settings: settings)
        runtime.install(.ffmpeg)
        for _ in 0..<1000 where runtime.busy { try await Task.sleep(for: .milliseconds(5)) }
        #expect(!runtime.busy)
        #expect(runtime.status.contains("already available"))
        #expect(settings.values.ffmpegPath == binary.path)
        let model = WhisperModel.catalog[0]
        let external = directory.appendingPathComponent("custom-model.bin")
        try sparseFile(external, bytes: model.bytes)
        settings.values.modelPath = external.path
        runtime.download(model)
        for _ in 0..<1000 where runtime.busy { try await Task.sleep(for: .milliseconds(5)) }
        #expect(!runtime.busy)
        #expect(runtime.status.contains("local tiny model file was found"))
        #expect(settings.values.modelPath == external.path)
        settings.values.pythonPath = binary.path
        runtime.installPipeline()
        for _ in 0..<1000 where runtime.busy { try await Task.sleep(for: .milliseconds(5)) }
        #expect(runtime.status.contains("explicitly reinitialize"))
        runtime.forgetPipelineSelection()
        #expect(settings.values.pythonPath.isEmpty)
        #expect(FileManager.default.fileExists(atPath: binary.path))
        #expect(FileManager.default.fileExists(atPath: external.path))
    }

    @Test func detectedOllamaServiceWithNoModelsStillBlocksInstall() async throws {
        let suite = "runtime-service-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let runtime = RuntimeManager(settings: AppSettings(defaults: defaults), aiModels: { [] })
        runtime.detectAI()
        for _ in 0..<1000 where runtime.busy { try await Task.sleep(for: .milliseconds(5)) }
        #expect(runtime.localAIAvailable)
        #expect(runtime.localAIModels.isEmpty)
        runtime.install(.ollama)
        for _ in 0..<1000 where runtime.busy { try await Task.sleep(for: .milliseconds(5)) }
        #expect(runtime.status.contains("already available at 127.0.0.1"))
    }
}
