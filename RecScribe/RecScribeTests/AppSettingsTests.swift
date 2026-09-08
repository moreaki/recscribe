import Foundation
import Testing
@testable import RecScribe

@MainActor
struct AppSettingsTests {
    @Test func nestedPreferencesRecoverPerFieldWithoutLosingUserChoices() throws {
        let data = Data(#"{"storage":{"maximumPartBytes":1048576,"archiveFormat":"flac","bitrateKbps":"bad","flacCompression":8},"modelPath":"/user/model","mode":"future","profile":"verified"}"#.utf8)
        let values = try JSONDecoder().decode(AppSettings.Values.self, from: data)
        #expect(values.storage.maximumPartBytes == 1_048_576)
        #expect(values.storage.archiveFormat == .flac)
        #expect(values.storage.bitrateKbps == RecordingStorageOptions().bitrateKbps)
        #expect(values.storage.flacCompression == 8)
        #expect(values.modelPath == "/user/model")
        #expect(values.mode == .verbatim)
        #expect(values.profile == .verified)
        #expect(values.migrationWarnings.count == 2)
        _ = try values.storage.validated()
        let roundTrip = try JSONDecoder().decode(AppSettings.Values.self, from: JSONEncoder().encode(values))
        #expect(roundTrip.storage == values.storage)
        #expect(roundTrip.migrationWarnings.isEmpty)
    }

    @Test func outOfRangePersistedStorageFallsBackIndependently() throws {
        let data = Data(#"{"storage":{"maximumPartBytes":9223372036854775807,"archiveFormat":"opus","bitrateKbps":9999,"flacCompression":-1},"pythonPath":"/user/python"}"#.utf8)
        let values = try JSONDecoder().decode(AppSettings.Values.self, from: data)
        _ = try values.storage.validated()
        #expect(values.storage.archiveFormat == .opus)
        #expect(values.pythonPath == "/user/python")
        #expect(values.migrationWarnings.count == 3)
        for cap in [RecordingStorageOptions.minimumPartBytes, RecordingStorageOptions.hardCap] {
            #expect(try RecordingStorageOptions.partBytes(mebibytes: Double(cap) / Double(RecordingStorageOptions.bytesPerMiB)) == cap)
        }
        #expect(throws: (any Error).self) { try RecordingStorageOptions.partBytes(mebibytes: 0) }
        #expect(throws: (any Error).self) { try RecordingStorageOptions.partBytes(mebibytes: 3585) }
    }

    @Test func defaultsPersistenceAndInvalidInputAreIndependentOfCheckout() throws {
        let name = "recscribe-settings-test-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = AppSettings(defaults: defaults)
        #expect(settings.values.modelPath.isEmpty)
        #expect(settings.values.pythonPath.isEmpty)
        settings.values.modelPath = "/explicit/model"
        settings.values.pythonPath = "/explicit/python"
        settings.setPartSizeMiB(1)
        settings.setPartSizeMiB(.nan)
        #expect(settings.validationMessage != nil)
        #expect(settings.values.storage.maximumPartBytes == RecordingStorageOptions.bytesPerMiB)
        let restored = AppSettings(defaults: defaults)
        #expect(restored.values.modelPath == "/explicit/model")
        #expect(restored.values.pythonPath == "/explicit/python")
        #expect(restored.values.storage == settings.values.storage)
    }

    @Test func discoveryHasDeterministicCandidatesAndNoPersistenceSideEffects() {
        let candidates = ["/first/bin", "/second/bin"]
        #expect(LocalToolDiscovery.executable("whisper-cli", directories: candidates, isExecutable: { $0 == "/second/bin/whisper-cli" }) == "/second/bin/whisper-cli")
        #expect(LocalToolDiscovery.executable("whisper-cli", directories: candidates, isExecutable: { _ in false }) == nil)
        #expect(AppSettings.Values().whisperPath.isEmpty)
    }
}
