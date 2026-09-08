import Foundation
import Testing
@testable import RecScribe

@MainActor struct TranscriptionConfigurationTests {
    @Test func verificationRejectsMissingAndAliasedModelsWithoutChangingPreferences() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let primary = root.appendingPathComponent("primary.bin")
        let secondary = root.appendingPathComponent("secondary.bin")
        let symlink = root.appendingPathComponent("symlink.bin")
        let hardlink = root.appendingPathComponent("hardlink.bin")
        try Data("synthetic primary".utf8).write(to: primary)
        try Data("synthetic secondary".utf8).write(to: secondary)
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: primary)
        try FileManager.default.linkItem(at: primary, to: hardlink)
        var settings = AppSettings.Values()
        settings.modelPath = primary.path
        settings.profile = .verified
        #expect(settings.verificationIssue?.contains("Choose a second") == true)
        for path in [primary.path, root.path + "/./primary.bin", symlink.path, hardlink.path] {
            settings.verificationModelPath = path
            #expect(settings.verificationIssue?.contains("are the same") == true)
            #expect(settings.verificationModelPath == path)
            #expect(settings.profile == .verified)
        }
        for path in [root.appendingPathComponent("missing.bin").path, root.path] {
            settings.verificationModelPath = path
            #expect(settings.verificationIssue?.contains("missing or unreadable") == true)
        }
        settings.verificationModelPath = secondary.path
        #expect(settings.verificationIssue == nil)
        settings.profile = .fast
        for path in ["", primary.path, root.appendingPathComponent("missing.bin").path] {
            settings.verificationModelPath = path
            #expect(settings.verificationIssue == nil)
        }
    }

    @Test func invalidVerificationPreservesPreviousTranscriptBeforeLaunchingPython() async {
        var settings = AppSettings.Values()
        settings.profile = .verified
        settings.modelPath = "/synthetic/same-model.bin"
        settings.verificationModelPath = settings.modelPath
        let previous = URL(fileURLWithPath: "/synthetic/previous-job")
        let source = URL(fileURLWithPath: "/synthetic/previous.wav")
        let library = SessionLibrary(settings: { settings }, initialJob: previous, initialSource: source)
        library.transcribe(URL(fileURLWithPath: "/synthetic/new.wav"))
        await library.shutdown()
        #expect(library.errorMessage?.contains("are the same") == true)
        #expect(library.latestJob == previous)
        #expect(library.latestSource == source)
        #expect(library.previousJob == nil)
        #expect(library.progress == 1)
        #expect(!library.busy)
    }
}
