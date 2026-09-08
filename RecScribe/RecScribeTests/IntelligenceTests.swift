import Foundation
import RecScribeCore
import Testing
@testable import RecScribe

@MainActor struct IntelligenceTests {
    @Test func outdatedPipelineRequiresExplicitSetup() {
        for version in ["0.1.0", "garbage", "", "0.2.0\nwarning"] { #expect(!PipelineRuntime.supportsTextActions(version)) }
        for version in ["0.2.0", "0.2.1", "0.10.0", "1.0.0"] { #expect(PipelineRuntime.supportsTextActions(version)) }
    }
    @Test("Signed Data Protection Keychain round trip", .enabled(if: ProcessInfo.processInfo.environment["HR_KEYCHAIN_TEST"] == "1"))
    func signedKeychainRoundTrip() throws {
        let store = KeychainIntelligenceSecret(service: "com.moreaki.recscribe.integration-test.\(UUID())")
        #expect(try store.load() == nil)
        try store.save("synthetic-secret")
        defer { try? store.remove() } // Only the uniquely named item created here.
        #expect(try store.load() == "synthetic-secret")
        try store.save("synthetic-updated")
        #expect(try store.load() == "synthetic-updated")
        try store.remove()
        #expect(try store.load() == nil)
    }
    @MainActor final class MemorySecret: IntelligenceSecretStore {
        var value: String?
        func load() throws -> String? { value }
        func save(_ value: String) throws { self.value = value }
        func remove() throws { value = nil }
    }

    @Test func credentialsAreExplicitValidatedAndNeverPreferences() throws {
        let store = MemorySecret(), credentials = IntelligenceCredentials(secrets: MemorySecret())
        #expect(throws: (any Error).self) { try credentials.key() }
        let subject = IntelligenceCredentials(secrets: store)
        subject.save("bad\nkey")
        #expect(store.value == nil)
        subject.save(" synthetic-secret ")
        #expect(try subject.key() == Data("synthetic-secret".utf8))
        subject.remove()
        #expect(store.value == nil)
        let defaults = try JSONEncoder().encode(AppSettings.Values())
        #expect(!String(decoding: defaults, as: UTF8.self).contains("synthetic-secret"))
    }

    private struct NativeModels: IntelligenceTransport {
        let waits: Bool
        func send(_ request: URLRequest, maximumBytes: Int) async throws -> Data {
            if waits { try await Task.sleep(for: .seconds(30)) }
            return Data(#"{"data":[{"id":"synthetic-text-model"},{"id":"gpt-realtime-whisper"}]}"#.utf8)
        }
    }
    @Test func connectionTestingDoesNotRequireAnyPythonConfiguration() async {
        let store = MemorySecret(); store.value = "synthetic-key"
        let credentials = IntelligenceCredentials(secrets: store, client: .init(transport: NativeModels(waits: false)))
        credentials.test()
        await waitUntil("native model discovery") { !credentials.busy }
        #expect(credentials.models == ["synthetic-text-model"])
        #expect(credentials.status.hasPrefix("Connected"))
        #expect(store.value == "synthetic-key")
    }
    @Test func connectionCancellationDoesNotPublishStaleModels() async {
        let store = MemorySecret(); store.value = "synthetic-key"
        let credentials = IntelligenceCredentials(secrets: store, client: .init(transport: NativeModels(waits: true)))
        credentials.test()
        credentials.cancel()
        await waitUntil("native connection cancellation") { !credentials.busy }
        #expect(credentials.models.isEmpty)
        #expect(credentials.status == "Connection test cancelled")
    }

    @Test func textRequestsSnapshotSettingsAndSeparateCloudFromAudio() throws {
        var settings = AppSettings.Values()
        let source = URL(fileURLWithPath: "/synthetic/transcript.json")
        #expect(throws: (any Error).self) { try TextProcessingRequest(transcript: source, settings: settings, summary: true) }
        settings.aiEnabled = true; settings.aiProvider = .openai; settings.openaiModel = "chosen-model"
        let request = try TextProcessingRequest(transcript: source, settings: settings, summary: false)
        settings.openaiModel = "later-selection"
        let options = request.options(cloudConsent: true)
        #expect(request.settings.mode == .normalize)
        #expect(request.model == "chosen-model")
        #expect(options.cloudConsent)
        #expect(options.provider == .openai)
        #expect(options.mode == .normalize)
        let summary = try TextProcessingRequest(transcript: source, settings: settings, summary: true)
        #expect(summary.settings.mode == .verbatim)
        settings.aiProvider = .ollama; settings.ollamaModel = "local-model"
        let local = try TextProcessingRequest(transcript: source, settings: settings, summary: false)
        #expect(local.options(cloudConsent: false).provider == .ollama)
        #expect(!local.options(cloudConsent: false).cloudConsent)
    }

    @Test func cloudTextRequestWaitsForConfirmationWithoutLaunchingJob() throws {
        var settings = AppSettings.Values()
        settings.aiEnabled = true; settings.aiProvider = .openai; settings.openaiModel = "synthetic"
        let library = SessionLibrary(settings: { settings })
        library.requestTextProcessing(URL(fileURLWithPath: "/synthetic-job"), summary: true)
        #expect(library.pendingTextRequest?.isCloud == true)
        #expect(!library.busy)
        #expect(library.latestJob == nil)
        library.pendingTextRequest = nil
        #expect(library.latestJob == nil)
    }

    @Test func vadHeaderRejectsRecognitionModelsAndTruncation() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        let prefix = Data([0x6c, 0x6d, 0x67, 0x67, 10, 0, 0, 0]) + Data("silero-16k".utf8)
        for bytes in [Data(), Data("ggml-asr".utf8), prefix] {
            try bytes.write(to: file)
            #expect(throws: (any Error).self) { try VADModel.validate(file.path) }
        }
        var header = prefix
        for value: UInt32 in [6, 2, 0, 512, 64, 4] {
            var word = value.littleEndian
            withUnsafeBytes(of: &word) { header.append(contentsOf: $0) }
        }
        try header.write(to: file)
        try VADModel.validate(file.path)
        try VADModel.validate("")
    }

    @Test func privateInputIsPipedAndNotRetainedInDiagnostics() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let runner = LocalProcessRunner(diagnosticsDirectory: root)
        let result = try runner.execute(URL(fileURLWithPath: "/usr/bin/wc"), ["-c"], cancel: WorkCancellation(), privateInput: Data("synthetic-secret".utf8))
        #expect(result.exitCode == 0)
        #expect(result.output.trimmingCharacters(in: .whitespacesAndNewlines) == String("synthetic-secret".utf8.count))
        let diagnostic = try Data(contentsOf: #require(result.diagnostics))
        #expect(!String(decoding: diagnostic, as: UTF8.self).contains("synthetic-secret"))
        #expect(throws: (any Error).self) {
            try runner.execute(URL(fileURLWithPath: "/usr/bin/wc"), [], cancel: WorkCancellation(), privateInput: Data(count: 2049))
        }
    }
}
