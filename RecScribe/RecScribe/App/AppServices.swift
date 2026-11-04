import AppKit
import Combine
import Foundation

/// The only composition root. Features receive dependencies, not global peers.
@MainActor
final class AppServices {
    let settings: AppSettings
    let runtime: RuntimeManager
    let library: SessionLibrary
    let recorder: RecorderViewModel
    let audio: AudioServices
    let live: LiveTranscription
    let navigation = StudioNavigation()
    let overflowMenu: OverflowMenu
    private(set) var menuBarController: MenuBarController?
    private var locationObservation: AnyCancellable?

    init(defaults: UserDefaults = .standard, supportDirectory: URL = AppSettings.supportDirectory) {
        let settings = AppSettings(defaults: defaults)
        let audio = AudioServices(defaults: defaults)
        self.audio = audio
        let runtime = RuntimeManager(settings: settings)
        let repository = ManifestRepository()
        let library = SessionLibrary(cancelRuntime: { runtime.cancel() }, settings: { settings.values },
            readSessions: { try await repository.sessions(in: $0) }, readJob: { try await repository.job(at: $0) },
            initialJob: defaults.url(forKey: "workspace.lastJob"), initialSource: defaults.url(forKey: "workspace.lastSource"),
            rememberJob: { job, source in
                defaults.set(job, forKey: "workspace.lastJob"); defaults.set(source, forKey: "workspace.lastSource")
            }, jobsDirectory: supportDirectory.appendingPathComponent("Jobs", isDirectory: true))
        let live = LiveTranscription(liveRoot: supportDirectory.appendingPathComponent("Live", isDirectory: true),
                                     settings: { settings.values })
        live.onBusyChange = { [weak library] in library?.setLiveWork($0) }
        live.onCloudTranscript = { [weak library] job, source in library?.acceptCloudTranscript(job, source: source) }
        runtime.isRecording = { [weak library] in (library?.recordingActive ?? false) || (library?.liveWorkActive ?? false) }
        let source = AudioSourceManager(defaults: defaults), location = SaveLocationManager(defaults: defaults)
        let gate = CaptureSessionGate()
        let test = AudioTestController(source: source, levels: audio.levels, monitor: audio.monitor,
            gate: gate, playback: audio.makePlayback(), saveDirectory: { location.resolvedDirectory })
        test.onActivity = { [weak library] in library?.setRecording($0) }
        test.onRetained = { [weak library] in library?.load($0.deletingLastPathComponent()) }
        let controller = RecordingController(saveLocation: location, audioSource: source, sessionLibrary: library, liveTranscription: live,
                                             levels: audio.levels,
                                             monitor: audio.monitor,
                                             captureGate: gate,
                                             storageOptions: { settings.values.storage })
        self.settings = settings
        self.runtime = runtime
        self.library = library
        self.live = live
        let recorder = RecorderViewModel(controller: controller, saveLocation: location, audioSource: source,
                                         defaults: defaults, audio: audio, audioTest: test)
        self.recorder = recorder
        overflowMenu = OverflowMenu(onSelectSource: { [weak recorder] in recorder?.setCaptureSource($0) },
            onRequestPermission: { [weak recorder] in recorder?.openSystemSettings() },
            onRecoverRecordings: { [weak library] in
                library?.recoverUnfinalizedSessions(in: location.resolvedDirectory)
            })
        test.canStart = { [weak recorder] in
            guard let recorder else { return false }
            return recorder.state.allowsCaptureSourceChange && !recorder.installLocationBlocksRecording && !recorder.isFinalizingAfterFailure
        }
        locationObservation = settings.$values.removeDuplicates {
            $0.processingLocation == $1.processingLocation && $0.cloudTranscriptionModel == $1.cloudTranscriptionModel
        }.dropFirst().sink { [weak live] _ in live?.configurationChanged() }
    }

    func start() {
        guard menuBarController == nil else { return }
        menuBarController = MenuBarController(viewModel: recorder, live: live, actions: overflowMenu)
    }

    func makeOverflowMenu() -> NSMenu {
        menuBarController?.makeOverflowMenu() ?? overflowMenu.makeNSMenu()
    }

    func shutdown() async {
        menuBarController?.close()
        menuBarController = nil
        await recorder.audioTest?.close()
        if recorder.isRecording { await recorder.stopRecording() }
        await recorder.waitForFailureFinalization()
        await audio.shutdown()
        await live.shutdown()
        await library.shutdown()
        await runtime.shutdown()
    }
}
