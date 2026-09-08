import Combine
import Foundation
import os

nonisolated enum LiveTranscriptionPolicy {
    static let chunkChoices = [10, 20, 30]
    static let defaultChunkSeconds = 20
    static let overlapSeconds = 1
    static let threadRange = 1...4
    static let defaultThreads = 2
    static let sampleRate = 16_000
    static let conversionFrames = 4_096
    static let previewSegments = 80
    static let previewCharacters = 48_000
    static let maximumResultBytes = 4 * 1_024 * 1_024
    static let timeout: TimeInterval = 300
    static let pollInterval: Duration = .seconds(1)
}

nonisolated struct LiveSegment: Codable, Identifiable, Sendable, Equatable {
    let id: UUID
    let startSeconds: Double
    let endSeconds: Double
    let channel: Int
    let language: String?
    let text: String
}

nonisolated struct LiveChunkResult: Codable, Sendable {
    var schemaVersion = 1
    var needsReview = true
    var engine = "whisper.cpp"
    var sourceManifest: URL?
    var model: String?
    let startFrame: Int64
    let endFrame: Int64
    let availableFrames: Int64
    let sampleRate: Int
    let durationSeconds: Double
    let segments: [LiveSegment]
    let directory: URL
}

/// Owns one serial utility worker. Turning off never stops recording; turning
/// back on catches up from the last committed cursor, including audio recorded
/// before opt-in. The retained UI preview is bounded; raw chunks stay on disk.
@MainActor
final class LiveTranscription: ObservableObject {
    @Published private(set) var enabled = false
    @Published private(set) var busy = false
    @Published private(set) var status = "Live transcription is off"
    @Published private(set) var segments: [LiveSegment] = []
    @Published private(set) var errorMessage: String?
    @Published private(set) var directory: URL?
    @Published private(set) var lagSeconds = 0.0
    @Published private(set) var lastChunkSeconds = 0.0
    private(set) var cursor: Int64 = 0
    private var manifest: URL?
    private var capturing = false
    private var generation = UUID()
    private var task: Task<Void, Never>?
    private var token: WorkCancellation?
    private let settings: () -> AppSettings.Values
    private let work: @Sendable (URL, URL, Int64, Bool, AppSettings.Values, WorkCancellation) async throws -> LiveChunkResult?
    private let wait: @Sendable () async throws -> Void
    var onBusyChange: (Bool) -> Void = { _ in }

    init(settings: @escaping () -> AppSettings.Values = { .init() },
         work: @escaping @Sendable (URL, URL, Int64, Bool, AppSettings.Values, WorkCancellation) async throws -> LiveChunkResult? = { source, output, cursor, final, settings, token in
             try await Task.detached(priority: .utility) {
                 try LiveWhisperTranscriber.step(manifest: source, directory: output, cursor: cursor,
                                                 finished: final, settings: settings, cancel: token)
             }.value
         }, wait: @escaping @Sendable () async throws -> Void = { try await Task.sleep(for: LiveTranscriptionPolicy.pollInterval) }) {
        self.settings = settings
        self.work = work
        self.wait = wait
    }

    func setEnabled(_ value: Bool) {
        enabled = value
        errorMessage = nil
        if value { status = capturing ? "Waiting for a complete audio chunk…" : "Armed for the next recording"; start() }
        else { invalidate(); status = "Live transcription is off · audio is still recorded" }
    }

    func recordingStarted(_ audio: URL) {
        invalidate()
        manifest = RecordingSession.manifestURL(for: audio)
        directory = AppSettings.supportDirectory.appendingPathComponent("Live/\(UUID())", isDirectory: true)
        cursor = 0
        segments = []
        lagSeconds = 0
        capturing = true
        errorMessage = nil
        if enabled { status = "Waiting for a complete audio chunk…"; start() }
    }

    func recordingStopped() {
        capturing = false
        if enabled { status = "Finishing remaining audio chunks…"; start() }
    }

    func shutdown() async {
        enabled = false
        invalidate()
        await task?.value
    }

    private func invalidate() {
        generation = UUID()
        token?.cancel()
        task?.cancel()
    }

    private func start() {
        guard enabled, task == nil, let manifest, let directory else { return }
        let id = generation, token = WorkCancellation(), values = settings(), work = work, wait = wait
        self.token = token
        busy = true
        onBusyChange(true)
        task = Task { [weak self] in
            do {
                while let self, enabled, generation == id {
                    let final = !capturing, position = cursor
                    let result = try await work(manifest, directory, position, final, values, token)
                    try token.check()
                    guard generation == id else { break }
                    if let result {
                        guard result.startFrame == position, result.endFrame > position, result.sampleRate > 0 else {
                            throw SessionError.invalid("Invalid live transcription cursor")
                        }
                        cursor = result.endFrame
                        segments = Self.preview(segments + result.segments)
                        lastChunkSeconds = result.durationSeconds
                        lagSeconds = Double(max(0, result.availableFrames - cursor)) / Double(result.sampleRate)
                        status = capturing ? "Live draft · \(Int(lagSeconds)) s queued at last snapshot" : "Finishing live draft…"
                    } else if final {
                        status = "Live draft ready · verify before use"
                        break
                    } else { try await wait() }
                }
            } catch is CancellationError { }
            catch {
                if let self, generation == id {
                    errorMessage = error.localizedDescription
                    status = "Live transcription needs attention · recording is unaffected"
                    enabled = false
                }
            }
            guard let self else { return }
            task = nil
            self.token = nil
            busy = false
            onBusyChange(false)
            if generation != id { start() } // A cancelled worker must exit before a replacement starts.
        }
    }

    static func preview(_ values: [LiveSegment]) -> [LiveSegment] {
        var count = 0
        return Array(values.suffix(LiveTranscriptionPolicy.previewSegments).reversed().prefix { value in
            count += value.text.count
            return count <= LiveTranscriptionPolicy.previewCharacters
        }.reversed())
    }
}
