import Combine
import Foundation

/// The only composition root. Features receive dependencies, not global peers.
@MainActor
final class AppServices: ObservableObject {
    let settings: AppSettings
    let runtime: RuntimeManager
    let library: SessionLibrary
    let recorder: RecorderViewModel
    let live: LiveTranscription
    private var locationObservation: AnyCancellable?

    init() {
        let settings = AppSettings()
        let runtime = RuntimeManager(settings: settings)
        let repository = ManifestRepository()
        let defaults = UserDefaults.standard
        let library = SessionLibrary(cancelRuntime: { runtime.cancel() }, settings: { settings.values },
            readSessions: { try await repository.sessions(in: $0) }, readJob: { try await repository.job(at: $0) },
            initialJob: defaults.url(forKey: "workspace.lastJob"), initialSource: defaults.url(forKey: "workspace.lastSource"),
            rememberJob: { job, source in
                defaults.set(job, forKey: "workspace.lastJob"); defaults.set(source, forKey: "workspace.lastSource")
            })
        let live = LiveTranscription(settings: { settings.values })
        live.onBusyChange = { [weak library] in library?.setLiveWork($0) }
        live.onCloudTranscript = { [weak library] job, source in library?.acceptCloudTranscript(job, source: source) }
        runtime.isRecording = { [weak library] in (library?.recordingActive ?? false) || (library?.liveWorkActive ?? false) }
        let source = AudioSourceManager(), location = SaveLocationManager()
        let controller = RecordingController(saveLocation: location, audioSource: source, sessionLibrary: library, liveTranscription: live,
                                             storageOptions: { settings.values.storage })
        self.settings = settings
        self.runtime = runtime
        self.library = library
        self.live = live
        self.recorder = RecorderViewModel(controller: controller, saveLocation: location, audioSource: source)
        locationObservation = settings.$values.removeDuplicates {
            $0.processingLocation == $1.processingLocation && $0.cloudTranscriptionModel == $1.cloudTranscriptionModel
        }.dropFirst().sink { [weak live] _ in live?.configurationChanged() }
    }
}
