// Optional visual artifacts: TEST_RUNNER_RECSCRIBE_SNAPSHOTS=/tmp/recscribe-previews
// These renderings support human review; they do not compare or replace frozen audio contracts.
import AppKit
import SwiftUI
import Testing
@testable import RecScribe

@MainActor
struct ReskinSnapshots {
    private static var outputDirectory: URL? {
        guard let path = ProcessInfo.processInfo.environment["RECSCRIBE_SNAPSHOTS"], !path.isEmpty else { return nil }
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        do { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
        catch { Issue.record("Cannot create visual artifact directory: \(error)"); return nil }
        return directory
    }

    private func makeViewModel(permission: PermissionStatus = .granted,
                               install: InstallLocation = .applications,
                               controller: MockRecordingControlling? = nil) -> RecorderViewModel {
        // The model owns its injected dependencies; no system audio or permission request is used.
        let harness = RecorderContractHarness(permission: permission, installation: install)
        if let controller {
            harness.cleanup()
            return RecorderViewModel(controller: controller, permissions: MockPermissionProviding(permission),
                clock: ManualClock(), saveLocation: harness.location, audioSource: harness.source,
                installLocation: MockInstallLocationProviding(install), defaults: harness.defaults)
        }
        harness.cleanup()
        return harness.model
    }

    private func write(_ name: String, size: CGSize, contrast: ColorSchemeContrast,
                       @ViewBuilder _ content: () -> some View) {
        guard let directory = Self.outputDirectory else { return }
        let root = content().frame(width: size.width, height: size.height)
            .background(WorkspaceStyle.background).preferredColorScheme(.dark)
            .studioTheme(contrast == .increased ? .highContrast : .standard)
        let surface = NSHostingView(rootView: root)
        surface.frame.size = size
        surface.appearance = NSAppearance(named: .darkAqua)
        let backing = NSWindow(contentRect: CGRect(origin: .zero, size: size),
            styleMask: .borderless, backing: .buffered, defer: false)
        backing.contentView = surface
        defer { backing.contentView = nil }
        backing.layoutIfNeeded()
        RunLoop.current.run(until: .now.addingTimeInterval(0.1))
        surface.layoutSubtreeIfNeeded()
        guard let bitmap = surface.bitmapImageRepForCachingDisplay(in: surface.bounds) else {
            Issue.record("No bitmap for visual artifact \(name)"); return
        }
        surface.cacheDisplay(in: surface.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else {
            Issue.record("PNG encoding failed for \(name)"); return
        }
        let suffix = contrast == .increased ? "-increased-contrast" : ""
        do { try png.write(to: directory.appendingPathComponent(name + suffix + ".png")) }
        catch { Issue.record("Cannot save visual artifact \(name): \(error)") }
    }

    @Test("Intelligence settings and actionable transcript workspace")
    func intelligenceWorkspace() throws {
        guard Self.outputDirectory != nil else { return }
        let suite = "recscribe-intelligence-snapshot-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        settings.values.aiEnabled = true
        settings.values.aiProvider = .openai
        settings.values.openaiModel = "your-selected-model"
        let runtime = RuntimeManager(settings: settings), recorder = makeViewModel()
        write("intelligence-openai-settings", size: AppWindow.settings.defaultSize, contrast: .standard) {
            ConfigurationView(section: .ai).environment(settings).environment(runtime)
                .environment(SessionLibrary()).environment(recorder)
        }
        for section in [TranscriptWorkspace.Section.transcript, .summary] {
            write("workspace-empty-\(section.rawValue)", size: CGSize(width: 700, height: 680), contrast: .standard) {
                TranscriptWorkspace(section: section).environment(LiveTranscription())
                    .environment(SessionLibrary())
            }
        }
    }

    @Test func transcriptReading() throws {
        guard Self.outputDirectory != nil else { return }
        let document = try ReadingFixtures.preview
        write("transcript-reading", size: CGSize(width: 680, height: 500), contrast: .standard) {
            TranscriptReadingView(document: document).padding(StudioSpacing.xl)
                .background(WorkspaceStyle.background).preferredColorScheme(.dark)
        }
        write("transcript-variants-expanded", size: CGSize(width: 680, height: 640), contrast: .standard) {
            TranscriptReadingView(document: document, expandedGroups: ["s3"]).padding(StudioSpacing.xl)
                .background(WorkspaceStyle.background).preferredColorScheme(.dark)
        }
        write("transcript-all-channels", size: CGSize(width: 680, height: 640), contrast: .standard) {
            TranscriptReadingView(document: document, mode: .channels).padding(StudioSpacing.xl)
                .background(WorkspaceStyle.background).preferredColorScheme(.dark)
        }
    }

    @Test func transcriptNavigation() {
        guard Self.outputDirectory != nil else { return }
        for section in TranscriptWorkspace.Section.allCases {
            for width: CGFloat in [560, 340, 220] {
                write("transcript-tabs-\(section.rawValue)-\(Int(width))", size: CGSize(width: width, height: 72), contrast: .standard) {
                    WorkspaceTabs(title: "Text view", selection: .constant(section)).padding(StudioSpacing.md)
                        .background(WorkspaceStyle.background).preferredColorScheme(.dark)
                }
            }
        }
        for section in SettingsSection.allCases {
            write("settings-tabs-\(section.rawValue)", size: CGSize(width: 720, height: 72), contrast: .standard) {
                WorkspaceTabs(title: "Settings", selection: .constant(section)).padding(StudioSpacing.md)
                    .background(WorkspaceStyle.background).preferredColorScheme(.dark)
            }
        }
    }

    @Test func processingLocationSettings() {
        guard Self.outputDirectory != nil else { return }
        let suite = "recscribe-cloud-settings-snapshot-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        let runtime = RuntimeManager(settings: settings)
        for location in ProcessingLocation.allCases {
            settings.values.processingLocation = location
            write("settings-\(location.rawValue)", size: AppWindow.settings.defaultSize, contrast: .standard) {
                ConfigurationView(section: .transcription).environment(settings).environment(runtime)
                    .environment(SessionLibrary()).environment(makeViewModel())
            }
        }
    }

    @Test func interruptedStudio() async {
        guard Self.outputDirectory != nil else { return }
        let suite = "recscribe-studio-snapshot-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        let controller = MockRecordingControlling(), library = SessionLibrary()
        let model = makeViewModel(controller: controller)
        await model.startRecording()
        model.duration = 40
        controller.emitStreamError("Synthetic sleep interruption")
        await model.waitForFailureFinalization()
        model.showError = false // Inspect the persistent state after dismissing the alert.
        let live = LiveTranscription(work: { _, output, cursor, _, _, _ in
            guard cursor < 40 else { return nil }
            let segments = cursor == 0 ? [LiveSegment(id: UUID(), startSeconds: 0, endSeconds: 20,
                channel: 0, language: "en", text: "This is a synthetic partial draft. Review the saved audio before using it.")] : []
            return LiveChunkResult(asrRuns: cursor == 0 ? 1 : 0, startFrame: cursor, endFrame: cursor + 20,
                availableFrames: 40, sampleRate: 1, durationSeconds: cursor == 0 ? 1.2 : 0.013,
                segments: segments, directory: output)
        })
        live.setEnabled(true)
        live.recordingStarted(URL(fileURLWithPath: "/synthetic.wav"))
        live.recordingStopped(needsReview: true)
        await waitUntil("synthetic draft drained") { !live.busy }
        for (name, size) in [("studio-interrupted", AppWindow.studio.defaultSize),
                             ("studio-interrupted-minimum", AppWindow.studio.minimumSize)] {
            write(name, size: size, contrast: .standard) {
                StudioView().environment(model).environment(live).environment(library).environment(settings)
            }
        }
        await live.shutdown()
        await library.shutdown()
    }


    @Test(arguments: [ColorSchemeContrast.standard, .increased])
    func transportAndRecoveryStates(contrast: ColorSchemeContrast) async {
        guard Self.outputDirectory != nil else { return }
        var states: [(String, RecorderViewModel)] = [
            ("ready", makeViewModel()), ("denied", makeViewModel(permission: .denied)),
            ("undetermined", makeViewModel(permission: .notDetermined)),
            ("translocated", makeViewModel(install: .translocated)),
            ("outside-applications", makeViewModel(install: .elsewhere(URL(fileURLWithPath: "/tmp/RecScribe.app"))))]
        let levels: [(String, Float)] = [("silence", 0), ("quiet", 0.05), ("loud", 0.6)]
        for (label, amplitude) in levels {
            let model = makeViewModel()
            await model.startRecording()
            model.waveformSamples = (0..<200).map { amplitude * abs(sin(Float($0) * 0.19)) }
            states.append((label, model))
        }
        let failedController = MockRecordingControlling()
        failedController.startError = PreviewFailure()
        let failed = makeViewModel(controller: failedController)
        await failed.startRecording()
        states.append(("error", failed))
        for (label, model) in states {
            write("window-" + label, size: CGSize(width: 450, height: 450), contrast: contrast) {
                RecorderView().environment(model)
            }
            // AppKit-hosted surfaces adapt their own palette; capture their standard presentation.
            if contrast == .standard {
                write("popover-" + label, size: CGSize(width: WorkspaceStyle.popoverWidth, height: 720), contrast: contrast) {
                    MenuBarPopoverView().environment(model)
                }
            }
            if model.isRecording { await model.stopRecording() }
        }
    }
    private struct PreviewFailure: LocalizedError {
        var errorDescription: String? { "Synthetic capture failure for visual review" }
    }

    @Test func onboardingAndInstallationAtAccessibleSizes() {
        guard Self.outputDirectory != nil else { return }
        for granted in [false, true] {
            let model = makeViewModel(permission: granted ? .granted : .notDetermined)
            for accessible in [false, true] {
                let suffix = "\(granted)-\(accessible)"
                write("onboarding-" + suffix, size: CGSize(width: 420, height: accessible ? 620 : 440), contrast: .standard) {
                    OnboardingView().environment(model).dynamicTypeSize(accessible ? .accessibility2 : .large)
                }
                write("installation-" + suffix, size: CGSize(width: 340, height: accessible ? 280 : 180), contrast: .standard) {
                    InstallLocationNoticeView(message: InstallLocation.translocated.explanation ?? "",
                        onReveal: {}, onDismiss: {}).dynamicTypeSize(accessible ? .accessibility2 : .large)
                }
            }
        }
    }
}
