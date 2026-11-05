import Foundation
import Testing
@testable import RecScribe

@MainActor struct AudioSourceManagerTests {
    @Test(arguments: [AudioSource.systemAll, .app(bundleID: "test.player"), .mic(deviceUID: "test.input")])
    func selectionIsReadThroughAndPersistedAcrossOwners(selection: AudioSource) throws {
        let identity = "source-contract-\(UUID())"
        let storage = try #require(UserDefaults(suiteName: identity))
        defer { storage.removePersistentDomain(forName: identity) }
        let first = AudioSourceManager(defaults: storage)
        #expect(first.selectedSource == .systemAll)
        first.setSelectedSource(selection)
        #expect(first.selectedSource == selection)
        #expect(AudioSourceManager(defaults: storage).selectedSource == selection)
    }
    @Test func systemValidationHasNoDiscoveryOrPermissionDependency() async throws {
        let identity = "source-validate-\(UUID())"
        let storage = try #require(UserDefaults(suiteName: identity))
        defer { storage.removePersistentDomain(forName: identity) }
        try await AudioSourceManager(defaults: storage).validate(.systemAll)
    }
    @Test func corruptPreferenceFallsBackWithoutDestroyingTheBlob() throws {
        let identity = "source-corrupt-\(UUID())"
        let storage = try #require(UserDefaults(suiteName: identity))
        defer { storage.removePersistentDomain(forName: identity) }
        let original = Data([0, 255, 7])
        storage.set(original, forKey: "selectedAudioSource")
        #expect(AudioSourceManager(defaults: storage).selectedSource == .systemAll)
        #expect(storage.data(forKey: "selectedAudioSource") == original)
    }
}
