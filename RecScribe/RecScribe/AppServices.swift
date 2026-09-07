import Combine

/// The only composition root. Features receive dependencies, not global peers.
@MainActor
final class AppServices: ObservableObject {
    let settings: AppSettings
    let runtime: RuntimeManager
    let library: SessionLibrary
    let recorder: RecorderViewModel

    init() {
        let settings = AppSettings()
        let runtime = RuntimeManager(settings: settings)
        let repository = ManifestRepository()
        let library = SessionLibrary(cancelRuntime: { runtime.cancel() }, settings: { settings.values },
            readSessions: { try await repository.sessions(in: $0) }, readJob: { try await repository.job(at: $0) })
        runtime.isRecording = { [weak library] in library?.recordingActive ?? false }
        let source = AudioSourceManager(), location = SaveLocationManager()
        let controller = RecordingController(saveLocation: location, audioSource: source, sessionLibrary: library,
                                             storageOptions: { settings.values.storage })
        self.settings = settings
        self.runtime = runtime
        self.library = library
        self.recorder = RecorderViewModel(controller: controller, saveLocation: location, audioSource: source)
    }
}
